import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/feed_item.dart';
import '../theme/tokens.dart';
import 'pages/watch.dart';
import 'playback_controller.dart';
import 'player/caption_drag_layer.dart';
import 'player/controls.dart';
import 'player/shortcuts.dart';
import 'player/settings_menu.dart';
import 'player/view_mode.dart';
import 'queue_controller.dart';


/// The watch route's name. The mini-player hides while this is on top.
const String watchRouteName = 'watch';

/// The app's one `Navigator`, reachable from the shell above it.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Which route is on top, as a provider.
class CurrentRoute extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? name) {
    if (state != name) state = name;
  }
}

final currentRouteProvider = NotifierProvider<CurrentRoute, String?>(CurrentRoute.new);

/// Keeps [currentRouteProvider] in step with the navigator stack.
///
/// The post-frame deferral is not optional: the *first* route is pushed during
/// the `Navigator`'s own first build, and writing to a provider from inside a
/// build throws. Every later push and pop happens outside a build and would be
/// fine either way — the initial one is what forces this.
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

/// Play [item] and show it — two independent halves. Moving the cursor starts
/// playback; pushing the route shows it. A related tile does only the first.
void openWatch(WidgetRef ref, VideoItem item) => openWatchIn(_containerOf(ref), item);

/// Bring the watch page up, if it is not already the top route.
///
/// `push`, never `pushReplacement` and never into a nested navigator: either
/// unmounts the feed, and the user comes back to the top of a grid they had
/// paged four continuations into. (`maintainState` belongs to the route being
/// *covered*, so setting it here would do nothing.)
void showWatchPage(WidgetRef ref) => showWatchPageIn(_containerOf(ref));

/// The container-taking forms — split out so navigation can be driven from a
/// test without inventing a `WidgetRef`.
void openWatchIn(ProviderContainer container, VideoItem item) {
  container.read(queueProvider.notifier).play(item);
  showWatchPageIn(container);
}

/// Leave the watch page and let the mini-player take over — the `i` key and the
/// mini-player button.
///
/// **A pop, not a mode** — the shell already draws the mini-player whenever
/// something is playing off the watch route, so this needs no state of its own
/// and lands on whichever page the video was opened from.
///
/// Fullscreen is dropped first, or popping leaves a borderless window covering
/// the monitor with a feed in it.
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

/// Everything that outlives a route: the mini-player, and the fullscreen layer.
///
/// Mounted through `MaterialApp.builder`, so its child **is** the `Navigator`
/// (task §1). The player itself lives higher still, in a provider on the
/// `ProviderScope` — architecture §2.8. Nothing here stops playback on a route
/// change or a window blur; background audio falls out of where the player
/// lives rather than being a feature.
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

    return PlayerShortcuts(
      // The settings menu's click-outside, as an **ancestor** rather than a
      // barrier on top. A translucent `Listener` over the app would swallow
      // every click it closed the menu on; an ancestor is on the hit-test path
      // of every descendant, so it sees the click and the target still gets it.
      child: Listener(
        onPointerDown: (event) {
          if (!ref.read(playerMenuProvider).open) return;
          // The gear counts as "on the menu" too, or pressing it while open
          // would close here and reopen on the tap. See `settingsMenuAnchorKey`.
          if (pointerIsOnSettingsMenu(event.position)) return;
          ref.read(playerMenuProvider.notifier).close();
        },
        child: Stack(
          children: [
            Positioned.fill(child: child),
            // The third mount point for the one texture (architecture §2.8):
            // the same surface the watch page draws, moved rather than rebuilt.
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
          ],
        ),
      ),
    );
  }
}

/// The player filling the window, with the app chrome behind it.
///
/// The OS window is made borderless by `PlayerViewController`; this is only the
/// part of fullscreen that is pixels. Both halves are needed and neither implies
/// the other.
class _FullscreenPlayer extends ConsumerWidget {
  const _FullscreenPlayer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final engine = ref.read(playbackEngineProvider);

    return ColoredBox(
      color: theme.tokens.scrim,
      // Its own `Overlay`, and not decoration: this subtree is above the
      // `Navigator` so it inherits none, and `Slider`'s value indicator needs
      // one. Architecture §2.8 — the same absence is why nothing here has a
      // tooltip.
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) => Stack(
              fit: StackFit.expand,
              children: [
                engine.videoSurface(),
                PlayerControls(engine: engine),
                // Fullscreen is the third mount point for the one texture
                // (§2.8), so it needs the caption handle too — a caption
                // draggable on the watch page and not in fullscreen would be
                // the same feature behaving differently in two places.
                CaptionDragLayer(aspectRatio: ref.watch(fullscreenAspectRatioProvider)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The collapsed player: live video, title, transport controls, progress.
///
/// Shows the **same surface** the watch page does, not a thumbnail — one
/// texture, one mount point at a time (architecture §2.8). It draws only when
/// the watch route is not on top, so the two are exclusive by construction.
///
/// TODO: a chevron here opens `EmbeddedQueuePanel` underneath this card, expanding in place.
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
                    // Letterboxed against the scrim rather than cropped: a
                    // 96×54 box is 16:9 and most video is, but a 4:3 upload
                    // cropped to fill loses its edges rather than its bars.
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
                  // No `tooltip:` on any of these — this widget is above the
                  // `Navigator`, so there is no `Overlay` to host one and it
                  // throws the first time the mini-player is drawn.
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
              // From the stream, never a property read (invariant 9), with the
              // quality-switch hold ahead of it — a reopened media reports zero
              // for both position and duration until the seek back lands.
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
