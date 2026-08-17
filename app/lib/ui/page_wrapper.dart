import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widgets/topbar.dart';

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

class PageWrapper extends ConsumerStatefulWidget {
  final Widget body;
  final Widget title;
  final List<Widget>? actions;

  const PageWrapper({super.key, required this.body, required this.title, this.actions});

  @override
  ConsumerState<PageWrapper> createState() => _PageWrapperState();
}

class _PageWrapperState extends ConsumerState<PageWrapper> {
  void _toggleDrawer() => ref.read(drawerStateProvider.notifier).toggle();

  @override
  Widget build(BuildContext context) {
    final isDrawerOpen = ref.watch(drawerStateProvider);

    return Scaffold(
      appBar: TopBar(
        title: widget.title,
        actions: widget.actions ?? [],
        toggleDrawer: _toggleDrawer,
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The inline drawer that pushes content instead of overlaying it
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            // 240px wide when open, 72px wide (mini drawer) when closed.
            // Change 72 to 0 if you want it completely hidden when closed!
            width: isDrawerOpen ? 240 : 72,
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: ListView(
                children: [
                  _DrawerItem(
                    key: const ValueKey('home'),
                    icon: Icons.home,
                    label: 'Home',
                    isOpen: isDrawerOpen,
                    isSelected: true, // Example of selected state
                    onTap: () {},
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
                    onTap: () {},
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

          // The actual page content
          Expanded(child: widget.body),
        ],
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
  static const double _closedHeight = 70.0;
  static const double _openHeight = 48.0;
  static const double _width = 64.0;
  static const double _borderRadius = 10.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Active state colors
    final activeColor = isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant;
    final backgroundColor = isSelected ? colorScheme.primaryContainer.withAlpha(128) : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(_borderRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(_borderRadius),
          child: AnimatedContainer(
            duration: _animDuration,
            curve: _animCurve,
            height: isOpen ? _openHeight : _closedHeight,
            child: Row(
              children: [
                // 1. Anchored Icon & Vertical Label Container (Fixed Width)
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
                          opacity: !isOpen ? 1.0 : 0.0,
                          child: AnimatedSlide(
                            duration: _animDuration,
                            curve: _animCurve,
                            offset: !isOpen ? Offset.zero : const Offset(0, 0.5),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2.0),
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.visible,
                                style: theme.textTheme.labelSmall?.copyWith(
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

                // 2. Horizontal Label (Visible only when OPEN)
                Expanded(
                  child: AnimatedOpacity(
                    duration: _animDuration,
                    curve: _animCurve,
                    opacity: isOpen ? 1.0 : 0.0,
                    child: AnimatedSlide(
                      duration: _animDuration,
                      curve: _animCurve,
                      offset: isOpen ? Offset.zero : const Offset(-0.2, 0),
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
              ],
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
