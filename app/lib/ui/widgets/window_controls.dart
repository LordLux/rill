import 'dart:io';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/screen_values.dart';
import '../../theme/tokens.dart';

/// The two native pieces of the title bar — the drag region and the
/// minimise/maximise/close cluster — behind one seam.
///
/// **They cannot be built under `flutter test`, and the failure is a crash
/// rather than a no-op.** `bitsdojo_window`'s `MoveWindow` and `WindowButton`
/// reach `appWindow` from inside `build()`, which resolves the native entry
/// point with `DynamicLibrary.lookup('bitsdojo_window_api')`. A `flutter test`
/// process has no Windows runner, so that symbol does not exist and every
/// widget test that pumps a title bar throws:
///
///     Invalid argument(s): Failed to lookup symbol 'bitsdojo_window_api':
///     The specified procedure could not be found. (error code: 127)
///
/// Measured 2026-09-16: that one cause accounted for **79 of the suite's 81
/// failures**, across nine files that mostly never mention the title bar — they
/// pump a page, and the page carries a `TopBar`.
///
/// **`Platform.isWindows` does not discriminate**, which is the trap here: it is
/// `true` inside `flutter test` on Windows, so the obvious guard passes and the
/// lookup still fails. The thing that actually differs is `FLUTTER_TEST`, which
/// the test runner sets in the environment.
///
/// **Why the default is made safe rather than overridden per test.** Only one
/// test file names `TopBar` directly; the rest reach it through a page, so an
/// override-per-test rule would have to be remembered by every future test that
/// pumps any route. `test/flutter_test_config.dart` already answers the same
/// shape of problem the same way for `shared_preferences` — mock it once,
/// globally, rather than asking each test to know which plugins are missing.
///
/// It stays a `Provider`, so a test that wants the real cluster, or wants to
/// assert against a fake, can still override [windowControlsProvider].
///
/// **If these buttons ever need to be asserted rather than merely absent**, the
/// move is to widen `WindowChrome` (`ui/player/window_chrome.dart`) with
/// `minimize` / `toggleMaximize` / `close`, and build the cluster here from
/// ordinary `IconButton`s driven by it — `NoWindowChrome` already records every
/// request so a test can assert the window was asked. The colours below are
/// already ours, so less is lost than it looks; what goes is bitsdojo's own
/// hover animation.
abstract class WindowControls {
  /// The drag-to-move region. Laid out under the bar's interactive children.
  Widget dragRegion();

  /// The minimise / maximise / close cluster, at the bar's trailing edge.
  Widget buttons(ThemeData theme);
}

/// The real thing: `bitsdojo_window`'s own widgets.
class NativeWindowControls implements WindowControls {
  const NativeWindowControls();

  /// `MoveWindow` is `HitTestBehavior.translucent` + `onPanStart` →
  /// `startDragging`, so taps on the children layered above it still reach
  /// them and no `DoNotMoveWindow` is needed.
  @override
  Widget dragRegion() => MoveWindow();

  @override
  Widget buttons(ThemeData theme) {
    final normal = _normalColors(theme.colorScheme);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: ScreenValues.titlebarWindowButtonsHeight,
          width: ScreenValues.titlebarWindowButtonsWidth,
          child: MinimizeWindowButton(colors: normal, animate: true),
        ),
        SizedBox(
          height: ScreenValues.titlebarWindowButtonsHeight,
          width: ScreenValues.titlebarWindowButtonsWidth,
          child: MaximizeWindowButton(colors: normal, animate: true),
        ),
        SizedBox(
          height: ScreenValues.titlebarWindowButtonsHeight,
          width: ScreenValues.titlebarWindowButtonsWidth,
          child: CloseWindowButton(colors: _closeColors(theme), animate: true),
        ),
      ],
    );
  }

  WindowButtonColors _normalColors(ColorScheme scheme) => WindowButtonColors(
    iconNormal: scheme.onSurface,
    iconMouseOver: scheme.onSurface,
    iconMouseDown: scheme.onSurface,
    normal: Colors.transparent,
    mouseOver: scheme.onSurface.withAlpha(30),
    mouseDown: scheme.onSurface.withAlpha(50),
  );

  WindowButtonColors _closeColors(ThemeData theme) {
    final red = theme.tokens.windowClose;
    return WindowButtonColors(
      iconNormal: theme.colorScheme.onSurface,
      // White on the red in both themes; the red does not follow the theme.
      iconMouseOver: theme.tokens.onScrim,
      iconMouseDown: theme.tokens.onScrim,
      normal: Colors.transparent,
      mouseOver: red,
      // A softer version of the same red, so pressing reads as a response
      // rather than a second, unrelated colour.
      mouseDown: red.withValues(alpha: 0.8),
    );
  }
}

/// Draws nothing and touches no native API. The answer under `flutter test`,
/// and on any platform that is not Windows.
///
/// The cluster keeps its footprint so a layout assertion sees the same row
/// widths it would on a real window; the drag region has no gesture detector,
/// so it absorbs nothing.
class NoWindowControls implements WindowControls {
  const NoWindowControls();

  @override
  Widget dragRegion() => const SizedBox.shrink();

  @override
  Widget buttons(ThemeData theme) => const SizedBox(
    height: ScreenValues.titlebarWindowButtonsHeight,
    width: ScreenValues.titlebarWindowButtonsWidth * 3,
  );
}

/// Whether this process can resolve `bitsdojo_window`'s native entry point.
///
/// `FLUTTER_TEST` is set by the `flutter test` runner. See the class doc above
/// for why `Platform.isWindows` is not the question.
bool get _canUseNativeWindow =>
    Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

WindowControls createWindowControls() =>
    _canUseNativeWindow ? const NativeWindowControls() : const NoWindowControls();

/// The title bar's native pieces. Override in a test that needs to assert
/// against them rather than simply not crash.
final windowControlsProvider = Provider<WindowControls>((ref) => createWindowControls());
