import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// The tooltip bubble, app-wide — installed as `ThemeData.tooltipTheme` below.
///
/// **A theme rather than per-widget arguments** so that tooltips this app does
/// not construct itself get it too: `IconButton(tooltip:)` and every other
/// Material component that builds its own `Tooltip` read the theme and cannot
/// be handed a `decoration`. `Tooltip` resolves `widget.decoration ??
/// tooltipTheme.decoration ?? default` (and the same for `textStyle`), so a
/// widget that passes nothing gets this, and one that passes its own still
/// wins.
///
/// Fixed dark, rather than derived from the scheme: Material 3's default
/// bubble follows `colorScheme.onSurface`, which on this app's theme is a pale
/// bubble with dark text — it read as a bug, and it made `ShortcutTooltip`'s
/// white key badge white-on-white. An instruction bubble should look the same
/// whatever the accent.
///
/// Kept public for the rare widget that styles a bubble-like surface by hand
/// and wants to match; an ordinary `Tooltip` needs neither.
const BoxDecoration tooltipBubbleDecoration = BoxDecoration(
  color: Color(0xE6212121),
  borderRadius: BorderRadius.all(Radius.circular(6)),
);
const TextStyle tooltipBubbleTextStyle = TextStyle(color: tooltipBubbleForeground, fontSize: 12, height: 1.3);

/// What is legible on [tooltipBubbleDecoration] — which never follows the
/// app theme, so neither may anything drawn inside it. `ShortcutTooltip`'s key
/// badge applies alpha to these at the call site.
const Color tooltipBubbleForeground = Color(0xFFFFFFFF);

/// Darkens an inset drawn on the bubble. See [tooltipBubbleForeground].
const Color tooltipBubbleShade = Color(0xFF000000);

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
    tooltipTheme: base.tooltipTheme.copyWith(
      decoration: tooltipBubbleDecoration,
      textStyle: tooltipBubbleTextStyle,
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
