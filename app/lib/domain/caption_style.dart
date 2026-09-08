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
    this.textOpacity,
    this.background,
    this.backgroundOpacity,
    this.window,
    this.windowOpacity,
    this.edgeStyle,
    this.forceStyleEnabled = true,
    this.forceFontFamily = true,
    this.forceFontSize = true,
    this.forceTextColor = true,
    this.forceTextOpacity = true,
    this.forceBackgroundColor = true,
    this.forceBackgroundOpacity = true,
    this.forceWindowColor = true,
    this.forceWindowOpacity = true,
    this.forceEdgeStyle = true,
  });

  /// A fresh session, and what the menu's *Reset* produces.
  static const CaptionStyle none = CaptionStyle();

  /// The "Force Style" master switch. Independent of the nine `forceXxx`
  /// flags below — it does not read them and toggling one does not change
  /// it — so a tile can be turned on or off without disturbing what the
  /// other eight are set to, and the menu can show the master truthfully
  /// without it drifting the moment any single tile differs from the rest.
  /// `false` gates every one of the nine off, in `ass.ts`'s `resolve()`,
  /// without touching their stored values — turning the master back on
  /// restores whatever the tiles already said.
  final bool forceStyleEnabled;

  final String? fontFamily;
  final bool forceFontFamily;

  /// Percentage of the document's own default size. 100 is unchanged.
  final double? fontSizePercent;
  final bool forceFontSize;

  /// Text colour, independent of [textOpacity] — resetting one to default
  /// (`null`) must not touch the other, so they are two nullable fields
  /// rather than one `Color?` carrying both in its alpha channel. Any alpha
  /// on this [Color] itself is ignored; [textOpacity] is authoritative.
  final Color? textColor;
  final bool forceTextColor;

  /// 0–1. Independent of [textColor] — see there for why.
  final double? textOpacity;
  final bool forceTextOpacity;

  /// The per-line box behind the words, independent of [backgroundOpacity]
  /// for the same reason [textColor] is independent of [textOpacity].
  final Color? background;
  final bool forceBackgroundColor;

  /// 0–1. `0` is a user turning the background off.
  final double? backgroundOpacity;
  final bool forceBackgroundOpacity;

  /// The rectangle around every caption on screen, independent of
  /// [windowOpacity] for the same reason [textColor] is independent of
  /// [textOpacity]. `0` opacity by default, which is what YouTube ships.
  final Color? window;
  final bool forceWindowColor;
  final double? windowOpacity;
  final bool forceWindowOpacity;

  final CaptionEdgeStyle? edgeStyle;
  final bool forceEdgeStyle;

  bool get isDefault =>
      fontFamily == null &&
      fontSizePercent == null &&
      textColor == null &&
      textOpacity == null &&
      background == null &&
      backgroundOpacity == null &&
      window == null &&
      windowOpacity == null &&
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
    Object? textOpacity = _unchanged,
    Object? background = _unchanged,
    Object? backgroundOpacity = _unchanged,
    Object? window = _unchanged,
    Object? windowOpacity = _unchanged,
    Object? edgeStyle = _unchanged,
    bool? forceStyleEnabled,
    bool? forceFontFamily,
    bool? forceFontSize,
    bool? forceTextColor,
    bool? forceTextOpacity,
    bool? forceBackgroundColor,
    bool? forceBackgroundOpacity,
    bool? forceWindowColor,
    bool? forceWindowOpacity,
    bool? forceEdgeStyle,
  }) {
    return CaptionStyle(
      fontFamily: identical(fontFamily, _unchanged) ? this.fontFamily : fontFamily as String?,
      fontSizePercent:
          identical(fontSizePercent, _unchanged) ? this.fontSizePercent : fontSizePercent as double?,
      textColor: identical(textColor, _unchanged) ? this.textColor : textColor as Color?,
      textOpacity:
          identical(textOpacity, _unchanged) ? this.textOpacity : textOpacity as double?,
      background: identical(background, _unchanged) ? this.background : background as Color?,
      backgroundOpacity: identical(backgroundOpacity, _unchanged)
          ? this.backgroundOpacity
          : backgroundOpacity as double?,
      window: identical(window, _unchanged) ? this.window : window as Color?,
      windowOpacity:
          identical(windowOpacity, _unchanged) ? this.windowOpacity : windowOpacity as double?,
      edgeStyle:
          identical(edgeStyle, _unchanged) ? this.edgeStyle : edgeStyle as CaptionEdgeStyle?,
      forceStyleEnabled: forceStyleEnabled ?? this.forceStyleEnabled,
      forceFontFamily: forceFontFamily ?? this.forceFontFamily,
      forceFontSize: forceFontSize ?? this.forceFontSize,
      forceTextColor: forceTextColor ?? this.forceTextColor,
      forceTextOpacity: forceTextOpacity ?? this.forceTextOpacity,
      forceBackgroundColor: forceBackgroundColor ?? this.forceBackgroundColor,
      forceBackgroundOpacity: forceBackgroundOpacity ?? this.forceBackgroundOpacity,
      forceWindowColor: forceWindowColor ?? this.forceWindowColor,
      forceWindowOpacity: forceWindowOpacity ?? this.forceWindowOpacity,
      forceEdgeStyle: forceEdgeStyle ?? this.forceEdgeStyle,
    );
  }

  Map<String, Object?> toJson() => {
        'fontFamily': fontFamily,
        'fontSizePercent': fontSizePercent,
        'textColor': _rgbToJson(textColor),
        'textOpacity': textOpacity,
        'background': _rgbToJson(background),
        'backgroundOpacity': backgroundOpacity,
        'window': _rgbToJson(window),
        'windowOpacity': windowOpacity,
        'edgeStyle': edgeStyle?.wire,
        'forceStyleEnabled': forceStyleEnabled,
        'forceFontFamily': forceFontFamily,
        'forceFontSize': forceFontSize,
        'forceTextColor': forceTextColor,
        'forceTextOpacity': forceTextOpacity,
        'forceBackgroundColor': forceBackgroundColor,
        'forceBackgroundOpacity': forceBackgroundOpacity,
        'forceWindowColor': forceWindowColor,
        'forceWindowOpacity': forceWindowOpacity,
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
      textColor: _rgbFromJson(json['textColor'] as Map<String, dynamic>?),
      textOpacity: (json['textOpacity'] as num?)?.toDouble(),
      background: _rgbFromJson(json['background'] as Map<String, dynamic>?),
      backgroundOpacity: (json['backgroundOpacity'] as num?)?.toDouble(),
      window: _rgbFromJson(json['window'] as Map<String, dynamic>?),
      windowOpacity: (json['windowOpacity'] as num?)?.toDouble(),
      edgeStyle: edge,
      forceStyleEnabled: json['forceStyleEnabled'] as bool? ?? true,
      forceFontFamily: json['forceFontFamily'] as bool? ?? true,
      forceFontSize: json['forceFontSize'] as bool? ?? true,
      forceTextColor: json['forceTextColor'] as bool? ?? true,
      forceTextOpacity: json['forceTextOpacity'] as bool? ?? true,
      forceBackgroundColor: json['forceBackgroundColor'] as bool? ?? true,
      forceBackgroundOpacity: json['forceBackgroundOpacity'] as bool? ?? true,
      forceWindowColor: json['forceWindowColor'] as bool? ?? true,
      forceWindowOpacity: json['forceWindowOpacity'] as bool? ?? true,
      forceEdgeStyle: json['forceEdgeStyle'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CaptionStyle &&
      other.fontFamily == fontFamily &&
      other.fontSizePercent == fontSizePercent &&
      other.textColor == textColor &&
      other.textOpacity == textOpacity &&
      other.background == background &&
      other.backgroundOpacity == backgroundOpacity &&
      other.window == window &&
      other.windowOpacity == windowOpacity &&
      other.edgeStyle == edgeStyle &&
      other.forceStyleEnabled == forceStyleEnabled &&
      other.forceFontFamily == forceFontFamily &&
      other.forceFontSize == forceFontSize &&
      other.forceTextColor == forceTextColor &&
      other.forceTextOpacity == forceTextOpacity &&
      other.forceBackgroundColor == forceBackgroundColor &&
      other.forceBackgroundOpacity == forceBackgroundOpacity &&
      other.forceWindowColor == forceWindowColor &&
      other.forceWindowOpacity == forceWindowOpacity &&
      other.forceEdgeStyle == forceEdgeStyle;

  @override
  int get hashCode => Object.hash(
        fontFamily,
        fontSizePercent,
        textColor,
        textOpacity,
        background,
        backgroundOpacity,
        window,
        windowOpacity,
        edgeStyle,
        Object.hash(
          forceStyleEnabled,
          forceFontFamily,
          forceFontSize,
          forceTextColor,
          forceTextOpacity,
          forceBackgroundColor,
          forceBackgroundOpacity,
          forceWindowColor,
          forceWindowOpacity,
          forceEdgeStyle,
        ),
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

/// YouTube's own default caption background: black at 75%. `LibassLayer`
/// paints this on a non-positional track with no [CaptionStyle.background]
/// set — see `_resolveOverlayColor`.
const Color captionDefaultBackground = Color(0xBF000000);

/// RGB only, in the order the sidecar reads it. Opacity travels as its own
/// field now (`textOpacity`/`backgroundOpacity`/`windowOpacity`), so there is
/// nothing here for the colour's own alpha channel to carry — any alpha this
/// [Color] happens to have is not sent and must not be read back out.
Map<String, Object?>? _rgbToJson(Color? color) {
  if (color == null) return null;
  return {
    'r': (color.r * 255).round(),
    'g': (color.g * 255).round(),
    'b': (color.b * 255).round(),
  };
}

Color? _rgbFromJson(Map<String, dynamic>? json) {
  if (json == null) return null;
  return Color.fromARGB(
    255,
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

  /// ASS `Fontsize`, after any user override. **Not an em size** — libass
  /// scales the face so its ascent plus descent equals this.
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
