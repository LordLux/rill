import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:silky_scroll/silky_scroll.dart';
import '../../domain/feed_item.dart';
import '../../theme/tokens.dart';
import '../queue_controller.dart';
import 'channel_badge.dart';
import 'media_tile.dart' show DurationBadgeTone, durationToneFor, formatVideoDuration;
import 'silky_scroll_absorber.dart';

/// A row's exit when its own X is pressed: the clear sweep's slide, then the
/// collapse that closes the gap the sweep never has to (architecture §2.8).
const Duration _rowSlide = Duration(milliseconds: 200);
const Duration _rowExit = Duration(milliseconds: 340);

/// Where the slide ends and the collapse begins, as a fraction of [_rowExit].
const double _rowSlidePhase = 200 / 340;

class EmbeddedQueuePanel extends ConsumerStatefulWidget {
  const EmbeddedQueuePanel({super.key, this.maxHeight = 400.0, this.borderRadius, this.onCollapse});

  final double maxHeight;
  final BorderRadiusGeometry? borderRadius;
  final VoidCallback? onCollapse;

  @override
  ConsumerState<EmbeddedQueuePanel> createState() => _EmbeddedQueuePanelState();
}

class _EmbeddedQueuePanelState extends ConsumerState<EmbeddedQueuePanel> with TickerProviderStateMixin {
  bool _expanded = true;

  /// True while the clear-sweep animation is running. Disables taps and
  /// locks the list from scrolling.
  bool _clearing = false;

  /// True while the pop-collapse phase is playing (squeeze → particles → shrink).
  bool _popping = false;

  /// Drives the icon rotation (0 → 0.5 turns = 180°).
  late final AnimationController _iconSpinCtrl;

  /// Squeeze scale for the pop effect. Goes 1 → ~0.02 → brief bounce → 0.
  ///
  /// Nullable backing field + `??=` getter so a `State` that predates the field
  /// survives a hot reload — deliberate, see architecture §2.8.
  AnimationController? __squeezeCtrl;
  AnimationController get _squeezeCtrl => __squeezeCtrl ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  /// Height-shrink after the pop. 1 = full height, 0 = gone.
  AnimationController? __shrinkCtrl;
  AnimationController get _shrinkCtrl => __shrinkCtrl ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  /// Per-row slide-and-fade, driving both the clear sweep and the entrance.
  ///
  /// Keyed by entry rather than index, so no diffing is needed to keep it in
  /// step with the queue — see architecture §2.8.
  final Map<QueueEntry, AnimationController> _itemCtrls = {};

  /// Keys used to measure which items are visible.
  final Map<QueueEntry, GlobalKey> _itemKeys = {};

  /// Rows on their way out: the click has been taken, the model still has them.
  /// Each names an entry, which is what makes the X spam-proof.
  final Map<QueueEntry, AnimationController> _removing = {};

  /// The scroll controller for the list so we can read scroll position.
  final ScrollController _baseScroll = ScrollController();
  late final SilkyScrollController _listScroll = SilkyScrollController(clientController: _baseScroll);

  /// Key on the list's ConstrainedBox to measure visible bounds.
  final GlobalKey _listBoxKey = GlobalKey();

  /// Key on the Material wrapper for measuring panel bounds (if needed).
  final GlobalKey _panelKey = GlobalKey();

  /// Key on the header to exactly pinpoint the center for particles.
  final GlobalKey _headerKey = GlobalKey();

  /// Active particle overlays from the pop effect.
  OverlayEntry? _particleOverlay;

  @override
  void initState() {
    super.initState();
    _iconSpinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _syncEntries(ref.read(queueProvider).entries);
  }

  @override
  void dispose() {
    if (_particleOverlay != null) {
      final entry = _particleOverlay!;
      _particleOverlay = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (entry.mounted) entry.remove();
      });
    }
    _iconSpinCtrl.dispose();
    __squeezeCtrl?.dispose();
    __shrinkCtrl?.dispose();
    for (final c in _itemCtrls.values) {
      c.dispose();
    }
    // Cleared as they are disposed, so an in-flight removal's `finally` finds
    // nothing left to dispose. It still applies its removal.
    for (final c in _removing.values) {
      c.dispose();
    }
    _removing.clear();
    _baseScroll.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  /// Bring the per-row controllers and keys in line with the queue: an entry is
  /// new or it is not, a controller still has an entry or it does not.
  void _syncEntries(List<QueueEntry> entries) {
    if (_clearing) return;

    // Nothing tracked yet means the panel is opening onto a queue that already
    // existed, so its first row is not an arrival and does not slide in.
    final opening = _itemCtrls.isEmpty;

    final present = entries.toSet();
    final departed = <AnimationController>[];
    _itemCtrls.removeWhere((entry, ctrl) {
      if (present.contains(entry)) return false;
      // Stopped now, disposed after the frame: this runs during the notification
      // that removed the row, which is still mounted and listening until the
      // build that follows.
      ctrl.stop();
      departed.add(ctrl);
      return true;
    });
    _itemKeys.removeWhere((entry, _) => !present.contains(entry));
    if (departed.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final ctrl in departed) {
          ctrl.dispose();
        }
      });
    }

    var arrival = 0;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      _itemKeys.putIfAbsent(entry, GlobalKey.new);
      if (_itemCtrls.containsKey(entry)) continue;

      final ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
      _itemCtrls[entry] = ctrl;
      if (opening && i == 0) continue;

      // The entrance is the dismissal backwards: 1 → 0 slides in from the right.
      ctrl.value = 1.0;
      final delay = Duration(milliseconds: 50 * arrival++);
      Future.delayed(delay, () {
        // The row may have been removed and its controller disposed by now, so
        // `mounted` alone is not enough.
        if (mounted && identical(_itemCtrls[entry], ctrl)) ctrl.reverse();
      });
    }
  }

  /// Scroll the list so the now-current row lands at the top of the viewport.
  ///
  /// Called a frame after the playhead moves, so the row's key is measuring
  /// the layout the new `isCurrent` flags produced rather than the stale one.
  /// A silent no-op when the row is not built at all — off-screen far enough
  /// that `ReorderableListView`'s cache extent never reached it — rather than
  /// jumping there first: every real trigger (autoplay, next/previous, or a
  /// tap on the row itself) starts from a row that is already on screen or
  /// adjacent to one that is.
  void _scrollToCurrent() {
    if (!mounted) return;
    final entry = ref.read(queueProvider).currentEntry;
    if (entry == null) return;
    final ctx = _itemKeys[entry]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _animateClear(QueueController controller) async {
    if (_clearing) return;
    setState(() => _clearing = true);

    // Who was here when the sweep started. Anything else at the end arrived
    // during it and survives — named rather than counted, because a count
    // cannot tell an addition from an addition plus a removal.
    final present = controller.entries.toSet();

    try {
      // Spin the icon 180°.
      _iconSpinCtrl.forward();

      // Figure out which items are visible inside the list viewport.
      final entries = controller.entries;
      // The row that survives the sweep is the one `clearAllButCurrent` keeps, which
      // is the *current* one — not row 0. They are the same only until autoplay
      // has advanced once.
      final keptEntry = ref.read(queueProvider).currentEntry;
      int firstVisible = 0;
      int lastVisible = entries.length - 1;

      final listRo = _listBoxKey.currentContext?.findRenderObject() as RenderBox?;
      // Nothing measurable means nothing on screen to slide, so skip to the
      // `finally` and clear outright rather than animating rows blind.
      if (listRo == null) return;

      final listTop = listRo.localToGlobal(Offset.zero).dy;
      final listBottom = listTop + listRo.size.height;

      bool foundFirst = false;
      for (int i = 0; i < entries.length; i++) {
        final ro = _itemKeys[entries[i]]?.currentContext?.findRenderObject() as RenderBox?;
        if (ro == null) continue;
        final itemTop = ro.localToGlobal(Offset.zero).dy;
        final itemBottom = itemTop + ro.size.height;
        final isVisible = itemBottom > listTop && itemTop < listBottom;
        if (isVisible && !foundFirst) {
          firstVisible = i;
          foundFirst = true;
        }
        if (isVisible) lastVisible = i;
      }
      if (!foundFirst) return; // Nothing visible: skip to the finally and clear.

      // Set up the staggered slide-off, bottom-to-top among visible items.
      final visibleCount = lastVisible - firstVisible + 1;
      const perItemDelay = Duration(milliseconds: 50);
      const perItemDuration = Duration(milliseconds: 200);

      for (int i = lastVisible; i >= firstVisible; i--) {
        final entry = entries[i];
        if (identical(entry, keptEntry)) continue; // It stays; don't slide it away.
        final staggerIndex = lastVisible - i;
        Future.delayed(perItemDelay * staggerIndex, () {
          if (mounted) _itemCtrls[entry]?.forward();
        });
      }

      // Hard cap: after 1 s, move on regardless.
      final totalStagger = perItemDelay * (visibleCount - 1) + perItemDuration;
      final waitDuration = totalStagger > const Duration(seconds: 1) ? const Duration(seconds: 1) : totalStagger;

      await Future.delayed(waitDuration);
      if (!mounted) return;

      // Collapse the panel to its closed header state.
      setState(() => _expanded = false);
      await Future.delayed(const Duration(milliseconds: 320));
      if (!mounted) return;

      // Squeeze → Pop → Shrink.
      await _popAndShrink();
    } catch (e) {
      // Unmounting mid-animation throws from the controllers; the `finally` still
      // has to apply the clear.
    } finally {
      final arrived = {
        for (final entry in controller.entries)
          if (!present.contains(entry)) entry,
      };

      controller.clearAllButCurrent(keep: arrived);

      if (mounted) {
        _resetClearState();
      }
    }
  }

  /// The X on a row: a removal that leaves something to show slides the row out,
  /// one that empties the panel plays the Clear button's whole sequence.
  ///
  /// The deciding count subtracts what is already leaving, or three fast clicks
  /// would all take the row path and pull the panel out from under themselves.
  void _requestRemove(QueueEntry entry, QueueController controller) {
    if (_clearing || _removing.containsKey(entry)) return;

    final remaining = controller.queueSize - _removing.length - 1;
    if (remaining <= 1) {
      _animateFinalRemove(entry, controller);
    } else {
      _animateRowRemove(entry, controller);
    }
  }

  /// Slide the row out, close the gap behind it, then remove it.
  ///
  /// Concurrent by design: each call holds its own entry, and the queue is only
  /// touched at the end, so none of them has to reason about the others.
  Future<void> _animateRowRemove(QueueEntry entry, QueueController controller) async {
    final ctrl = AnimationController(vsync: this, duration: _rowExit);
    setState(() => _removing[entry] = ctrl);

    try {
      ctrl.forward();
      // The wall clock, not the controller's future: a cancelled `TickerFuture`
      // never completes, and the removal below would be owed forever.
      await Future.delayed(_rowExit);
    } catch (e) {
      // The animation went away with the panel. The removal is still owed.
    } finally {
      // Null when `dispose` got there first — disposing twice is an error.
      final owned = _removing.remove(entry);
      controller.remove(entry);
      if (mounted) setState(() {});
      if (owned != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => owned.dispose());
      }
    }
  }

  /// The removal that empties the panel: slide the row, then pop the panel
  Future<void> _animateFinalRemove(QueueEntry entry, QueueController controller) async {
    if (_clearing) return;
    setState(() => _clearing = true);

    try {
      // Slide the specific item out
      _itemCtrls[entry]?.forward();

      await Future.delayed(_rowSlide);
      if (!mounted) return;

      // Collapse the panel to its closed header state
      setState(() => _expanded = false);
      await Future.delayed(const Duration(milliseconds: 320));
      if (!mounted) return;

      // Squeeze → Pop → Shrink
      await _popAndShrink();
    } catch (e) {
      // Ignore
    } finally {
      controller.remove(entry);
      if (mounted) {
        _resetClearState();
      }
    }
  }

  /// Squeeze → particle-pop → height-shrink.
  Future<void> _popAndShrink() async {
    setState(() => _popping = true);

    // Measured off the header before the squeeze distorts the box, so the burst
    // starts from its centre whatever the list height is.
    final ro = _headerKey.currentContext?.findRenderObject() as RenderBox?;
    final panelCenter = ro?.localToGlobal(ro.size.center(Offset.zero));

    _squeezeCtrl.reset();
    await _squeezeCtrl.forward();
    if (!mounted) return;

    if (panelCenter != null) _spawnParticles(panelCenter);

    await Future.delayed(const Duration(milliseconds: 380));
    if (!mounted) return;
    _shrinkCtrl.reset();
    await _shrinkCtrl.forward();
    if (!mounted) return;
  }
  
  void _onCollapse() {
    if (_clearing) return;
    
    if (widget.onCollapse != null) {
      widget.onCollapse!();
    } else {
      setState(() => _expanded = !_expanded);
    }
  }

  void _spawnParticles(Offset center) {
    final scheme = Theme.of(context).colorScheme;

    final overlay = Overlay.of(context);
    _particleOverlay = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: _ParticleBurst(
          center: center,
          color: scheme.primary,
          onComplete: () {
            _particleOverlay?.remove();
            _particleOverlay = null;
          },
        ),
      ),
    );
    overlay.insert(_particleOverlay!);
  }

  void _resetClearState() {
    if (!mounted) return;
    _iconSpinCtrl.reset();
    _squeezeCtrl.reset();
    _shrinkCtrl.reset();
    for (final c in _itemCtrls.values) {
      c.reset();
    }
    setState(() {
      _clearing = false;
      _popping = false;
      _expanded = true;
    });
    // `_syncEntries` returns early while `_clearing`, so the rows the sweep
    // removed still have controllers and keys until this reconciles them.
    _syncEntries(ref.read(queueProvider).entries);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final queue = ref.watch(queueProvider);
    final controller = ref.read(queueProvider.notifier);

    // No `setState` here: the `ref.watch` above already rebuilds on this, and
    // the listener exists only to reconcile the controllers before it does.
    ref.listen<List<QueueEntry>>(
      queueProvider.select((q) => q.entries),
      (previous, next) => _syncEntries(next),
    );

    // `version` bumps exactly when the playhead moves to a different track —
    // autoplay advancing, the next/previous shortcuts, and jumping to a row —
    // and deliberately not on a reorder or a Clear (which keeps the same
    // track playing). That is exactly "any change in the video being played",
    // so it is the one signal this needs rather than three separate ones.
    ref.listen<int>(
      queueProvider.select((q) => q.version),
      (previous, next) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
      },
    );

    if (queue.entries.length <= 1 && !_clearing && !_popping) {
      return const SizedBox.shrink();
    }

    final nextItem = queue.next;

    // The list is a `SilkyScroll` and so already on the hover stack; the header,
    // the clear button and the edges are not. See `SilkyScrollAbsorber`.
    Widget panel = SilkyScrollAbsorber(
      child: Material(
        key: _panelKey,
        color: scheme.surfaceContainer,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: widget.borderRadius ?? BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Material(
              color: Colors.transparent,
              child: Ink(
                key: _headerKey,
                color: scheme.surfaceContainerHighest,
                child: InkWell(
                  onTap: _clearing ? null : () => _onCollapse(),
                  borderRadius: _expanded ? const BorderRadius.vertical(top: Radius.circular(12)) : BorderRadius.circular(12),
                  child: Padding(
                    padding: EdgeInsets.only(left: 16, top: 12, bottom: 12, right: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  // A mix says so, and says which one. The queue
                                  // behaves differently at its end — it extends
                                  // rather than stopping — so the panel naming
                                  // it is not decoration (Task 26 §3).
                                  if (queue.isMix) ...[
                                    Icon(Icons.podcasts, size: 15, color: scheme.onSurfaceVariant),
                                    const SizedBox(width: 6),
                                  ],
                                  Expanded(
                                    child: Text(
                                      _headerTitle(queue, nextItem),
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: scheme.onSurface,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Builder(
                                builder: (context) {
                                  // Both states built every time. Passing the *current*
                                  // subtitle to both slots meant the text swapped
                                  // instantly and the crossfade faded between two
                                  // copies of the same thing.
                                  Widget subtitleFor(bool expanded) {
                                    final (text, icon) = _headerSubtitle(queue, controller, expanded);
                                    return _mixSubtitle(
                                      icon,
                                      Text(
                                        text,
                                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    );
                                  }

                                  return AnimatedCrossFade(
                                    duration: const Duration(milliseconds: 200),
                                    crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                                    // subtitle slides upwards when appearing
                                    firstChild: subtitleFor(false),
                                    secondChild: subtitleFor(true),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        AnimatedCrossFade(
                          duration: const Duration(milliseconds: 200),
                          crossFadeState: _expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                          firstChild: Row(
                            children: [
                              TextButton(
                                onPressed: _clearing ? null : () => _animateClear(controller),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: scheme.onSurface,
                                ),
                                child: Row(
                                  children: [
                                    RotationTransition(
                                      turns: _iconSpinCtrl.drive(
                                        Tween(begin: 0.0, end: 0.5).chain(CurveTween(curve: Curves.easeOutCubic)),
                                      ),
                                      child: const Icon(Icons.clear_all_sharp, size: 18),
                                    ),
                                    const SizedBox(width: 4),
                                    const Text('Clear'),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 2),
                            ],
                          ),
                          secondChild: const SizedBox.shrink(),
                        ),
                        AnimatedRotation(
                          turns: _expanded ? 0 : 0.5,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                          child: IconButton(
                            icon: Icon(Icons.keyboard_arrow_up),
                            color: scheme.onSurfaceVariant,
                            onPressed: _clearing ? null : () => _onCollapse(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Queue List
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 300),
              sizeCurve: Curves.easeOutCubic,
              firstCurve: Curves.easeOut,
              secondCurve: Curves.easeOut,
              crossFadeState: _expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
              secondChild: const SizedBox(width: double.infinity, height: 0),
              firstChild: ConstrainedBox(
                key: _listBoxKey,
                constraints: BoxConstraints(maxHeight: math.max(0.0, widget.maxHeight - 66.0)),
                child: SilkyScroll(
                  controller: _listScroll,
                  builder: (context, scrollController, physics, pointerDeviceKind) {
                    return ReorderableListView.builder(
                      scrollController: scrollController,
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      physics: _clearing ? const NeverScrollableScrollPhysics() : physics,
                      itemCount: queue.entries.length,
                      onReorderItem: (oldIndex, target) => controller.reorder(oldIndex, target),
                      itemBuilder: (context, index) {
                        final entry = queue.entries[index];
                        return _QueueItemTile(
                          key: _itemKeys.putIfAbsent(entry, GlobalKey.new),
                          entry: entry,
                          index: index,
                          isCurrent: index == queue.currentIndex,
                          scheme: scheme,
                          controller: controller,
                          dismissAnimation: _itemCtrls[entry],
                          removeAnimation: _removing[entry],
                          clearing: _clearing,
                          onRemove: () => _requestRemove(entry, controller),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );

    panel = Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: panel,
    );

    if (_popping) {
      panel = AnimatedBuilder(
        animation: Listenable.merge([_squeezeCtrl, _shrinkCtrl]),
        builder: (context, child) {
          // scaleX outruns scaleY so the box deforms rather than merely shrinking.
          final sq = Curves.easeInExpo.transform(_squeezeCtrl.value);
          final scaleX = 1.0 - sq * 0.99;
          final scaleY = 1.0 - sq * 0.95;

          final shrink = Curves.easeInCubic.transform(_shrinkCtrl.value);
          final heightFactor = 1.0 - shrink;

          return Opacity(
            opacity: (1.0 - sq * 0.95).clamp(0.0, 1.0),
            child: ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: heightFactor,
                child: Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.diagonal3Values(scaleX, scaleY, 1.0),
                  child: child,
                ),
              ),
            ),
          );
        },
        child: panel,
      );
    }

    return panel;
  }

  Widget _mixSubtitle(Widget? icon, Text textWidget) {
    if (icon != null)
      return Row(
        children: [
          icon,
          const SizedBox(width: 4),
          textWidget,
        ],
      );

    return textWidget;
  }
}

/// Particle burst effect
class _ParticleBurst extends StatefulWidget {
  const _ParticleBurst({
    required this.center,
    required this.color,
    required this.onComplete,
  });

  final Offset center;
  final Color color;
  final VoidCallback onComplete;

  @override
  State<_ParticleBurst> createState() => _ParticleBurstState();
}

class _ParticleBurstState extends State<_ParticleBurst> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final List<_Particle> _particles;

  static const _count = 12;
  static final _rng = math.Random();

  @override
  void initState() {
    super.initState();
    _ctrl =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 500),
        )..addStatusListener((s) {
          if (s == AnimationStatus.completed) widget.onComplete();
        });

    _particles = List.generate(_count, (_) {
      final angle = _rng.nextDouble() * 2 * math.pi;
      final speed = 40.0 + _rng.nextDouble() * 80.0;
      final radius = 2.0 + _rng.nextDouble() * 3.0;
      return _Particle(
        dx: math.cos(angle) * speed,
        dy: math.sin(angle) * speed,
        radius: radius,
      );
    });

    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return CustomPaint(
          size: MediaQuery.of(context).size,
          painter: _ParticlePainter(
            particles: _particles,
            center: widget.center,
            progress: _ctrl.value,
            color: widget.color,
          ),
        );
      },
    );
  }
}

class _Particle {
  _Particle({required this.dx, required this.dy, required this.radius});
  final double dx;
  final double dy;
  final double radius;
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter({
    required this.particles,
    required this.center,
    required this.progress,
    required this.color,
  });

  final List<_Particle> particles;
  final Offset center;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOut.transform(progress);
    final opacity = (1.0 - Curves.easeIn.transform(progress)).clamp(0.0, 1.0);

    for (final p in particles) {
      final pos = center + Offset(p.dx * t, p.dy * t);
      final r = p.radius * (1.0 - progress * 0.5);
      final paint = Paint()..color = color.withValues(alpha: opacity);
      canvas.drawCircle(pos, r, paint);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.progress != progress;
}

/// Queue item tile
/// The panel's headline.
///
/// A mix is named rather than called "Queue": it is the one queue the user did
/// not assemble, so which mix it is, is the only thing that identifies it.
String _headerTitle(QueueState queue, VideoItem? nextItem) {
  final mix = queue.mix;
  if (mix != null) return mix.title ?? 'Mix';
  return nextItem != null ? 'Next: ${nextItem.title}' : 'Queue';
}

/// The line under the headline.
///
/// **A mix shows no position, deliberately.** `n / total` is honest for a
/// hand-built queue and misleading for a radio: the total is a sliding window
/// that grows by 24 every time the queue tops itself up, so a viewer watching
/// the denominator climb would reasonably read it as the list changing under
/// them rather than as the thing working. What a mix shows instead is what is
/// coming next, and — per §4 — whether it has stopped.
(String, Widget?) _headerSubtitle(QueueState queue, QueueController controller, bool expanded) {
  final position = queue.currentIndex != null ? '${queue.currentIndex! + 1} / ${queue.items.length}' : '${queue.items.length} items';

  final mix = queue.mix;

  if (expanded) return ('Mixes are playlists YouTube makes for you', null);
  if (mix == null) return (position, null);
  if (controller.mixError != null) return ('Paused. Couldn\'t load more', null);
  if (mix.exhausted) return ('End of mix', null);

  final nextItem = queue.next;
  return (nextItem?.title != null ? 'Next: ${nextItem?.title}' : 'Mix', null);
}

class _QueueItemTile extends StatefulWidget {
  const _QueueItemTile({
    required super.key,
    required this.entry,
    required this.index,
    required this.isCurrent,
    required this.scheme,
    required this.controller,
    required this.onRemove,
    this.dismissAnimation,
    this.removeAnimation,
    this.clearing = false,
  });

  final QueueEntry entry;
  final int index;
  final bool isCurrent;
  final ColorScheme scheme;
  final QueueController controller;
  final VoidCallback onRemove;

  /// The shared slide, driven by the clear sweep and the entrance
  final AnimationController? dismissAnimation;

  /// This row's own exit, non-null from the click until the queue is told
  final AnimationController? removeAnimation;

  final bool clearing;

  /// The video item this row represents
  VideoItem get item => entry.item;

  /// On its way out: inert to everything, because the decision is already taken
  bool get removing => removeAnimation != null;

  @override
  State<_QueueItemTile> createState() => _QueueItemTileState();
}

class _QueueItemTileState extends State<_QueueItemTile> {
  bool _isHovered = false;

  /// The duration / LIVE / STATION pill, scaled down for the queue row's
  /// 72×40 thumbnail. Same source of truth as the grid tiles
  /// ([formatVideoDuration], [durationToneFor]) — a mix's synthetic seed-video
  /// entry has neither a duration nor a live flag, so this draws nothing for
  /// it, which is deliberate (see `CLAUDE.md`'s mix-in-queue note).
  Widget _durationBadge(BuildContext context) {
    final tokens = Theme.of(context).tokens;
    final tone = durationToneFor(widget.item);
    final text = tone == DurationBadgeTone.station ? 'STATION' : (tone == DurationBadgeTone.live ? 'LIVE' : formatVideoDuration(widget.item));
    if (text == null) return const SizedBox.shrink();

    final isLiveLike = tone == DurationBadgeTone.live || tone == DurationBadgeTone.station;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
      decoration: BoxDecoration(
        color: isLiveLike ? tokens.liveBadge.withValues(alpha: 0.8) : tokens.scrim.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: tokens.onScrim,
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
          height: 1.4,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final inert = widget.clearing || widget.removing;

    Widget tile = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Stack(
        children: [
          ListTile(
            selected: widget.isCurrent,
            selectedTileColor: widget.scheme.surfaceContainerHigh,
            mouseCursor: inert ? SystemMouseCursors.basic : SystemMouseCursors.click,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4).copyWith(right: 16),
            leading: SizedBox(
              width: 82,
              height: 60,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      widget.item.thumbnailUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(color: widget.scheme.surfaceContainerHighest),
                    ),
                    Positioned(
                      bottom: 2,
                      right: 2,
                      child: _durationBadge(context),
                    ),
                  ],
                ),
              ),
            ),
            title: Text(
              widget.item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: widget.isCurrent ? widget.scheme.primary : widget.scheme.onSurface,
              ),
            ),
            subtitle: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.item.channelName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: widget.scheme.onSurfaceVariant),
                  ),
                ),
                ChannelBadge(
                  channelId: widget.item.channelId,
                  isArtistChannel: widget.item.isArtistChannel,
                  isVerified: widget.item.isVerified,
                  size: 12,
                  paddingLeft: 4,
                ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 50),
                  crossFadeState: !inert && _isHovered ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                  firstChild: Tooltip(
                    message: 'Remove',
                    waitDuration: const Duration(milliseconds: 300),
                    preferBelow: false,
                    showDuration: const Duration(milliseconds: 800),
                    exitDuration: const Duration(milliseconds: 0),
                    child: IconButton(
                      mouseCursor: SystemMouseCursors.click,
                      icon: Icon(Icons.close, size: 18, color: widget.scheme.onSurfaceVariant),
                      onPressed: widget.onRemove,
                    ),
                  ),
                  secondChild: const SizedBox.shrink(),
                ),
                if (!inert)
                  ReorderableDragStartListener(
                    index: widget.index,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Icon(Icons.drag_handle, size: 18, color: widget.scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
            onTap: inert ? null : () => widget.controller.jumpTo(widget.index),
          ),
          // Current indicator
          if (widget.isCurrent)
            Positioned(
              left: -0.5,
              top: 0,
              bottom: 0,
              child: Icon(Icons.play_arrow, color: widget.scheme.onSurfaceVariant, size: 12),
            ),
        ],
      ),
    );

    // This row's own exit takes precedence over the shared slide.
    final removal = widget.removeAnimation;
    if (removal != null) {
      return AnimatedBuilder(
        animation: removal,
        builder: (context, child) {
          // Slide first, then collapse — by then the row is transparent, so what
          // the eye follows is the rows below rising.
          final t = removal.value;
          final slide = Curves.easeInCubic.transform((t / _rowSlidePhase).clamp(0.0, 1.0));
          final collapse = Curves.easeOutCubic.transform(
            ((t - _rowSlidePhase) / (1 - _rowSlidePhase)).clamp(0.0, 1.0),
          );
          return ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: 1.0 - collapse,
              child: Opacity(
                opacity: 1.0 - slide,
                child: FractionalTranslation(
                  translation: Offset(slide * 0.5, 0),
                  child: child,
                ),
              ),
            ),
          );
        },
        child: tile,
      );
    }

    // Wrap with the dismiss/enter animation when available.
    final anim = widget.dismissAnimation;
    if (anim != null) {
      tile = AnimatedBuilder(
        animation: anim,
        builder: (context, child) {
          // When entering, the controller runs 1→0 (reverse), so the visual
          // is the mirror of the dismiss: slide in from the right.
          final t = Curves.easeInCubic.transform(anim.value);
          return Opacity(
            opacity: 1.0 - t,
            child: FractionalTranslation(
              translation: Offset(t * 0.5, 0),
              child: child,
            ),
          );
        },
        child: tile,
      );
    }

    return tile;
  }
}
