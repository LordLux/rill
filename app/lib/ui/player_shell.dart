import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

// Upgraded Follower explicitly polling the leader size. 
// Completely eliminates the 1-frame fullscreen freeze bug!
class LayerLinkFollower extends StatefulWidget {
  final LayerLink link;
  final Widget child;
  final bool fullscreen;

  const LayerLinkFollower({super.key, required this.link, required this.child, required this.fullscreen});

  @override
  State<LayerLinkFollower> createState() => _LayerLinkFollowerState();
}

class _LayerLinkFollowerState extends State<LayerLinkFollower> with SingleTickerProviderStateMixin {
  Size _lastSize = Size.zero;
  late Ticker _ticker;

  @override
  void initState() {
    super.initState();
    // A Ticker flawlessly captures the exact frame media_kit updates its texture size.
    _ticker = createTicker((_) {
      if (widget.link.leaderSize != null && widget.link.leaderSize != _lastSize) {
        setState(() {
          _lastSize = widget.link.leaderSize!;
        });
      }
    });
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
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
            LayerLinkFollower(
              link: engine.videoLayerLink,
              fullscreen: fullscreen,
              child: LibassLayer(aspectRatio: ref.watch(fullscreenAspectRatioProvider)),
            ),
          ],
        ),
      ),
    );
  }
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