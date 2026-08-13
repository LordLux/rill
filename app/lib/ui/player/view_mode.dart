/// Theatre and fullscreen — two different things, as YouTube has them.
///
/// **Theatre** is a layout change: the player fills the app's content area and
/// the app chrome stays. **Fullscreen** is an OS window change: borderless over
/// the monitor, all chrome hidden, previous bounds restored on exit.
///
/// They are two independent flags rather than one three-valued mode, and that is
/// what makes `Esc` "exit fullscreen, then theatre" fall out instead of needing a
/// remembered previous mode: leaving fullscreen reveals whatever theatre was
/// already set to.
///
/// **The state is app-level, not route-level.** A mode owned by the watch route
/// dies with the route, which is how an app ends up borderless over the monitor
/// with no player in it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../playback_controller.dart';
import '../player_shell.dart';
import 'window_chrome.dart';

/// The window, as a provider so a test can put a [NoWindowChrome] in its place
/// and still assert that it was asked.
final windowChromeProvider = Provider<WindowChrome>((ref) => createWindowChrome());

@immutable
class PlayerViewState {
  const PlayerViewState({this.theatre = false, this.fullscreen = false});

  final bool theatre;
  final bool fullscreen;

  /// Whether the player is drawn full-window above the `Navigator` rather than
  /// inside the watch page. One mount point at a time — see `player_shell.dart`.
  bool get isImmersive => fullscreen;

  PlayerViewState copyWith({bool? theatre, bool? fullscreen}) => PlayerViewState(
        theatre: theatre ?? this.theatre,
        fullscreen: fullscreen ?? this.fullscreen,
      );

  @override
  bool operator ==(Object other) =>
      other is PlayerViewState && other.theatre == theatre && other.fullscreen == fullscreen;

  @override
  int get hashCode => Object.hash(theatre, fullscreen);
}

class PlayerViewController extends Notifier<PlayerViewState> {
  @override
  PlayerViewState build() {
    // The anti-stranding rules, both of them, in the object that owns the state
    // rather than in whichever widget happens to notice. Leaving the watch route
    // or losing the video drops both modes — otherwise "go fullscreen, then
    // navigate" is a borderless window showing a feed, with the OS chrome gone
    // and no player left to press `Esc` at.
    ref.listen(currentRouteProvider, (previous, next) {
      if (next != watchRouteName) reset();
    });
    ref.listen(playbackProvider.select((playback) => playback.item == null), (previous, next) {
      if (next) reset();
    });
    return const PlayerViewState();
  }

  void toggleTheatre() => _set(state.copyWith(theatre: !state.theatre));

  void toggleFullscreen() => _set(state.copyWith(fullscreen: !state.fullscreen));

  void setFullscreen(bool value) => _set(state.copyWith(fullscreen: value));

  /// `Esc`: fullscreen first, then theatre. Returns whether it consumed the key,
  /// so an `Esc` with neither mode on stays available to whatever else wants it.
  bool escape() {
    if (state.fullscreen) {
      _set(state.copyWith(fullscreen: false));
      return true;
    }
    if (state.theatre) {
      _set(state.copyWith(theatre: false));
      return true;
    }
    return false;
  }

  /// Back to an ordinary window and an ordinary layout.
  ///
  /// The anti-stranding rule, stated once: leaving the watch route or stopping
  /// playback drops both modes. Without it, "enter fullscreen, navigate" leaves
  /// a borderless window showing a feed.
  void reset() => _set(const PlayerViewState());

  void _set(PlayerViewState next) {
    if (next == state) return;
    if (next.fullscreen != state.fullscreen) {
      // Not awaited: the window call crosses into Win32 and the layout must not
      // wait on it. `WindowChrome.setFullscreen` is idempotent, so the state and
      // the window cannot disagree about which direction they are going.
      unawaited(ref.read(windowChromeProvider).setFullscreen(next.fullscreen));
    }
    state = next;
  }
}

final playerViewProvider =
    NotifierProvider<PlayerViewController, PlayerViewState>(PlayerViewController.new);
