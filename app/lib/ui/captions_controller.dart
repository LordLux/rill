import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

import '../data/rpc/client.dart';
import '../domain/caption_style.dart';
import '../domain/caption_track.dart';
import '../domain/libass_flag.dart';
import 'player/caption_geometry.dart';
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
    this.style = CaptionStyle.none,
    this.offset = CaptionOffset.zero,
    this.layout,
    this.metrics,
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

  /// The caption style menu's current state.
  ///
  /// **A session preference, like [CaptionsController.preferredLanguage]** —
  /// someone who turned the background off wants it off on the next video too.
  /// It survives a video change and a track change; only *Reset* clears it.
  final CaptionStyle style;

  /// Where the user dragged the caption, as a fraction of the frame.
  ///
  /// **Not a preference.** It resets when the track changes and when the video
  /// changes, because a position chosen to dodge one video's burned-in subtitle
  /// means nothing on the next. It does survive turning captions off and on,
  /// which is the one continuity a user notices.
  final CaptionOffset offset;

  /// The geometry the current document was generated with, or null before one.
  final CaptionLayout? layout;

  /// The width table measured against [layout], for the hit rect and the clamp.
  ///
  /// Measured once per layout rather than per frame — it is 74 `TextPainter`
  /// layouts — and re-measured whenever the font or size changes, because that
  /// is what makes it wrong.
  final CaptionMetrics? metrics;

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
    CaptionStyle? style,
    CaptionOffset? offset,
    Object? layout = _unchanged,
    Object? metrics = _unchanged,
  }) {
    return CaptionsState(
      tracks: tracks ?? this.tracks,
      selectedId: identical(selectedId, _unchanged) ? this.selectedId : selectedId as String?,
      isLoadingTracks: isLoadingTracks ?? this.isLoadingTracks,
      isLoadingTrack: isLoadingTrack ?? this.isLoadingTrack,
      error: identical(error, _unchanged) ? this.error : error as String?,
      style: style ?? this.style,
      offset: offset ?? this.offset,
      layout: identical(layout, _unchanged) ? this.layout : layout as CaptionLayout?,
      metrics: identical(metrics, _unchanged) ? this.metrics : metrics as CaptionMetrics?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CaptionsState &&
      other.selectedId == selectedId &&
      other.isLoadingTracks == isLoadingTracks &&
      other.isLoadingTrack == isLoadingTrack &&
      other.error == error &&
      other.style == style &&
      other.offset == offset &&
      other.layout == layout &&
      identical(other.metrics, metrics) &&
      _sameTracks(other.tracks, tracks);

  @override
  int get hashCode => Object.hash(
      selectedId, isLoadingTracks, isLoadingTrack, error, tracks.length, style, offset, layout);

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

  /// The style menu's state, held on the controller rather than read off
  /// [state] — for the same reason [preferredLanguage] is.
  ///
  /// It is a *session preference* and outlives every `CaptionsState` the
  /// controller builds, and `_load` runs from `build()`, before there is a state
  /// to read. Riverpod throws on that ("tried to read the state of an
  /// uninitialized provider") rather than returning a default, so a preference
  /// that lives only in state is a preference the first load cannot see.
  /// [CaptionsState.style] mirrors this for the UI.
  @visibleForTesting
  CaptionStyle preferredStyle = CaptionStyle.none;

  int _generation = 0;
  bool _disposed = false;
  int? _loadReqId;
  int? _loadStyledReqId;
  int? _selectReqId;
  Timer? _styleDebounce;

  /// Trailing debounce for slider input. Long enough to collapse a drag into a
  /// handful of commits, short enough that letting go feels immediate.
  static const Duration _styleDebounceDelay = Duration(milliseconds: 120);

  void _cancel(int? id) {
    if (id != null) RpcClient.instance.cancel(id);
  }

  @override
  CaptionsState build() {
    ref.listen(libassEnabledProvider, (_, __) {
      if (state.selectedId != null) unawaited(_reapply());
    });

    ref.onDispose(() {
      _disposed = true;
      _styleDebounce?.cancel();
    });

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
    _cancel(_loadReqId);
    _cancel(_loadStyledReqId);
    _cancel(_selectReqId);
    _loadReqId = null;
    _loadStyledReqId = null;
    _selectReqId = null;

    // Detach immediately. The previous video's captions are still attached to a
    // player that is about to hold a different video, and leaving them up until
    // the new list arrives shows the wrong words over the right picture.
    unawaited(ref.read(playbackEngineProvider).setSubtitle(null));

    // The style is a session preference and survives; the offset and the
    // measured geometry belong to the document that is going away.
    if (videoId == null) {
      state = CaptionsState(style: preferredStyle);
      return;
    }

    state = CaptionsState(style: preferredStyle, isLoadingTracks: true);

    List<CaptionTrack> tracks;
    try {
      final req = RpcClient.instance.callCancelable('captions.list', {'videoId': videoId});
      _loadReqId = req.id;
      final result = await req.response;
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

    _cancel(_loadStyledReqId);
    final req = RpcClient.instance.callCancelable('captions.list', {
      'videoId': videoId,
      'includeStyled': true,
    });
    _loadStyledReqId = req.id;

    try {
      final result = await req.response;
      if (ref.read(playbackProvider).item?.id != videoId) return;
      final tracks = [
        for (final entry in (result as Map)['tracks'] as List<dynamic>)
          CaptionTrack.fromJson((entry as Map).cast<String, Object?>()),
      ];
      if (ref.read(playbackProvider).item?.id != videoId) return;
      state = state.copyWith(tracks: tracks);
    } on Object catch (e) {
      if (e is RpcException && e.retry == RpcRetryMode.auto) {
        if (ref.read(playbackProvider).item?.id != videoId) return;
        Timer(const Duration(seconds: 2), () {
          if (ref.read(playbackProvider).item?.id == videoId) unawaited(loadStyled());
        });
      }
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
    _cancel(_selectReqId);
    
    final engine = ref.read(playbackEngineProvider);

    if (trackId == null) {
      preferOn = false;
      // The offset survives an Off/On round trip — that is the one continuity a
      // user notices, and §2 of the task brief asks for it explicitly. It is the
      // *track* changing that resets it, below.
      state = state.copyWith(selectedId: null, isLoadingTrack: false, error: null);
      await engine.setSubtitle(null);
      return;
    }

    final videoId = ref.read(playbackProvider).item?.id;
    if (videoId == null) return;

    // A different track is a different caption, and a position chosen for one
    // has no meaning on the other — a manual track and an auto-generated one do
    // not even put their lines in the same place.
    final changingTrack = state.selectedId != null && state.selectedId != trackId;
    state = state.copyWith(
      selectedId: trackId,
      isLoadingTrack: true,
      error: null,
      offset: changingTrack ? CaptionOffset.zero : null,
    );

    await _fetch(videoId, trackId, generation);
  }

  /// `captions.get` with the current style, offset and width table, then attach.
  ///
  /// **Every one of those is applied by the sidecar, during generation.** The
  /// mpv properties that look like they would do it act on the ASS `Style`, and
  /// `sub-ass-override=force` overrides the `Style` too — not the inline tags a
  /// styled track is made of. See `captions/style.ts` for the measurement.
  ///
  /// It costs a re-render and a `sub-add` per change: measured 2026-08-20 at
  /// 1.0–1.3 ms of render on ordinary documents and `sub-add`'s 12–36 ms, so
  /// ~15–40 ms end to end. `sub-add` does **not** rebuild the video texture, so
  /// the picture never blinks. Slider input is debounced in [setStyle].
  Future<void> _fetch(String videoId, String trackId, int generation) async {
    final engine = ref.read(playbackEngineProvider);
    try {
      final req = RpcClient.instance.callCancelable('captions.get', {
        'videoId': videoId,
        'trackId': trackId,
        if (!preferredStyle.isDefault) 'style': preferredStyle.toJson(),
        if (!state.offset.isZero) 'offset': state.offset.toJson(),
        // Only alongside an offset, because that is the only thing it changes:
        // the clamp. Sending it otherwise would mint a cache entry per client
        // for a table that made no difference to the document.
        if (!state.offset.isZero && state.metrics != null) 'metrics': state.metrics!.toJson(),
        if (ref.read(libassEnabledProvider)) 'renderer': 'libass_layer',
      });
      _selectReqId = req.id;
      final result = await req.response;
      final content = CaptionTrackContent.fromJson((result as Map).cast<String, Object?>());
      if (_stale(generation)) return;

      await engine.setSubtitle(content.content);
      if (_stale(generation)) return;

      preferOn = true;
      preferredLanguage = content.languageCode;
      
      // Update track in list if we learned its styled/positional status
      List<CaptionTrack>? newTracks;
      if (content.styled != null || content.positional != null) {
        final i = state.tracks.indexWhere((t) => t.id == trackId);
        if (i >= 0 && (state.tracks[i].styled != content.styled || state.tracks[i].positional != content.positional)) {
          newTracks = List.of(state.tracks);
          newTracks[i] = newTracks[i].copyWith(
            styled: content.styled,
            positional: content.positional,
          );
        }
      }

      state = state.copyWith(
        tracks: newTracks,
        isLoadingTrack: false,
        layout: content.layout,
        metrics: _metricsFor(content.layout),
      );
    } on Object catch (e) {
      if (_stale(generation)) return;
      // Back to Off rather than leaving a track ticked that is not showing. A
      // control claiming captions are on over a video with none is the failure
      // that gets reported as "captions are broken" with nothing to go on.
      state = state.copyWith(selectedId: null, isLoadingTrack: false, error: e.toString());
    }
  }

  /// The width table for a layout, re-measured only when the layout moves.
  ///
  /// 74 `TextPainter` layouts, so it is cheap but not free, and the font and size
  /// are the only things that change it. Returning the existing table when they
  /// have not is what keeps a slider drag from re-measuring on every commit.
  CaptionMetrics? _metricsFor(CaptionLayout? layout) {
    if (layout == null) return null;
    final held = state.layout;
    if (held != null &&
        state.metrics != null &&
        held.fontFamily == layout.fontFamily &&
        held.fontSize == layout.fontSize) {
      return state.metrics;
    }
    return measureAdvances(layout);
  }

  /// Apply a style from the menu, regenerating the document.
  ///
  /// **Debounced, trailing.** A colour or opacity slider fires per frame, and
  /// each change is a round trip and a `sub-add`; without this a drag of the
  /// opacity slider would queue sixty of them. Discrete controls — font family,
  /// edge style — pass `immediate` and commit at once, because a debounce there
  /// is only a delay.
  Future<void> setStyle(CaptionStyle style, {bool immediate = false}) async {
    if (style == preferredStyle) return;
    preferredStyle = style;
    state = state.copyWith(style: style);
    _styleDebounce?.cancel();
    if (immediate) return _reapply();
    final completer = Completer<void>();
    _styleDebounce = Timer(_styleDebounceDelay, () {
      unawaited(_reapply().whenComplete(completer.complete));
    });
    return completer.future;
  }

  /// Commit a drag. Not debounced — it fires once, on release.
  Future<void> setOffset(CaptionOffset offset) async {
    if (offset == state.offset) return;
    state = state.copyWith(offset: offset);
    return _reapply();
  }

  /// The menu's *Reset*: everything it owns, including the drag.
  Future<void> resetStyle() async {
    if (preferredStyle.isDefault && state.offset.isZero) return;
    _styleDebounce?.cancel();
    preferredStyle = CaptionStyle.none;
    state = state.copyWith(style: CaptionStyle.none, offset: CaptionOffset.zero);
    return _reapply();
  }

  /// Re-render the selected track and re-attach it. A no-op when captions are off
  /// — the style is still remembered and applies when they come back on.
  Future<void> _reapply() async {
    final trackId = state.selectedId;
    final videoId = ref.read(playbackProvider).item?.id;
    if (trackId == null || videoId == null) return;
    final generation = ++_generation;
    _cancel(_selectReqId);
    await _fetch(videoId, trackId, generation);
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
