import 'package:freezed_annotation/freezed_annotation.dart';

part 'playback_source.freezed.dart';
part 'playback_source.g.dart';

/// One playable video+audio pair — `protocol.md` §3.5.
///
/// `audioUrl` is null for a muxed stream (the progressive floor), in which case
/// mpv gets one URL and no `--audio-file`.
@freezed
abstract class PlaybackVariant with _$PlaybackVariant {
  const factory PlaybackVariant({
    required String videoUrl,
    String? audioUrl,
    int? itag,
    required int height,
    required int fps,
    required String videoCodec,
    required String audioCodec,
  }) = _PlaybackVariant;

  factory PlaybackVariant.fromJson(Map<String, Object?> json) => _$PlaybackVariantFromJson(json);
}

/// One audio track a video can play with — `protocol.md` §3.5, Task 39 (the sidecar's
/// `AudioTrack`; not named so here because media_kit exports an `AudioTrack` of its own).
///
/// The markers are read from YouTube's `xtags`, never from [displayName], and [displayName] has
/// YouTube's own "original" wording removed: the menu draws an *Original* badge from [isOriginal]
/// and an *AI dub* badge from [isAutoDubbed].
@freezed
abstract class AudioTrackOption with _$AudioTrackOption {
  const factory AudioTrackOption({
    required String id,
    required String displayName,
    @Default(false) bool isOriginal,
    @Default(false) bool isDubbed,
    @Default(false) bool isAutoDubbed,
  }) = _AudioTrackOption;

  factory AudioTrackOption.fromJson(Map<String, Object?> json) => _$AudioTrackOptionFromJson(json);
}

/// `playback.open`'s result — identical in Phase 1 and Phase 2 (§3.5).
///
/// **Quality selection is the client's.** `variants` arrives ranked best-first
/// and every entry is playable from the same `/player` response, so stepping
/// down costs no round trip. This task always takes `variants.first`; the
/// stepper that F16 argues for (2160p60 dropped 16–29% of frames on an Intel
/// iGPU where 1080p60 dropped none) is its own task, and the contract is already
/// shaped for it.
///
/// `transport` is telemetry — Flutter must not be able to tell which ladder rung
/// served it. `qualityDegraded` drives a badge, never a dead end.
@freezed
abstract class PlaybackSource with _$PlaybackSource {
  const PlaybackSource._();

  const factory PlaybackSource({
    required String sessionId,
    int? durationMs,
    String? startTimestamp,
    String? storyboardTemplate,

    /// The widest still YouTube lists for this video — `protocol.md` §3.5.
    ///
    /// For surfaces that draw artwork instead of a picture. **Not something
    /// the client could have built from the tile's `thumbnailUrl`**: 1280x720
    /// is YouTube's ceiling and the watch page's related rail ships 480x360
    /// (`architecture.md` F40). Null is ordinary — fall back to the tile's.
    String? posterUrl,
    @Default(false) bool qualityDegraded,
    @Default('plain') String transport,

    /// The video's audio tracks, original first (Task 39). Empty when there is nothing to
    /// choose from, and then the menu offers no *Audio track* entry.
    @Default(<AudioTrackOption>[]) List<AudioTrackOption> audioTracks,

    /// The track every variant's `audioUrl` carries. Null exactly when [audioTracks] is empty.
    String? audioTrackId,
    @Default(<PlaybackVariant>[]) List<PlaybackVariant> variants,
  }) = _PlaybackSource;

  factory PlaybackSource.fromJson(Map<String, Object?> json) => _$PlaybackSourceFromJson(json);

  /// The variant to open. Null only when the sidecar returned an empty ladder,
  /// which the caller treats as an unplayable source rather than a crash.
  PlaybackVariant? get best => variants.isEmpty ? null : variants.first;

  Duration? get duration => durationMs == null ? null : Duration(milliseconds: durationMs!);
}
