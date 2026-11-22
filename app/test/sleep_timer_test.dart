/// The sleep timer's rules (Task 38, `architecture.md` §2.18), against the real playback controller,
/// a [FakeEngine] and a fake-sidecar process — the same rig as `read_recovery_test.dart`, because
/// "a real ending, not a dropped read" is the controller's to decide and only that rig drives it.
///
/// Real time, not fake: the sidecar is a process. The timer's own clock is injected
/// ([sleepClockProvider]), so a duration is run out by moving that clock, not by waiting.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/queue_controller.dart';
import 'package:rill/ui/sleep_timer.dart';
import 'package:rill/ui/video_info.dart';

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

/// Records what would have been run, and runs nothing.
class FakePower implements SystemPower {
  FakePower({this.canSleep = true, this.canHibernate = true});

  @override
  final bool canSleep;
  @override
  final bool canHibernate;
  final List<SleepEndAction> runs = [];

  @override
  Future<bool> run(SleepEndAction action) async {
    runs.add(action);
    return true;
  }
}

late FakeEngine engine;
late ProviderContainer container;
late FakePower power;
var clock = Duration.zero;

Future<void> boot() async {
  await RpcClient.instance.killForTestAndWait();
  RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
  await RpcClient.instance.start();
  engine = FakeEngine();
  power = FakePower();
  clock = Duration.zero;
  container = ProviderContainer(overrides: [
    playbackEngineProvider.overrideWithValue(engine),
    sleepClockProvider.overrideWithValue(() => clock),
    systemPowerProvider.overrideWithValue(power),
  ]);
  container.read(playbackProvider);
  container.read(sleepTimerProvider);
}

Future<void> settle([int millis = 250]) => Future<void>.delayed(Duration(milliseconds: millis));

PlaybackState get playback => container.read(playbackProvider);
SleepTimerState get timer => container.read(sleepTimerProvider);
SleepTimerController get sleep => container.read(sleepTimerProvider.notifier);
QueueController get queue => container.read(queueProvider.notifier);

/// Plays the queue built from [ids], from the first.
Future<void> playQueue(List<String> ids) async {
  for (final id in ids) {
    queue.addToQueue(video(id));
  }
  await settle();
  expect(playback.item?.id, ids.first);
  expect(engine.playing, isTrue);
}

/// The video on screen plays to its real end: the clock at the end (the fake's ten minutes,
/// within `shortEndBy`), then mpv's end of file.
Future<void> endsForReal() async {
  engine.emitPosition(const Duration(minutes: 9, seconds: 58));
  engine.complete();
  await settle(400);
}

void main() {
  // The fade watches the keyboard and the pointer through the bindings.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(boot);

  tearDown(() async {
    container.dispose();
    await RpcClient.instance.killForTestAndWait();
  });

  group('a duration', () {
    test('fires after its time on a fake clock while playing, not before, and pauses', () async {
      await playQueue(['aaa']);
      sleep.startDuration(const Duration(minutes: 1));
      expect(timer.kind, SleepKind.duration);
      expect(timer.left, const Duration(minutes: 1));

      clock = const Duration(seconds: 59);
      await settle();
      expect(timer.isOn, isTrue, reason: 'a second to go');
      expect(timer.left, const Duration(seconds: 1));
      expect(engine.playing, isTrue);

      clock = const Duration(seconds: 61);
      await settle();
      expect(timer.isOn, isFalse, reason: 'it turned itself off');
      expect(engine.playing, isFalse, reason: 'it paused');
      expect(engine.outputGain, 1, reason: 'and the volume is back');
      expect(container.read(sleepNoteProvider), 'Sleep timer: paused');
      expect(playback.item?.id, 'aaa');
    });

    test('counts while paused too, and still runs its end action when it runs out', () async {
      await playQueue(['aaa']);
      await engine.pause();
      container.read(sleepEndActionProvider.notifier).set(SleepEndAction.closeRill);
      sleep.startDuration(const Duration(minutes: 1));
      clock = const Duration(minutes: 2);
      await settle();
      expect(timer.isOn, isFalse);
      expect(engine.playing, isFalse);
      expect(power.runs, [SleepEndAction.closeRill], reason: 'the action runs though playback was already paused');
    });
  });

  group('end of video', () {
    test('pauses at the real ending, and nothing autoplays', () async {
      await playQueue(['aaa', 'bbb']);
      sleep.endOfVideo();
      // MUTATION 2: return `false` from the `holdAtRealEnding` check in `_onCompleted` (or delete
      // the check) and this fails: the queue advances and `bbb` plays.
      await endsForReal();
      expect(playback.item?.id, 'aaa', reason: 'autoplay did not move on');
      expect(container.read(queueProvider).currentIndex, 0);
      expect(engine.playing, isFalse, reason: 'paused at the end');
      expect(timer.isOn, isFalse);
      expect(container.read(sleepNoteProvider), 'Sleep timer: paused');

      // Play from there opens the video again, with a session of its own, so the replay is
      // reported; unpausing the parked player would have replayed it with none.
      expect(playback.sessionId, isNull, reason: 'the ended watch closed its session');
      await container.read(playbackProvider.notifier).togglePlayPause();
      await settle(400);
      expect(engine.opened, hasLength(2), reason: 'reopened');
      expect(playback.item?.id, 'aaa');
      expect(playback.sessionId, isNotNull, reason: 'a new session for the replay');
      expect(engine.playing, isTrue);
    });

    test('a dropped read (`_endedShort`) does not fire it, and the recovery reopen does not either', () async {
      await playQueue(['aaa', 'bbb']);
      sleep.endOfVideo();
      engine.emitPosition(const Duration(minutes: 2));
      // MUTATION 1: move the `holdAtRealEnding` check above the `_endedShort()` test in
      // `_onCompleted` and this fails: the timer fires on a dropped connection.
      engine.cutOff();
      await settle(600);
      expect(engine.opened, hasLength(2), reason: 'recovered by reopening');
      expect(timer.kind, SleepKind.videoEnd, reason: 'still waiting for the real end');
      expect(engine.playing, isTrue, reason: 'nothing paused');
      expect(timer.started, 1, reason: 'a reopen of the same video is not a new one');

      await endsForReal();
      expect(timer.isOn, isFalse, reason: 'the real end fires it');
      expect(playback.item?.id, 'aaa');
    });
  });

  group('when there is nothing left to wait for', () {
    test('stopping playback (the miniplayer close button) turns the timer off', () async {
      await playQueue(['aaa', 'bbb']);
      sleep.endOfVideo();
      await container.read(playbackProvider.notifier).stop();
      await settle();
      expect(timer.isOn, isFalse, reason: 'left on, it would fire on a video started hours later');
    });

    test('a queue that plays out short of N turns an after-N timer off', () async {
      await playQueue(['aaa']);
      sleep.afterVideos(3);
      await endsForReal();
      expect(container.read(queueProvider).playedOut, isTrue);
      expect(timer.isOn, isFalse);
      expect(power.runs, isEmpty, reason: 'turned off, not fired');
    });
  });

  group('after N videos', () {
    test('the current video is the first; it pauses when the Nth ends', () async {
      await playQueue(['aaa', 'bbb', 'ccc']);
      sleep.afterVideos(2);
      expect(timer.waitsFor, 'After 2 videos');
      await endsForReal();
      expect(playback.item?.id, 'bbb', reason: 'the first ending is not the second video');
      expect(timer.started, 2);
      expect(timer.waitsFor, 'After 1 video');
      await endsForReal();
      expect(playback.item?.id, 'bbb', reason: 'paused at the end of the second, nothing autoplayed');
      expect(engine.playing, isFalse);
      expect(timer.isOn, isFalse);
    });

    test('a video started by Next or a click counts too', () async {
      await playQueue(['aaa', 'bbb', 'ccc']);
      sleep.afterVideos(2);
      container.read(playbackProvider.notifier).next();
      await settle();
      expect(playback.item?.id, 'bbb');
      expect(timer.started, 2, reason: 'a start the viewer made counts like autoplay');
      await endsForReal();
      expect(playback.item?.id, 'bbb');
      expect(timer.isOn, isFalse);
    });

    test('a video skipped before it ends is counted, and the timer fires at the next real ending', () async {
      // The rule chosen for a skip (§2.18): the skipped video started, so it counts; nothing fires
      // on the skip itself — the viewer pressing Next is awake — and the next real ending fires.
      await playQueue(['aaa', 'bbb', 'ccc', 'ddd']);
      sleep.afterVideos(2);
      container.read(playbackProvider.notifier).next(); // bbb, the 2nd, skipped before its end
      await settle();
      container.read(playbackProvider.notifier).next(); // ccc
      await settle();
      expect(playback.item?.id, 'ccc');
      expect(timer.started, 3);
      expect(timer.isOn, isTrue, reason: 'a skip fires nothing');
      expect(engine.playing, isTrue);
      await endsForReal();
      expect(playback.item?.id, 'ccc', reason: 'the first real ending past N fires');
      expect(engine.playing, isFalse);
      expect(timer.isOn, isFalse);
    });
  });

  group('chapters', () {
    // `chapters1` in the fake sidecar: chapters at 0:00, 1:30, 5:00 and 8:00 of ten minutes.
    Future<void> playChapters() async {
      await container.read(videoInfoProvider('chapters1').future);
      await playQueue(['chapters1', 'bbb']);
    }

    test('end of chapter fires at the end of the chapter the playhead is in', () async {
      await playChapters();
      engine.emitPosition(const Duration(seconds: 10));
      sleep.endOfChapter();
      engine.emitPosition(const Duration(seconds: 80));
      engine.emitPosition(const Duration(seconds: 89, milliseconds: 500));
      await settle(50);
      expect(timer.isOn, isTrue);
      engine.emitPosition(const Duration(seconds: 90, milliseconds: 200));
      await settle();
      expect(timer.isOn, isFalse, reason: 'the chapter ended');
      expect(engine.playing, isFalse);
    });

    test('a seek into another chapter moves the target to that chapter\'s end; a seek within one changes nothing', () async {
      await playChapters();
      engine.emitPosition(const Duration(seconds: 10));
      sleep.endOfChapter();
      engine.emitPosition(const Duration(seconds: 11));

      // A short seek across a boundary (Shift + . is one second) is a seek, not the chapter ending.
      engine.emitPosition(const Duration(seconds: 89));
      await container.read(playbackProvider.notifier).seek(const Duration(seconds: 91));
      await settle(50);
      expect(timer.isOn, isTrue, reason: 'seeking over 1:30 is not playing to it');
      await container.read(playbackProvider.notifier).seek(const Duration(seconds: 40)); // back into "Intro"
      engine.emitPosition(const Duration(seconds: 41));
      await container.read(playbackProvider.notifier).seek(const Duration(seconds: 60)); // within it
      engine.emitPosition(const Duration(seconds: 41));
      await container.read(playbackProvider.notifier).seek(const Duration(seconds: 320)); // into "Build"
      engine.emitPosition(const Duration(seconds: 321));
      await settle(50);
      expect(timer.isOn, isTrue, reason: 'passing 1:30 on the way is not playing to it');

      engine.emitPosition(const Duration(seconds: 479, milliseconds: 600));
      await settle(50);
      expect(timer.isOn, isTrue);
      engine.emitPosition(const Duration(seconds: 480, milliseconds: 100));
      await settle();
      expect(timer.isOn, isFalse, reason: 'it fired at the end of the chapter the seek landed in');
      expect(engine.playing, isFalse);
    });

    test('chapters that arrive after playback started are not a chapter ending', () async {
      // Not preloaded: the timer's own first read starts `video.info`, so the first samples see none.
      await playQueue(['chapters1', 'bbb']);
      sleep.afterChapters(3);
      engine.emitPosition(const Duration(seconds: 100)); // in "Explore", but no chapters known yet
      await settle(400); // `video.info` lands
      // MUTATION: drop the `listEquals(chapters, _chaptersSeen)` re-derive in `_onPosition` and this
      // fails at 2: chapter 0 to chapter 1 by a 0.2 s step reads as playing to the end of one.
      engine.emitPosition(const Duration(seconds: 100, milliseconds: 200));
      await settle(50);
      expect(timer.started, 1, reason: 'the list arriving ended no chapter');
      expect(timer.isOn, isTrue);
    });

    test('the last chapter ends at the real ending, and nothing autoplays', () async {
      await playChapters();
      engine.emitPosition(const Duration(seconds: 500));
      sleep.endOfChapter();
      engine.emitPosition(const Duration(seconds: 501));
      await endsForReal();
      expect(timer.isOn, isFalse);
      expect(playback.item?.id, 'chapters1');
    });

    test('after N chapters counts on across an autoplayed video, which counts as one chapter without chapters', () async {
      await playChapters();
      engine.emitPosition(const Duration(seconds: 481)); // "Outro", the last: the 1st
      sleep.afterChapters(3);
      engine.emitPosition(const Duration(seconds: 482));
      await endsForReal(); // bbb starts: the 2nd (no chapters, so all of it)
      expect(playback.item?.id, 'bbb');
      expect(timer.started, 2);
      expect(timer.isOn, isTrue);
      await endsForReal(); // bbb was the last in the queue: it plays out with 2 of 3 started
      expect(timer.isOn, isFalse, reason: 'the queue played out short of N, so the timer is off rather than left to fire later');
    });
  });
}
