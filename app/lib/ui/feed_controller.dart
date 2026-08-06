import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
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

  /// How this error may be answered, from `protocol.md` §4. `null` when there is
  /// no error.
  ///
  /// Carried next to the message because the message alone cannot tell the UI
  /// whether to offer a retry: `user` means show one, `no` means retrying
  /// changes nothing until a login or a policy does. A retry button on a `no`
  /// is a button that lies.
  final RpcRetryMode? errorRetry;

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
    this.errorRetry,
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
    Object? errorRetry = _unchanged,
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
      errorRetry:
          identical(errorRetry, _unchanged) ? this.errorRetry : errorRetry as RpcRetryMode?,
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

  /// Delays for silently re-trying a `retry: "auto"` failure.
  ///
  /// This lives here rather than in the sidecar on purpose, and §4 now says so.
  /// A sidecar-side retry cannot be superseded: switch chip filters while it is
  /// on attempt 3 and it keeps working on a request nobody wants, with `$cancel`
  /// arriving while it is asleep between attempts and no one listening. Here,
  /// the timer is cancelled by `loadHome` and any answer it produces is dropped
  /// by the generation guard — the same two mechanisms that supersede everything
  /// else, rather than a second cancellation path plumbed into a retry loop
  /// across the process boundary.
  ///
  /// Capped, because an uncapped silent retry is the same pathology as the
  /// scroll loop it replaces, only politer: nothing on screen ever says the feed
  /// has stopped working. After the last delay the failure becomes visible and
  /// the user decides. The cap is only real if a retry cannot refill it — see
  /// `isAutoRetry` on [loadHome], which is the bug this comment used to describe
  /// without preventing.
  ///
  /// Mutable only so a test need not spend the real 15 s watching the budget run
  /// out. Nothing in the app writes to it.
  @visibleForTesting
  static List<Duration> autoBackoff = const [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  int _autoAttempt = 0;
  Timer? _retryTimer;

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
    // A backoff timer can outlive the notifier — a disposed `Notifier` throws on
    // assignment to `state`, so the tick would land as an error with no owner.
    ref.onDispose(() {
      _retryTimer?.cancel();
      _retryTimer = null;
    });
    Future.microtask(loadHome);
    return const FeedState(surface: surface);
  }

  Future<void> loadHome({
    String? chipToken,
    bool isLoadMore = false,
    /// Set only by the backoff timer in [_fail].
    ///
    /// Without it a base load's retry re-entered here as an ordinary base load
    /// and reset `_autoAttempt` to 0 — refilling the budget it was spending, so
    /// the cap never bit. A failing base feed then retried every second forever
    /// behind a spinner that never became an error: precisely the pathology the
    /// cap exists to prevent, reintroduced by the retry path itself.
    bool isAutoRetry = false,
  }) async {
    final generation = ++_generation;

    // A pending backoff belongs to the request this one replaces. Left running
    // it would re-issue the old filter's page on top of the new one.
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!isLoadMore && !isAutoRetry) _autoAttempt = 0;

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
      state = state.copyWith(isLoading: true, error: null, errorRetry: null);
    } else {
      state = state.copyWith(
        isLoading: true,
        error: null,
        errorRetry: null,
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

      _autoAttempt = 0;
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
        return;
      }
      _fail(e.message, e.retry, generation: generation, chipToken: chipToken, isLoadMore: isLoadMore);
    } catch (e) {
      if (generation != _generation) return;
      _inFlight = null;
      // Not an envelope — a bug on this side of the boundary. It carries no
      // `retry` of its own, and `user` is the honest reading: nothing will fix
      // itself, but letting the user try again costs nothing.
      _fail(e.toString(), RpcRetryMode.user, generation: generation, chipToken: chipToken, isLoadMore: isLoadMore);
    }
  }

  /// Land a failure: silently for an `auto` still inside its budget, visibly
  /// otherwise.
  void _fail(
    String message,
    RpcRetryMode retry, {
    required int generation,
    required String? chipToken,
    required bool isLoadMore,
  }) {
    if (retry == RpcRetryMode.auto && _autoAttempt < autoBackoff.length) {
      final delay = autoBackoff[_autoAttempt++];
      // No error on the state: §4 says an `auto` failure shows a loading state,
      // and `isLoading` is also what holds `loadMore`'s gate shut in the
      // meantime, so a scroll cannot race the timer.
      state = state.copyWith(isLoading: true, error: null, errorRetry: null);
      _retryTimer?.cancel();
      _retryTimer = Timer(delay, () {
        if (generation != _generation) return;
        loadHome(chipToken: chipToken, isLoadMore: isLoadMore, isAutoRetry: true);
      });
      return;
    }

    state = state.copyWith(
      isLoading: false,
      error: message,
      // An `auto` that has run out of budget is no longer the sidecar's to
      // retry. It becomes the user's call, which is what `user` means.
      errorRetry: retry == RpcRetryMode.auto ? RpcRetryMode.user : retry,
    );
  }

  /// Paging triggered by the scroll position.
  ///
  /// The listener behind this fires on *every* scroll notification within 400 px
  /// of the bottom, so the error gate is not a nicety: without it one failed
  /// page turns each subsequent scroll into another identical failing request,
  /// unbounded and invisible — the error surface only replaces the grid when
  /// there are no items, so a populated feed shows nothing at all while it
  /// hammers the sidecar.
  ///
  /// Nothing here clears the gate. `retryMore` does, because a person asked.
  Future<void> loadMore() async {
    if (state.isLoading || state.continuation == null) return;
    if (state.error != null) return;
    await loadHome(chipToken: state.selectedToken, isLoadMore: true);
  }

  /// The user answering a `retry: "user"` footer.
  Future<void> retryMore() async {
    if (state.isLoading || state.continuation == null) return;
    _autoAttempt = 0;
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
