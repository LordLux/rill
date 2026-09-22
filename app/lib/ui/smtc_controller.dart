import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_media_session/flutter_media_session.dart' as fms;

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

  final durationSub = engine.durationStream.listen((duration) {
    final item = ref.read(playbackProvider).item;
    if (item != null) {
      fms.FlutterMediaSessionPlatform.instance.updateMetadata(
        fms.MediaMetadata(
          title: item.title,
          artist: item.channelName,
          artworkUri: item.thumbnailUrl.isNotEmpty ? item.thumbnailUrl : null,
          duration: duration,
        ),
      );
    }
  });

  ref.listen(playbackProvider, (previous, next) {
    final item = next.item;
    if (item == null) {
      fms.FlutterMediaSessionPlatform.instance.updateMetadata(const fms.MediaMetadata());
    } else {
      // Do not use engine.duration here as it is stale when a new video starts.
      // The durationSub will handle appending the duration once it resolves.
      fms.FlutterMediaSessionPlatform.instance.updateMetadata(
        fms.MediaMetadata(
          title: item.title,
          artist: item.channelName,
          artworkUri: item.thumbnailUrl.isNotEmpty ? item.thumbnailUrl : null,
        ),
      );
    }
  });

  ref.onDispose(() {
    playingSub.cancel();
    positionSub.cancel();
    durationSub.cancel();
    session.clearActionHandler();
  });
});
