import 'package:freezed_annotation/freezed_annotation.dart';

part 'storyboard_spec.freezed.dart';
part 'storyboard_spec.g.dart';

/// `video.storyboard`'s result — one fetchable sprite sheet (`protocol.md` §3.7).
///
/// The sidecar has already picked the level and substituted every placeholder, so [url] is
/// fetched as-is and this side constructs no URLs. **[intervalMs] is what a frame represents,
/// not a display rate** — level 0 puts ~6 s of video behind each one.
@freezed
abstract class StoryboardSpec with _$StoryboardSpec {
  const StoryboardSpec._();

  const factory StoryboardSpec({
    required String url,
    required int columns,
    required int rows,

    /// Frames actually on the sheet, row-major from the top left — never more than
    /// `columns * rows`. Trailing cells of a partly-filled sheet hold no frame.
    required int frameCount,
    required int frameWidth,
    required int frameHeight,
    required int intervalMs,
    @Default(0) int level,
  }) = _StoryboardSpec;

  factory StoryboardSpec.fromJson(Map<String, Object?> json) => _$StoryboardSpecFromJson(json);

  /// The sheet's pixel size, which a decoded image must match — a mismatch puts every frame at
  /// the wrong offset, which renders as a smear rather than an error.
  int get sheetWidth => columns * frameWidth;
  int get sheetHeight => rows * frameHeight;

  /// Whether this describes something fetchable and drawable at all; the arithmetic downstream
  /// divides by these, and an empty [url] would be requested as the page's own path.
  bool get isUsable =>
      url.isNotEmpty && frameCount > 0 && columns > 0 && rows > 0 && frameWidth > 0 && frameHeight > 0;
}
