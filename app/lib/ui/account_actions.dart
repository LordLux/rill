import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../data/rpc/client.dart';
import '../domain/video_detail.dart';
import 'auth_controller.dart';

/// What the user has just done to their account this session — likes, Watch
/// Later, subscriptions — keyed by the video or channel it was done to.
///
/// **Why this is not widget state any more.** It used to live in the watch
/// page's `_ActionsState` and `SubscribeButton`'s own `State`, and a `State` is
/// thrown away far more often than it looks: switching normal ↔ theatre moved
/// the metadata and the rail to a different position in `WatchLayout`, a window
/// resize across the two-column breakpoint moves them to a different *parent*,
/// and the mini-player round trip rebuilds the whole page. Each time, the fresh
/// `State` fell back to `VideoDetail.myRating` / `isSubscribed` — the `/next`
/// response cached from when the page first opened — so a like that had
/// reached YouTube displayed as "no rating". Measured with a probe `State` in
/// each slot: three `State`s for one normal → theatre → normal round trip.
///
/// The rating is a fact about the account, not about a widget instance, so it
/// is kept where no rebuild can reach it. `WatchLayout` is keyed as well (so
/// purely visual state such as an expanded queue survives the theatre toggle),
/// but keys cannot survive reparenting, and this store does not need them to.
///
/// **An entry means "the user acted, and this is the outcome".** Absence means
/// "defer to what the server said", which is how a failed action is undone:
/// the entry is put back to whatever it was, including removed.
///
/// **Reset when the account changes.** One account's likes must never be drawn
/// over another's — sign out, or sign in as someone else, and every entry is
/// dropped. A re-verification of the same account keeps them.
class AccountActions<K, V> extends Notifier<Map<K, V>> {
  @override
  Map<K, V> build() {
    // Watching the identity, not the whole state: `isBusy` and friends change
    // constantly and must not wipe the store.
    ref.watch(authProvider.select((auth) => (auth.isSignedIn, auth.accountHandle)));
    return const {};
  }

  void set(K key, V value) {
    if (state[key] == value && state.containsKey(key)) return;
    state = {...state, key: value};
  }

  /// Back to "whatever the server said".
  void clear(K key) {
    if (!state.containsKey(key)) return;
    state = {...state}..remove(key);
  }

  /// Undo an optimistic write: restore the entry exactly as it was before, which
  /// may mean removing it rather than writing the old value.
  void restore(K key, {required bool had, V? previous}) {
    if (had) {
      set(key, previous as V);
    } else {
      clear(key);
    }
  }
}

/// Video id → the rating the user last set.
final ratingActionsProvider = NotifierProvider<AccountActions<String, VideoRating>, Map<String, VideoRating>>(
  AccountActions<String, VideoRating>.new,
);

/// Like, dislike or un-rate a video: set optimistically in
/// [ratingActionsProvider], ask the sidecar, and roll back if it refuses.
/// Returns null on success, or the message to show the user.
///
/// One path for all three: tapping the currently active side clears the
/// rating, tapping the other switches straight to it. `action.dislike` while
/// liked removes the like server-side on its own, so this never has to call
/// `action.removeRating` first.
///
/// **The one implementation** — the watch page's buttons and the taskbar's
/// thumbnail toolbar both call it, so the two cannot disagree about which way
/// a tap toggles. [serverRating] is what `video.info` reported, used until the
/// user has acted locally.
///
/// Takes a `read` rather than a `Ref`, because a widget holds a `WidgetRef`
/// and a provider holds a `Ref`, and both have exactly this method.
Future<String?> rateVideo(
  T Function<T>(ProviderListenable<T> provider) read,
  String videoId,
  VideoRating target, {
  required VideoRating serverRating,
}) async {
  final actions = read(ratingActionsProvider.notifier);
  final store = read(ratingActionsProvider);
  final had = store.containsKey(videoId);
  final previous = store[videoId];
  final current = previous ?? serverRating;
  final next = current == target ? VideoRating.none : target;

  actions.set(videoId, next);
  final method = switch (next) {
    VideoRating.like => 'action.like',
    VideoRating.dislike => 'action.dislike',
    VideoRating.none => 'action.removeRating',
  };

  String? failure;
  try {
    await RpcClient.instance.call(method, {'videoId': videoId});
  } on RpcException catch (e) {
    failure = e.code == 'AUTH_REQUIRED' ? 'Sign in to rate videos' : e.message;
  } catch (e) {
    failure = '$e';
  }
  // Undone in the store whatever became of the caller — a rating that failed
  // while the layout was switching must not stay drawn as set.
  if (failure != null) actions.restore(videoId, had: had, previous: previous);
  return failure;
}

/// Video id → whether it is in Watch Later, as of the user's last action.
final watchLaterActionsProvider = NotifierProvider<AccountActions<String, bool>, Map<String, bool>>(
  AccountActions<String, bool>.new,
);

/// Channel id → whether the user is subscribed, as of their last action.
///
/// Shared by the watch page and the search artist panel, so subscribing in one
/// is what the other shows.
final subscriptionActionsProvider = NotifierProvider<AccountActions<String, bool>, Map<String, bool>>(
  AccountActions<String, bool>.new,
);
