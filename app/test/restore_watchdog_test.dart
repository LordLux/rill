/// Leaving audio-only can, rarely, wedge: the player says it is playing, nothing
/// is loading, and the position never moves — no picture, no sound, and
/// play/pause does nothing. Going back to audio-only and out again fixes it at
/// once, so that is what the watchdog does first. `docs/todo.md` 44.
///
/// These drive the fake engine through the symptom, never the cause: the cause
/// has not been caught live, so nothing here claims to reproduce it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/audio_mode_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

late FakeEngine engine;
late ProviderContainer container;

Future<void> boot() async {
  RpcClient.instance.killForTest();
  await Future<void>.delayed(const Duration(milliseconds: 150));
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  await RpcClient.instance.start();

  engine = FakeEngine();
  container = ProviderContainer(
    overrides: [playbackEngineProvider.overrideWithValue(engine)],
  );
  container.read(playbackProvider);
}

Future<void> settle([int millis = 250]) => Future<void>.delayed(Duration(milliseconds: millis));

/// Playing, past the start watchdog, then into audio-only and back out — the
/// restore under test has just begun when this returns.
Future<void> leaveAudioOnly() async {
  container.read(queueProvider.notifier).play(video('aaa'));
  await settle();
  engine.emitPosition(const Duration(seconds: 1));
  // The open sets the track too (what the mode was at open); only what
  // happens from here is under test.
  engine.videoTrackCalls.clear();
  await container.read(audioModeProvider.notifier).setMode(true);
  await settle(50);
  await container.read(audioModeProvider.notifier).setMode(false);
  await settle(20);
  expect(engine.videoTrackCalls, [false, true], reason: 'into audio-only and out');
}

/// Playback that is actually happening: the position moving about a tick at a
/// time, the way the real engine's does.
Timer advance() {
  var position = engine.position;
  return Timer.periodic(const Duration(milliseconds: 10), (_) {
    position += const Duration(milliseconds: 10);
    engine.emitPosition(position);
  });
}

void main() {
  setUp(() async {
    PlaybackController.restoreStallTick = const Duration(milliseconds: 10);
    // First recovery ~160 ms after the restore, the second ~320 ms: every check
    // below sits well clear of both.
    PlaybackController.restoreStallGrace = const Duration(milliseconds: 150);
    await boot();
  });

  tearDown(() async {
    container.dispose();
    RpcClient.instance.killForTest();
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });

  test('a restore stuck while playing toggles the video track off and on', () async {
    await leaveAudioOnly();

    // The symptom: says playing, no picture, and the position never moves.
    await settle(240);

    expect(engine.videoTrackCalls, [false, true, false, true]);
    expect(engine.opened.length, 1, reason: 'the toggle comes first — no reopen yet');
  });

  test('a restore that plays is left alone', () async {
    await leaveAudioOnly();
    engine.setVideoOutputReady(true);
    final ticking = advance();
    await settle(400);
    ticking.cancel();

    expect(engine.videoTrackCalls, [false, true]);
  });

  test('a slow restore is not stuck: the picture arriving late is fine', () async {
    await leaveAudioOnly();
    // Frozen for less than the grace — the refetch §2.4 measured — then fine.
    await settle(90);
    engine.setVideoOutputReady(true);
    final ticking = advance();
    await settle(400);
    ticking.cancel();

    expect(engine.videoTrackCalls, [false, true]);
  });

  test('a paused player is never stuck', () async {
    await leaveAudioOnly();
    engine.setPlaying(false);
    await settle(400);

    expect(engine.videoTrackCalls, [false, true]);
  });

  test('stuck again after the toggle reopens the stream, once', () async {
    await leaveAudioOnly();

    // Neither the toggle nor anything after it ever moves the position.
    await settle(700);

    expect(engine.videoTrackCalls.take(4), [false, true, false, true]);
    expect(engine.opened.length, 2, reason: 'one reopen through the quality-switch path');

    await settle(500);
    expect(engine.opened.length, 2, reason: 'and then it stops — no loop');
  });

  test('going back to audio-only cancels the watch', () async {
    await leaveAudioOnly();
    await container.read(audioModeProvider.notifier).setMode(true);
    await settle(400);

    expect(engine.videoTrackCalls, [false, true, false]);
  });
}
