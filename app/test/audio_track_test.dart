/// Choosing an audio track (Task 39, `protocol.md` §3.5), against a real fake-sidecar process and
/// a [FakeEngine].
///
/// A pick is `playback.open {preload: true, audioTrackId}`, so the watch keeps its one session;
/// the engine's second player carries it ([PlaybackEngine.switchAudio]) and a reopen at the
/// position is the fallback. The choice then sticks for the video: a quality switch, the
/// audio-only toggle and a recovery reopen all stay on it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/playback/engine.dart';
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

PlaybackState get playback => container.read(playbackProvider);
PlaybackController get controller => container.read(playbackProvider.notifier);

Future<void> settle([int millis = 250]) => Future<void>.delayed(Duration(milliseconds: millis));

/// [action], with the clock moving on once it has reopened, as a playing video's does: the reopen
/// waits for the clock to pass where it seeked (`_waitForPicture`), and the fake clock stands still.
Future<void> withClock(Future<void> action, Duration from) async {
  await settle();
  engine.emitPosition(from + const Duration(seconds: 1));
  await action;
}

Future<List<Map<String, dynamic>>> opens() async {
  final response = await RpcClient.instance.call('test.playbackLog', {}) as Map<String, dynamic>;
  return (response['opens'] as List<dynamic>).cast<Map<String, dynamic>>();
}

/// `tracks1` open, playing at [at].
Future<void> watching({Duration at = const Duration(minutes: 3)}) async {
  container.read(queueProvider.notifier).play(video('tracks1'));
  await settle();
  expect(playback.source?.audioTrackId, 'en.4', reason: 'it opens on the original');
  engine.emitPosition(at);
  engine.setPlaying(true);
}

void main() {
  setUp(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
    engine = FakeEngine();
    container = ProviderContainer(overrides: [playbackEngineProvider.overrideWithValue(engine)]);
    container.read(playbackProvider);
  });

  tearDown(() async {
    container.dispose();
    await RpcClient.instance.killForTestAndWait();
  });

  test('a pick asks for that track as a preload, and the second player carries it, keeping the session', () async {
    await watching();
    final session = playback.sessionId;
    engine.audioSwitchResult = VideoSwitch.done;

    await controller.chooseAudioTrack('hi.10');

    final asked = (await opens()).last;
    expect(asked, containsPair('preload', true), reason: 'no second session, so no second history entry');
    expect(asked, containsPair('audioTrackId', 'hi.10'));
    expect(engine.audioSwitches.single.audioUrl, endsWith('/audio/hi.10'));
    expect(engine.audioSwitches.single.height, 2160, reason: 'the same quality, with the new audio');
    expect(engine.opened, hasLength(1), reason: 'the swap, not a reopen');
    expect(playback.source?.audioTrackId, 'hi.10');
    expect(playback.variant?.audioUrl, endsWith('/audio/hi.10'));
    expect(playback.sessionId, session, reason: 'reports keep going to the watch the viewer started');
    expect(playback.source?.sessionId, session);
    expect(playback.switchingAudioTrackId, isNull);
  });

  test('where the second player cannot, the media reopens at the position, playing as it was', () async {
    await watching(at: const Duration(minutes: 3));
    // `unsupported`, as a plain engine answers (and the swapping one does in audio-only mode).
    await withClock(controller.chooseAudioTrack('es.3'), const Duration(minutes: 3));

    expect(engine.opened.last.audioUrl, endsWith('/audio/es.3'));
    expect(engine.seeks.last, const Duration(minutes: 3), reason: 'the clock does not go back to 0:00');
    expect(engine.seeks.every((seek) => seek >= const Duration(minutes: 3)), isTrue);
    expect(playback.source?.audioTrackId, 'es.3');
    expect(engine.playing, isTrue);
  });

  test('a paused video stays paused through the reopen', () async {
    await watching();
    engine.setPlaying(false);
    await controller.chooseAudioTrack('es.3');
    await settle();
    expect(engine.opened.last.audioUrl, endsWith('/audio/es.3'));
    expect(engine.playing, isFalse);
  });

  test('the choice survives a quality switch', () async {
    await watching();
    engine.audioSwitchResult = VideoSwitch.done;
    await controller.chooseAudioTrack('hi.10');

    // MUTATION: in `chooseAudioTrack`, set only `variant` and not `source` on success, and this
    // fails: the quality menu lists the old ladder, whose audio is the original's, and the switch
    // reopens with it.
    final lower = playback.variants.firstWhere((variant) => variant.height == 720);
    await withClock(controller.switchQuality(lower), const Duration(minutes: 3));
    expect(engine.opened.last.height, 720);
    expect(engine.opened.last.audioUrl, endsWith('/audio/hi.10'), reason: 'the quality changed, not the language');
    expect(playback.source?.audioTrackId, 'hi.10');
  });

  test('the choice survives the audio-only toggle and a recovery reopen', () async {
    await watching();
    engine.audioSwitchResult = VideoSwitch.done;
    await controller.chooseAudioTrack('hi.10');

    await container.read(audioModeProvider.notifier).setMode(true);
    await settle(100);
    await container.read(audioModeProvider.notifier).setMode(false);
    engine.setVideoOutputReady(true);
    await settle(100);
    expect(engine.opened, hasLength(1), reason: 'the toggle reopens nothing');
    expect(playback.source?.audioTrackId, 'hi.10');

    // A dropped read resolves the video again (todo 107): the new answer must carry the track.
    engine.emitPosition(const Duration(minutes: 3));
    engine.cutOff();
    await settle(500);
    final reopen = (await opens()).last;
    expect(reopen, containsPair('preload', false));
    expect(reopen, containsPair('audioTrackId', 'hi.10'));
    expect(engine.opened.last.audioUrl, endsWith('/audio/hi.10'));
  });

  test('another video starts on its original: the choice was for one video', () async {
    await watching();
    engine.audioSwitchResult = VideoSwitch.done;
    await controller.chooseAudioTrack('hi.10');

    container.read(queueProvider.notifier).play(video('aaa'));
    await settle();
    expect((await opens()).last, containsPair('audioTrackId', null));
    expect(controller.chosenAudioTrackId, isNull);
  });

  test('a single-track video offers nothing to choose, and a pick is ignored', () async {
    container.read(queueProvider.notifier).play(video('aaa'));
    await settle();
    expect(playback.audioTracks, isEmpty);
    expect(playback.audioTrackId, isNull);
    final before = (await opens()).length;
    await controller.chooseAudioTrack('hi.10');
    expect(await opens(), hasLength(before));
  });
}
