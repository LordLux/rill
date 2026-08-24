/// The caption style menu, the drag offset, and the geometry that makes both
/// possible — Task 19. `docs/architecture.md` §2.9, `protocol.md` §3.8.
///
/// **None of this is applied on the Flutter side.** It is collected here and
/// sent to the sidecar, which folds it into the ASS document it generates. mpv
/// has live properties for most of it and they cannot be used: they act on the
/// ASS `Style`, and `sub-ass-override=force` — the switch that is meant to make
/// them win — overrides the `Style` too, **not the inline override tags** a
/// styled track is made of. A user changing the font colour would see it work on
/// plain tracks and silently do nothing on styled ones. Measured against the
/// bundled libmpv 2026-08-19.
///
/// Hand-written rather than `freezed`, deliberately. Every class here is a
/// handful of fields with one job — crossing the RPC boundary — and two of them
/// carry a `Color`, which needs a converter either way. The generated code would
/// be longer than the file.
library;

import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

/// The three edge treatments ASS can express.
///
/// **YouTube names five and two of them cannot be honoured.** ASS has `\bord`
/// and `\shad` and no bevel, so *Raised* and *Depressed* both render as a drop
/// shadow — offering them would be two menu entries with one result. Recorded as
/// an accepted limitation in `architecture.md` §2.9 rather than faked.
enum CaptionEdgeStyle {
  none('none', 'None'),
  dropShadow('dropShadow', 'Drop shadow'),
  outline('outline', 'Outline');

  const CaptionEdgeStyle(this.wire, this.label);

  /// What the sidecar's `CaptionEdgeStyle` calls it.
  final String wire;
  final String label;
}

/// Everything the caption style menu owns.
///
/// Every field is nullable and `null` means **the track decides** — not "off".
/// An unset [background] still draws, at YouTube's own default, because the box
/// is drawn unconditionally and is what the user grabs to drag the caption.
@immutable
class CaptionStyle {
  const CaptionStyle({
    this.fontFamily,
    this.fontSizePercent,
    this.textColor,
    this.background,
    this.window,
    this.edgeStyle,
    this.forceFontFamily = true,
    this.forceFontSize = true,
    this.forceTextColor = true,
    this.forceBackground = true,
    this.forceWindow = true,
    this.forceEdgeStyle = true,
  });

  /// A fresh session, and what the menu's *Reset* produces.
  static const CaptionStyle none = CaptionStyle();

  final String? fontFamily;
  final bool forceFontFamily;

  /// Percentage of the document's own default size. 100 is unchanged.
  final double? fontSizePercent;
  final bool forceFontSize;

  /// Text colour *and* opacity — the alpha channel is the font-opacity control.
  final Color? textColor;
  final bool forceTextColor;

  /// The per-line box behind the words. A zero alpha is a user turning it off.
  final Color? background;
  final bool forceBackground;

  /// The rectangle around every caption on screen. Zero alpha by default, which
  /// is what YouTube ships.
  final Color? window;
  final bool forceWindow;

  final CaptionEdgeStyle? edgeStyle;
  final bool forceEdgeStyle;

  bool get isDefault =>
      fontFamily == null &&
      fontSizePercent == null &&
      textColor == null &&
      background == null &&
      window == null &&
      edgeStyle == null;

  /// **A sentinel per field, because every one of them has to be clearable.**
  ///
  /// Hard invariant 10: `value ?? this.value` cannot *unset* anything, so the
  /// menu's per-control "back to default" would silently do nothing on exactly
  /// the controls it is for. Each parameter takes `_unchanged` instead.
  CaptionStyle copyWith({
    Object? fontFamily = _unchanged,
    Object? fontSizePercent = _unchanged,
    Object? textColor = _unchanged,
    Object? background = _unchanged,
    Object? window = _unchanged,
    Object? edgeStyle = _unchanged,
    bool? forceFontFamily,
    bool? forceFontSize,
    bool? forceTextColor,
    bool? forceBackground,
    bool? forceWindow,
    bool? forceEdgeStyle,
  }) {
    return CaptionStyle(
      fontFamily: identical(fontFamily, _unchanged) ? this.fontFamily : fontFamily as String?,
      fontSizePercent:
          identical(fontSizePercent, _unchanged) ? this.fontSizePercent : fontSizePercent as double?,
      textColor: identical(textColor, _unchanged) ? this.textColor : textColor as Color?,
      background: identical(background, _unchanged) ? this.background : background as Color?,
      window: identical(window, _unchanged) ? this.window : window as Color?,
      edgeStyle:
          identical(edgeStyle, _unchanged) ? this.edgeStyle : edgeStyle as CaptionEdgeStyle?,
      forceFontFamily: forceFontFamily ?? this.forceFontFamily,
      forceFontSize: forceFontSize ?? this.forceFontSize,
      forceTextColor: forceTextColor ?? this.forceTextColor,
      forceBackground: forceBackground ?? this.forceBackground,
      forceWindow: forceWindow ?? this.forceWindow,
      forceEdgeStyle: forceEdgeStyle ?? this.forceEdgeStyle,
    );
  }

  Map<String, Object?> toJson() => {
        'fontFamily': fontFamily,
        'fontSizePercent': fontSizePercent,
        'textColor': _colorToJson(textColor),
        'background': _colorToJson(background),
        'window': _colorToJson(window),
        'edgeStyle': edgeStyle?.wire,
        'forceFontFamily': forceFontFamily,
        'forceFontSize': forceFontSize,
        'forceTextColor': forceTextColor,
        'forceBackground': forceBackground,
        'forceWindow': forceWindow,
        'forceEdgeStyle': forceEdgeStyle,
      };

  factory CaptionStyle.fromJson(Map<String, dynamic> json) {
    CaptionEdgeStyle? edge;
    if (json['edgeStyle'] != null) {
      edge = CaptionEdgeStyle.values.where((e) => e.wire == json['edgeStyle']).firstOrNull;
    }
    return CaptionStyle(
      fontFamily: json['fontFamily'] as String?,
      fontSizePercent: (json['fontSizePercent'] as num?)?.toDouble(),
      textColor: _colorFromJson(json['textColor'] as Map<String, dynamic>?),
      background: _colorFromJson(json['background'] as Map<String, dynamic>?),
      window: _colorFromJson(json['window'] as Map<String, dynamic>?),
      edgeStyle: edge,
      forceFontFamily: json['forceFontFamily'] as bool? ?? true,
      forceFontSize: json['forceFontSize'] as bool? ?? true,
      forceTextColor: json['forceTextColor'] as bool? ?? true,
      forceBackground: json['forceBackground'] as bool? ?? true,
      forceWindow: json['forceWindow'] as bool? ?? true,
      forceEdgeStyle: json['forceEdgeStyle'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CaptionStyle &&
      other.fontFamily == fontFamily &&
      other.fontSizePercent == fontSizePercent &&
      other.textColor == textColor &&
      other.background == background &&
      other.window == window &&
      other.edgeStyle == edgeStyle &&
      other.forceFontFamily == forceFontFamily &&
      other.forceFontSize == forceFontSize &&
      other.forceTextColor == forceTextColor &&
      other.forceBackground == forceBackground &&
      other.forceWindow == forceWindow &&
      other.forceEdgeStyle == forceEdgeStyle;

  @override
  int get hashCode => Object.hash(
        fontFamily,
        fontSizePercent,
        textColor,
        background,
        window,
        edgeStyle,
        forceFontFamily,
        forceFontSize,
        forceTextColor,
        forceBackground,
        forceWindow,
        forceEdgeStyle,
      );
}

const Object _unchanged = Object();

/// What a caption can be coloured, and `null` for "leave it to the track".
///
/// **Deliberately here and not in `lib/theme/tokens.dart`.** These are not roles
/// in the app's colour scheme — they are values the user picks for text drawn
/// inside the video, sent to the sidecar and rendered by libass. Tying them to
/// the theme would make a caption change colour when the app did, which is not
/// a thing anyone wants. Living outside `lib/ui/` is also what keeps
/// `rill_lints/no_color_literals` correctly quiet about them.
const List<Color?> captionPalette = [
  null,
  captionWhite,
  captionBlack,
  Color(0xFFFFEB3B),
  Color(0xFF4CAF50),
  Color(0xFF2196F3),
  Color(0xFFF44336),
  Color(0xFF9C27B0),
];

const Color captionWhite = Color(0xFFFFFFFF);
const Color captionBlack = Color(0xFF000000);

/// YouTube's own default caption background: black at 75%.
///
/// The sidecar draws this when nobody has said otherwise, and the value is
/// repeated here for two things that need it before a document exists — the
/// menu's opacity slider, so it starts where the caption is, and the drag ghost.
const double captionDefaultBackgroundOpacity = 0.75;
const Color captionDefaultBackground = Color(0xBF000000);

/// Straight RGBA, in the order the sidecar reads it. ASS's inversion is the
/// sidecar's business and stays there.
Map<String, Object?>? _colorToJson(Color? color) {
  if (color == null) return null;
  return {
    'r': (color.r * 255).round(),
    'g': (color.g * 255).round(),
    'b': (color.b * 255).round(),
    'a': color.a,
  };
}

Color? _colorFromJson(Map<String, dynamic>? json) {
  if (json == null) return null;
  return Color.fromARGB(
    ((json['a'] as num) * 255).round(),
    json['r'] as int,
    json['g'] as int,
    json['b'] as int,
  );
}

/// Where the user dragged the caption, as a fraction of the video rect.
///
/// **A delta, not a coordinate.** It is added to whatever position the source
/// gives — none, an ASR rolling window, or a per-cue styled position — so one
/// rule covers every kind of track and nothing has to ask which kind it is
/// holding. A fraction rather than pixels so it survives resize, fullscreen and
/// the mini-player.
@immutable
class CaptionOffset {
  const CaptionOffset(this.dx, this.dy);

  static const CaptionOffset zero = CaptionOffset(0, 0);

  final double dx;
  final double dy;

  bool get isZero => dx == 0 && dy == 0;

  CaptionOffset operator +(CaptionOffset other) =>
      CaptionOffset(dx + other.dx, dy + other.dy);

  Map<String, Object?> toJson() => {'dx': dx, 'dy': dy};

  @override
  bool operator ==(Object other) =>
      other is CaptionOffset && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'CaptionOffset(${dx.toStringAsFixed(4)}, ${dy.toStringAsFixed(4)})';
}

/// The geometry the ASS document was written with, sent by `captions.get`.
///
/// **This exists because nothing publishes a caption's rectangle.** libass
/// composites into the video texture and mpv exposes only the plain text, so the
/// hit rectangle, the hover cursor, the drag ghost and the live clamp all run on
/// a Flutter estimate of the same string. These are the numbers that make the
/// estimate match the document — eight values per *track*, sent rather than
/// duplicated as constants here, because two copies of a layout constant are two
/// things that have to agree and eventually will not.
@immutable
class CaptionLayout {
  const CaptionLayout({
    required this.fontFamily,
    required this.fontSize,
    required this.playResX,
    required this.playResY,
    required this.margin,
    required this.outlineWidth,
    required this.boxPadding,
    required this.defaultAlignment,
    required this.defaultX,
    required this.defaultY,
    required this.lineSpacing,
  });

  factory CaptionLayout.fromJson(Map<String, Object?> json) => CaptionLayout(
        fontFamily: json['fontFamily'] as String? ?? 'Arial',
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 48,
        playResX: (json['playResX'] as num?)?.toDouble() ?? 1920,
        playResY: (json['playResY'] as num?)?.toDouble() ?? 1080,
        margin: (json['margin'] as num?)?.toDouble() ?? 60,
        outlineWidth: (json['outlineWidth'] as num?)?.toDouble() ?? 2.5,
        boxPadding: (json['boxPadding'] as num?)?.toDouble() ?? 6,
        defaultAlignment: (json['defaultAlignment'] as num?)?.toInt() ?? 2,
        defaultX: (json['defaultX'] as num?)?.toDouble() ?? 960,
        defaultY: (json['defaultY'] as num?)?.toDouble() ?? 1020,
        lineSpacing: (json['lineSpacing'] as num?)?.toDouble() ?? 1.2,
      );

  final String fontFamily;

  /// ASS `Fontsize`, after any user override. **Not an em size** — see
  /// `CaptionMetrics.measure`, which is the only place that difference matters.
  final double fontSize;
  final double playResX;
  final double playResY;
  final double margin;
  final double outlineWidth;
  final double boxPadding;

  /// ASS numpad alignment an unpositioned cue lands on. 2 is bottom-centre.
  final int defaultAlignment;
  final double defaultX;
  final double defaultY;
  final double lineSpacing;

  Map<String, Object?> toJson() => {
        'fontFamily': fontFamily,
        'fontSize': fontSize,
        'playResX': playResX,
        'playResY': playResY,
        'margin': margin,
        'outlineWidth': outlineWidth,
        'boxPadding': boxPadding,
        'defaultAlignment': defaultAlignment,
        'defaultX': defaultX,
        'defaultY': defaultY,
        'lineSpacing': lineSpacing,
      };

  @override
  bool operator ==(Object other) =>
      other is CaptionLayout &&
      other.fontFamily == fontFamily &&
      other.fontSize == fontSize &&
      other.playResX == playResX &&
      other.playResY == playResY &&
      other.margin == margin &&
      other.outlineWidth == outlineWidth &&
      other.boxPadding == boxPadding &&
      other.defaultAlignment == defaultAlignment &&
      other.defaultX == defaultX &&
      other.defaultY == defaultY &&
      other.lineSpacing == lineSpacing;

  @override
  int get hashCode => Object.hash(fontFamily, fontSize, playResX, playResY, margin, outlineWidth,
      boxPadding, defaultAlignment, defaultX, defaultY, lineSpacing);
}

/// How wide a string will be, per character, in the document's own pixels.
///
/// **Flutter measures it and sends it, because neither side can do it alone.**
/// The sidecar holds every cue's text and has no font engine; Flutter has the
/// font engine and never sees a cue it is not currently displaying. So Flutter
/// measures the alphabet once per font and size, and the sidecar applies the
/// table to the cue texts it already holds.
///
/// **A table, not a single pixels-per-character number**, and that is measured
/// rather than assumed. Advances at Arial 48 through the bundled libass run from
/// 8.3 px to 40.5 px — a 4.9x range — and a scalar calibrated on a
/// representative sentence under-estimates an all-capitals caption by 26% and a
/// run of `M` by 46%. Under-estimating is the one direction that lets text clip
/// off the edge of the player, which is the failure the clamp exists to prevent.
/// Summing per-character advances lands within +1–2% on every real caption line
/// tried, always on the safe side. `sidecar/scratch/measure-advances.ts`.
@immutable
class CaptionMetrics {
  const CaptionMetrics({required this.advances, required this.fallbackAdvance});

  final Map<String, double> advances;

  /// What a character outside the table is charged — CJK, emoji, accented Latin.
  /// The widest advance measured, so an unlisted glyph is over-counted.
  final double fallbackAdvance;

  Map<String, Object?> toJson() => {
        'advances': advances,
        'fallbackAdvance': fallbackAdvance,
      };

  /// The widest of a string's `\N`-separated lines, in the document's pixels.
  ///
  /// The same sum the sidecar performs, so the hit rectangle the user sees and
  /// the clamp the sidecar applies cannot disagree about the same caption.
  double widthOf(String text) {
    var widest = 0.0;
    for (final line in text.split('\n')) {
      var width = 0.0;
      for (final character in line.characters()) {
        width += advances[character] ?? fallbackAdvance;
      }
      if (width > widest) widest = width;
    }
    return widest;
  }
}

extension on String {
  /// Grapheme-naive, and deliberately the same split the sidecar does with
  /// `for…of` over a string: both iterate code points, so both charge a
  /// surrogate pair once.
  Iterable<String> characters() sync* {
    for (final rune in runes) {
      yield String.fromCharCode(rune);
    }
  }
}
