# Silky Scroll

`SilkyScroll` is a Flutter package that provides natural and smooth scroll animations for mouse wheel, trackpad, and touch inputs.

<p align="center">
  <img src="https://raw.githubusercontent.com/Dynaruid/silky_scroll/refs/heads/main/assets/scroll.webp" width="600" alt="✨ SilkyScroll vs ↔ Default comparison"/>
</p>

<p align="center">
  <b>✨ SilkyScroll</b>&nbsp;&nbsp;&nbsp;↔&nbsp;&nbsp;&nbsp;<b>Default</b>
</p>

---

## Features

- **Smooth Scroll Animation** — Interpolates mouse wheel input for seamless scrolling
- **Smart Input Detection** — Automatically detects mouse, trackpad, and touch to apply appropriate physics
- **Edge Locking & Nested Forwarding** — Locks scrolling at boundaries and automatically forwards touch/trackpad deltas to the parent scroll view
- **Stretch Effect** — Supports Android stretch and iOS bounce overscroll effects
- **Horizontal Scroll** — Supports both horizontal and vertical directions
- **Preset Widgets** — Drop-in `SilkyListView`, `SilkyGridView`, `SilkyCustomScrollView`, `SilkySingleChildScrollView` with zero boilerplate
- **All Platforms** — Android, iOS, Web, Windows, macOS, Linux

---

## Getting Started

```bash
flutter pub add silky_scroll
```

---

## Basic Usage

Simply wrap your scrollable widget with `SilkyScroll`.

```dart
SilkyScroll(
  builder: (context, controller, physics, pointerDeviceKind) => ListView(
    controller: controller,
    physics: physics,
    children: [...],
  ),
)
```

---

## Preset Widgets

Preset widgets are drop-in replacements for Flutter's scrollable widgets. They eliminate the builder boilerplate by automatically wiring `controller` and `physics` internally.

| Preset Widget                | Wraps                   |
| ---------------------------- | ----------------------- |
| `SilkyListView`              | `ListView`              |
| `SilkyListView.builder`      | `ListView.builder`      |
| `SilkyListView.separated`    | `ListView.separated`    |
| `SilkyGridView`              | `GridView`              |
| `SilkyGridView.builder`      | `GridView.builder`      |
| `SilkyGridView.count`        | `GridView.count`        |
| `SilkyGridView.extent`       | `GridView.extent`       |
| `SilkyCustomScrollView`      | `CustomScrollView`      |
| `SilkySingleChildScrollView` | `SingleChildScrollView` |

### Before (builder pattern)

```dart
SilkyScroll(
  builder: (context, controller, physics, _) => ListView.builder(
    controller: controller,
    physics: physics,
    itemCount: 100,
    itemBuilder: (context, i) => ListTile(title: Text('Item $i')),
  ),
)
```

### After (preset)

```dart
SilkyListView.builder(
  itemCount: 100,
  itemBuilder: (context, i) => ListTile(title: Text('Item $i')),
)
```

### SilkyCustomScrollView

```dart
SilkyCustomScrollView(
  slivers: [
    SliverAppBar(title: Text('Header')),
    SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => ListTile(title: Text('Item $i')),
        childCount: 50,
      ),
    ),
  ],
)
```

### SilkySingleChildScrollView

```dart
SilkySingleChildScrollView(
  padding: EdgeInsets.all(16),
  child: Column(children: [...]),
)
```

### Customizing SilkyScroll behavior

Preset widgets accept all `SilkyScroll` parameters directly, or via a shared `SilkyScrollConfig`:

```dart
// Individual parameters
SilkyListView.builder(
  scrollSpeed: 1.5,
  animationCurve: Curves.easeOutCubic,
  itemCount: 100,
  itemBuilder: (context, i) => Text('$i'),
)

// Shared config (overrides individual parameters when provided)
final config = SilkyScrollConfig(scrollSpeed: 1.5);

SilkyListView.builder(
  silkyConfig: config,
  itemCount: 100,
  itemBuilder: (context, i) => Text('$i'),
)
```

### Detecting pointer device kind

```dart
SilkyListView.builder(
  itemCount: 100,
  itemBuilder: (context, i) => Text('$i'),
  onPointerDeviceKindChanged: (kind) {
    // PointerDeviceKind.mouse, .trackpad, .touch
  },
)
```

---

## Custom Usage

You can connect an external `ScrollController` and fine-tune animation properties.

```dart
class _ScrollExampleState extends State<ScrollExample> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SilkyScroll(
        controller: _scrollController,
        physics: const BouncingScrollPhysics(),
        silkyScrollDuration: const Duration(milliseconds: 2000),
        scrollSpeed: 1.5,
        animationCurve: Curves.easeOutQuart,
        direction: Axis.vertical,
        builder: (context, controller, physics, pointerDeviceKind) {
          return ListView.builder(
            controller: controller,
            physics: physics,
            itemCount: 50,
            itemBuilder: (context, index) => ListTile(title: Text('Item $index')),
          );
        },
      ),
    );
  }
}
```

---

## Using SilkyScrollConfig

You can share the same configuration across multiple `SilkyScroll` widgets.

```dart
const config = SilkyScrollConfig(
  silkyScrollDuration: Duration(milliseconds: 1000),
  scrollSpeed: 1.5,
  animationCurve: Curves.easeOutCubic,
  enableStretchEffect: true,
);

SilkyScroll.fromConfig(
  config: config,
  builder: (context, controller, physics, pointerDeviceKind) => ListView(...),
)
```

---

## Horizontal Mouse Wheel Behavior

For horizontal `SilkyScroll` widgets, regular mouse-wheel vertical deltas are
forwarded to a vertical parent scroll view when one is the nearest scrollable
ancestor. If there is no vertical parent, the horizontal scroll view handles the
wheel itself. That keeps standalone horizontal lists and horizontal-in-
horizontal lists usable, while vertical pages still scroll naturally. Touch and
trackpad scrolling keep their native behavior.

Holding Shift turns a mouse-wheel delta into an explicit horizontal-scroll
command. In that mode, the horizontal `SilkyScroll` owns the wheel signal even
at its start or end edge, so the same Shift-wheel gesture does not spill into a
vertical parent scroll view.

Use `mouseWheelVerticalDeltaBehavior` to tune this policy:

```dart
SilkyScroll(
  direction: Axis.horizontal,
  mouseWheelVerticalDeltaBehavior: MouseWheelVerticalDeltaBehavior.always,
  builder: (context, controller, physics, pointerDeviceKind) => ListView(
    scrollDirection: Axis.horizontal,
    controller: controller,
    physics: physics,
    children: [...],
  ),
)
```

Available values:

- `forwardToVerticalAncestorOrSelf` (default): vertical parent first, otherwise self
- `forwardToVerticalAncestor`: vertical parent only
- `always`: always scroll this horizontal view
- `shiftOnly`: ignore vertical wheel deltas unless Shift is pressed

With `always`, mouse-wheel input is owned by the horizontal view first,
regardless of wheel delta axis. Without Shift, when that horizontal view is
already at the start or end edge, the wheel delta is handed to the nearest
parent scroll view, regardless of the parent's axis. Holding Shift keeps the
gesture locked to the horizontal view even at the edge. Set
`edgeForwardingMode` to `EdgeForwardingMode.none` to prevent this edge handoff.

---

## Web: Overscroll Behavior Control

On web, `SilkyScroll` automatically sets `overscroll-behavior-x: none` while the widget is mounted (controlled by the `blockWebOverscrollBehaviorX` parameter, default `true`). This blocks browser back/forward swipe gestures.

When all `SilkyScroll` widgets with blocking enabled are disposed, the CSS is automatically restored to `auto`.

### Per-widget control

```dart
// Disable browser swipe blocking for this widget
SilkyScroll(
  blockWebOverscrollBehaviorX: false,
  builder: (context, controller, physics, pointerDeviceKind) => ListView(...),
)
```

### Global control

You can also set a global block flag that persists independently of widgets:

```dart
import 'package:silky_scroll/silky_scroll.dart';

// Force block browser swipe gestures globally
SilkyScrollGlobalManager.instance
    .setBlockOverscrollBehaviorX(true);

// Remove the global block (widgets may still block individually)
SilkyScrollGlobalManager.instance
    .setBlockOverscrollBehaviorX(false);
```

The actual CSS is set to `none` when **any** widget requests blocking **or** the global flag is `true`. It reverts to `auto` only when both are inactive.

> On non-web platforms this is a no-op.

---

## Parameters

| Parameter                         | Type                              | Default                           | Description                                                    |
| --------------------------------- | --------------------------------- | --------------------------------- | -------------------------------------------------------------- |
| `controller`                      | `ScrollController?`               | `null`                            | External scroll controller                                     |
| `silkyScrollDuration`             | `Duration`                        | `1600ms`                          | Scroll animation duration                                      |
| `scrollSpeed`                     | `double`                          | `1`                               | Scroll speed multiplier                                        |
| `animationCurve`                  | `Curve`                           | `Curves.easeOutCirc`              | Animation curve                                                |
| `direction`                       | `Axis`                            | `vertical`                        | Scroll direction                                               |
| `physics`                         | `ScrollPhysics`                   | `ScrollPhysics()`                 | Scroll physics                                                 |
| `edgeLockingDelay`                | `Duration`                        | `650ms`                           | Lock delay after reaching edge                                 |
| `overScrollingLockingDelay`       | `Duration`                        | `700ms`                           | Overscroll lock delay                                          |
| `enableStretchEffect`             | `bool`                            | `true`                            | Overscroll stretch effect                                      |
| `edgeForwardingMode`              | `EdgeForwardingMode`              | `EdgeForwardingMode.sameAxisOnly` | Edge delta forwarding to ancestor                              |
| `mouseWheelVerticalDeltaBehavior` | `MouseWheelVerticalDeltaBehavior` | `forwardToVerticalAncestorOrSelf` | Shift-free vertical mouse wheel behavior for horizontal scroll |
| `decayLogFactor`                  | `double`                          | `12`                              | Smooth-scroll convergence speed                                |
| `blockWebOverscrollBehaviorX`     | `bool`                            | `true`                            | Block browser swipe on web                                     |
| `setManualPointerDeviceKind`      | `Function?`                       | `null`                            | Manual pointer device override                                 |
| `onScroll`                        | `Function(double)?`               | `null`                            | Scroll event callback                                          |
| `onEdgeOverScroll`                | `Function(double)?`               | `null`                            | Edge overscroll callback                                       |
| `debugMode`                       | `bool`                            | `false`                           | Debug logging                                                  |

---

## License

MIT
