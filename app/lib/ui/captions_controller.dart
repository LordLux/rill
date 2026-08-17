import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/playback/engine.dart';
import '../data/rpc/client.dart';
import '../domain/caption_cue.dart';
import '../domain/caption_track.dart';
import '../domain/video_detail.dart';
import 'playback_controller.dart';
import 'video_info.dart';

class CaptionsState {
  const CaptionsState({
    this.enabled = false,
    this.selectedTrack,
    this.cues = const [],
    this.currentCue,
  });

  final bool enabled;
  final CaptionTrack? selectedTrack;
  final List<CaptionCue> cues;
  final CaptionCue? currentCue;

  CaptionsState copyWith({
    bool? enabled,
    CaptionTrack? selectedTrack,
    List<CaptionCue>? cues,
    Object? currentCue = const Object(),
  }) {
    return CaptionsState(
      enabled: enabled ?? this.enabled,
      selectedTrack: selectedTrack ?? this.selectedTrack,
      cues: cues ?? this.cues,
      currentCue: currentCue == const Object() ? this.currentCue : currentCue as CaptionCue?,
    );
  }
}

class CaptionsController extends Notifier<CaptionsState> {
  StreamSubscription<Duration>? _positionSubscription;

  PlaybackEngine get _engine => ref.read(playbackEngineProvider);
  String? get _currentVideoId => ref.read(playbackProvider).item?.id;

  @override
  CaptionsState build() {
    _loadPreferences();

    ref.listen(playbackProvider.select((p) => p.item?.id), (previous, nextId) {
      if (previous == nextId) return;
      if (nextId == null) {
        state = CaptionsState(enabled: state.enabled, selectedTrack: state.selectedTrack);
        return;
      }
      
      if (state.enabled) {
        _ensureTrackSelectedAndFetch(nextId);
      }
    });

    _positionSubscription = _engine.positionStream.listen(_onPositionChanged);
    ref.onDispose(() => _positionSubscription?.cancel());

    return const CaptionsState();
  }

  Future<void> _ensureTrackSelectedAndFetch(String videoId) async {
    try {
      final info = await ref.read(videoInfoProvider(videoId).future);
      if (_currentVideoId != videoId) return;
      if (state.selectedTrack != null) {
        final match = info.captionTracks.where((t) => t.vssId == state.selectedTrack!.vssId).firstOrNull;
        if (match != null) {
          await _fetchCues(videoId, match.vssId);
          return;
        }
      }
      await _autoSelectTrack(videoId, info: info);
    } catch (_) {}
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool('captions_enabled') ?? false;
    if (enabled && !state.enabled) {
      state = state.copyWith(enabled: true);
      final videoId = _currentVideoId;
      if (videoId != null) {
        await _ensureTrackSelectedAndFetch(videoId);
      }
    }
  }

  Future<void> _savePreferences(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('captions_enabled', enabled);
  }

  Future<void> _autoSelectTrack(String videoId, {VideoDetail? info}) async {
    try {
      final detail = info ?? await ref.read(videoInfoProvider(videoId).future);
      if (_currentVideoId != videoId) return;
      if (detail == null || detail.captionTracks.isEmpty) return;
      
      final autoTrack = detail.captionTracks.where((t) => t.kind == 'asr').firstOrNull;
      final track = autoTrack ?? detail.captionTracks.first;
      await setTrack(track);
    } catch (_) {}
  }

  void _onPositionChanged(Duration position) {
    if (!state.enabled || state.cues.isEmpty) return;
    final posMs = position.inMilliseconds;
    final activeCue = state.cues.where((c) => c.startMs <= posMs && c.endMs >= posMs).lastOrNull;
    if (state.currentCue != activeCue) {
      state = state.copyWith(currentCue: activeCue ?? null);
    }
  }

  Future<void> setTrack(CaptionTrack? track) async {
    if (track == null) {
      state = state.copyWith(enabled: false, cues: [], currentCue: null);
      _savePreferences(false);
      return;
    }
    state = state.copyWith(enabled: true, selectedTrack: track);
    _savePreferences(true);
    final videoId = _currentVideoId;
    if (videoId != null) {
      await _fetchCues(videoId, track.vssId);
    }
  }

  void toggle() {
    if (state.enabled) {
      setTrack(null);
    } else {
      final videoId = _currentVideoId;
      if (videoId == null) return;
      
      // Update state to enabled immediately so the UI responds, then fetch
      state = state.copyWith(enabled: true);
      _savePreferences(true);
      _ensureTrackSelectedAndFetch(videoId);
    }
  }

  Future<void> _fetchCues(String videoId, String vssId) async {
    try {
      final response = await RpcClient.instance.call('video.captions', {
        'videoId': videoId,
        'vssId': vssId,
      });
      if (videoId != _currentVideoId || state.selectedTrack?.vssId != vssId) return;
      
      final result = VideoCaptionsResult.fromJson(response as Map<String, dynamic>);
      state = state.copyWith(cues: result.cues);
      _onPositionChanged(_engine.position);
    } catch (e) {
      print('Failed to fetch captions: $e');
    }
  }
}

final captionsProvider = NotifierProvider<CaptionsController, CaptionsState>(CaptionsController.new);
