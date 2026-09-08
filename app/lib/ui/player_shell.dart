import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/feed_item.dart';
import '../theme/tokens.dart';
import 'pages/watch.dart';
import 'playback_controller.dart';
import 'player/controls.dart';
import 'player/libass_layer.dart';
import 'player/shortcuts.dart';
import 'player/settings_menu.dart';
import 'player/view_mode.dart';
import 'queue_controller.dart';
import 'widgets/topbar.dart';

const String watchRouteName = 'watch';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class CurrentRoute extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? name) {
    if (state != name) state = name;
  }
}

final currentRouteProvider = NotifierProvider<CurrentRoute, String?>(CurrentRoute.new);

class RouteTracker extends NavigatorObserver {
  RouteTracker(this._onChange);

  final void Function(String? routeName) _onChange;

  void _report(Route<dynamic>? route) {
    final name = route?.settings.name;
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange(name));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _report(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _report(previousRoute);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _report(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _report(newRoute);
}

final routeTrackerProvider = Provider<RouteTracker>((ref) {
  return RouteTracker((name) => ref.read(currentRouteProvider.notifier).set(name));
});

// Polls the leader size once per rendered frame — see `_scheduleCheck` for
// why that is not a `Ticker` (any more).
// Completely eliminates the 1-frame fullscreen freeze bug!
class LayerLinkFollower extends StatefulWidget {
  final LayerLink link;
  final Widget child;
  final bool fullscreen;

  const LayerLinkFollower({super.key, required this.link, required this.child, required this.fullscreen});

  @override
  State<LayerLinkFollower> createState() => _LayerLinkFollowerState();
}

class _LayerLinkFollowerState extends State<LayerLinkFollower> {
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _scheduleCheck();
  }

  /// Re-checks `widget.link.leaderSize` after every frame the app renders,
  /// for any reason — and only after such a frame, never on its own.
  ///
  /// **This used to be a raw `Ticker`.** A `Ticker` requests a fresh frame on
  /// every tick for as long as it runs — invisible in a real app, but it means
  /// `SchedulerBinding` never reports "nothing pending" while this widget is
  /// mounted, which is always: `PlayerShell` mounts it above the entire app
  /// (`main.dart`'s `MaterialApp.builder`), unconditionally, whether or not a
  /// video is even open. Every `pumpAndSettle` in a test that builds through
  /// `PlayerShell` timed out the instant it existed — confirmed by disabling
  /// libass entirely and getting the identical timeout, which ruled out
  /// captions as the cause and pointed here instead (measured 2026-08-27).
  ///
  /// `leaderSize` is a layout/paint *output* — `CompositedTransformTarget`
  /// only reports a new one because Flutter already laid out and painted a
  /// frame that changed it, which only happens because something (fullscreen
  /// toggling, an aspect-ratio provider, a window resize) already triggered a
  /// rebuild and therefore already scheduled that frame. So riding
  /// `addPostFrameCallback` — fire once after a frame that was going to
  /// happen anyway, check, `setState` if the size moved (which schedules the
  /// *next* frame for the corrected size), then re-register for whatever
  /// frame comes after that — catches the same change the Ticker did, at the
  /// same one-frame-later timing, without ever asking the engine for a frame
  /// nothing else needed. Once nothing is changing `leaderSize` any more, no
  /// frame is scheduled, this callback simply waits, and `pumpAndSettle`
  /// converges like it is supposed to.
  void _scheduleCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final leaderSize = widget.link.leaderSize;
      if (leaderSize != null && leaderSize != _lastSize) {
        setState(() {
          _lastSize = leaderSize;
        });
      }
      _scheduleCheck();
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.fullscreen
        ? MediaQuery.sizeOf(context)
        : (widget.link.leaderSize ?? Size.zero);

    return CompositedTransformFollower(
      link: widget.link,
      showWhenUnlinked: false,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: widget.child,
      ),
    );
  }
}

void openWatch(WidgetRef ref, VideoItem item) => openWatchIn(_containerOf(ref), item);

void showWatchPage(WidgetRef ref) => showWatchPageIn(_containerOf(ref));

void openWatchIn(ProviderContainer container, VideoItem item) {
  container.read(queueProvider.notifier).play(item);
  showWatchPageIn(container);
}

void toMiniPlayer(WidgetRef ref) => toMiniPlayerIn(_containerOf(ref));

void toMiniPlayerIn(ProviderContainer container) {
  container.read(playerViewProvider.notifier).reset();
  if (container.read(currentRouteProvider) != watchRouteName) return;
  rootNavigatorKey.currentState?.maybePop();
}

void showWatchPageIn(ProviderContainer container) {
  if (container.read(currentRouteProvider) == watchRouteName) return;
  rootNavigatorKey.currentState?.push(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: watchRouteName),
      builder: (_) => const WatchPage(),
    ),
  );
}

ProviderContainer _containerOf(WidgetRef ref) =>
    ProviderScope.containerOf(ref.context, listen: false);

class PlayerShell extends ConsumerWidget {
  const PlayerShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(playbackProvider);
    final onWatchPage = ref.watch(currentRouteProvider) == watchRouteName;
    final view = ref.watch(playerViewProvider);
    final fullscreen = view.fullscreen && playback.item != null;
    final showMini = playback.item != null && !onWatchPage && !fullscreen;
    final engine = ref.read(playbackEngineProvider);

    return PlayerShortcuts(
      child: Listener(
        onPointerDown: (event) {
          if (!ref.read(playerMenuProvider).open) return;
          if (pointerIsOnSettingsMenu(event.position)) return;
          ref.read(playerMenuProvider.notifier).close();
        },
        child: Stack(
          children: [
            Positioned.fill(child: child),
            if (fullscreen) const Positioned.fill(child: _FullscreenPlayer()),
            if (showMini)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: MiniPlayer(),
                ),
              ),
            // The only caption renderer (§2.9). It hides mpv's own on mount, so
            // nothing here has to keep `sub-visibility` in step with a toggle.
            //
            // **Clipped below the page's own TopBar when not fullscreen.** The
            // caption paints last in this Stack — above everything, including
            // `page_wrapper.dart`'s `Scaffold(appBar: TopBar(...))` — and
            // `CompositedTransformFollower` repositions it purely at the
            // compositing layer, so scrolling the watch page's video up under
            // a sticky bar does not stop the caption from following it there
            // too. The clip has to be `Positioned.fill` over the *whole* Stack
            // (screen coordinates) rather than sized to the follower's own
            // box: the follower's transform is a descendant of this clip, so a
            // fixed rect here stays fixed on screen regardless of where the
            // transform later moves the caption to.
            //
            // **`OverflowBox` is load-bearing, not decoration.** `Positioned.fill`
            // gives `ClipRect` tight constraints spanning the whole Stack, and
            // constraints flow straight through `ClipRect` and
            // `CompositedTransformFollower` — both are plain proxies for layout
            // purposes — to `LayerLinkFollower`'s inner `SizedBox(width:
            // leaderSize.width, height: leaderSize.height)`. A `SizedBox`
            // cannot be smaller than a tight incoming constraint, so without
            // this the caption was laid out at the *window's* size instead of
            // the video's, rendering at several times its correct scale over
            // the whole page — measured 2026-08-26, this is what shipped for
            // one round before being caught. `OverflowBox` reports whatever
            // size its parent (`ClipRect`) imposes upward, unrelated to its
            // child's, while handing the child its own unconstrained (0..∞)
            // constraints — restoring exactly the free sizing `LayerLinkFollower`
            // had before this clip existed, with the clip still applied.
            Positioned.fill(
              child: ClipRect(
                clipper: _BelowTopBarClipper(
                  fullscreen ? 0 : MediaQuery.paddingOf(context).top + TopBar.preferredHeight,
                ),
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: 0,
                  minHeight: 0,
                  maxWidth: double.infinity,
                  maxHeight: double.infinity,
                  child: LayerLinkFollower(
                    link: engine.videoLayerLink,
                    fullscreen: fullscreen,
                    child: LibassLayer(aspectRatio: ref.watch(fullscreenAspectRatioProvider)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cuts off everything above [top], leaving the rest of the clipped subtree's
/// own coordinates untouched. Used to keep the caption layer off the TopBar.
class _BelowTopBarClipper extends CustomClipper<Rect> {
  const _BelowTopBarClipper(this.top);

  final double top;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, top, size.width, size.height);

  @override
  bool shouldReclip(covariant _BelowTopBarClipper oldClipper) => oldClipper.top != top;
}

class _FullscreenPlayer extends ConsumerWidget {
  const _FullscreenPlayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final engine = ref.read(playbackEngineProvider);

    return ColoredBox(
      color: theme.tokens.scrim,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) => Stack(
              fit: StackFit.expand,
              children: [
                engine.videoSurface(),
                PlayerControls(engine: engine),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final playback = ref.watch(playbackProvider);
    final item = playback.item;
    if (item == null) return const SizedBox.shrink();

    final engine = ref.read(playbackEngineProvider);

    return Material(
      elevation: 8,
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: InkWell(
          onTap: () => showWatchPage(ref),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 96,
                    height: 54,
                    child: ColoredBox(
                      color: theme.tokens.scrim,
                      child: engine.videoSurface(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: scheme.onSurface),
                        ),
                        Text(
                          item.channelName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  StreamBuilder<bool>(
                    stream: engine.playingStream,
                    initialData: engine.playing,
                    builder: (context, snapshot) => IconButton(
                      mouseCursor: SystemMouseCursors.click,
                      icon: Icon(
                        (snapshot.data ?? false) ? Icons.pause : Icons.play_arrow,
                        color: scheme.onSurface,
                      ),
                      onPressed: () => ref.read(playbackProvider.notifier).togglePlayPause(),
                    ),
                  ),
                  IconButton(
                    mouseCursor: SystemMouseCursors.click,
                    icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
                    onPressed: () => ref.read(playbackProvider.notifier).stop(),
                  ),
                ],
              ),
              StreamBuilder<Duration>(
                stream: engine.positionStream,
                initialData: engine.position,
                builder: (context, snapshot) {
                  final hold = playback.hold;
                  final duration = hold?.duration ?? engine.duration;
                  final position = hold?.position ?? snapshot.data ?? Duration.zero;
                  final value = duration > Duration.zero
                      ? position.inMilliseconds / duration.inMilliseconds
                      : 0.0;
                  return LinearProgressIndicator(
                    value: value.clamp(0.0, 1.0),
                    minHeight: 2,
                    backgroundColor: scheme.surfaceContainerHighest,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}