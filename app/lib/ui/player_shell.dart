import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/feed_item.dart';
import '../theme/tokens.dart';
import 'pages/watch.dart';
import 'playback_controller.dart';
import 'player/controls.dart';
import 'player/shortcuts.dart';
import 'player/view_mode.dart';
import 'queue_controller.dart';
import 'widgets/queue_panel.dart';

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

/// Play [item] and show it.
///
/// Both halves matter and they are independent: moving the queue's cursor is
/// what starts playback, and pushing the route is what shows it. A related tile
/// tapped from the watch page does the first and skips the second — which is
/// how "replaces the current video without pushing a second watch route" (§3)
/// falls out rather than being special-cased.
void openWatch(WidgetRef ref, VideoItem item) => openWatchIn(_containerOf(ref), item);

/// Bring the watch page up, if it is not already the top route.
///
/// A plain `push`, and that is the whole of task §3's "`maintainState` default,
/// so the feed's scroll survives".
///
/// Note where that flag actually lives: `maintainState` is a property of the
/// route being *covered*, not of the one covering it, so what keeps the feed
/// alive is the feed route's own default — setting it on this route would do
/// nothing at all. What this function has to get right is narrower and easier to
/// break: `push`, not `pushReplacement`, and not into a nested navigator. Either
/// of those unmounts the feed, and the user comes back from a video to the top
/// of a grid they had paged four continuations into. `player_shell_test.dart`
/// pins the end result rather than the flag.
void showWatchPage(WidgetRef ref) => showWatchPageIn(_containerOf(ref));

/// The container-taking forms, which is what everything above actually needs.
///
/// Split out so the navigation can be driven from a test without inventing a
/// `WidgetRef` — a `WidgetRef` is a widget's handle on a container, and these
/// two functions only ever wanted the container.
void openWatchIn(ProviderContainer container, VideoItem item) {
  container.read(queueProvider.notifier).play(item);
  showWatchPageIn(container);
}

/// Leave the watch page and let the mini-player take over — the `i` key and the
/// mini-player button.
///
/// **A pop, not a mode.** The mini-player is already what the shell draws
/// whenever something is playing and the watch route is not on top, so this needs
/// no state of its own: going back to wherever the user came from *is* the
/// feature. That also means it lands on the previous page rather than on a fixed
/// one, which is what "return to the previous page" has to mean once there is
/// more than one place a video can be opened from.
///
/// Fullscreen is dropped first. Popping while borderless would leave the window
/// covering the monitor with a feed in it — the same stranding
/// `PlayerViewController` guards against, and cheaper to prevent here than to
/// unpick afterwards.
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

/// Everything that outlives a route.
///
/// Mounted through `MaterialApp.builder`, so its child **is** the `Navigator`
/// (task §1). The player itself lives further up still — in a provider on the
/// `ProviderScope` — and this is what draws around it: the mini-player, and the
/// queue panel that both it and the watch page open.
///
/// A player inside the watch route would be destroyed on pop, which is what
/// makes a mini-player and background playback impossible. Nothing here stops
/// playback on a route change or a window blur, and that is the whole of
/// requirement #6: background audio is a property of where the player lives, not
/// a feature bolted on afterwards.
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
      child: Stack(
        children: [
          Positioned.fill(child: child),
          // The fullscreen mount point.
          //
          // The **same** surface the watch page draws, moved here rather than
          // rebuilt — the third mount point after the watch page and the
          // mini-player, and the same mechanism: the texture belongs to the
          // engine, so a `Video` widget appearing here and disappearing there
          // creates and frees nothing. That is what makes "do not destroy and
          // recreate the video output on a mode change" a property of the
          // structure rather than something to be careful about.
          if (fullscreen) const Positioned.fill(child: _FullscreenPlayer()),
          if (showMini)
            Positioned(
              right: 16,
              bottom: 16,
              child: MiniPlayer(),
            ),
        ],
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
      // An `Overlay` of its own, and it is not decoration.
      //
      // This subtree is above the `Navigator`, so it inherits none — and
      // Material's `Slider` renders its value indicator through an
      // `OverlayPortal`, which throws "No Overlay widget found" without one.
      // Measured: both the scrubber and the volume slider took the whole
      // fullscreen layer down the first time it was entered. The same absence
      // is why nothing here carries a tooltip (see `MiniPlayer`), and one
      // `Overlay` answers both.
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

/// The collapsed player: live video, title, transport controls, progress.
///
/// It shows the **same surface** the watch page does, not a thumbnail. That is
/// the visible payoff of §1's structure: the texture belongs to the engine on
/// the `ProviderScope`, so the `Video` widget here is a `Texture` id reference
/// that any subtree may hold, and moving between the two mount points creates
/// and frees nothing (`VideoController` registers its release on
/// `Player.dispose`, and `setSize` is never called from layout).
///
/// One texture, one mount point at a time: the mini-player draws only when the
/// watch route is not on top, so the two are mutually exclusive by construction.
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
      child: SizedBox(
        width: 380,
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
                  // No `tooltip:` on any of these, and the queue panel is opened
                  // through the navigator's own context rather than this one.
                  // Both for the same reason: this widget is *above* the
                  // `Navigator`, so there is no `Overlay` and no `Navigator`
                  // above it to host a tooltip or a modal route. A tooltip here
                  // throws "No Overlay widget found" the first time the
                  // mini-player is drawn — which is to say, in front of the user.
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
                    icon: Icon(Icons.queue_music, color: scheme.onSurface),
                    onPressed: () {
                      final navigatorContext = rootNavigatorKey.currentContext;
                      if (navigatorContext != null) showQueuePanel(navigatorContext);
                    },
                  ),
                  IconButton(
                    mouseCursor: SystemMouseCursors.click,
                    icon: Icon(Icons.close, color: scheme.onSurfaceVariant),
                    onPressed: () => ref.read(playbackProvider.notifier).stop(),
                  ),
                ],
              ),
              // Position from the stream, never a property read (invariant 9) —
              // and the quality-switch hold ahead of it, for the same reason the
              // scrubber prefers it: a reopened media reports zero until the
              // seek back lands, and this bar would drop to the start with it.
              StreamBuilder<Duration>(
                stream: engine.positionStream,
                initialData: engine.position,
                builder: (context, snapshot) {
                  // Duration from the hold as well as position — a reopened
                  // media reports zero for both, and this bar divides by it.
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
