import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/feed_item.dart';
import '../theme/tokens.dart';
import 'audio_mode_controller.dart';
import 'mini_player_stop.dart';
import 'pages/watch.dart';
import 'playback_controller.dart';
import 'player/audio_art_surface.dart';
import 'now_playing_art.dart';
import 'player/audio_backdrop.dart';
import 'player/player_slates.dart';
import 'player/controls.dart';
import 'player/libass_layer.dart';
import 'player/shortcuts.dart';
import 'player/settings_menu.dart';
import 'player/view_mode.dart';
import 'queue_controller.dart';
import 'smtc_controller.dart';
import 'taskbar_controller.dart';
import 'widgets/topbar.dart';

const String watchRouteName = 'watch';

/// The home route's name, and it is **not `null`**.
///
/// `MaterialApp(home:)` builds its route through `onGenerateRoute` with
/// `Navigator.defaultRouteName`, so the settings it carries are
/// `RouteSettings(name: '/')`. Verified 2026-09-09 by logging every route the
/// observer sees: `name=/ type=MaterialPageRoute<dynamic>`.
///
/// This used to be assumed to be `null` — `page_wrapper.dart` said so in a
/// comment and keyed the rail's Home highlight on it — which is why Home was
/// never lit while on Home. The one moment it *was* `null` was while a popup
/// was open, because a `PopupRoute` carries no name, so the highlight appeared
/// only when a menu or dialog was covering it.
const String homeRouteName = '/';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

class CurrentRoute extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? name) {
    if (state != name) state = name;
  }
}

/// The topmost **page** route's name. Popups and dialogs do not change it.
final currentRouteProvider = NotifierProvider<CurrentRoute, String?>(CurrentRoute.new);

/// The section the user is in, which the watch page does not change.
///
/// The rail highlights a *section*, and opening a video is not leaving one — a
/// video opened from Home is still Home, and lighting nothing while it plays
/// reads as the rail losing its place. So this holds the last page route that
/// was not the watch page.
final sectionRouteProvider = NotifierProvider<CurrentRoute, String?>(CurrentRoute.new);

/// Whether a popup or dialog is currently on top of the page stack.
///
/// Not a route *name* — a `PopupRoute` has none — but the fact that one exists,
/// which is what anything reaching for `maybePop` needs to know before it pops
/// somebody else's dialog.
class TransientRouteOpen extends Notifier<bool> {
  int _depth = 0;

  @override
  bool build() => false;

  void push() {
    _depth += 1;
    state = true;
  }

  void pop() {
    // Clamped: `didRemove` and `didPop` can both fire for one route in some
    // teardown orders, and a negative depth would latch this false forever.
    _depth = _depth > 0 ? _depth - 1 : 0;
    state = _depth > 0;
  }
}

final transientRouteOpenProvider =
    NotifierProvider<TransientRouteOpen, bool>(TransientRouteOpen.new);

/// Watches the navigator and reports the topmost **page** route.
///
/// **Popups, dialogs and full-screen dialog routes are deliberately
/// invisible to this.** A `PopupMenuButton` pushes a `_PopupMenuRoute` and
/// `showDialog` pushes a `DialogRoute`; both extend `PopupRoute`, neither is
/// a `PageRoute`, and neither carries a `settings.name`. Reporting them set
/// the current route to `null`, which two separate features then read as
/// "the user navigated away":
///
///   - `PlayerShell` popped the mini-player up over the watch page the moment
///     you opened the account menu or the share dialog, because `null` is not
///     `watchRouteName`.
///   - the rail lit Home, because `null` was mistaken for the home route.
///
/// Filtering on `route is PageRoute` fixed both at the source rather than
/// teaching each consumer to recognise a dialog. `PageRoute` and `PopupRoute`
/// are siblings under `ModalRoute`, so the test is exact rather than a guess
/// about class names.
///
/// **A `fullscreenDialog: true` `PageRoute` gets the same treatment as a
/// popup, added 2026-09-30.** `showLoginFlow`'s `LoginPage` route is exactly
/// this — a `MaterialPageRoute` with no `settings.name`, so it reported
/// `null` the same way a popup used to, and the same bug came back in the
/// one shape this filter did not cover: with the account menu open on top of
/// a playing video's watch page, `PlayerShell` floated the mini-player over
/// Google's full-screen sign-in page, because `null` is still not
/// `watchRouteName`. `fullscreenDialog` is visually and semantically a modal
/// takeover, not a real navigation away from whatever page is underneath it
/// — closer to `PopupRoute` than to an ordinary `PageRoute` push — so it is
/// routed through `_transient` instead of `_report` here too.
class RouteTracker extends NavigatorObserver {
  RouteTracker({required this.onPageRoute, required this.onTransientChange});

  final void Function(String? routeName) onPageRoute;
  final void Function(bool pushed) onTransientChange;

  /// A `PageRoute` this tracker should report as a real navigation — every
  /// one except a full-screen dialog, which behaves like a popup instead.
  bool _isReportablePage(Route<dynamic> route) => route is PageRoute && !route.fullscreenDialog;

  /// A route `_transient` should count — an ordinary popup, or a full-screen
  /// dialog `PageRoute` (see the class doc comment).
  bool _isTransient(Route<dynamic> route) =>
      route is PopupRoute || (route is PageRoute && route.fullscreenDialog);

  /// A tooltip's overlay entry is a semantics node grafted under its anchor; a page swap that removes the
  /// anchor while it is up can leave that node without a parent (`architecture.md` F51). Close them first.
  void _closeTooltips() => Tooltip.dismissAllToolTips();

  void _report(Route<dynamic>? route) {
    final name = route?.settings.name;
    WidgetsBinding.instance.addPostFrameCallback((_) => onPageRoute(name));
  }

  void _transient(bool pushed) {
    WidgetsBinding.instance.addPostFrameCallback((_) => onTransientChange(pushed));
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _closeTooltips();
    if (_isReportablePage(route)) {
      _report(route);
    } else if (_isTransient(route)) {
      _transient(true);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _closeTooltips();
    if (_isReportablePage(route)) {
      _report(previousRoute);
    } else if (_isTransient(route)) {
      _transient(false);
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isReportablePage(route)) {
      _report(previousRoute);
    } else if (_isTransient(route)) {
      _transient(false);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _closeTooltips();
    if (newRoute != null && _isReportablePage(newRoute)) _report(newRoute);
  }
}

final routeTrackerProvider = Provider<RouteTracker>((ref) {
  return RouteTracker(
    onPageRoute: (name) {
      ref.read(currentRouteProvider.notifier).set(name);
      // The watch page is a route but not a section — see [sectionRouteProvider].
      if (name != watchRouteName) ref.read(sectionRouteProvider.notifier).set(name);
    },
    onTransientChange: (pushed) {
      final notifier = ref.read(transientRouteOpenProvider.notifier);
      if (pushed) {
        notifier.push();
      } else {
        notifier.pop();
      }
    },
  );
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

/// The miniplayer's focus scope. It lives above the `Navigator`, and Tab never
/// leaves a route's scope for the root's, so without a key for it the
/// miniplayer's buttons are unreachable from the keyboard. F6 moves focus in and
/// back (`PlayerShortcuts`) — Windows' own "next pane".
final miniPlayerScopeProvider = Provider<FocusScopeNode>((ref) {
  final node = FocusScopeNode(debugLabel: 'miniplayer');
  ref.onDispose(node.dispose);
  return node;
});

/// Whether the miniplayer is on screen: something is loaded, and this is not the
/// watch page (which has the real player) or fullscreen.
final miniPlayerShownProvider = Provider<bool>((ref) {
  final bool hasItem;
  try {
    hasItem = ref.watch(playbackProvider.select((p) => p.item != null));
  } on Object {
    // No playback engine (a surface under test, or the app before it is set up): no miniplayer.
    return false;
  }
  final onWatch = ref.watch(currentRouteProvider) == watchRouteName;
  final fullscreen = ref.watch(playerViewProvider.select((v) => v.fullscreen));
  return hasItem && !onWatch && !fullscreen;
});

KeyEventResult _miniPlayerTab(FocusNode scope, KeyEvent event) {
  if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.tab) return KeyEventResult.ignored;
  final focus = FocusManager.instance.primaryFocus;
  final context = scope.context;
  if (focus == null || context == null) return KeyEventResult.ignored;
  final forward = !HardwareKeyboard.instance.isShiftPressed;
  final policy = FocusTraversalGroup.of(context);
  final edge = forward ? policy.findLastFocus(scope, ignoreCurrentFocus: true) : policy.findFirstFocus(scope, ignoreCurrentFocus: true);
  if (!identical(edge, focus)) return KeyEventResult.ignored;
  return MiniPlayerStop.leave(forward: forward) ? KeyEventResult.handled : KeyEventResult.ignored;
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
  // **Never pop somebody else's dialog.** `currentRouteProvider` now ignores
  // popups, so it still reads `watch` while a share dialog or a menu is open —
  // and `maybePop` would close *that* instead of leaving the watch page. Before
  // popups were filtered out this could not happen, because the guard above
  // saw `null` and returned; the filter is what makes this check necessary.
  if (container.read(transientRouteOpenProvider)) return;
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
    ref.listen(smtcControllerProvider, (_, _) {});
    ref.listen(taskbarControllerProvider, (_, _) {});
    final playback = ref.watch(playbackProvider);
    final onWatchPage = ref.watch(currentRouteProvider) == watchRouteName;
    final view = ref.watch(playerViewProvider);
    // Watched unconditionally, so the gate exists before the first toggle and sees it.
    final layerReady = ref.watch(playerLayerGateProvider.select((g) => g.layer));
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
            // One frame after the page's controls have gone (`PlayerLayerGate`).
            if (fullscreen && layerReady) const Positioned.fill(child: _FullscreenPlayer()),
            if (showMini)
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Align(
                  alignment: Alignment.bottomRight,
                  // A scope of its own, because Tab cannot leave a route's scope for
                  // this one — F6 is how the keyboard gets here (`shortcuts.dart`).
                  child: FocusScope(
                    node: ref.watch(miniPlayerScopeProvider),
                    // Tab off either end of the miniplayer's controls goes back to the
                    // page (`MiniPlayerStop`), instead of wrapping inside the scope.
                    onKeyEvent: (scope, event) => _miniPlayerTab(scope, event),
                    child: MiniPlayer(),
                  ),
                ),
              ),
            // The only caption renderer (§2.9). It hides mpv's own on mount, so
            // nothing here has to keep `sub-visibility` in step with a toggle.
            //
            // **Not mounted in audio-only.** It renders through libass in
            // Flutter rather than through mpv, so `vid=no` does not suppress
            // it: with captions left on, it kept drawing them over the artwork
            // while `controls.dart` hid the CC button that would have turned
            // them off.
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
            if (!ref.watch(audioModeProvider))
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

/// The player above the `Navigator`.
///
/// **A focus scope that takes focus on entry and gives it back on exit.** It is a
/// plain sibling of the page in a `Stack`, so without one the page underneath —
/// covered, but still focusable — stayed in the Tab walk and nothing moved focus
/// into the player. Entering puts focus in the player's controls; Tab then cycles
/// inside; leaving restores whatever had focus before (when that is still
/// there to take it).
class _FullscreenPlayer extends ConsumerStatefulWidget {
  const _FullscreenPlayer();

  @override
  ConsumerState<_FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends ConsumerState<_FullscreenPlayer> {
  final FocusScopeNode _scope = FocusScopeNode(debugLabel: 'fullscreen player');

  /// What had focus before this mounted; where focus goes back to. Read in
  /// `initState`, not lazily: by `dispose` focus is already inside the player.
  FocusNode? _before;

  @override
  void initState() {
    super.initState();
    _before = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scope.requestFocus();
    });
  }

  @override
  void dispose() {
    final before = _before;
    _scope.dispose();
    // After this frame: the page underneath is rebuilt as this unmounts.
    if (before != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (before.context != null && before.canRequestFocus) before.requestFocus();
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = ref.read(playbackEngineProvider);

    return FocusScope(
      node: _scope,
      child: ColoredBox(
      color: theme.tokens.scrim,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) => Stack(
              fit: StackFit.expand,
              children: [
                // With `vid=no` the texture decodes nothing, so without the
                // overlay this is a black screen. It stays mounted underneath
                // so the artwork can crossfade over it rather than replace it.
                engine.videoSurface(),
                AudioArtOverlay(
                  show: ref.watch(audioModeProvider) || ref.watch(playbackProvider).isRestoringVideo,
                  imageUrl: ref.watch(nowPlayingBackdropProvider),
                ),
                PlayerControls(
                  engine: engine,
                  child: const PlayerSlates(showQueue: true, injectMaterial: true),
                ),
              ],
            ),
          ),
        ],
      ),
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
                      child: ref.watch(audioModeProvider)
                          ? AudioArtSurface(thumbnailUrl: item.thumbnailUrl, scrim: false, iconSize: 24)
                          : engine.videoSurface(),
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
                      // `semanticLabel`, not `tooltip:` — this sits above the `Navigator`,
                      // which has no `Overlay` to host one (architecture.md §2.8).
                      icon: Icon(
                        (snapshot.data ?? false) ? Icons.pause : Icons.play_arrow,
                        color: scheme.onSurface,
                        semanticLabel: (snapshot.data ?? false) ? 'Pause' : 'Play',
                      ),
                      // Nothing to play in a premiere, a members-only video or a
                      // failure — the controller would ignore the press anyway.
                      onPressed: playback.isUnplayable ? null : () => ref.read(playbackProvider.notifier).togglePlayPause(),
                    ),
                  ),
                  IconButton(
                    mouseCursor: SystemMouseCursors.click,
                    icon: Icon(Icons.close, color: scheme.onSurfaceVariant, semanticLabel: 'Close'),
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