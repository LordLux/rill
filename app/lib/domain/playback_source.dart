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
    @Default(false) bool qualityDegraded,
    @Default('plain') String transport,
    @Default(<PlaybackVariant>[]) List<PlaybackVariant> variants,
  }) = _PlaybackSource;

  factory PlaybackSource.fromJson(Map<String, Object?> json) => _$PlaybackSourceFromJson(json);

  /// The variant to open. Null only when the sidecar returned an empty ladder,
  /// which the caller treats as an unplayable source rather than a crash.
  PlaybackVariant? get best => variants.isEmpty ? null : variants.first;

  Duration? get duration => durationMs == null ? null : Duration(milliseconds: durationMs!);
}
