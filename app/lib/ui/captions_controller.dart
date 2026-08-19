import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../data/rpc/client.dart';
import '../domain/caption_track.dart';
import 'playback_controller.dart';

/// `copyWith` sentinel — hard invariant 10.
///
/// Every nullable field here is one the controller has to be able to *clear*:
/// `selectedId` on Off, `error` on a successful retry, and both of them on a new
/// video. `value ?? this.value` would make each of those a silent no-op — the
/// exact failure `FeedState.copyWith` shipped.
const Object _unchanged = Object();

@immutable
class CaptionsState {
  const CaptionsState({
    this.tracks = const [],
    this.selectedId,
    this.isLoadingTracks = false,
    this.isLoadingTrack = false,
    this.error,
  });

  /// Every track for the current video, **after** the sidecar's `ANDROID_VR` →
  /// `MWEB` fallback (`protocol.md` §3.8).
  ///
  /// Empty is a settled answer once [isLoadingTracks] is false: the fallback has
  /// run, and the CC control is hidden rather than disabled. A disabled control
  /// would say "later" about something that is never coming for this video.
  final List<CaptionTrack> tracks;

  /// The track being displayed, or null for Off.
  final String? selectedId;

  final bool isLoadingTracks;

  /// A `captions.get` in flight. Distinct from [isLoadingTracks] because it must
  /// not hide the control that was just used to start it.
  final bool isLoadingTrack;

  /// A caption failure never touches playback — it is reported here and shown on
  /// the caption page, not over the video.
  final String? error;

  bool get hasTracks => tracks.isNotEmpty;
  bool get isOn => selectedId != null;

  CaptionTrack? get selected {
    for (final track in tracks) {
      if (track.id == selectedId) return track;
    }
    return null;
  }

  CaptionsState copyWith({
    List<CaptionTrack>? tracks,
    Object? selectedId = _unchanged,
    bool? isLoadingTracks,
    bool? isLoadingTrack,
    Object? error = _unchanged,
  }) {
    return CaptionsState(
      tracks: tracks ?? this.tracks,
      selectedId: identical(selectedId, _unchanged) ? this.selectedId : selectedId as String?,
      isLoadingTracks: isLoadingTracks ?? this.isLoadingTracks,
      isLoadingTrack: isLoadingTrack ?? this.isLoadingTrack,
      error: identical(error, _unchanged) ? this.error : error as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CaptionsState &&
      other.selectedId == selectedId &&
      other.isLoadingTracks == isLoadingTracks &&
      other.isLoadingTrack == isLoadingTrack &&
      other.error == error &&
      _sameTracks(other.tracks, tracks);

  @override
  int get hashCode =>
      Object.hash(selectedId, isLoadingTracks, isLoadingTrack, error, tracks.length);

  static bool _sameTracks(List<CaptionTrack> a, List<CaptionTrack> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Caption tracks for whatever the player has open, and which one is showing.
///
/// **It listens to `playbackProvider` rather than being called by the watch
/// page**, for the same reason `PlaybackController` listens to the queue: the
/// video changes from a tile tap, from queue autoplay, from the mini player and
/// from a related-video click, and a controller that has to be told would be
/// wrong on whichever path someone forgot.
///
/// `captions.list` is issued **alongside** `video.info`, never behind it. §3.8
/// explains why it is not a field on `VideoDetail`: the fallback it may run is a
/// second `/player` call, and putting it on the open path would break §3.3's
/// one-call property for the ~29% of videos with no captions. Nothing about
/// playback waits for this.
class CaptionsController extends Notifier<CaptionsState> {
  /// The language the user last chose, for the rest of the session.
  ///
  /// **Language, not track id.** A `vssId` is per video (`.en`, `a.en`), so
  /// carrying one to the next video would match nothing about half the time —
  /// and would match the *wrong* thing when a video happens to reuse the id with
  /// a different provenance. Someone who turned on German wants German on the
  /// next video, whether YouTube transcribed it or a human wrote it.
  @visibleForTesting
  String? preferredLanguage;

  /// Whether captions were on. Kept apart from [preferredLanguage] so turning
  /// them off does not forget which language to restore.
  @visibleForTesting
  bool preferOn = false;

  int _generation = 0;
  bool _disposed = false;

  @override
  CaptionsState build() {
    ref.onDispose(() => _disposed = true);

    ref.listen(playbackProvider.select((playback) => playback.item?.id), (previous, next) {
      if (previous == next) return;
      unawaited(_load(next));
    });

    final current = ref.read(playbackProvider).item?.id;
    if (current != null) unawaited(_load(current));
    return const CaptionsState();
  }

  /// Fetch the track list for a video and apply the session preference.
  Future<void> _load(String? videoId) async {
    // Claimed before the await, and checked after every one: opening two videos
    // quickly must not let the first one's track list arrive over the second's.
    // The generation counter is the same mechanism `PlaybackController` and the
    // feed use, for the same reason.
    final generation = ++_generation;

    // Detach immediately. The previous video's captions are still attached to a
    // player that is about to hold a different video, and leaving them up until
    // the new list arrives shows the wrong words over the right picture.
    unawaited(ref.read(playbackEngineProvider).setSubtitle(null));

    if (videoId == null) {
      state = const CaptionsState();
      return;
    }

    state = const CaptionsState(isLoadingTracks: true);

    List<CaptionTrack> tracks;
    try {
      final result = await RpcClient.instance.call('captions.list', {'videoId': videoId});
      tracks = [
        for (final entry in (result as Map)['tracks'] as List<dynamic>)
          CaptionTrack.fromJson((entry as Map).cast<String, Object?>()),
      ];
    } on Object catch (e) {
      if (_stale(generation)) return;
      // No tracks and an error is the same thing to the control — it hides —
      // but the message is kept so a caption failure is not indistinguishable
      // from a video that has none.
      state = state.copyWith(isLoadingTracks: false, error: e.toString());
      return;
    }
    if (_stale(generation)) return;

    state = state.copyWith(tracks: tracks, isLoadingTracks: false, error: null);

    final resume = _preferredTrack(tracks);
    if (resume != null) await select(resume.id);
  }

  /// Fill in `styled` for the current video's tracks, for the menu's badge.
  ///
  /// **Not part of [_load], and that is the whole point.** The flag needs the
  /// caption *document*, one fetch per track — measured at 69 KB and 73 ms for
  /// six real tracks, which parallelise, so it is one round trip's latency. That
  /// is a menu's budget. Putting it on the open path would spend it on every
  /// video for a badge most of them never show, and §3.8 keeps `captions.list`
  /// off that path deliberately.
  ///
  /// Idempotent and cheap to call again: the sidecar caches the answer per track,
  /// and this returns immediately once every track has one.
  Future<void> loadStyled() async {
    final videoId = ref.read(playbackProvider).item?.id;
    if (videoId == null || state.tracks.isEmpty) return;
    if (state.tracks.every((track) => track.styled != null)) return;

    final generation = _generation;
    try {
      final result = await RpcClient.instance.call('captions.list', {
        'videoId': videoId,
        'includeStyled': true,
      });
      final tracks = [
        for (final entry in (result as Map)['tracks'] as List<dynamic>)
          CaptionTrack.fromJson((entry as Map).cast<String, Object?>()),
      ];
      if (_stale(generation)) return;
      state = state.copyWith(tracks: tracks);
    } on Object {
      // A badge is not worth an error state. The rows stay unbadged.
    }
  }

  /// The track to turn on automatically, or null to stay off.
  ///
  /// Only ever the language the user already chose this session. Never a
  /// default: captions nobody asked for are a worse failure than captions nobody
  /// gets, and YouTube's own behaviour is off unless you say otherwise.
  CaptionTrack? _preferredTrack(List<CaptionTrack> tracks) {
    if (!preferOn || preferredLanguage == null) return null;
    final wanted = preferredLanguage!;
    // Exact language first, then the base tag — a user on "en" should get
    // "en-GB" rather than nothing, and one on "pt-BR" should accept "pt".
    for (final track in tracks) {
      if (track.languageCode == wanted) return track;
    }
    final base = wanted.split('-').first;
    for (final track in tracks) {
      if (track.languageCode.split('-').first == base) return track;
    }
    return null;
  }

  /// Show a track, or turn captions off with null.
  Future<void> select(String? trackId) async {
    final generation = ++_generation;
    final engine = ref.read(playbackEngineProvider);

    if (trackId == null) {
      preferOn = false;
      state = state.copyWith(selectedId: null, isLoadingTrack: false, error: null);
      await engine.setSubtitle(null);
      return;
    }

    final videoId = ref.read(playbackProvider).item?.id;
    if (videoId == null) return;

    state = state.copyWith(selectedId: trackId, isLoadingTrack: true, error: null);

    try {
      final result = await RpcClient.instance.call('captions.get', {'videoId': videoId, 'trackId': trackId});
      final content = CaptionTrackContent.fromJson((result as Map).cast<String, Object?>());
      if (_stale(generation)) return;

      await engine.setSubtitle(content.content);
      if (_stale(generation)) return;

      preferOn = true;
      preferredLanguage = content.languageCode;
      state = state.copyWith(isLoadingTrack: false);
    } on Object catch (e) {
      if (_stale(generation)) return;
      // Back to Off rather than leaving a track ticked that is not showing. A
      // control claiming captions are on over a video with none is the failure
      // that gets reported as "captions are broken" with nothing to go on.
      state = state.copyWith(selectedId: null, isLoadingTrack: false, error: e.toString());
    }
  }

  /// The **C** key and the CC button: on to the best available track, or off.
  ///
  /// "Best available" is the session's language if the video has it, and
  /// otherwise the first track — which is YouTube's own ordering, with the
  /// video's original language first.
  Future<void> toggle() async {
    if (state.tracks.isEmpty) return;
    if (state.isOn) {
      await select(null);
      return;
    }
    // `preferOn` is false here by definition, so ask for the preferred language
    // directly rather than through `_preferredTrack`, which is about resuming.
    final wanted = preferredLanguage;
    CaptionTrack? pick;
    if (wanted != null) {
      for (final track in state.tracks) {
        if (track.languageCode.split('-').first == wanted.split('-').first) {
          pick = track;
          break;
        }
      }
    }
    await select((pick ?? state.tracks.first).id);
  }

  bool _stale(int generation) => _disposed || generation != _generation;
}

final captionsProvider =
    NotifierProvider<CaptionsController, CaptionsState>(CaptionsController.new);
