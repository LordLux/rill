import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/screen_values.dart';
import '../page_wrapper.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Titlebar button shell — shared sizing and padding for every non-window button
// ─────────────────────────────────────────────────────────────────────────────

/// Provides the standard sized hit-box, padding, ink-splash, and optional
/// tooltip for a titlebar button whose content is an arbitrary widget.
///
/// **[onTap] non-null** → the shell owns the interaction: wraps [child] in an
/// [InkWell] (and a [Tooltip] when [tooltip] is also set). Use this for passive
/// content like icons.
///
/// **[onTap] null** → the child manages its own interaction (e.g. a
/// [PopupMenuButton]). The shell only contributes sizing, padding, and the
/// [Material] the child's own ink will splash against.
class TitleBarWidgetButton extends ConsumerWidget {
  const TitleBarWidgetButton({
    super.key,
    required this.child,
    this.onTap,
    this.tooltip,
    this.overrideRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? tooltip;
  final double? overrideRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDrawerOpen = ref.watch(drawerStateProvider);
    final radius = overrideRadius ?? (isDrawerOpen ? ScreenValues.railItemBorderRadiusSelected : ScreenValues.railItemBorderRadius);
    final br = BorderRadius.circular(radius);

    Widget content = SizedBox(
      width: ScreenValues.railButtonWidth,
      height: ScreenValues.railButtonHeight,
      child: child,
    );

    if (onTap != null) {
      content = InkWell(onTap: onTap, borderRadius: br, child: content);
      if (tooltip != null) content = Tooltip(message: tooltip!, child: content);
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: br,
        clipBehavior: Clip.antiAlias,
        child: content,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Icon-specific convenience — delegates to [TitleBarWidgetButton]
// ─────────────────────────────────────────────────────────────────────────────

class TitleBarIconButton extends ConsumerWidget {
  const TitleBarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.scheme,
    this.overrideRadius,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final ColorScheme scheme;
  final double? overrideRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TitleBarWidgetButton(
      onTap: onTap,
      tooltip: tooltip,
      overrideRadius: overrideRadius,
      child: Icon(icon, color: scheme.onSurface, size: 22),
    );
  }
}
