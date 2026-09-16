/// The accent **seed**, its presets, and the persistence behind them.
///
/// This file is one of the two places in the app allowed to name a colour
/// (`theme/tokens.dart` is the other). Everything under `lib/ui/` reads roles
/// off `ColorScheme` instead, enforced by the `no_color_literals` rule in
/// `tool/rill_lints`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Deliberately not red. Red is the single strongest signal of YouTube's brand
/// and this app does not borrow it.
const Color kDefaultAccent = Color(0xFF7C4DFF);

/// The swatches offered by the temporary debug control.
///
/// These are *seeds*, not values that reach a widget: every one of them is run
/// through `ColorScheme.fromSeed`, so a very light or very saturated pick still
/// derives readable foregrounds rather than painting unreadable text.
const List<({String name, Color seed})> kAccentPresets = [
  (name: 'Purple', seed: kDefaultAccent),
  (name: 'Blue', seed: Color(0xFF2979FF)),
  (name: 'Teal', seed: Color(0xFF00BFA5)),
  (name: 'Lime', seed: Color(0xFFAEEA00)),
  (name: 'Amber', seed: Color(0xFFFFC400)),
  (name: 'Pink', seed: Color(0xFFFF4081)),
];

const String _prefsKey = 'accent_seed_argb';

/// The accent in effect, persisted across launches.
///
/// `build()` returns the default synchronously and the stored value lands a
/// frame or two later — the same shape as `FeedController`. Blocking the first
/// frame on a disk read to avoid one repaint is the worse trade; resetting to
/// purple on every launch, which is what no persistence at all would do, reads
/// as broken.
class AccentController extends Notifier<Color> {
  @override
  Color build() {
    Future.microtask(_restore);
    return kDefaultAccent;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(_prefsKey);
    if (stored != null) state = Color(stored);
  }

  Future<void> set(Color accent) async {
    if (accent == state) return;
    state = accent;
    final prefs = await SharedPreferences.getInstance();
    // `toARGB32` rather than the deprecated `.value`: same 32 bits, and it does
    // not drag in the wide-gamut fields that `Color` now carries.
    await prefs.setInt(_prefsKey, accent.toARGB32());
  }
}

final accentProvider = NotifierProvider<AccentController, Color>(
  AccentController.new,
);

extension ColorLightVariation on Color {
  Color darken([double amount = .1]) => _darken(this, amount);
  Color lighten([double amount = .1]) => _lighten(this, amount);
}

Color _darken(Color color, [double amount = .1]) {
  assert(amount >= 0 && amount <= 1);

  final hsl = HSLColor.fromColor(color);
  final hslDark = hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0));

  return hslDark.toColor();
}

Color _lighten(Color color, [double amount = .1]) {
  assert(amount >= 0 && amount <= 1);

  final hsl = HSLColor.fromColor(color);
  final hslLight = hsl.withLightness((hsl.lightness + amount).clamp(0.0, 1.0));

  return hslLight.toColor();
}