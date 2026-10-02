/// Layout dimensions shared across the app — the numbers that would otherwise
/// get retyped (and drift) at every call site that needs the same answer to
/// "how wide should this get."
class ScreenValues {
  const ScreenValues._();

  /// The maximum width of the content area for the main column of the watch page
  static const double contentMaxWidth = 1096.0;
  static const double normalAspectRatio = 16 / 9;

  /// A Short's actual video aspect ratio. Not what a Short's *thumbnail box*
  /// is shaped like — see [shortAspectRatioSecondary] for that, and use it
  /// for any layout math sizing a Short's tile. Kept for reference (a real
  /// vertical thumbnail source would need this), currently unused.
  static const double shortAspectRatio = 9 / 16;

  /// The shape of a Short's thumbnail *box*, measured off youtube.com's own
  /// Shorts shelf — 2:3, not the raw 9:16 the video itself is. Use it for
  /// sizing a Short's tile and for the `AspectRatio` its thumbnail sits in.
  ///
  /// **On its own this is not enough to crop out the pillarbox fill** — see
  /// [shortThumbnailZoom], which is the other half of the fix and must be
  /// applied together with this everywhere a Short's thumbnail is drawn.
  static const double shortAspectRatioSecondary = 2 / 3;

  /// The extra zoom a Short's thumbnail *image* needs on top of
  /// [shortAspectRatioSecondary], to crop out YouTube's pillarbox fill
  /// instead of merely shrinking it.
  ///
  /// YouTube's thumbnail for a Short is a 16:9 canvas with the real vertical
  /// video composited into a fixed-size centred window, coloured/blurred
  /// fill either side — and that window's position is a **constant fraction
  /// of the canvas, not content-dependent**: measured pixel-exact identical
  /// (247–472 of 720, full height) across three unrelated Shorts thumbnails
  /// on 2026-08-28. `BoxFit.cover` into a plain `shortAspectRatioSecondary`
  /// box does crop *some* of the fill (a landscape image into a portrait box
  /// always crops width), but nowhere near enough — the maths: `cover`'s
  /// visible width, as a fraction of canvas width, is
  /// `shortAspectRatioSecondary / canvasAspectRatio` ≈ 0.374 of the canvas,
  /// against the real window's measured 0.3125 — a visibly wide fill band
  /// left standing on each side, which is exactly the bug this constant
  /// fixes. Applying this as an additional uniform zoom (`Transform.scale`,
  /// centred) after `cover` shrinks the visible window down to exactly the
  /// measured content fraction; because the zoom is uniform, the same factor
  /// that removes the horizontal fill also crops the vertical extent down to
  /// the matching 2:3 shape — one number does both, verified against the
  /// measured pixel bounds rather than derived from the ratio alone.
  ///
  /// `= shortAspectRatioSecondary / (canvasAspectRatio × contentWidthFraction)`,
  /// with `canvasAspectRatio` = 720 / 404 and `contentWidthFraction` =
  /// 225 / 720, both the measured values above.
  static const double shortThumbnailZoom = 1.197;

  /// The height of the custom titlebar that replaces the default Windows
  /// chrome. Kept in [ScreenValues] so the caption-clip in `player_shell.dart`
  /// and any future overlay can read it without importing `topbar.dart`.
  static const double titlebarsHeight = 50.0;
  
  /// The height of the window buttons in the custom titlebar
  static const double titlebarWindowButtonsHeight = 38.0;
  /// The width of the window buttons in the custom titlebar
  static const double titlebarWindowButtonsWidth = 45.5;
  
  /// The width of the left rail when it is closed
  static const double closedRailWidth = 72.0;
  /// The width of the left rail when it is open
  static const double openRailWidth = 240.0;
  
  /// The height of a button in the left rail
  static const double railButtonHeight = 48.0;
  /// The width of a button in the left rail when the rail is closed
  static const double railButtonWidth = 64.0;
  
  /// The border radius of a button in the left rail when it is selected
  static const double railItemBorderRadiusSelected = 6.0;
  /// The border radius of a button in the left rail when it is not selected
  static const double railItemBorderRadius = 6.0;
}
