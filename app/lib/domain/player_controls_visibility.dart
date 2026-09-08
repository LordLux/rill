import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The bottom control bar, shared between `PlayerControls`'s fullscreen and
/// windowed mounts — they are mutually exclusive (`watch.dart` mounts one only
/// when `!fullscreen`, `player_shell.dart`'s `_FullscreenPlayer` the other only
/// when `fullscreen`), so one `GlobalKey` naturally always resolves to
/// whichever is actually on screen.
final GlobalKey playerControlsBarKey = GlobalKey(debugLabel: 'player-controls-bar');

/// Whether that bar is currently visible (not auto-hidden), so `LibassLayer`
/// can keep a caption from sitting under it. `controls.dart` is the single
/// writer, through `_PlayerControlsState._setVisible` — every place `_visible`
/// changes goes through the one method, so this cannot drift from what
/// `_visible` actually is the way two independently-updated copies would.
class PlayerControlsVisibility extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool value) {
    if (state != value) state = value;
  }
}

final playerControlsVisibleProvider =
    NotifierProvider<PlayerControlsVisibility, bool>(PlayerControlsVisibility.new);
