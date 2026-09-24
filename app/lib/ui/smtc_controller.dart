import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_media_session/flutter_media_session.dart' as fms;

import 'now_playing_art.dart';
import 'playback_controller.dart';
import 'queue_controller.dart';

final smtcControllerProvider = Provider<void>((ref) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return;

  final session = fms.FlutterMediaSession();
  
  // Activate the session on the platform
  session.activate();

  ref.onDispose(() async {
    await session.deactivate();
  });

  final engine = ref.read(playbackEngineProvider);

  session.setActionHandler(
    onPlay: () => engine.play(),
    onPause: () => engine.pause(),
    onSkipToNext: () => ref.read(queueProvider.notifier).advance(),
    onSkipToPrevious: () => ref.read(queueProvider.notifier).back(),
  );

  // Sync state from App to SMTC
  Duration lastPosition = Duration.zero;
  DateTime lastUpdate = DateTime.now();

  void pushState() {
    lastPosition = engine.position;
    lastUpdate = DateTime.now();
    fms.FlutterMediaSessionPlatform.instance.updatePlaybackState(fms.PlaybackState(
      status: engine.playing ? fms.PlaybackStatus.playing : fms.PlaybackStatus.paused,
      position: engine.position,
    ));
  }

  final playingSub = engine.playingStream.listen((_) => pushState());

  final positionSub = engine.positionStream.listen((position) {
    if (!engine.playing) return;
    final now = DateTime.now();
    final elapsed = now.difference(lastUpdate);
    final expected = lastPosition + elapsed;
    // Push update only if position jumps unexpectedly (a seek)
    if ((position - expected).abs() > const Duration(milliseconds: 1000)) {
      pushState();
    }
  });

  // **One place builds the metadata**, called from the three things that can
  // change it: a new track, its duration arriving, and better artwork arriving.
  // The artwork is the same resolver the audio-only layout reads, so the
  // flyout shows the song's cover rather than the tile thumbnail — which is
  // 480x360 off the related rail (`architecture.md` F40).
  //
  // Not `engine.duration` for a new track: it is the previous one's until the
  // new one reports, so a duration is only sent once this track has its own.
  Duration? knownDuration;
  void pushMetadata() {
    final item = ref.read(playbackProvider).item;
    fms.FlutterMediaSessionPlatform.instance.updateMetadata(
      item == null
          ? const fms.MediaMetadata()
          : fms.MediaMetadata(
              title: item.title,
              artist: item.channelName,
              artworkUri: ref.read(nowPlayingArtProvider),
              duration: knownDuration,
            ),
    );
  }

  final durationSub = engine.durationStream.listen((duration) {
    if (duration <= Duration.zero) return;
    knownDuration = duration;
    pushMetadata();
  });

  ref.listen(playbackProvider.select((p) => p.item?.id), (previous, next) {
    if (previous == next) return;
    knownDuration = null;
    pushMetadata();
  });

  ref.listen(nowPlayingArtProvider, (previous, next) {
    if (previous != next) pushMetadata();
  });

  ref.onDispose(() {
    playingSub.cancel();
    positionSub.cancel();
    durationSub.cancel();
    session.clearActionHandler();
  });
});
