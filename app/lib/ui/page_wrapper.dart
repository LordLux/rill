import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:silky_scroll/silky_scroll.dart';

import '../theme/screen_values.dart';
import 'focus_surface.dart';
import 'mini_player_stop.dart';
import 'pages/all_subscriptions.dart' show allSubscriptionsRouteName;
import 'pages/subscriptions.dart';
import 'player_shell.dart'
    show currentRouteProvider, homeRouteName, rootNavigatorKey, sectionRouteProvider, transientRouteOpenProvider;
import 'widgets/topbar.dart';
import 'widgets/update_banner.dart';

const String drawerPrefsKey = 'left_drawer_open';

/// Whether the inline drawer is open
class DrawerStateController extends Notifier<bool> {
  DrawerStateController({this.initial = true});

  final bool initial;

  @override
  bool build() => initial;

  Future<void> toggle() async {
    state = !state;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(drawerPrefsKey, state);
  }
}

final drawerStateProvider = NotifierProvider<DrawerStateController, bool>(
  DrawerStateController.new,
);

/// The stored drawer state, for seeding [drawerStateProvider] before `runApp`
Future<bool> readDrawerOpen() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(drawerPrefsKey) ?? true;
}

/// The colour the title bar and the rail are on *this frame*, for every page at
/// once, and the one each page's own ground fades down from ([pageGroundFor]).
/// Null until the first page has painted.
///
/// Each page builds its own title bar and rail, and routes swap with no
/// transition, so a colour owned by a page cuts in and out with it. Every page
/// paints this one value instead, and only the page on top moves it: a page
/// that opens, or that a Back uncovers, carries on from wherever the last one
/// left the colour, mid-fade included.
///
/// A plain notifier rather than provider state, and the fade is not a target
/// each page animates towards on its own. Both were tried (2026-10-09) and cut
/// on a Back: a covered page's tickers are muted and Riverpod pauses its
/// subscriptions, so it comes back holding a stale colour and no fade, and
/// shows it the moment the outgoing page is removed.
class PageChrome extends ValueNotifier<Color?> {
  PageChrome() : super(null);

  /// The page whose fade is moving [value]. Taking it over stops the last one.
  Object? driver;
}

/// A page's own ground under a chrome of [tint]: that colour at the top, gone by
/// three quarters of the way down. Plain [ground] when the two are the same,
/// which is every page that brings no colour of its own.
@visibleForTesting
BoxDecoration pageGroundFor(Color tint, Color ground) {
  if (tint == ground) return BoxDecoration(color: ground);
  return BoxDecoration(
    gradient: LinearGradient(
      begin: const Alignment(-3 / 20, -1.0),
      end: const Alignment(1 / 20, 1.0),
      colors: [tint, ground],
      stops: const [0.0, 0.75],
    ),
  );
}

final pageChromeProvider = Provider<PageChrome>((ref) {
  final chrome = PageChrome();
  ref.onDispose(chrome.dispose);
  return chrome;
});

class PageWrapper extends ConsumerStatefulWidget {
  final Widget body;
  final Widget title;
  final List<Widget>? actions;

  /// Whether the page's own first control exists yet. The watch page's is the
  /// player's, which only mounts once the video has loaded; landing keyboard focus
  /// before that would pick the first thing that *is* there (the Like button).
  final bool landingReady;

  /// A colour of the page's own (a playlist's tint): the title bar and the rail
  /// are painted on it, and the page's ground fades down from it. Null is the
  /// theme's, on a plain ground.
  final Color? tint;

  const PageWrapper({
    super.key,
    required this.body,
    required this.title,
    this.actions,
    this.landingReady = true,
    this.tint,
  });

  @override
  ConsumerState<PageWrapper> createState() => _PageWrapperState();
}

class _PageWrapperState extends ConsumerState<PageWrapper> with SingleTickerProviderStateMixin {
  /// How long the title bar and the rail take to change colour between pages.
  static const Duration _chromeFadeDuration = Duration(milliseconds: 300);

  late final PageChrome _chrome = ref.read(pageChromeProvider);
  late final AnimationController _chromeFade = AnimationController(vsync: this, duration: _chromeFadeDuration)
    ..addListener(_paintChrome);
  ColorTween? _chromeTween;

  void _paintChrome() {
    final tween = _chromeTween;
    if (tween == null) return;
    // Another page is on top now and has carried on from where this one was.
    if (!identical(_chrome.driver, this)) {
      _chromeFade.stop();
      return;
    }
    _chrome.value = tween.evaluate(_chromeFade);
  }

  /// Take the chrome over and fade it to [want] from whatever it is showing.
  void _fadeChromeTo(Color want) {
    if (identical(_chrome.driver, this) && _chromeTween?.end == want) return;
    final from = _chrome.value ?? want;
    _chrome.driver = this;
    _chromeTween = ColorTween(begin: from, end: want);
    if (from == want) {
      _chromeFade.value = 1;
      _chrome.value = want;
    } else {
      _chromeFade.forward(from: 0);
    }
  }

  /// A zero-size marker at the very front of the page content (order 0, ahead of
  /// every numbered surface). Not a Tab stop; it exists so "the first thing Tab
  /// would reach in the content" can be asked of the real traversal policy instead
  /// of guessed from the widget tree.
  final FocusNode _landing = FocusNode(debugLabel: 'page content start', skipTraversal: true);

  @override
  void initState() {
    super.initState();
    // Reached from the keyboard, a new page starts with focus on its own content —
    // not back at the title bar, which is three groups of Tab away. Not the first
    // page (nothing opened it) and not after a pointer (focus is not shown).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isFirst == false) _landOnContent(attempt: 0);
    });
  }

  /// Focus the first focusable thing in the content, waiting a moment for pages that
  /// fill in after they open (a feed fetches before it has a tile).
  void _landOnContent({required int attempt}) {
    if (!mounted) return;
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) return;
    // The user already moved on, or focus is somewhere inside this page.
    final scope = FocusScope.of(context);
    if (scope.focusedChild != null) return;
    if (!widget.landingReady) {
      if (attempt < 48) Future<void>.delayed(const Duration(milliseconds: 250), () => _landOnContent(attempt: attempt + 1));
      return;
    }
    // Let the marker take part in the walk for one step: focus it, ask for the next
    // stop, and put it back out of the walk.
    _landing
      ..skipTraversal = false
      ..requestFocus();
    final moved = _landing.nextFocus();
    _landing.skipTraversal = true;
    final landed = FocusManager.instance.primaryFocus;
    if (moved && landed != null && !identical(landed, _landing) && _landing.context != null) {
      // Only a stop inside this page's content counts — the walk may have wrapped
      // round to the title bar when the content has nothing focusable yet.
      final inContent = landed.ancestors.contains(_landing.parent);
      if (inContent) return;
    }
    _landing.unfocus();
    if (attempt < 12) {
      Future<void>.delayed(const Duration(milliseconds: 250), () => _landOnContent(attempt: attempt + 1));
    }
  }

  @override
  void dispose() {
    _chromeFade.dispose();
    _landing.dispose();
    super.dispose();
  }

  /// Whether this page is the one showing. True with no route at all (a test).
  bool get _isOnTop => ModalRoute.of(context)?.isCurrent ?? true;

  void _toggleDrawer() => ref.read(drawerStateProvider.notifier).toggle();

  void _openSubscriptions() {
    if (ref.read(currentRouteProvider) == subscriptionsRouteName) return;
    rootNavigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: subscriptionsRouteName),
        builder: (_) => const SubscriptionsPage(),
      ),
    );
  }

  /// Pop the topmost page route — the watch page, Subscriptions, a search,
  /// wherever the back arrow is showing from.
  ///
  /// Guarded the same way `toMiniPlayerIn` is: a `PopupRoute` (a dialog, say —
  /// not the account menu, which is an `OverlayEntry` and pushes no route) can
  /// be on top of the same Navigator without changing
  /// `currentRouteProvider`, and `maybePop` would close *that* rather than
  /// leave the page — though in practice a modal one already blocks this
  /// button's tap from landing at all.
  void _goBack() {
    if (ref.read(transientRouteOpenProvider)) return;
    rootNavigatorKey.currentState?.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final isDrawerOpen = ref.watch(drawerStateProvider);
    // **The section, not the route.** Opening a video does not leave the
    // section it was opened from — a watch page reached from Home is still
    // Home, and lighting nothing while it plays reads as the rail losing its
    // place. `sectionRouteProvider` is the last page route that was not the
    // watch page; see `player_shell.dart`.
    final section = ref.watch(sectionRouteProvider);
    // "All subscriptions" is reached from the Subscriptions page (Task 21
    // §4) and is still part of that section, not a route of its own the
    // drawer knows about — so it keeps Subscriptions highlighted rather
    // than falling through to `!isOnSubscriptions` and lighting up Home,
    // which is wrong for *any* non-subscriptions, non-home page (watch,
    // search — this just happened to be the one someone noticed first).
    final isOnSubscriptions = section == subscriptionsRouteName || section == allSubscriptionsRouteName;
    // **`'/'`, not `null`.** This used to read `currentRoute == null` on the
    // belief that the root route carries no name. It carries `'/'` —
    // `MaterialApp(home:)` routes it through `Navigator.defaultRouteName` —
    // so Home was never lit while on Home. Verified 2026-09-09; the constant
    // and the evidence are on `homeRouteName`.
    //
    // `null` is still accepted, because that is the state before the observer
    // has reported anything at all, and the first frame is on Home.
    final isOnHome = section == null || section == homeRouteName;

    // The back arrow tracks the actual page route, not the section: a search
    // or the watch page both warrant one even though the watch page leaves
    // `section` untouched (see `sectionRouteProvider`).
    final currentRoute = ref.watch(currentRouteProvider);
    final showBack = currentRoute != null && currentRoute != homeRouteName;

    // Only the page on top moves the chrome (`PageChrome`), and it takes it
    // over after the frame: its first frame is still the colour it covers.
    final ground = Theme.of(context).scaffoldBackgroundColor;
    final wantChrome = widget.tint ?? ground;
    if (_isOnTop && !(identical(_chrome.driver, this) && _chromeTween?.end == wantChrome)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _isOnTop) _fadeChromeTo(wantChrome);
      });
    }

    // Tab order is by `ShellFocusOrder`, not by where `appBar` and `body` happen
    // to sit in the tree: title bar, rail, search, top-bar actions, page.
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      // The one surface the title bar and the rail both sit on: neither paints
      // a ground of its own, so a change of colour fades in under both.
      child: ValueListenableBuilder<Color?>(
      valueListenable: _chrome,
      builder: (context, color, child) => ColoredBox(color: color ?? wantChrome, child: child),
      child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: TopBar(
        toggleDrawer: _toggleDrawer,
        showBackButton: showBack,
        onBack: _goBack,
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // First in the Tab order wherever the miniplayer is on screen.
          const MiniPlayerStop(),
          // The inline drawer that pushes content instead of overlaying it
          FocusSurface(
            order: ShellFocusOrder.rail,
            child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            // 240px wide when open, 72px wide (mini drawer) when closed.
            // Change 72 to 0 if you want it completely hidden when closed!
            width: isDrawerOpen ? ScreenValues.openRailWidth : ScreenValues.closedRailWidth,
            child: Material(
              type: MaterialType.transparency,
              child: SilkyListView(
                children: [
                  _DrawerItem(
                    key: const ValueKey('home'),
                    icon: Icons.home,
                    label: 'Home',
                    isOpen: isDrawerOpen,
                    isSelected: isOnHome,
                    onTap: () {
                      rootNavigatorKey.currentState?.popUntil((route) => route.isFirst);
                    },
                  ),
                  // No Shorts entry. The parser strips Shorts by design — it is
                  // the product's first requirement — so the item could never
                  // have shown anything. The rest of these are placeholders that
                  // become real in later tasks.
                  _DrawerItem(
                    key: const ValueKey('subscriptions'),
                    icon: Icons.subscriptions_outlined,
                    label: 'Subscriptions',
                    isOpen: isDrawerOpen,
                    isSelected: isOnSubscriptions,
                    onTap: _openSubscriptions,
                  ),
                  if (isDrawerOpen) ...[
                    const Divider(height: 32),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Text('You', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ],
                  _DrawerItem(
                    key: const ValueKey('playlists'),
                    icon: Icons.playlist_play,
                    label: 'Playlists',
                    isOpen: isDrawerOpen,
                    onTap: () {},
                  ),
                  _DrawerItem(
                    key: const ValueKey('history'),
                    icon: Icons.history,
                    label: 'History',
                    isOpen: isDrawerOpen,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
          ),

          // The actual page content, under the required-update banner when
          // there is one (architecture.md §2.14).
          Expanded(
            child: FocusSurface(
              order: ShellFocusOrder.content,
              // The watch page numbers its columns (`WatchFocusOrder`); every other
              // page has no numbers and is read in reading order.
              ordered: true,
              child: Column(
                children: [
                  // See [_landing].
                  FocusTraversalOrder(
                    order: const NumericFocusOrder(0),
                    child: Focus(focusNode: _landing, child: const SizedBox.shrink()),
                  ),
                  const UpdateBanner(),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadiusGeometry.only(topLeft: Radius.circular(10)),
                      // The page's own ground, from the same value as the chrome so
                      // the two fade together and meet with no seam. A page paints
                      // none of its own: one that did would pop in over this.
                      child: ValueListenableBuilder<Color?>(
                        valueListenable: _chrome,
                        builder: (context, color, child) =>
                            DecoratedBox(decoration: pageGroundFor(color ?? wantChrome, ground), child: child),
                        child: widget.body,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isOpen;
  final bool isSelected;
  final VoidCallback onTap;

  const _DrawerItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isOpen,
    this.isSelected = false,
    required this.onTap,
  });

  static const Duration _animDuration = Duration(milliseconds: 300);
  static const Curve _animCurve = Curves.fastOutSlowIn;
  static const double _closedHeight = ScreenValues.closedRailWidth - 2.0;
  static const double _openHeight = ScreenValues.railButtonHeight;
  static const double _width = ScreenValues.railButtonWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Active state colors
    final activeColor = isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant;
    final backgroundColor = isSelected ? colorScheme.primaryContainer.withAlpha(128) : Colors.transparent;
    final borderRadius = isSelected ? ScreenValues.railItemBorderRadiusSelected : ScreenValues.railItemBorderRadius;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(borderRadius),
        clipBehavior: Clip.antiAlias,
        // One name for the item. The two visual labels below (closed and open rail) are
        // both in the tree, so left alone Narrator read "Home Home".
        child: Semantics(
          label: label,
          selected: isSelected,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(borderRadius),
            child: AnimatedContainer(
              duration: _animDuration,
              curve: _animCurve,
              height: isOpen ? _openHeight : _closedHeight,
              child: Row(
                children: [
                  // Anchored Icon & Vertical Label Container (Fixed Width)
                  SizedBox(
                    width: _width, // Fixed width for icon and vertical label
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Fixed Icon
                        Icon(
                          icon,
                          size: 26.0,
                          color: activeColor,
                        ),

                        // Vertical Label (Visible only when CLOSED)
                        AnimatedClipRect(
                          open: !isOpen,
                          horizontal: false,
                          child: AnimatedOpacity(
                            duration: _animDuration,
                            curve: _animCurve,
                            // Semantics are never skipped at 0: anything with an overlay inside (a tooltip)
                            // would be left an orphan (F51).
                            alwaysIncludeSemantics: true,
                            opacity: !isOpen ? 1.0 : 0.0,
                            child: AnimatedSlide(
                              duration: _animDuration,
                              curve: _animCurve,
                              offset: !isOpen ? Offset.zero : const Offset(0, 0.5),
                              child: Padding(
                                padding: const EdgeInsets.only(top: 2.0),
                                child: ExcludeSemantics(
                                  child: Text(
                                    label,
                                    maxLines: 1,
                                    overflow: TextOverflow.visible,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: activeColor,
                                      fontSize: key == const ValueKey('subscriptions') ? 9 : 11.0,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Horizontal Label (Visible only when OPEN)
                  Expanded(
                    child: AnimatedOpacity(
                      duration: _animDuration,
                      curve: _animCurve,
                      alwaysIncludeSemantics: true, // F51
                      opacity: isOpen ? 1.0 : 0.0,
                      child: AnimatedSlide(
                        duration: _animDuration,
                        curve: _animCurve,
                        offset: isOpen ? Offset.zero : const Offset(-0.2, 0),
                        child: ExcludeSemantics(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: activeColor,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ),
        ),
      ),
    );
  }
}

/// Helper widget to smoothly clip label overflow during vertical transitions
class AnimatedClipRect extends StatelessWidget {
  final Widget child;
  final bool open;
  final bool horizontal;

  const AnimatedClipRect({
    super.key,
    required this.child,
    required this.open,
    this.horizontal = true,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedAlign(
      duration: const Duration(milliseconds: 300),
      curve: Curves.fastOutSlowIn,
      alignment: Alignment.center,
      heightFactor: horizontal ? 1.0 : (open ? 1.0 : 0.0),
      widthFactor: horizontal ? (open ? 1.0 : 0.0) : 1.0,
      child: ClipRect(child: child),
    );
  }
}
