/// Where a caption is on screen, and how wide the next one will be — Task 19.
///
/// **Nothing publishes a caption's rectangle.** libass composites into the video
/// texture (`architecture.md` §2.9, Decision 1) and media_kit exposes no
/// separate subtitle surface, so there is no bitmap to hit-test, measure or
/// drag. What there *is* is the plain text of the cue currently on screen —
/// mpv's `sub-text`, which stays populated while libass draws, measured
/// 2026-08-20 — plus the [CaptionLayout] the document was generated with.
///
/// So the hit rectangle, the hover cursor, the drag ghost and the live clamp all
/// run on **one estimate, produced here**, rather than three approximations that
/// can disagree. The sidecar's clamp for cues that have not appeared yet runs on
/// [measureAdvances]' table, applied there to the cue texts it already holds —
/// same instrument, same outward bias, applied in the two places a position is
/// decided.
///
/// **Everything rounds outward.** An over-estimate makes the hit rectangle
/// slightly too large and stops the drag a few pixels short of the corner; an
/// under-estimate lets text clip off the edge of the player. Only one of those
/// is a bug.
library;

import 'package:flutter/painting.dart';

import '../../domain/caption_style.dart';

/// The characters the width table covers. Everything else is charged
/// [CaptionMetrics.fallbackAdvance], which is the widest of these.
const String _alphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,!?\'"-:;()';

/// The size the vertical metrics are probed at. Large enough that the ratio it
/// produces is not a rounding artefact.
const double _probeSize = 100;

/// Measure one advance per character, in the document's own pixels.
///
/// **The conversion in the middle is the part that is not obvious.** ASS's
/// `Fontsize` is not an em size: libass scales the face so that its
/// *ascent + descent* equals `Fontsize`. Measured 2026-08-20 against the bundled
/// libass, Arial's advances at `Fontsize: 48` come out at 0.895x what an
/// em-sized 48 px `TextPainter` gives — and 2048/2288, Arial's units-per-em over
/// its ascent-plus-descent, is exactly 0.895. Measuring at the nominal size and
/// sending that would over-estimate every caption by ~11.7%: safe, but enough to
/// visibly stop the drag short of a corner. So the probe below derives the
/// equivalent Flutter size from the same face rather than hard-coding a ratio
/// for one font.
CaptionMetrics measureAdvances(CaptionLayout layout) {
  final probe = _painter('Hg', layout.fontFamily, _probeSize);
  final metrics = probe.computeLineMetrics();
  final extent = metrics.isEmpty ? _probeSize : metrics.first.ascent + metrics.first.descent;
  final size = extent <= 0 ? layout.fontSize : layout.fontSize * _probeSize / extent;

  // A space measured on its own is trimmed by `TextPainter`, so it is measured
  // as a difference instead. Nothing else needs the trick.
  final pair = _painter('x x', layout.fontFamily, size).width;
  final solid = _painter('xx', layout.fontFamily, size).width;

  final advances = <String, double>{};
  for (final character in _alphabet.split('')) {
    advances[character] =
        character == ' ' ? (pair - solid) : _painter(character, layout.fontFamily, size).width;
  }
  final widest = advances.values.fold(0.0, (a, b) => a > b ? a : b);
  return CaptionMetrics(advances: advances, fallbackAdvance: widest);
}

TextPainter _painter(String text, String family, double size) {
  return TextPainter(
    text: TextSpan(
      text: text,
      // `height: 1` so the line box is the font's own, not Flutter's default
      // 1.2x — the vertical probe above reads `ascent`/`descent` off it.
      style: TextStyle(fontFamily: family, fontSize: size, height: 1),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
}

/// The estimate is inflated by this before it is used, in both places.
///
/// The per-character sum lands within +1–2% of what libass draws on every real
/// caption line measured, and this covers the rest: Flutter's shaper is not
/// libass's, and the two disagree slightly on kerning and on font fallback.
const double captionEstimateInflation = 1.04;

/// Where the caption sits inside the video rectangle, in **screen** pixels.
///
/// Returns null when there is nothing to place — no text on screen.
///
/// The three ingredients are the layout's default anchor (the sidecar's
/// `\pos` for an undragged, unpositioned cue), the user's drag delta, and the
/// estimate. A *styled* track positions each cue individually and publishes none
/// of it, so on those the handle falls back to the default anchor: approximate,
/// still grabbable, and measured at 0% of ordinary tracks (§2.9).
Rect? captionRect({
  required String? text,
  required CaptionLayout layout,
  required CaptionMetrics? metrics,
  required CaptionOffset offset,
  required Rect video,
}) {
  if (text == null || text.trim().isEmpty || metrics == null) return null;

  final scaleX = video.width / layout.playResX;
  final scaleY = video.height / layout.playResY;

  final size = captionSize(text: text, layout: layout, metrics: metrics);
  final width = size.width * scaleX;
  final height = size.height * scaleY;

  final anchorX = (layout.defaultX + offset.dx * layout.playResX) * scaleX + video.left;
  final anchorY = (layout.defaultY + offset.dy * layout.playResY) * scaleY + video.top;

  // The default alignment is bottom-centre, and every other value it could take
  // is handled the same way the sidecar handles it.
  final left = anchorX - width * horizontalAlign(layout.defaultAlignment);
  final top = anchorY - height * verticalAlign(layout.defaultAlignment);
  return Rect.fromLTWH(left, top, width, height);
}

/// The caption's box in the document's own pixels, padding included.
Size captionSize({
  required String text,
  required CaptionLayout layout,
  required CaptionMetrics metrics,
}) {
  final lines = text.split('\n');
  final width = metrics.widthOf(text) * captionEstimateInflation + 2 * layout.boxPadding;
  final height = lines.length * layout.fontSize * layout.lineSpacing;
  return Size(width, height);
}

/// The fraction of a box that sits left of its `\an` anchor.
double horizontalAlign(int alignment) {
  final column = alignment % 3; // 1 left, 2 centre, 0 right
  return column == 1 ? 0 : (column == 2 ? 0.5 : 1);
}

/// The fraction of a box that sits above its `\an` anchor.
double verticalAlign(int alignment) {
  return alignment <= 3 ? 1 : (alignment <= 6 ? 0.5 : 0);
}

/// The drag delta that puts [rect] where the pointer wants it, clamped so the
/// caption cannot leave the frame — not even partly.
///
/// The clamp is against the *video* rectangle rather than the widget, because
/// the widget is letterboxed and the caption belongs to the picture.
CaptionOffset clampedOffset({
  required CaptionOffset proposed,
  required Size captionSize,
  required CaptionLayout layout,
  required int alignment,
}) {
  final anchorX = layout.defaultX + proposed.dx * layout.playResX;
  final anchorY = layout.defaultY + proposed.dy * layout.playResY;
  final pad = layout.boxPadding;

  final x = _clampSpan(anchorX, captionSize.width, horizontalAlign(alignment), layout.playResX, pad);
  final y = _clampSpan(anchorY, captionSize.height, verticalAlign(alignment), layout.playResY, pad);
  return CaptionOffset(
    (x - layout.defaultX) / layout.playResX,
    (y - layout.defaultY) / layout.playResY,
  );
}

/// The same rule `ass.ts` applies, so the ghost stops where the caption will.
double _clampSpan(double anchor, double extent, double align, double limit, double pad) {
  final low = pad;
  final high = limit - pad;
  if (extent >= high - low) return low + extent * align;
  final start = (anchor - extent * align).clamp(low, high - extent);
  return start + extent * align;
}

/// The video's rectangle inside a `BoxFit.contain` surface of [box].
///
/// media_kit letterboxes the texture, so the widget's bounds are not the
/// picture's bounds and a caption placed against the widget drifts on any aspect
/// ratio but the window's.
Rect videoRectIn(Size box, double aspectRatio) {
  if (!aspectRatio.isFinite || aspectRatio <= 0) return Rect.fromLTWH(0, 0, box.width, box.height);
  final boxRatio = box.width / box.height;
  if (boxRatio > aspectRatio) {
    final width = box.height * aspectRatio;
    return Rect.fromLTWH((box.width - width) / 2, 0, width, box.height);
  }
  final height = box.width / aspectRatio;
  return Rect.fromLTWH(0, (box.height - height) / 2, box.width, height);
}
