import 'package:flutter_riverpod/flutter_riverpod.dart';

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
