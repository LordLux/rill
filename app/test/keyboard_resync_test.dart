import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/keyboard_resync.dart';

/// A modifier whose release went to another window (Alt+Tab) stays "held" in Flutter, and then no
/// shortcut or Tab matches. Coming back to the window must clear it.
void main() {
  testWidgets('getting the window back clears a modifier whose release never arrived', (tester) async {
    KeyboardResync.install();
    // The platform's truth: nothing is down (Alt was let go in the other window).
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.keyboard, (call) async {
      if (call.method == 'getKeyboardState') return <int, int>{};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.keyboard, null));

    await tester.pumpWidget(const SizedBox());
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    expect(HardwareKeyboard.instance.isAltPressed, isTrue, reason: 'Alt went down in this window');

    // Alt+Tab: the window loses the keyboard, the release goes elsewhere, the window gets it back.
    WidgetsBinding.instance.handleViewFocusChanged(const ViewFocusEvent(viewId: 0, state: ViewFocusState.unfocused, direction: ViewFocusDirection.undefined));
    expect(HardwareKeyboard.instance.isAltPressed, isTrue, reason: 'still believed held while away');
    WidgetsBinding.instance.handleViewFocusChanged(const ViewFocusEvent(viewId: 0, state: ViewFocusState.focused, direction: ViewFocusDirection.undefined));
    // The platform is asked over a channel: let that round trip finish.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(HardwareKeyboard.instance.isAltPressed, isFalse, reason: 'and cleared on the way back');
  });

  testWidgets('a platform that cannot say what is down: the modifiers are released, a held letter is not', (tester) async {
    KeyboardResync.install();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.keyboard, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.keyboard, null));

    await tester.pumpWidget(const SizedBox());
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    WidgetsBinding.instance.handleViewFocusChanged(const ViewFocusEvent(viewId: 0, state: ViewFocusState.focused, direction: ViewFocusDirection.undefined));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(HardwareKeyboard.instance.isAltPressed, isFalse);
    expect(HardwareKeyboard.instance.logicalKeysPressed, contains(LogicalKeyboardKey.keyA), reason: 'only modifiers are guessed at');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
  });
}
