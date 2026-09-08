/// Where the picture is inside the player surface.
///
/// **This file used to be the caption *estimate*** — a per-character advance
/// table, a predicted caption rectangle, and a clamp built on both, because
/// libass composited into the video texture and published no geometry, so the
/// hit target, the hover cursor and the drag ghost all had to be guessed from
/// mpv's `sub-text`. `LibassLayer` renders the document itself and reads the
/// real boxes back out of `ass_render_frame`, so there is nothing left to guess
/// and the estimate went with the pipeline that needed it (`architecture.md`
/// §2.9).
///
/// What survives is the one piece of geometry that was never an estimate:
/// media_kit letterboxes the texture, so the widget's bounds are not the
/// picture's bounds, and both the drag layer and `LibassLayer` have always had
/// to work that out for themselves. It stays here because nothing else computes
/// it.
library;

import 'dart:ui';

/// The video's rectangle inside a `BoxFit.contain` surface of [box].
///
/// A caption placed against the widget rather than the picture drifts on any
/// aspect ratio but the window's.
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
