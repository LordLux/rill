import 'dart:async';
import 'dart:ui' show AppLifecycleState, ViewFocusEvent, ViewFocusState;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Brings Flutter's idea of which keys are held back in line with Windows' when the window is
/// given the keyboard back.
///
/// **Why:** Alt+Tab (and Win+Ctrl+Arrow, Win+Tab…) hands the keyboard to another window between
/// the modifier going down and coming up, so the key-up is delivered there and never to this
/// window. Flutter then believes Alt is held for good. Every shortcut and Tab is matched
/// "without modifiers", so with a modifier stuck down none of them fire again — the app
/// seems dead to the keyboard (mouse and the OS's own shortcuts still work) until Alt happens
/// to be pressed and released inside the window. Measured 2026-10-03 from `RILL_KEY_DIAG` logs:
/// every press after an Alt+Tab read `down=[Alt Left+…]`.
///
/// Flutter's own `HardwareKeyboard.syncKeyboardState` is no help: it only adds the keys the
/// platform says are down, and never removes one. So this asks the platform what is actually
/// down and releases whatever Flutter holds that it does not. If the platform cannot say, the
/// four modifiers are released — they are the ones that matter, and one genuinely still held
/// will simply be pressed again by its next repeat or released by its own key-up (ignored when
/// it is not held).
final class KeyboardResync with WidgetsBindingObserver {
  KeyboardResync._();

  static KeyboardResync? _instance;

  /// Once, from `main`; calling it again does nothing.
  static void install() {
    if (_instance != null) return;
    _instance = KeyboardResync._();
    WidgetsBinding.instance.addObserver(_instance!);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state == ViewFocusState.focused) unawaited(_sync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_sync());
  }

  static final Set<PhysicalKeyboardKey> _modifiers = {
    PhysicalKeyboardKey.altLeft,
    PhysicalKeyboardKey.altRight,
    PhysicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.controlRight,
    PhysicalKeyboardKey.shiftLeft,
    PhysicalKeyboardKey.shiftRight,
    PhysicalKeyboardKey.metaLeft,
    PhysicalKeyboardKey.metaRight,
  };

  /// Releases, in Flutter's state, every key the platform does not hold.
  Future<void> _sync() async {
    final keyboard = HardwareKeyboard.instance;
    Set<int>? actuallyDown;
    try {
      final state = await SystemChannels.keyboard.invokeMapMethod<int, int>('getKeyboardState');
      actuallyDown = state?.keys.toSet();
    } on Object {
      // The platform cannot say: fall back to the modifiers.
    }

    for (final physical in keyboard.physicalKeysPressed.toList()) {
      final stale = actuallyDown == null ? _modifiers.contains(physical) : !actuallyDown.contains(physical.usbHidUsage);
      if (!stale) continue;
      // The logical key Flutter recorded on press, or nothing: guessing another one makes the
      // key-up disagree with the press, which `HardwareKeyboard` asserts against.
      final logical = keyboard.lookUpLayout(physical);
      if (logical == null) continue;
      keyboard.handleKeyEvent(KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: Duration.zero, synthesized: true));
    }
  }
}
