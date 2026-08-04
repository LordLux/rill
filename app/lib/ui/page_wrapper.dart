import 'package:flutter/material.dart';

import 'widgets/topbar.dart';

class PageWrapper extends StatefulWidget {
  final Widget body;
  final Widget? title;
  final List<Widget>? actions;

  const PageWrapper({super.key, required this.body, this.title, this.actions});

  @override
  State<PageWrapper> createState() => _PageWrapperState();
}

class _PageWrapperState extends State<PageWrapper> {
  bool _isDrawerOpen = true;

  void _toggleDrawer() => setState(() => _isDrawerOpen = !_isDrawerOpen);

  @override
  Widget build(BuildContext context) {
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
            width: _isDrawerOpen ? 240 : 72,
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: ListView(
                children: [
                  _DrawerItem(
                    key: const ValueKey('home'),
                    icon: Icons.home,
                    label: 'Home',
                    isOpen: _isDrawerOpen,
                    isSelected: true, // Example of selected state
                    onTap: () {},
                  ),
                  _DrawerItem(
                    key: const ValueKey('shorts'),
                    icon: Icons.explore_outlined,
                    label: 'Shorts',
                    isOpen: _isDrawerOpen,
                    onTap: () {},
                  ),
                  _DrawerItem(
                    key: const ValueKey('subscriptions'),
                    icon: Icons.subscriptions_outlined,
                    label: 'Subscriptions',
                    isOpen: _isDrawerOpen,
                    onTap: () {},
                  ),
                  if (_isDrawerOpen) ...[
                    const Divider(height: 32),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      child: Text('You', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ],
                  _DrawerItem(
                    key: const ValueKey('history'),
                    icon: Icons.history,
                    label: 'History',
                    isOpen: _isDrawerOpen,
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
