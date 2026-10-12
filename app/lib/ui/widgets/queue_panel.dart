import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/services.dart' show KeyDownEvent, KeyEvent, KeyRepeatEvent, LogicalKeyboardKey, Clipboard, ClipboardData;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:silky_scroll/silky_scroll.dart';
import '../../domain/feed_item.dart';
import '../../theme/tokens.dart';
import '../focus_ring.dart';
import '../focus_surface.dart';
import '../queue_controller.dart';
import '../spoken.dart';
import 'channel_badge.dart';
import 'shortcut_tooltip.dart';
import 'media_tile.dart' show DurationBadgeTone, durationToneFor, formatVideoDuration;
import '../pages/playlist.dart' show openPlaylistPage;

/// A row's exit when its own X is pressed: the clear sweep's slide, then the
/// collapse that closes the gap the sweep never has to (architecture §2.8).
const Duration _rowSlide = Duration(milliseconds: 200);
const Duration _rowExit = Duration(milliseconds: 340);

/// How close to the end of the loaded rows a scroll has to get before the next
/// page of a playlist is asked for: about five rows.
const double _loadMoreWithin = 360;

/// How many rows of one batch play the staggered entrance.
const int _staggeredArrivals = 12;

/// Where the slide ends and the collapse begins, as a fraction of [_rowExit].
const double _rowSlidePhase = 200 / 340;

/// The header menu's rows, and through them the menu: never narrower than this.
///
/// On the rows because `MenuStyle.minimumSize` does not do it: the panel is laid
/// out at the width of its widest row inside the box that minimum sizes, so a
/// menu holding only "Copy link" stayed as narrow as those two words.
final ButtonStyle _headerMenuItemStyle = MenuItemButton.styleFrom(minimumSize: const Size(200, 48));

/// The number column's width per digit, at the row number's 11 px.
const double _digitWidth = 7;

/// Over how many rows the number column widens ahead of a longer number.
const double _digitRampRows = 10;

/// A row's height before the list has laid one out to measure.
const double _nominalRowExtent = 80;

/// How many digits wide a playlist's number column is, when [bottomRow] is the
/// number of the row at the list's bottom edge — fractional, so 90.5 is row 90
/// half scrolled in.
///
/// A function of position alone, so it is the same scrolling either way: the
/// column takes the ten rows before a longer number to widen for it, and is
/// full width as that number comes into view. Never wider than [maxDigits],
/// which is what the playlist's last row needs.
@visibleForTesting
double numberColumnDigits(double bottomRow, int maxDigits) {
  final row = math.max(bottomRow, 1.0);
  var digits = 1;
  var longer = 10.0; // the first number with one more digit
  while (row >= longer) {
    digits++;
    longer *= 10;
  }
  final ramp = ((row - (longer - _digitRampRows)) / _digitRampRows).clamp(0.0, 1.0);
  return math.min(digits + ramp, maxDigits.toDouble());
}

/// The address of what the queue is playing through, or null for a queue put
/// together by hand, which has none.
///
/// A playlist is its own page. A mix has no page: YouTube addresses one as a
/// video *in* it, `watch?v=…&list=RD…`, so the link is the video the queue is on.
@visibleForTesting
String? queueLinkFor(QueueState queue) {
  final mix = queue.mix;
  if (mix == null) return null;
  final playing = queue.current?.id;
  if (mix.isPlaylist || playing == null) return 'https://www.youtube.com/playlist?list=${mix.playlistId}';
  return 'https://www.youtube.com/watch?v=$playing&list=${mix.playlistId}';
}

class _ContextMenuIntent extends Intent {
  const _ContextMenuIntent();
}

class EmbeddedQueuePanel extends ConsumerStatefulWidget {
  const EmbeddedQueuePanel({super.key, this.maxHeight = 400.0, this.borderRadius, this.onCollapse});

  final double maxHeight;
  final BorderRadiusGeometry? borderRadius;
  final VoidCallback? onCollapse;

  @override
  ConsumerState<EmbeddedQueuePanel> createState() => _EmbeddedQueuePanelState();
}

class _EmbeddedQueuePanelState extends ConsumerState<EmbeddedQueuePanel> with TickerProviderStateMixin {
  final MenuController _headerMenuCtrl = MenuController();

  /// The enclosing page's scroll position, watched to close the header menu.
  ScrollPosition? _pageScroll;

  /// The press now in progress closed the header menu, so it is not also a
  /// click on the header: dismissing a menu should not collapse the queue.
  bool _pressClosedMenu = false;
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

  /// How many digits wide a playlist's number column is right now, for every
  /// row at once. Follows the scroll position ([numberColumnDigits]).
  final ValueNotifier<double> _numberDigits = ValueNotifier<double>(1);

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
    _syncNumberDigits();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The page the panel sits in: scrolling it moves the header out from under its menu.
    final pageScroll = Scrollable.maybeOf(context)?.position;
    if (_pageScroll != pageScroll) {
      _pageScroll?.removeListener(_closeHeaderMenu);
      _pageScroll = pageScroll;
      _pageScroll?.addListener(_closeHeaderMenu);
    }
  }

  void _closeHeaderMenu() {
    if (_headerMenuCtrl.isOpen) _headerMenuCtrl.close();
  }

  /// Size the number column for the rows in view. [metrics] is the list's
  /// scroll position; without one it is read from the controller, and before
  /// the list has laid out it is worked out from the panel's height.
  void _syncNumberDigits([ScrollMetrics? metrics]) {
    if (!mounted) return;
    final queue = ref.read(queueProvider);
    final count = queue.entries.length;
    if (count == 0 || !(queue.mix?.isPlaylist ?? false)) return;

    final at = metrics ?? (_baseScroll.hasClients ? _baseScroll.position : null);
    var rowExtent = _nominalRowExtent;
    var bottom = math.max(0.0, widget.maxHeight - 66.0);
    if (at != null && at.hasContentDimensions && at.hasViewportDimension) {
      rowExtent = at.extentTotal / count;
      bottom = at.extentBefore + at.extentInside;
    }
    if (rowExtent <= 0) return;

    // The row whose top edge is at the bottom of the list: the next to appear.
    final bottomRow = math.min(bottom / rowExtent, count.toDouble()) + 1;
    _numberDigits.value = numberColumnDigits(bottomRow, '${queue.displayLength}'.length);
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
    try {
      _pageScroll?.removeListener(_closeHeaderMenu);
    } catch (_) {}
    _numberDigits.dispose();
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
      // A playlist page is a hundred rows. Only the first screenful of a batch
      // can be seen arriving; the rest are simply there, rather than each
      // holding a timer for up to five seconds to slide in off screen.
      if (arrival >= _staggeredArrivals) continue;

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

    // Rows arriving, the panel resizing and the queue becoming a playlist all
    // change what is in view without a scroll.
    final numbered = queue.mix?.isPlaylist ?? false;
    if (numbered) WidgetsBinding.instance.addPostFrameCallback((_) => _syncNumberDigits());

    final nextItem = queue.next;

    Widget panel = Material(
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
          FocusTraversalOrder(
            order: const NumericFocusOrder(0),
            child: Material(
              color: Colors.transparent,
              child: MenuAnchor(
                controller: _headerMenuCtrl,
                style: MenuStyle(
                  backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
                  shape: const WidgetStatePropertyAll(
                    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
                  ),
                  mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
                ),
                menuChildren: [
                  if (queue.mix?.isPlaylist ?? false)
                    MenuItemButton(
                      style: _headerMenuItemStyle,
                      leadingIcon: const Icon(Icons.playlist_play),
                      onPressed: () => openPlaylistPage(queue.mix!.playlistId),
                      child: const Text('Go to Playlist'),
                    ),
                  // A mix too: it has a link, only no page to go to.
                  if (queueLinkFor(queue) case final url?)
                    MenuItemButton(
                      style: _headerMenuItemStyle,
                      leadingIcon: const Icon(Icons.link),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: url));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Link copied to clipboard'),
                              behavior: SnackBarBehavior.floating,
                              duration: Duration(seconds: 2),
                            ),
                          );
                        }
                      },
                      child: const Text('Copy link'),
                    ),
                ],
                builder: (context, menuController, child) {
                  return Shortcuts(
                    shortcuts: {
                      SingleActivator(LogicalKeyboardKey.f10, shift: true): const _ContextMenuIntent(),
                    },
                    child: Actions(
                      actions: {
                        _ContextMenuIntent: CallbackAction<_ContextMenuIntent>(
                          // Nothing to offer on a queue put together by hand, so no empty menu.
                          onInvoke: (_) => menuController.isOpen
                              ? menuController.close()
                              : (queueLinkFor(queue) == null ? null : menuController.open()),
                        ),
                      },
                      child: Ink(
                        key: _headerKey,
                        color: scheme.surfaceContainerHighest,
                        // The header is the menu's own anchor, so a press on it is not
                        // the "outside" press that closes the menu everywhere else.
                        child: Listener(
                          onPointerDown: (event) {
                            _pressClosedMenu = event.buttons == kPrimaryButton && menuController.isOpen;
                            if (_pressClosedMenu) menuController.close();
                          },
                          child: GestureDetector(
                            excludeFromSemantics: true,
                            // Open or not: an open menu moves to the new place, as it does
                            // for a right-click anywhere else.
                            onSecondaryTapUp: (details) => queueLinkFor(queue) == null
                                ? null
                                : menuController.open(position: details.localPosition),
                            child: InkWell(
                              onTap: _clearing
                                  ? null
                                  : () {if (!_pressClosedMenu) _onCollapse();},
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
                                                Icon(
                                                  queue.mix!.isPlaylist ? Icons.playlist_play : Icons.podcasts,
                                                  size: queue.mix!.isPlaylist ? 18 : 15,
                                                  color: scheme.onSurfaceVariant,
                                                ),
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
                                              Text line(String text) => Text(
                                                text,
                                                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              );

                                              // A playlist keeps its position where it is and
                                              // changes only what follows it.
                                              if (queue.mix?.isPlaylist ?? false) {
                                                Widget tail(bool expanded) {
                                                  final text = _playlistTail(queue, controller, expanded);
                                                  return text == null ? const SizedBox(width: double.infinity) : line(' · $text');
                                                }

                                                final same = _playlistTail(queue, controller, false) == _playlistTail(queue, controller, true);
                                                return Row(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    line(_position(queue)),
                                                    Expanded(
                                                      // One widget when both states say the same thing,
                                                      // so there is nothing to animate and nothing said twice.
                                                      child: same
                                                          ? tail(_expanded)
                                                          : AnimatedCrossFade(
                                                              duration: const Duration(milliseconds: 200),
                                                              alignment: Alignment.topLeft,
                                                              crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                                                              firstChild: tail(false),
                                                              secondChild: tail(true),
                                                            ),
                                                    ),
                                                  ],
                                                );
                                              }

                                              Widget subtitleFor(bool expanded) {
                                                final (text, icon) = _headerSubtitle(queue, controller, expanded);
                                                return _mixSubtitle(icon, line(text));
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
                                    // The tooltip is outside the rotation (it would be turned upside down) and opens to
                                    // the left: above the button is outside the panel, which clips it.
                                    ShortcutTooltip(
                                      label: _expanded ? 'Collapse queue' : 'Expand queue',
                                      silent: true,
                                      side: TooltipSide.left,
                                      child: AnimatedRotation(
                                        turns: _expanded ? 0 : 0.5,
                                        duration: const Duration(milliseconds: 300),
                                        curve: Curves.easeOutCubic,
                                        child: IconButton(
                                          // The icon names the button: `IconButton(tooltip:)` used to.
                                          icon: Icon(Icons.keyboard_arrow_up, semanticLabel: _expanded ? 'Collapse queue' : 'Expand queue'),
                                          color: scheme.onSurfaceVariant,
                                          onPressed: _clearing ? null : () => _onCollapse(),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
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
                builder: (context, scrollController, physics, _) {
                  // A playlist loads only so far ahead of the playhead; reaching the
                  // end of what is here asks for the next page.
                  return NotificationListener<ScrollNotification>(
                    onNotification: (notification) {
                      final metrics = notification.metrics;
                      if (metrics.axis == Axis.vertical && metrics.extentAfter < _loadMoreWithin) {
                        controller.loadMoreOfPlaylist();
                      }
                      if (notification.depth == 0) _syncNumberDigits(metrics);
                      if (notification is ScrollUpdateNotification) _closeHeaderMenu();
                      return false;
                    },
                    child: ReorderableListView.builder(
                      scrollController: scrollController,
                      shrinkWrap: true,
                      buildDefaultDragHandles: false,
                      physics: _clearing ? const NeverScrollableScrollPhysics() : physics,
                      itemCount: queue.entries.length,
                      onReorderItem: (oldIndex, target) => controller.reorder(oldIndex, target),
                      itemBuilder: (context, index) {
                        final entry = queue.entries[index];
                        return FocusTraversalOrder(
                          key: ValueKey(_itemKeys.putIfAbsent(entry, GlobalKey.new)),
                          order: NumericFocusOrder(1.0 + index),
                          child: _QueueItemTile(
                            key: _itemKeys.putIfAbsent(entry, GlobalKey.new),
                            entry: entry,
                            index: index,
                            itemCount: queue.entries.length,
                            isCurrent: index == queue.currentIndex,
                            // A playlist has an order worth showing; a mix and a
                            // hand-built queue do not.
                            numberDigits: numbered ? _numberDigits : null,
                            scheme: scheme,
                            controller: controller,
                            dismissAnimation: _itemCtrls[entry],
                            removeAnimation: _removing[entry],
                            clearing: _clearing,
                            onRemove: () => _requestRemove(entry, controller),
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ],
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

    // Ordered: the header (with Clear and collapse), then each row in turn. Reading
    // order alone went by on-screen position, which in a scrolling list skipped
    // rows, and walked backwards through the header before the row above.
    return FocusSurface(ordered: true, child: panel);
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
  if (mix != null) return mix.title ?? (mix.isPlaylist ? 'Playlist' : 'Mix');
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
///
/// A playlist does not come through here: it always shows its position, with
/// [_playlistTail] after it.
///
/// **"End of" is said when the last video has finished, not when the list is
/// known to be finite.** Until the last of them ends, the line says what is
/// next, and then that this is the last one.
(String, Widget?) _headerSubtitle(QueueState queue, QueueController controller, bool expanded) {
  final mix = queue.mix;

  if (expanded) {
    if (mix != null) return ('Mixes are playlists YouTube makes for you', null);
    return (_position(queue), null);
  }

  if (mix == null) return (_position(queue), null);
  if (controller.mixError != null) return ('Paused. Couldn\'t load more', null);
  if (queue.playedOut) return ('End of mix', null);

  final nextItem = queue.next;
  if (nextItem != null) return ('Next: ${nextItem.title}', null);
  // Nothing after this one. Only "last" once nothing more can arrive — before
  // that a top-up is still out, and the list simply names itself.
  if (mix.exhausted) return ('Last video', null);
  return ('Mix', null);
}

/// `3 / 135`. A playlist's total is YouTube's count while pages are still to
/// come (`displayLength`), which is why it can be shown for one and not for a mix.
String _position(QueueState queue) {
  final total = queue.displayLength;
  return queue.currentIndex != null ? '${queue.currentIndex! + 1} / $total' : '$total items';
}

/// What follows a playlist's position, or null for nothing.
///
/// The error and the end are said in both states, because the open list shows
/// neither. What is next, and that this is the last one, the open list already
/// shows — so those are the collapsed panel's alone.
String? _playlistTail(QueueState queue, QueueController controller, bool expanded) {
  if (controller.mixError != null) return 'Paused. Couldn\'t load more';
  if (queue.playedOut) return 'End of playlist';
  if (expanded) return null;

  final nextItem = queue.next;
  if (nextItem != null) return 'Next: ${nextItem.title}';
  return (queue.mix?.exhausted ?? false) ? 'Last video' : null;
}

class _QueueItemTile extends StatefulWidget {
  const _QueueItemTile({
    required super.key,
    required this.entry,
    required this.index,
    required this.itemCount,
    required this.isCurrent,
    this.numberDigits,
    required this.scheme,
    required this.controller,
    required this.onRemove,
    this.dismissAnimation,
    this.removeAnimation,
    this.clearing = false,
  });

  final QueueEntry entry;
  final int index;
  final int itemCount;
  final bool isCurrent;

  /// Non-null for a playlist: the row shows its position, in a column this
  /// many digits wide — a fraction while the list scrolls towards longer
  /// numbers. The playing row shows its arrow there.
  final ValueListenable<double>? numberDigits;
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

  /// Keyboard focus is somewhere in this row, so the remove button shows as it
  /// does under the pointer — a button that only exists while hovered cannot be
  /// Tabbed to.
  bool _focusWithin = false;

  /// Only while the user is navigating by keyboard: focus a click left on the row
  /// must not leave Remove showing.
  bool _keyboard = KeyboardNavigation.active;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onMode);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onMode);
    super.dispose();
  }

  void _onMode(FocusHighlightMode mode) {
    final on = mode == FocusHighlightMode.traditional;
    if (mounted && on != _keyboard) setState(() => _keyboard = on);
  }

  /// Up and Down on the reorder handle move the row one place. The handle keeps
  /// focus: the row's `State` follows its entry's key to the new index.
  KeyEventResult _onHandleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp && widget.index > 0) {
      widget.controller.reorder(widget.index, widget.index - 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown && widget.index < widget.itemCount - 1) {
      widget.controller.reorder(widget.index, widget.index + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowDown) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

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

  /// What a screen reader says for the row: title, channel, whether it is playing, length.
  String _rowLabel() {
    final tone = durationToneFor(widget.item);
    final clock = formatVideoDuration(widget.item);
    final length = spokenLength(
      isLive: tone == DurationBadgeTone.live,
      isStation: tone == DurationBadgeTone.station,
      clock: clock,
    );
    return [
      if (widget.numberDigits != null) 'number ${widget.index + 1}',
      widget.item.title,
      widget.item.channelName,
      if (widget.isCurrent) 'now playing',
      ?length,
    ].where((part) => part.isNotEmpty).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final inert = widget.clearing || widget.removing;
    final bool isPlaylist = widget.numberDigits != null;

    // The row fills the panel edge to edge, so the ring sits inside it.
    Widget tile = FocusRingShape(
      inflate: -1,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onFocusChange: (has) {
            if (_focusWithin != has) setState(() => _focusWithin = has);
          },
          child: Stack(
            children: [
              // The row is one thing to listen to — "title, channel, duration" — with its Remove
              // and Reorder as separate nodes of their own (`container: true`); left to merge, the
              // row read as "group", and the handle read the whole row followed by its hint.
              ListTile(
                selected: widget.isCurrent,
                selectedTileColor: widget.scheme.surfaceContainerHigh,
                mouseCursor: inert ? SystemMouseCursors.basic : SystemMouseCursors.click,
                contentPadding: EdgeInsets.symmetric(horizontal: isPlaylist ? 5 : 12, vertical: 4).copyWith(right: 16),
                leading: ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isPlaylist)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ValueListenableBuilder<double>(
                            valueListenable: widget.numberDigits!,
                            builder: (context, digits, child) => SizedBox(width: _digitWidth * digits, child: child),
                            child: widget.isCurrent
                                // The arrow is wider than one digit: centred over the
                                // column rather than squeezed into it.
                                ? OverflowBox(
                                    minWidth: 12,
                                    maxWidth: 12,
                                    fit: OverflowBoxFit.deferToChild,
                                    child: Icon(Icons.play_arrow, color: widget.scheme.onSurfaceVariant, size: 12),
                                  )
                                : Center(
                                    child: Text(
                                      '${widget.index + 1}',
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      softWrap: false,
                                      style: TextStyle(fontSize: 11, color: widget.scheme.onSurfaceVariant),
                                    ),
                                  ),
                          ),
                        ),
                      SizedBox(
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
                    ],
                  ),
                ),
                // The row's one name lives on its title, which is what the tile's own tap node
                // merges: a label on a wrapper around the tile never reached it.
                // The row's name is on the row itself (below).
                title: ExcludeSemantics(
                  child: Text(
                    widget.item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: widget.isCurrent ? widget.scheme.primary : widget.scheme.onSurface,
                    ),
                  ),
                ),
                subtitle: ExcludeSemantics(
                  child: Row(
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
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The tooltip wraps the cross-fade, not the button: `AnimatedCrossFade` clips to its
                    // box, and a bubble to the left of the X is outside it.
                    ShortcutTooltip(
                      label: 'Remove',
                      silent: true,
                      announce: false,
                      side: TooltipSide.left,
                      child: AnimatedCrossFade(
                        duration: const Duration(milliseconds: 50),
                        crossFadeState: !inert && (_isHovered || (_focusWithin && _keyboard)) ? CrossFadeState.showFirst : CrossFadeState.showSecond,
                        firstChild: Semantics(
                          container: true,
                          label: 'Remove from queue',
                          child: IconButton(
                            mouseCursor: SystemMouseCursors.click,
                            icon: ExcludeSemantics(child: Icon(Icons.close, size: 18, color: widget.scheme.onSurfaceVariant)),
                            onPressed: widget.onRemove,
                          ),
                        ),
                        secondChild: const SizedBox.shrink(),
                      ),
                    ),
                    if (!inert)
                      // Focusable, with Up/Down to reorder: the keyboard's way of doing
                      // what dragging does. `ArrowKeyClaim` stops the player's seek and
                      // volume shortcuts taking the arrows first.
                      ArrowKeyClaim(
                        // The `Semantics` is the *outer* one: a `Focus` outside it puts its
                        // focused flag on the row's node, and Narrator then read the whole row
                        // when the handle was focused.
                        child: Semantics(
                          container: true,
                          label: 'Use the up and down arrows to reorder',
                          child: Focus(
                            onKeyEvent: _onHandleKey,
                            child: ReorderableDragStartListener(
                              index: widget.index,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: ExcludeSemantics(
                                    child: Icon(Icons.drag_handle, size: 18, color: widget.scheme.onSurfaceVariant),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                onTap: inert ? null : () => widget.controller.jumpTo(widget.index),
              ),
              // Current indicator. A numbered row draws it in the number's place instead.
              if (widget.isCurrent && widget.numberDigits == null)
                Positioned(
                  left: -0.5,
                  top: 0,
                  bottom: 0,
                  child: Icon(Icons.play_arrow, color: widget.scheme.onSurfaceVariant, size: 12),
                ),
            ],
          ),
        ),
      ),
    );

    // The row's name, on the node ReorderableListView puts the focus on (not a child of it): that
    // is the node Narrator lands on, and it used to be an unnamed "group".
    tile = Semantics(label: _rowLabel(), child: tile);

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
                alwaysIncludeSemantics: true, // F51: tooltips inside, and the row reaches 0
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
            alwaysIncludeSemantics: true, // F51
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
