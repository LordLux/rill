import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// The whole theme, derived from one seed.
///
/// The accent is a seed, never a value a widget paints with. `fromSeed` is what
/// keeps a user's very light or very saturated pick readable: it derives the
/// foreground for every role rather than trusting the input to be usable as a
/// text colour.
ThemeData buildRillTheme(Color accent) {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  );
  final base = ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: GoogleFonts.roboto().fontFamily,
  );
  final tokens = RillTokens.from(scheme);

  // No font-size delta here, deliberately.
  //
  // `TextThemeMod` wrapped the whole app to apply `fontSizeDelta: -1.0` (and to
  // take a `themeMode` and an `onThemeModeChanged` it used for nothing). That
  // delta never did anything: every style on a Material 3 `ThemeData.textTheme`
  // has a **null** `fontSize` — the size is resolved later, per component — and
  // `TextStyle.apply` leaves a null size null. In a release build it silently
  // changed nothing; in a debug build the assert on line 996 of `text_style.dart`
  // fires, which is why deleting it rather than moving it here is the fix. If a
  // smaller type scale is wanted later it has to be a real `TextTheme`, not a
  // delta over one that has no sizes in it.
  return base.copyWith(
    extensions: [tokens],
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values) platform: const _NoTransitionsBuilder(),
      },
    ),
    chipTheme: base.chipTheme.copyWith(
      // The selected filter chip is one of the few places the accent belongs.
      backgroundColor: scheme.surfaceContainerHighest,
      side: BorderSide.none,
      selectedColor: scheme.primaryContainer,
      labelStyle: TextStyle(color: scheme.onSurface),
      secondaryLabelStyle: TextStyle(color: scheme.onPrimaryContainer),
    ),
  );
}

class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T>? route,
    BuildContext? context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget? child,
  ) {
    return child!;
  }
}
