import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/feed_item.dart';
import '../data/rpc/client.dart';

/// `copyWith` sentinel: tells "leave this alone" apart from "set this to null".
///
/// Without it every nullable field is `value ?? this.value`, which cannot clear
/// anything — `continuation: null` on a fresh load silently kept the previous
/// feed's continuation, so paging after a filter switch would have fetched the
/// *old* filter's next page.
const Object _unchanged = Object();

class FeedState {
  /// Which feed this is — `feed.home` here, with `feed.subscriptions` and
  /// `feed.history` already specified in protocol.md §3.2.
  final String surface;

  /// The chip bar, per surface.
  ///
  /// Keyed rather than flat because the bar belongs to the surface: home's
  /// filters must not appear over subscriptions. It is a map today so that
  /// adding the second surface is a key, not a refactor.
  final Map<String, List<Chip>> chipBars;

  /// The filter in effect, as a chip token. `null` is unfiltered.
  ///
  /// Stored instead of a `Chip`, so a cached bar's `selected` flags — which are
  /// whatever the server said when the bar was fetched — can never contradict
  /// the filter actually applied.
  final String? selectedToken;

  final List<FeedItem> items;
  final String? continuation;
  final bool isLoading;
  final String? error;
  final bool isAuthDegraded;
  final bool isAnonymous;

  const FeedState({
    required this.surface,
    this.chipBars = const {},
    this.selectedToken,
    this.items = const [],
    this.continuation,
    this.isLoading = true,
    this.error,
    this.isAuthDegraded = false,
    this.isAnonymous = false,
  });

  /// This surface's chip bar. Derived, so no response path can blank it by
  /// forgetting to carry it forward — which is exactly how it used to vanish.
  List<Chip> get chips => chipBars[surface] ?? const [];

  Chip? get selectedChip => resolveSelectedChip(chips, selectedToken);

  FeedState copyWith({
    Map<String, List<Chip>>? chipBars,
    Object? selectedToken = _unchanged,
    List<FeedItem>? items,
    Object? continuation = _unchanged,
    bool? isLoading,
    Object? error = _unchanged,
    bool? isAuthDegraded,
    bool? isAnonymous,
  }) {
    return FeedState(
      surface: surface,
      chipBars: chipBars ?? this.chipBars,
      selectedToken:
          identical(selectedToken, _unchanged) ? this.selectedToken : selectedToken as String?,
      items: items ?? this.items,
      continuation:
          identical(continuation, _unchanged) ? this.continuation : continuation as String?,
      isLoading: isLoading ?? this.isLoading,
      error: identical(error, _unchanged) ? this.error : error as String?,
      isAuthDegraded: isAuthDegraded ?? this.isAuthDegraded,
      isAnonymous: isAnonymous ?? this.isAnonymous,
    );
  }
}

/// Which chip reads as selected, given the filter in effect.
///
/// The sidecar ships `selected` per chip — the feed's own idea of which filter
/// is active, which is "All" on an unfiltered load. With a token in effect the
/// token wins, because the cached bar's flags describe the moment it was
/// fetched, not the filter the user has since chosen.
///
/// Falls back to the first chip: "All" is first by construction, and an
/// anchored strip beats an unanchored one.
Chip? resolveSelectedChip(List<Chip> chips, String? token) {
  if (chips.isEmpty) return null;
  if (token != null) {
    return chips.firstWhere((c) => c.token == token, orElse: () => chips.first);
  }
  return chips.firstWhere((c) => c.selected, orElse: () => chips.first);
}

/// The one place a chip bar is written.
///
/// Only a base browse carries one: a continuation response has no `header` at
/// all — measured, `home-continuation.json` has no `contents` and zero
/// `chipCloudChipRenderer` — so a chip-filtered or paged response saying
/// nothing about the bar is the normal case, not a signal to clear it.
///
/// Feed-scope only. A continuation can still carry `scope: 'shelf'` chips from
/// shelves inside its own content (8 of them in that same capture); those are
/// an in-content filter, not the feed's, and putting them in this bar would
/// replace the filter strip with something unrelated — the original bug wearing
/// a different hat.
Map<String, List<Chip>> storeChipBar(
  Map<String, List<Chip>> bars,
  String surface,
  List<Chip> incoming, {
  required bool isBaseBrowse,
}) {
  if (!isBaseBrowse) return bars;
  final bar = incoming.where((c) => c.scope == 'feed').toList();
  if (bar.isEmpty) return bars;
  return {...bars, surface: bar};
}

class FeedController extends Notifier<FeedState> {
  static const String surface = 'home';

  /// Bumped by every request. A response whose generation is stale is dropped
  /// rather than merged: `$cancel` is best-effort and a response already on the
  /// wire cannot be recalled, so the guard is what actually holds the promise
  /// that one filter's page never lands in another filter's results.
  int _generation = 0;
  int? _inFlight;

  /// Completed when a newer request supersedes this one.
  ///
  /// A cancelled request's future never completes — the transport's contract —
  /// so awaiting it after `$cancel` would hang forever, and `loadHome()` would
  /// hang with it. Anything awaiting a refresh would then wait on a response
  /// that is never coming. Racing the response against this signal means a
  /// superseded `loadHome()` returns promptly and quietly.
  Completer<void>? _superseded;

  @override
  FeedState build() {
    Future.microtask(loadHome);
    return const FeedState(surface: surface);
  }

  Future<void> loadHome({String? chipToken, bool isLoadMore = false}) async {
    final generation = ++_generation;

    // Supersede whatever is in flight. Filtering fast while a load-more is
    // pending would otherwise append the old filter's next page to the new
    // filter's results.
    final previous = _inFlight;
    if (previous != null) {
      RpcClient.instance.cancel(previous);
      _inFlight = null;
    }
    if (_superseded?.isCompleted == false) _superseded!.complete();
    final superseded = _superseded = Completer<void>();

    if (isLoadMore) {
      state = state.copyWith(isLoading: true, error: null);
    } else {
      state = state.copyWith(
        isLoading: true,
        error: null,
        items: const [],
        continuation: null,
        selectedToken: chipToken,
        isAuthDegraded: false,
        isAnonymous: false,
      );
    }

    try {
      final params = <String, dynamic>{};
      if (chipToken != null) params['chipToken'] = chipToken;
      if (isLoadMore && state.continuation != null) {
        params['continuation'] = state.continuation;
      }

      final request = RpcClient.instance.callCancelable('feed.home', params);
      _inFlight = request.id;

      dynamic response;
      var answered = false;
      await Future.any<void>([
        request.response.then((value) {
          response = value;
          answered = true;
        }),
        superseded.future,
      ]);
      // Either a newer request took over while this one was on the wire, or it
      // landed anyway — `$cancel` cannot recall a response already sent, so the
      // generation is what actually decides.
      if (!answered || generation != _generation) return;
      _inFlight = null;

      // An empty feed is ambiguous — no recommendations, or a session the
      // server stopped honouring. Only `auth.verify` tells them apart.
      if ((response['items'] as List?)?.isEmpty == true && !isLoadMore && chipToken == null) {
        final authResponse = await RpcClient.instance.call('auth.verify', {});
        if (generation != _generation) return;
        final stateStr = authResponse['state'] as String?;
        if (stateStr == 'degraded') {
          state = state.copyWith(isAuthDegraded: true, isLoading: false);
          return;
        } else if (stateStr == 'anonymous') {
          state = state.copyWith(isAnonymous: true, isLoading: false);
          return;
        }
      }

      final rawChips = response['chips'] as List<dynamic>? ?? [];
      final parsedChips = rawChips.map((c) => Chip.fromJson(c as Map<String, dynamic>)).toList();

      final rawItems = response['items'] as List<dynamic>? ?? [];
      final parsedItems = rawItems.map((i) => FeedItem.fromJson(i as Map<String, dynamic>)).toList();

      // An empty token is the "All" chip, which the sidecar treats as a base
      // browse — so it comes back with a bar, and is one.
      final isBaseBrowse = !isLoadMore && (chipToken == null || chipToken.isEmpty);

      state = state.copyWith(
        isLoading: false,
        chipBars: storeChipBar(state.chipBars, surface, parsedChips, isBaseBrowse: isBaseBrowse),
        items: isLoadMore ? [...state.items, ...parsedItems] : parsedItems,
        continuation: response['continuation'] as String?,
      );
    } on RpcException catch (e) {
      if (generation != _generation) return;
      _inFlight = null;
      if (e.code == 'AUTH_DEGRADED') {
        state = state.copyWith(isAuthDegraded: true, isLoading: false);
      } else {
        state = state.copyWith(isLoading: false, error: e.message);
      }
    } catch (e) {
      if (generation != _generation) return;
      _inFlight = null;
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> loadMore() async {
    if (state.isLoading || state.continuation == null) return;
    await loadHome(chipToken: state.selectedToken, isLoadMore: true);
  }

  void selectChip(Chip chip) {
    if (state.selectedChip?.token == chip.token) return;
    loadHome(chipToken: chip.token);
  }
}

final feedProvider = NotifierProvider<FeedController, FeedState>(() {
  return FeedController();
});
