// Exactly one `no_color_literals` violation, on purpose — tool/lint_gate.dart
// fails unless this file produces exactly one diagnostic. `dart:ui`'s Color
// is enough to trigger the rule (see `_isFlutterUi` in no_color_literals.dart),
// so the package's only dependency is the Flutter SDK itself — a local
// reference, nothing to download — and it resolves fast.
import 'dart:ui' show Color;

const Color canaryColor = Color(0x16092004);
