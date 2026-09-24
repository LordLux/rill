/// The player's keyboard shortcuts, and the guard that keeps them out of text.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../captions_controller.dart';
import '../playback_controller.dart';
import '../player_shell.dart';
import 'settings_menu.dart';
import 'view_mode.dart';

enum PlayerAction {
  playPause,
  seekBackward,
  seekForward,
  volumeUp,
  volumeDown,
  mute,
  fullscreen,
  theatre,
  escape,
  seekToDecile,
  frameBackward,
  frameForward,
  previous,
  next,
  miniPlayer,
  captions,
}

/// The visible label for an action's current keybinding — a tooltip's own
/// "M" badge reads straight from here rather than carrying its own copy of
/// the letter.
///
/// **This is the one thing a future rebind feature should have to change.**
/// Hand-kept in sync with [resolvePlayerShortcut] rather than derived from
/// it — that function is an if-chain matching on modifier combinations
/// (`Shift+P`) that `LogicalKeyboardKey` has no single-glyph label for, and a
/// derivation clever enough to produce these strings automatically would be
/// more code, and less legible, than the dozen entries below. When shortcuts
/// become user-configurable, this becomes a lookup into whatever holds the
/// user's bindings instead of a `const` — every tooltip that reads it today
/// needs no change at all.
///
/// Omitted rather than guessed for anything with no single clean label: the
/// two-speed seeks (arrows vs. `,`/`.`, plain vs. Shift), volume up/down (no
/// discrete button shows them today), and `escape`/`seekToDecile` (neither is
/// a button).
const Map<PlayerAction, String> playerActionKeyLabel = {
  PlayerAction.playPause: 'Space',
  PlayerAction.mute: 'M',
  PlayerAction.fullscreen: 'F',
  PlayerAction.theatre: 'T',
  PlayerAction.miniPlayer: 'I',
  PlayerAction.captions: 'C',
  PlayerAction.previous: 'Shift+P',
  PlayerAction.next: 'Shift+N',
};

/// One resolved key press. [seconds] carries ∓5 or ∓10; [decile] carries 0–9.
@immutable
class PlayerShortcut {
  const PlayerShortcut(this.action, {this.seconds = 0, this.decile});

  final PlayerAction action;
  final int seconds;
  final int? decile;

  @override
  bool operator ==(Object other) =>
    other is PlayerShortcut &&
    other.action == action &&
    other.seconds == seconds &&
    other.decile == decile;

  @override
  int get hashCode => Object.hash(action, seconds, decile);

  @override
  String toString() => 'PlayerShortcut($action, ${seconds}s, decile=$decile)';
}

/// Whether a text field owns the keyboard right now.
///
/// **The whole of "typing `f` in the search box must not go fullscreen"**, and
/// it has to be explicit: character input reaches a `TextField` over the
/// text-input channel, so `EditableText` leaves a plain `f` unhandled and it
/// propagates to every ancestor handler.
///
/// The focused node is the one inside `EditableText`, so the field is found by
/// walking up from it rather than by inspecting the node.
bool textEntryHasFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// A key press, as a player action — or null for everything else.
///
/// Down events only. Repeats are dropped deliberately: a held arrow key would
/// queue one seek per repeat, and F15 measured a 1.2–1.3 s stall per seek.
PlayerShortcut? resolvePlayerShortcut(KeyEvent event) {
  if (event is! KeyDownEvent) return null;

  final keyboard = HardwareKeyboard.instance;
  // `Ctrl+F` is find, `Alt+F` is a menu, `Win+…` belongs to the shell. Shift is
  // not excluded — it changes nothing about these keys and excluding it would
  // make caps-lock a silent off switch.
  if (keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed) {
    return null;
  }

  final key = event.logicalKey;
  final shift = keyboard.isShiftPressed;

  // `Shift + P` / `Shift + N` — the queue, from the keyboard.
  //
  // They exist because the buttons do not always: previous and next are drawn
  // only when the queue has somewhere to go, so on an ordinary video there is
  // nothing on the bar to press. Shifted rather than bare, because `n` and `p`
  // are the sort of letters a later feature wants, and because these move to a
  // *different video* — the one action here that cannot be undone by pressing
  // the same key again.
  if (key == LogicalKeyboardKey.keyP && shift) return const PlayerShortcut(PlayerAction.previous);
  if (key == LogicalKeyboardKey.keyN && shift) return const PlayerShortcut(PlayerAction.next);
  if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) return const PlayerShortcut(PlayerAction.playPause);
  if (key == LogicalKeyboardKey.arrowLeft) return const PlayerShortcut(PlayerAction.seekBackward, seconds: 5);
  if (key == LogicalKeyboardKey.arrowRight) return const PlayerShortcut(PlayerAction.seekForward, seconds: 5);
  if (key == LogicalKeyboardKey.keyJ) return const PlayerShortcut(PlayerAction.seekBackward, seconds: 10);
  if (key == LogicalKeyboardKey.keyL) return const PlayerShortcut(PlayerAction.seekForward, seconds: 10);
  if (key == LogicalKeyboardKey.arrowUp) return const PlayerShortcut(PlayerAction.volumeUp);
  if (key == LogicalKeyboardKey.arrowDown) return const PlayerShortcut(PlayerAction.volumeDown);
  if (key == LogicalKeyboardKey.keyM) return const PlayerShortcut(PlayerAction.mute);
  if (key == LogicalKeyboardKey.keyF) return const PlayerShortcut(PlayerAction.fullscreen);
  if (key == LogicalKeyboardKey.keyT) return const PlayerShortcut(PlayerAction.theatre);
  if (key == LogicalKeyboardKey.keyI) return const PlayerShortcut(PlayerAction.miniPlayer);
  // `C`, the same key youtube.com uses. Subject to [textEntryHasFocus] like
  // every other letter here — typing "c" in the search box must not turn on
  // subtitles behind it.
  if (key == LogicalKeyboardKey.keyC) return const PlayerShortcut(PlayerAction.captions);
  if (key == LogicalKeyboardKey.escape) return const PlayerShortcut(PlayerAction.escape);

  // TODO add end and home for seeking to the start and end of the video
  // TODO add `Shift + ,` and `Shift + .` for .25x speed increase/decrease
  // TODO add `q` to toggle the queue, `Shift + q` to clear it, and `Shift + m` to toggle the menu

  // `,` and `.` step one frame; with Shift they step one second.
  //
  // **Both spellings of each key, and that is not belt-and-braces.** Flutter
  // derives the logical key from the character the layout produces, so
  // Shift + `,` arrives as `LogicalKeyboardKey.less` on a US layout and as
  // `comma` with the shift flag set on others. Matching only one spelling makes
  // the Shift row of the table work on some keyboards and silently not on
  // others — and `<` cannot be typed without Shift, so the two branches below
  // cannot disagree about which one a press meant.
  if (key == LogicalKeyboardKey.comma || key == LogicalKeyboardKey.less) //
    return shift ? const PlayerShortcut(PlayerAction.seekBackward, seconds: 1) : const PlayerShortcut(PlayerAction.frameBackward);

  if (key == LogicalKeyboardKey.period || key == LogicalKeyboardKey.greater) //
    return shift ? const PlayerShortcut(PlayerAction.seekForward, seconds: 1) : const PlayerShortcut(PlayerAction.frameForward);

  final decile = _decileOf(key);
  if (decile != null) return PlayerShortcut(PlayerAction.seekToDecile, decile: decile);

  return null;
}

int? _decileOf(LogicalKeyboardKey key) {
  const digits = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  const numpad = <LogicalKeyboardKey>[
    LogicalKeyboardKey.numpad0,
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];
  final digit = digits.indexOf(key);
  if (digit >= 0) return digit;
  final pad = numpad.indexOf(key);
  return pad >= 0 ? pad : null;
}

/// Installs the shortcuts for as long as its subtree is mounted.
///
/// A global [HardwareKeyboard] handler rather than a `Shortcuts` widget, because
/// the focus chain is not a reliable delivery route here: with nothing focused,
/// the primary focus is the root scope and a `Focus` widget partway down the
/// tree is simply not on the path. The player is above the `Navigator` and has
/// to answer keys whether or not anything in the page has taken focus — so the
/// handler is global and the *scoping* is done by [textEntryHasFocus] instead.
class PlayerShortcuts extends ConsumerStatefulWidget {
  const PlayerShortcuts({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PlayerShortcuts> createState() => _PlayerShortcutsState();
}

class _PlayerShortcutsState extends ConsumerState<PlayerShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (textEntryHasFocus()) return false;

    final shortcut = resolvePlayerShortcut(event);
    if (shortcut == null) return false;

    // Nothing to control. Returning false leaves the key to the rest of the app
    // rather than swallowing every space bar on a page with no video on it.
    if (ref.read(playbackProvider).item == null) return false;

    return _dispatch(shortcut);
  }

  bool _dispatch(PlayerShortcut shortcut) {
    final playback = ref.read(playbackProvider.notifier);
    final view = ref.read(playerViewProvider.notifier);

    switch (shortcut.action) {
      case PlayerAction.playPause:
        playback.togglePlayPause();
      case PlayerAction.seekBackward:
        playback.seekBy(Duration(seconds: -shortcut.seconds));
      case PlayerAction.seekForward:
        playback.seekBy(Duration(seconds: shortcut.seconds));
      case PlayerAction.volumeUp:
        playback.nudgeVolume(volumeStep);
      case PlayerAction.volumeDown:
        playback.nudgeVolume(-volumeStep);
      case PlayerAction.mute:
        playback.toggleMute();
      case PlayerAction.fullscreen:
        view.toggleFullscreen();
      case PlayerAction.theatre:
        view.toggleTheatre();
      case PlayerAction.escape:
        // **The menu first, and all of it at once.** `Esc` on an open subpage
        // closes the whole thing rather than stepping back a page — the back
        // arrow is what walks the stack, and a key that took two presses to
        // dismiss one panel would be a key doing the arrow's job badly.
        // `close()` resets the page too, so the next open starts at the root.
        if (ref.read(playerMenuProvider).open) {
          ref.read(playerMenuProvider.notifier).close();
          return true;
        }
        // The one shortcut that can decline. With neither mode on, `Esc` is
        // somebody else's key.
        return view.escape();
      case PlayerAction.seekToDecile:
        playback.seekToFraction((shortcut.decile ?? 0) / 10);
      case PlayerAction.frameBackward:
        playback.stepFrame(-1);
      case PlayerAction.frameForward:
        playback.stepFrame(1);
      case PlayerAction.previous:
        playback.previous();
      case PlayerAction.next:
        playback.next();
      case PlayerAction.miniPlayer:
        toMiniPlayerIn(ProviderScope.containerOf(context, listen: false));
      case PlayerAction.captions:
        // Declines when the video has no tracks, rather than swallowing the key
        // — the same shape as `escape`. `toggle()` is already a no-op on an
        // empty list; returning false here also leaves `c` to the rest of the
        // app on a video that cannot have captions.
        if (!ref.read(captionsProvider).hasTracks) return false;
        unawaited(ref.read(captionsProvider.notifier).toggle());
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One press of ↑ or ↓, on mpv's 0–100 scale.
const double volumeStep = 5;
