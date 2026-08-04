import 'package:flutter/material.dart';

class TextThemeMod extends StatelessWidget {
  const TextThemeMod({
    super.key,
    required this.child,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final Widget child;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.apply(fontSizeDelta: -1.0),
      ),
      child: child,
    );
  }
}
