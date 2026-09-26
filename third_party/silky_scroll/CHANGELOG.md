# Changelog

All notable changes to this project will be documented in this file.

## 2.6.4

### Changed

- Updated `SilkyScroll.fromConfig` so runtime scroll behavior changes are applied without remounting the scroll widget.
- Refined the config playground example to update scroll settings live and keep the demo list fully cached for smoother comparison.

### Fixed

- Recalculate the animator smoothing factor from the latest `silkyScrollDuration` and `decayLogFactor` values.

## 2.6.3

### Added

- Added `scrollCacheExtent` support to `SilkyListView`, `SilkyGridView`, and `SilkyCustomScrollView` presets.

### Changed

- Replaced internal Flutter preset calls from deprecated `cacheExtent` to `scrollCacheExtent`.
- Raised the minimum Flutter version to `3.44.0` to match the stable release that provides `ScrollCacheExtent`.

## 2.6.2

### Added

- **Shift-wheel horizontal scrolling**: Holding Shift now turns vertical mouse-wheel input into an explicit horizontal-scroll command for horizontal `SilkyScroll` widgets.
- **`MouseWheelVerticalDeltaBehavior`**: Added configuration for how horizontal scroll views handle vertical mouse-wheel deltas without Shift (`forwardToVerticalAncestorOrSelf`, `forwardToVerticalAncestor`, `always`, `shiftOnly`).

### Changed

- **Horizontal mouse-wheel forwarding**: Horizontal `SilkyScroll` widgets now prefer vertical ancestor scrolling for regular mouse-wheel deltas, while standalone horizontal views can still handle the wheel themselves.
- **Edge forwarding with Shift**: Shift-wheel gestures stay owned by the horizontal view at its edges instead of spilling into a vertical parent scroll view.
- **Preset widgets**: Propagate the new mouse-wheel vertical delta behavior option through `SilkyListView`, `SilkyGridView`, `SilkyCustomScrollView`, and `SilkySingleChildScrollView`.

### Fixed

- **Ancestor forwarding respects disabled physics**: Edge forwarding and horizontal mouse-wheel handoff no longer move an ancestor scroll view when its physics reject user scrolling, such as `NeverScrollableScrollPhysics`.

### Removed

- **Internal planning docs**: Removed the mouse Shift horizontal scroll implementation plan from `docs/`.

## 2.6.1

### Changed

- **Default `silkyScrollDuration`**: Changed from `850ms` to `1600ms` for a more natural, buttery-smooth scroll feel.
- **Default `animationCurve`**: Changed from `Curves.easeOutQuart` to `Curves.easeOutCirc` to better complement the longer animation duration.
- **Removed internal `_kScrollDeltaFactor` (0.5 multiplier)**: Scroll delta is now applied directly without the hidden halving factor. `scrollSpeed` now reflects the full intended distance without an invisible reduction.
- **README**: Comprehensively rewritten — clearer structure, preset widget table, before/after examples, and improved parameter documentation.
- **Code style**: Internal formatting and documentation comment improvements across `SilkyScrollAnimator`, `SilkyScrollConfig`, `SilkyScrollController`, `SilkyScrollWidget`, and all preset widgets.

## 2.6.0

### Added

- **Preset widgets**: Drop-in replacements for Flutter scrollable widgets with built-in SilkyScroll smooth scrolling — no manual `controller` / `physics` wiring needed.
  - `SilkyListView` — wraps `ListView` (default, `.builder`, `.separated`)
  - `SilkyGridView` — wraps `GridView` (default, `.builder`, `.count`, `.extent`)
  - `SilkyCustomScrollView` — wraps `CustomScrollView`
  - `SilkySingleChildScrollView` — wraps `SingleChildScrollView`
- **`silkyConfig` parameter on presets**: Accepts a `SilkyScrollConfig` to share configuration across multiple preset widgets. When provided, overrides individual SilkyScroll parameters.
- **`onPointerDeviceKindChanged` callback on presets**: Optional callback that fires when the detected `PointerDeviceKind` changes (mouse, trackpad, touch).

## 2.5.0

### Breaking

- **Removed `OverscrollBehaviorX` enum export**: The `OverscrollBehaviorX` enum is no longer exported from the barrel file. Use `setBlockOverscrollBehaviorX(bool)` instead.
- **Removed `setOverscrollBehaviorX(OverscrollBehaviorX)` API**: Replaced with `setBlockOverscrollBehaviorX(bool)` on `SilkyScrollGlobalManager`.
- **`overscroll-behavior-x` no longer applied at import time**: The CSS property is now managed per-widget lifecycle instead of being set globally when `SilkyScrollGlobalManager` is initialized.

### Added

- **`blockWebOverscrollBehaviorX` parameter**: New parameter on `SilkyScroll` and `SilkyScrollConfig` (default: `true`). When `true`, `overscroll-behavior-x: none` is applied while the widget is mounted; when all blocking widgets are disposed, it reverts to `auto`.
- **`setBlockOverscrollBehaviorX(bool)` API**: New global API on `SilkyScrollGlobalManager` for explicit user-level overscroll blocking control.
- **Widget-based block counting**: Multiple `SilkyScroll` widgets can coexist — the CSS block is maintained as long as at least one widget (or the global flag) requests it.

### Changed

- **Overscroll behavior lifecycle**: `overscroll-behavior-x` CSS is now synced via `_syncOverscrollBehaviorX()`, combining widget-level block count and user-level flag (`shouldBlock = widgetBlockCount > 0 || userBlock`).

### Removed

- `blockOverscrollBehaviorXHtml()` method from `SilkyScrollWebManagerInterface` and its implementations.

## 2.4.3

### Fixed

- **Export `SilkyScrollGlobalManager`**: Added missing `SilkyScrollGlobalManager` export to the barrel file (`silky_scroll.dart`).

## 2.4.2

### Changed

- **`isPlatformBouncingScrollPhysics` runtime detection**: Changed from `late final bool` to `bool` so it can be re-evaluated on every build. Added `detectBouncingPhysics(BuildContext)` method that resolves the physics chain via `ScrollConfiguration.of(context).getScrollPhysics(context)` at runtime.
- **Build-time detection call**: `SilkyScrollWidget.build()` now calls `silkyScrollState.detectBouncingPhysics(context)` on every build to keep bouncing-physics detection up to date.

### Fixed

- **`_isWithinScrollExtent()` precision**: Replaced `.round()`-based integer comparison with ±0.5 px tolerance comparison. Also changed `pixels >= 0` to `pixels >= pos.minScrollExtent - 0.5` to handle cases where `minScrollExtent` is non-zero. This prevents offsets exceeding `maxExtent` by a sub-pixel amount (e.g. 0.3 px) from being misidentified as "within range", which could trigger an incorrect physics block.
- **`SilkyScrollPosition.correctBy` override**: Added override in `SilkyScrollPosition` that suppresses the viewport's clamp correction while in the overscroll region (`outOfRange`) during an active scroll (`activity!.isScrolling`), preventing BouncingScrollPhysics bounce-back from being clamped. Normal correction is preserved during `IdleScrollActivity` and during initialization (`activity == null`).

## 2.4.1

### Fixed

- **Bounce-back freeze on BouncingScrollPhysics**: Fixed a bug where lifting the finger while the scroll offset was in the overscroll region (iOS bounce) could permanently freeze the scroll position. `_checkEdgeLockOnTouchUp` now skips `_setBlocked(true)` when the offset is outside the normal scroll extent, preventing `createBallisticSimulation()` from being suppressed by the blocking state before Flutter's `goBallistic()` fires.
- **Bounce-back recovery on unlock**: `_unlockScroll` now triggers `goBallistic(0.0)` when physics were blocked and the offset is still in the overscroll region, ensuring the bounce-back simulation restarts after the edge-lock timer expires.

## 2.4.0

### Breaking

- **Removed `recoilDurationSec`**: The `recoilDurationSec` parameter and `kDefaultRecoilDurationSec` constant have been removed. Bounce-back animations are now delegated to Flutter's native `BouncingScrollPhysics` ballistic simulation.
- **Removed `SilkyEdgeDetector`**: Edge detection logic has been inlined into `SilkyScrollState`.
- **Removed `SilkyScrollMousePointerManager`**: Fully replaced by `SilkyScrollGlobalManager`.
- **`handleTouchScroll` split**: `handleTouchScroll` has been split into `handleTrackpadScroll` and `handleTouchDragScroll` for separate handling of trackpad and touch drag inputs.
- **`silkyScrollDuration` default changed**: From `700ms` to `850ms`.

### Added

- **`EdgeForwardingMode` enum**: New enum (`none`, `sameAxisOnly`, `always`) controlling how edge-locked scroll deltas are forwarded to ancestor scrollables. Exported from barrel file.
- **`edgeForwardingMode` parameter**: Added to `SilkyScrollConfig` and `SilkyScroll` widget (default: `EdgeForwardingMode.sameAxisOnly`).
- **Native bounce delegation**: `triggerNativeBounce()` delegates overscroll bounce-back to Flutter's native `BouncingScrollPhysics` via `goBallistic(0.0)`, replacing the custom recoil animation.
- **Ancestor scrollable detection**: Edge-locking is now skipped on BouncingScrollPhysics platforms when there is no ancestor scrollable to forward to, allowing native bounce to play normally.

### Changed

- **Recoil animation replaced**: Custom recoil ticker logic removed; overscroll recovery now uses Flutter's native ballistic simulation.
- **Edge-locking on BouncingScrollPhysics**: Physics are no longer blocked during edge-lock on iOS/macOS to preserve native bounce-back animation. Physics are only blocked dynamically when an outward delta arrives for forwarding.
- **Improved gesture unlock**: `_tryGestureUnlock` now requires `currentInputSpeed > 2` before recognizing an inward direction change.
- **Ancestor forwarding axis check**: When `edgeForwardingMode == sameAxisOnly`, forwarding only occurs when the ancestor shares the same scroll axis.
- Renamed internal `currentScrollSpeed` → `currentInputSpeed`, `_recentDeltaSamples` → `_recentInputDeltaSamples` for clarity.

### Removed

- `recoilDurationSec` parameter and `kDefaultRecoilDurationSec` constant.
- `SilkyEdgeDetector` class and its test file.
- `SilkyScrollMousePointerManager` class and its test file.
- `isRecoilScroll` state field, `onAnimationStateChanged()` delegate callback, and all recoil ticker logic from `SilkyScrollAnimator`.

## 2.3.0

### Added

- **Nested scroll forwarding on edge lock**: When an inner `SilkyScroll` reaches a scroll boundary and becomes edge-locked, subsequent touch and trackpad deltas in the same (outward) direction are now forwarded to the nearest ancestor `Scrollable`, allowing the outer scroll view to take over scrolling seamlessly.

### Changed

- `SilkyScrollState` now accepts a `BuildContext` reference (set automatically by the widget) to locate ancestor scrollables at runtime.
- `handleTouchScroll` checks the edge-lock phase and delta direction before deciding whether to forward to the ancestor or continue internal processing.

## 2.2.2

### Fixed

- Removed stray `print` call in `SilkyScrollGlobalManager.setOverscrollBehaviorX()`.
- Renamed local variable `_flushWindow` → `flushWindow` in `ScrollDeltaSampleAnalyzer` to satisfy `no_leading_underscores_for_local_identifiers` lint.

## 2.2.1

### Changed

- Added `Web: Overscroll Behavior Control` section to README documenting `setOverscrollBehaviorX()` API and `OverscrollBehaviorX` enum usage.

## 2.2.0

### Breaking

- **`SilkyScrollGlobalManager` access changed**: Replaced factory constructor with `SilkyScrollGlobalManager.instance` static field for explicit singleton semantics.
- **`overscroll-behavior-x` default behavior changed**: Now permanently set to `none` on both `<html>` and `<body>` elements at initialization, instead of temporarily blocking per scroll event via Timer.

### Added

- `OverscrollBehaviorX` enum — type-safe CSS values (`auto`, `none`, `contain`) for the `overscroll-behavior-x` property, exported from the barrel file.
- `SilkyScrollGlobalManager.setOverscrollBehaviorX()` — allows manually overriding the `overscroll-behavior-x` CSS property at runtime.

### Changed

- **`blockOverscrollBehaviorX` call timing**: Now invoked only for `PointerDeviceKind.trackpad`, and before the delta threshold check instead of inside it.
- **Web helper simplified**: Removed `Timer`-based delay/reset logic; `overscroll-behavior-x` is applied once at init and can be changed explicitly via `setOverscrollBehaviorX()`.
- **Web helper targets both root elements**: `overscroll-behavior-x` is now set on both `<html>` and `<body>` (previously only `<body>`).

### Fixed

- Fixed `_lockedEdgeDirection` not being assigned when entering `BlockedScrollPhysics`, which could cause incorrect edge-lock direction tracking.

## 2.1.1

### Changed

- **`currentScrollSpeed` caching**: Results are now cached for ~16 ms (one frame), eliminating redundant `calculateAverageSpeed` calls from `_checkNeedLocking`, `_checkEdgeLockOnTouchUp`, and `_tryGestureUnlock` within the same frame.
- **`_recordDelta` trimming optimization**: Replaced `removeWhere` O(n) full-scan with `removeRange(0, count)` exploiting the time-sorted order of samples.
- **`calculateAverageSpeed` allocation reduction**: Rewrote to single-pass inline aggregation, removing 5+ intermediate list allocations (`List.of`, `windowGroups`, `windowAggregates`, `windowSpeeds`, `movementSpeeds`) per call.
- **`blockOverscrollBehaviorXHtml` Timer reuse**: Replaced per-event cancel+recreate pattern with timestamp tracking and a single reusable Timer, reducing Timer object churn during rapid trackpad scrolling.
- **`scrollDeltaX` comparison**: Replaced `(scrollDeltaX * 10).toInt() != 0` with `scrollDeltaX.abs() >= 0.1` for clarity and to avoid unnecessary float-to-int conversion.

### Removed

- Removed `recentDeltaSamples` public getter (unused externally).

## 2.1.0

### Breaking

- **Builder signature changed**: `SilkyScrollWidgetBuilder` now receives a 4th parameter `PointerDeviceKind? pointerDeviceKind`, allowing widgets to adapt their behavior based on the detected input device.
- **Removed bubbling option**: Scroll bubbling to parent views is now seamlessly integrated into the default edge-locking logic, providing a much more natural nested-scroll experience without any configuration.

### Added

- `decayLogFactor` parameter — controls the exponential-decay log factor for smooth-scroll convergence speed (default: `12`).
- `recoilDurationSec` parameter — controls the duration of the bounce-back (recoil) animation in seconds (default: `0.2`).
- `setManualPointerDeviceKind` callback — allows manually overriding the detected pointer device kind for custom input handling.
- Exported `kDefaultDecayLogFactor` and `kDefaultRecoilDurationSec` constants from barrel file.

### Changed

- Scroll bubbling is now handled automatically within the core edge-locking state machine, eliminating the need for a separate configuration option and delivering smoother transitions in nested scroll views.
- Recoil (bounce-back) animation and overshoot clamping now only activate when the widget's scroll physics is `BouncingScrollPhysics`. Non-bouncing physics (e.g. `ClampingScrollPhysics`) no longer overshoot scroll extents or trigger recoil.

## 2.0.3

### Fixed

- Fixed `include_file_not_found` warning in example `analysis_options.yaml` by replacing deprecated `flutter_lints` with `lints`.
- Removed unnecessary `package:flutter/scheduler.dart` import in `SilkyScrollState` (already provided by `material.dart`).
- Removed unused `package:flutter/foundation.dart` import in input handler tests.
- Replaced unnecessary lambdas with tear-offs in state tests.

## 2.0.2

### Changed

- **Ticker-based animation engine**: Replaced per-event `controller.animateTo()` with a single `Ticker` + `jumpTo()` loop using frame-rate-independent exponential smoothing. Eliminates the stutter caused by repeatedly cancelling and restarting easing curves on rapid mouse-wheel input.
- **Targeted rebuild**: Replaced `ListenableBuilder` (which rebuilt the entire widget subtree on every `notifyListeners()`) with a dedicated `_onPhysicsChanged` listener that calls `setState` only when the `ScrollPhysics` reference actually changes.
- **Recoil animation**: Bounce-back (recoil) to edge now runs inside the same Ticker using `Curves.easeInOutSine` interpolation, avoiding a separate `animateTo()` call that could conflict with ongoing scroll animations.

### Fixed

- **Overscroll bounce-back stutter**: Added `silkyTickerActive` flag to `SilkyScrollPosition` that suppresses `goBallistic()` while the Ticker is running. Previously, each `jumpTo()` during overscroll triggered Flutter's `BouncingScrollPhysics` spring simulation, which fought with the Ticker every frame — causing visible jitter at both top and bottom edges.

## 2.0.1

### Fixed

- `onScroll` and `onEdgeOverScroll` callbacks were not passed from `SilkyScroll` widget to `SilkyScrollState`, causing them to always be `null`.
- `onEdgeOverScroll` was never invoked; it is now called when mouse-wheel or touch/trackpad scroll reaches an edge.

## 2.0.0

### Breaking

- Removed `provider` dependency; replaced with `InheritedWidget` + `ListenableBuilder`.
- Applied Dart 3 `final class` / `abstract interface class` modifiers to all public classes. External `extends` / `implements` is no longer permitted for concrete types.
- Exported `ScrollPhysicsPhase` enum from barrel file.

### Added

- `SilkyScrollConfig.copyWith`, `==`, `hashCode`, and `toString`.
- `SilkyScrollGlobalManager.resetForTesting` (`@visibleForTesting`).
- `SilkyScrollWebManagerInterface.isWebPlatform` for conditional-import–based platform detection.
- `SilkyEdgeDetector`: sub-pixel edge detection using threshold instead of `toInt()`.
- State machine `_transitionTo` now guards against Timer creation after dispose.
- `SilkyScrollController.attach`/`detach` guard against duplicate position registration.
- Test infrastructure: `test/helpers/test_helpers.dart` shared utilities.
- New tests for `SilkyScrollAnimator`, `SilkyInputHandler`, `SilkyScrollConfig`, and integration tests (67 total, up from 24).

### Changed

- `kIsWeb` runtime branching in `SilkyInputHandler` replaced with conditional-import pattern via `isWebPlatform`.
- `ListenableBuilder` rebuild scope reduced: `onAnimationStateChanged` no longer triggers unnecessary widget rebuilds for recoil state.
- Dispose order in `SilkyScrollState` made deterministic and safe.
- Edge-detection refactored to switch expression / pattern matching (Dart 3).
- `SilkyScrollAnimator._handleRecoil` refactored to switch expression.
- Web helper magic number `Duration(milliseconds: 700)` extracted to `_kOverscrollBehaviorXResetDelay` constant.
- Lint configuration upgraded from `flutter_lints` to `package:lints/recommended.yaml` with custom rules.
- Example restructured to `example/lib/main.dart` + `example/pubspec.yaml` (pub.dev guideline).
- README image paths updated from `Bluebar1/dyn_mouse_scroll` to `Dynaruid/silky_scroll`.

### Removed

- Legacy duplicate source files under `lib/` root (moved to `lib/src/` in Phase 1).

### Fixed

- `_unlockScroll` now correctly transitions `_physicsPhase` back to `ScrollPhysicsPhase.normal`.
- `_transitionTo` checks `_disposed` before creating a new Timer.

## 1.0.16

### Added

- Support for Android's scroll stretch effect.

## 1.0.15

### Changed

- Applied dart format.

## 1.0.14

### Fixed

- Removed usage of `Platform` from `dart:io` due to compatibility issues causing errors on Safari in iOS 18.2.

## 1.0.13

### Fixed

- Fixed bug about web import.

## 1.0.12

### Added

- Added an option to configure whether scroll bubbling is propagated when an inner scroll view reaches its edge within nested scroll views.

## 1.0.11

### Changed

- General updates.

## 1.0.10

### Changed

- Updated README.

## 1.0.9

### Fixed

- Fixed drag bug.

## 1.0.8

### Changed

- Adjusted duration of scroll momentum.

## 1.0.7

### Changed

- Adjusted duration of scroll momentum.

## 1.0.6

### Changed

- The duration of scroll momentum transferred to the parent widget has been adjusted to behave more naturally.

## 1.0.5

### Added

- Enhanced scroll behavior for touch interfaces. When the scrollable content reaches the edge during an ongoing scroll gesture, if the parent widget is also scrollable, the scroll momentum is seamlessly transferred to the parent widget.

## 1.0.4

### Changed

- Changed the method of specifying the scroll duration.

## 1.0.3

### Changed

- Adjusted the interval of the scroll lock timer.

## 1.0.2

### Added

- Web support improvements.

## 1.0.1

### Added

- Web support.

## 1.0.0

### Added

- Initial release.
