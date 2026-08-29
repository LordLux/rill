import 'dart:async';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import '../domain/artist_panel.dart';
import '../domain/feed_item.dart';
import '../domain/search_filters.dart';
import '../data/rpc/client.dart';

/// Which RPC family a surface needs beyond `{method, hasChips}`.
///
/// Every surface shares one request/response shape *except* which extra
/// parameter it needs: home's chip token, search's `q` and `filters`.
/// `SurfaceKind` is what [FeedController.load] branches on to add that one
/// extra thing — everything else (generation guard, supersede, retry budget,
/// paging) is identical across all three and does not know this enum exists.
enum SurfaceKind { home, search, subscriptions }

/// A feed surface, generalised per Task 20 §1: which RPC method, whether it
/// has chips, and what an empty first page means.
///
/// This is the abstraction `FeedController` was built for in Task 12 — a
/// surface is a value now, not the `static const String surface = 'home'` and
/// the hardcoded `feed.home` call this replaces.
class SurfaceConfig {
  const SurfaceConfig({
    required this.kind,
    required this.surface,
    required this.method,
    this.hasChips = false,
    this.checkAuthOnEmpty = false,
    this.autoLoadOnBuild = true,
  });

  final SurfaceKind kind;

  /// The key into [FeedState.chipBars] and the value [FeedState.surface] carries.
  final String surface;

  /// The RPC method this surface loads through.
  final String method;

  /// Whether a base browse on this surface carries a chip bar at all. A
  /// surface with none must never render an empty strip — `FeedPage` already
  /// gates on `state.chips.isNotEmpty`, so this only has to make sure
  /// `chipBars[surface]` is never written for a surface that has none.
  final bool hasChips;

  /// Whether an empty, unfiltered first page is ambiguous enough to need
  /// `auth.verify` — home and subscriptions both go empty for "no
  /// recommendations yet" and for "the session is degraded", and only
  /// `auth.verify` tells those apart (protocol.md §3.1). Search's empty page
  /// means "no results for this query"; asking `auth.verify` about it would
  /// answer a question nobody asked.
  final bool checkAuthOnEmpty;

  /// Whether `build()` should fetch the first page on its own. Home and
  /// subscriptions have nothing else to wait for; search has no query yet —
  /// the caller supplies one via [FeedController.search].
  final bool autoLoadOnBuild;
}

const SurfaceConfig homeSurface = SurfaceConfig(
  kind: SurfaceKind.home,
  surface: 'home',
  method: 'feed.home',
  hasChips: true,
  checkAuthOnEmpty: true,
);

const SurfaceConfig subscriptionsSurface = SurfaceConfig(
  kind: SurfaceKind.subscriptions,
  surface: 'subscriptions',
  method: 'feed.subscriptions',
  checkAuthOnEmpty: true,
);

/// The channel list (Task 21 §4) — a different browse endpoint from the video
/// feed above (`subscriptions.channels`, not `feed.subscriptions`), reusing
/// [SurfaceKind.subscriptions] since it needs exactly the same shape: no
/// chips, no query params beyond `continuation`, and the same
/// `auth.verify`-on-empty ambiguity between "no subscriptions" and "degraded
/// session". Its items are `ChannelItem`-kind [FeedItem]s, which [FeedView]
/// already renders via [ChannelTile] — no new controller or widget needed.
const SurfaceConfig subscriptionsChannelsSurface = SurfaceConfig(
  kind: SurfaceKind.subscriptions,
  surface: 'subscriptions-channels',
  method: 'subscriptions.channels',
  checkAuthOnEmpty: true,
);

const SurfaceConfig searchSurface = SurfaceConfig(
  kind: SurfaceKind.search,
  surface: 'search',
  method: 'search.query',
  autoLoadOnBuild: false,
);

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

  /// The search surface's query text. `null` on every other surface.
  final String? query;

  /// The search surface's active filters, or `null` for unfiltered. `null` on
  /// every other surface.
  final SearchFilters? filters;

  /// The artist panel `search.query` may carry (Task 21 §3, protocol.md
  /// §3.3). `null` on every other surface, and `null` on search itself
  /// whenever the response carried none — most searches.
  final ArtistPanel? artist;

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
    this.query,
    this.filters,
    this.artist,
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
    Object? query = _unchanged,
    Object? filters = _unchanged,
    Object? artist = _unchanged,
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
      query: identical(query, _unchanged) ? this.query : query as String?,
      filters: identical(filters, _unchanged) ? this.filters : filters as SearchFilters?,
      artist: identical(artist, _unchanged) ? this.artist : artist as ArtistPanel?,
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
  FeedController([this.config = homeSurface]);

  final SurfaceConfig config;

  /// Kept for existing home call sites and tests: always `'home'`, the same
  /// value `config.surface` carries when [config] is [homeSurface].
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
    if (config.autoLoadOnBuild) Future.microtask(load);
    // `FeedState.isLoading` defaults to true because home and subscriptions
    // both start fetching the instant they build. A surface that waits for an
    // explicit query (search) must not carry that default forward — nothing
    // would ever clear it, and `isLoading` would read true forever on a page
    // nobody has searched from yet.
    return FeedState(surface: config.surface, isLoading: config.autoLoadOnBuild);
  }

  /// Home's entry point, unchanged in name, signature and behaviour — an alias
  /// for [load] with the shape home has always had. Existing call sites and
  /// tests use this name directly.
  Future<void> loadHome({
    String? chipToken,
    bool isLoadMore = false,
    bool isAutoRetry = false,
  }) {
    return load(chipToken: chipToken, isLoadMore: isLoadMore, isAutoRetry: isAutoRetry);
  }

  /// The search surface's entry point. A fresh query starts a fresh page, the
  /// same way [selectChip] starts a fresh page on a new chip token — items and
  /// continuation are cleared, not appended.
  Future<void> search(String query, {SearchFilters? filters}) {
    return load(query: query, filters: filters ?? const SearchFilters());
  }

  /// The search surface's filter menu: keeps the current query, replaces the
  /// filters, starts a fresh page.
  Future<void> updateFilters(SearchFilters filters) {
    final query = state.query;
    if (query == null) return Future<void>.value();
    return load(query: query, filters: filters);
  }

  Future<void> load({
    String? chipToken,
    String? query,
    SearchFilters? filters,
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
    // A load-more or an auto-retry repeats whatever the base load started;
    // only a fresh, non-paging call may change the query or the filters.
    final effectiveQuery = isLoadMore || isAutoRetry ? state.query : (query ?? state.query);
    final effectiveFilters = isLoadMore || isAutoRetry ? state.filters : (filters ?? state.filters);

    // The search surface needs a query to do anything. Asking with none is a
    // no-op rather than a request the sidecar would refuse as BAD_REQUEST —
    // this is also what keeps `build()` cheap to leave `autoLoadOnBuild: false`
    // for, since nothing here fires until [search] supplies one.
    if (config.kind == SurfaceKind.search && (effectiveQuery == null || effectiveQuery.isEmpty)) {
      return;
    }

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
        query: effectiveQuery,
        filters: effectiveFilters,
        // Explicit, not left to default to null via `??`: hard invariant 10.
        // Without this a fresh search that carries no panel would keep
        // showing the previous search's, since nothing else in this branch
        // touches it.
        artist: null,
        isAuthDegraded: false,
        isAnonymous: false,
      );
    }

    try {
      final params = <String, dynamic>{};
      if (config.hasChips && chipToken != null) params['chipToken'] = chipToken;
      if (config.kind == SurfaceKind.search) {
        params['q'] = effectiveQuery;
        if (effectiveFilters != null && !effectiveFilters.isEmpty) {
          params['filters'] = effectiveFilters.toJson();
        }
      }
      if (isLoadMore && state.continuation != null) {
        params['continuation'] = state.continuation;
      }

      final request = RpcClient.instance.callCancelable(config.method, params);
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

      // An empty first page is ambiguous on a surface `auth.verify` can
      // explain — no recommendations yet, or a session the server stopped
      // honouring. Search has no such ambiguity: an empty page just means no
      // results, so this never runs there (`config.checkAuthOnEmpty`).
      if (config.checkAuthOnEmpty &&
          (response['items'] as List?)?.isEmpty == true &&
          !isLoadMore &&
          chipToken == null) {
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

      // A surface with no chip bar (search, subscriptions) never reads
      // `chips` off the response and never writes `chipBars` — `FeedPage`
      // already skips an empty bar, so this only has to make sure one is
      // never stored for a surface that has none.
      final parsedChips = config.hasChips && response['chips'] != null
          ? (response['chips'] as List<dynamic>)
              .map((c) => Chip.fromJson(c as Map<String, dynamic>))
              .toList()
          : const <Chip>[];

      final rawItems = response['items'] as List<dynamic>? ?? [];
      final parsedItems = await Isolate.run(
          () => rawItems.map((i) => FeedItem.fromJson(i as Map<String, dynamic>)).toList());

      // An empty token is the "All" chip, which the sidecar treats as a base
      // browse — so it comes back with a bar, and is one.
      final isBaseBrowse = config.hasChips && !isLoadMore && (chipToken == null || chipToken.isEmpty);

      // Only search.query's *first-page* response ever carries this key
      // (protocol.md §3.3) — a continuation response carries no panel at
      // all, so a load-more must keep whatever the base load found rather
      // than overwriting it with the absence on this page.
      final rawArtist = response['artist'] as Map<String, dynamic>?;
      final parsedArtist =
          isLoadMore ? state.artist : (rawArtist != null ? ArtistPanel.fromJson(rawArtist) : null);

      _autoAttempt = 0;
      state = state.copyWith(
        isLoading: false,
        chipBars: config.hasChips
            ? storeChipBar(state.chipBars, config.surface, parsedChips, isBaseBrowse: isBaseBrowse)
            : state.chipBars,
        items: isLoadMore ? [...state.items, ...parsedItems] : parsedItems,
        continuation: response['continuation'] as String?,
        artist: parsedArtist,
      );
    } on RpcException catch (e) {
      if (generation != _generation) return;
      _inFlight = null;
      if (e.code == 'AUTH_DEGRADED') {
        state = state.copyWith(isAuthDegraded: true, isLoading: false);
        return;
      }
      _fail(
        e.message,
        e.retry,
        generation: generation,
        chipToken: chipToken,
        query: effectiveQuery,
        filters: effectiveFilters,
        isLoadMore: isLoadMore,
      );
    } catch (e) {
      if (generation != _generation) return;
      _inFlight = null;
      // Not an envelope — a bug on this side of the boundary. It carries no
      // `retry` of its own, and `user` is the honest reading: nothing will fix
      // itself, but letting the user try again costs nothing.
      _fail(
        e.toString(),
        RpcRetryMode.user,
        generation: generation,
        chipToken: chipToken,
        query: effectiveQuery,
        filters: effectiveFilters,
        isLoadMore: isLoadMore,
      );
    }
  }

  /// Land a failure: silently for an `auto` still inside its budget, visibly
  /// otherwise.
  void _fail(
    String message,
    RpcRetryMode retry, {
    required int generation,
    required String? chipToken,
    required String? query,
    required SearchFilters? filters,
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
        load(
          chipToken: chipToken,
          query: query,
          filters: filters,
          isLoadMore: isLoadMore,
          isAutoRetry: true,
        );
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
    await load(
      chipToken: state.selectedToken,
      query: state.query,
      filters: state.filters,
      isLoadMore: true,
    );
  }

  /// The user answering a `retry: "user"` footer.
  Future<void> retryMore() async {
    if (state.isLoading || state.continuation == null) return;
    _autoAttempt = 0;
    await load(
      chipToken: state.selectedToken,
      query: state.query,
      filters: state.filters,
      isLoadMore: true,
    );
  }

  void selectChip(Chip chip) {
    if (state.selectedChip?.token == chip.token) return;
    load(chipToken: chip.token);
  }
}

final feedProvider = NotifierProvider<FeedController, FeedState>(() {
  return FeedController(homeSurface);
});

final searchProvider = NotifierProvider<FeedController, FeedState>(() {
  return FeedController(searchSurface);
});

final subscriptionsProvider = NotifierProvider<FeedController, FeedState>(() {
  return FeedController(subscriptionsSurface);
});

final subscriptionsChannelsProvider = NotifierProvider<FeedController, FeedState>(() {
  return FeedController(subscriptionsChannelsSurface);
});
