import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/playback/engine.dart';
import 'package:rill/data/playback/swapping_engine.dart';
import 'package:rill/domain/playback_source.dart';

import 'fake_engine.dart';

PlaybackVariant variant(int height) => PlaybackVariant(
      videoUrl: 'https://fake.invalid/$height',
      audioUrl: 'https://fake.invalid/audio',
      height: height,
      fps: 60,
      videoCodec: 'vp9',
      audioCodec: 'opus',
    );

/// A [FakeEngine] that can be the standby: it records what a standby is asked, and can be made
/// to fail or to hold.
class FakeSlot extends FakeEngine implements SwapSlot {
  FakeSlot(this.name) {
    inPlaceSwitch = true;
  }

  final String name;
  PlaybackVariant? _last;
  int prepared = 0;
  final List<Duration> aimedAt = [];

  /// Makes the next open throw, as a stream that would not open does.
  Object? openFails;

  /// Held by a test that needs the standby's seek still in flight.
  Future<void>? seekGate;

  @override
  PlaybackVariant? get lastOpened => _last;

  @override
  bool get videoEnabled => videoTrackEnabled;

  @override
  Future<void> prepareStandby() async => prepared++;

  @override
  Future<void> open(
    PlaybackVariant variant, {
    bool play = true,
    bool Function()? shouldPlay,
    bool retainSubtitle = false,
    bool isLive = false,
  }) async {
    final failure = openFails;
    if (failure != null) throw failure;
    await super.open(variant, play: play, shouldPlay: shouldPlay, retainSubtitle: retainSubtitle, isLive: isLive);
    _last = variant;
  }

  @override
  Future<VideoSwitch> switchVideo(PlaybackVariant variant) async {
    final result = await super.switchVideo(variant);
    if (result == VideoSwitch.done) _last = variant;
    return result;
  }

  @override
  Future<void> seekAndWait(Duration to) async {
    aimedAt.add(to);
    final gate = seekGate;
    if (gate != null) await gate;
    await seek(to);
  }
}

const tuning = SwapTuning(
  firstLead: Duration(milliseconds: 400),
  reaimLead: Duration(milliseconds: 300),
  trigger: Duration(milliseconds: 20),
  tooClose: Duration(milliseconds: 100),
  openTimeout: Duration(seconds: 3),
  prepareTimeout: Duration(seconds: 5),
  maxReaims: 2,
  maxFailures: 2,
);

class Rig {
  Rig({bool enabled = true}) {
    engine = SwappingEngine(
      () {
        final slot = FakeSlot('p${slots.length}');
        slots.add(slot);
        return slot;
      },
      tuning: tuning,
      enabled: enabled,
      settle: () async {},
    );
  }

  late final SwappingEngine engine;
  final List<FakeSlot> slots = [];

  FakeSlot get first => slots.first;

  /// The clock of whichever player is active, running at normal speed while it plays.
  Timer? _clock;

  void runClock() {
    _clock = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final active = engine.active as FakeSlot;
      if (active.playing) active.emitPosition(active.position + const Duration(milliseconds: 10));
    });
  }

  void stopClock() => _clock?.cancel();
}

Future<void> mount(WidgetTester tester, SwappingEngine engine) => tester.pumpWidget(
      MaterialApp(home: SizedBox(width: 200, height: 100, child: engine.videoSurface())),
    );

Future<void> started(Rig rig, {Duration at = const Duration(seconds: 100)}) async {
  await rig.engine.open(variant(1080));
  rig.first.emitPosition(at);
}

void main() {
  testWidgets('a switch swaps to a second player at the clock, and the streams follow it', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      rig.runClock();

      final positions = <Duration>[];
      final playing = <bool>[];
      rig.engine.positionStream.listen(positions.add);
      rig.engine.playingStream.listen(playing.add);

      final result = await rig.engine.switchVideo(variant(720));
      expect(result, VideoSwitch.done);
      expect(rig.slots, hasLength(2), reason: 'the first player and a standby');
      final standby = rig.slots[1];
      expect(rig.engine.active, same(standby));
      expect(standby.opened.single, variant(720));
      expect(standby.prepared, 1);
      expect(standby.playing, isTrue, reason: 'the standby plays from the swap');
      expect(rig.first.playing, isFalse, reason: 'and the first player is paused');
      expect(standby.aimedAt.single, greaterThan(const Duration(seconds: 100)), reason: 'aimed past the clock');
      expect(rig.first.switched, isEmpty, reason: 'the in-place switch was not needed');
      expect(playing, isNot(contains(false)), reason: 'nothing above the engine saw the picture stop');

      // The old player is stopped and disposed once it is off the stage.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(rig.first.stopCount, 1);
      expect(rig.first.disposeCount, 1);

      // From here only the new player's events arrive.
      positions.clear();
      standby.emitPosition(const Duration(seconds: 101));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(positions, contains(const Duration(seconds: 101)));
      expect(rig.engine.position, standby.position);

      rig.stopClock();
      await rig.engine.dispose();
    });
  });

  testWidgets('the swap happens when the clock gets to the target, not before', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      rig.runClock();

      final switching = rig.engine.switchVideo(variant(720));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(rig.engine.active, same(rig.first), reason: 'the target is 400 ms ahead');
      await switching;
      expect(rig.engine.active, same(rig.slots[1]));
      final target = rig.slots[1].aimedAt.single;
      expect(rig.first.position, greaterThanOrEqualTo(target - const Duration(milliseconds: 40)));
      expect(rig.first.position, lessThan(target + const Duration(milliseconds: 100)));

      rig.stopClock();
      await rig.engine.dispose();
    });
  });

  testWidgets('paused, the standby goes to the clock and the swap is a flip', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      await rig.engine.pause();

      final result = await rig.engine.switchVideo(variant(720));
      expect(result, VideoSwitch.done);
      final standby = rig.slots[1];
      expect(standby.aimedAt.single, const Duration(seconds: 100));
      expect(standby.playing, isFalse);
      expect(rig.engine.playing, isFalse);
      expect(rig.engine.active, same(standby));

      await rig.engine.dispose();
    });
  });

  testWidgets('a standby that fails to open is dropped and the active player switches in place', (tester) async {
    await tester.runAsync(() async {
      var made = 0;
      final engine = SwappingEngine(
        () {
          final slot = FakeSlot('p');
          if (made++ > 0) slot.openFails = StateError('the video stream would not open');
          return slot;
        },
        tuning: tuning,
        settle: () async {},
      );
      final lines = <String>[];
      engine.trace = lines.add;
      await mount(tester, engine);
      final first = engine.active as FakeSlot;
      await engine.open(variant(1080));
      first.emitPosition(const Duration(seconds: 100));

      final result = await engine.switchVideo(variant(720));
      expect(result, VideoSwitch.done);
      expect(engine.active, same(first), reason: 'the first player kept the picture');
      expect(first.switched, [variant(720)], reason: 'and switched in place');
      expect(engine.hasStandby, isFalse);
      expect(lines.join('\n'), contains('switching in place'));

      await engine.dispose();
    });
  });

  testWidgets('after enough failures in a row it stops trying a second player', (tester) async {
    await tester.runAsync(() async {
      var made = 0;
      final slots = <FakeSlot>[];
      final engine = SwappingEngine(
        () {
          final slot = FakeSlot('p${made++}');
          if (made > 1) slot.openFails = StateError('no');
          slots.add(slot);
          return slot;
        },
        tuning: tuning,
        settle: () async {},
      );
      await mount(tester, engine);
      await engine.open(variant(1080));
      slots.first.emitPosition(const Duration(seconds: 100));

      await engine.switchVideo(variant(720));
      await engine.switchVideo(variant(480));
      expect(slots, hasLength(3), reason: 'two standbys tried');
      await engine.switchVideo(variant(360));
      expect(slots, hasLength(3), reason: 'the third switch did not make one');
      expect(slots.first.switched, [variant(720), variant(480), variant(360)]);

      await engine.dispose();
    });
  });

  testWidgets('with no picture mounted, or the second player turned off, it switches in place', (tester) async {
    await tester.runAsync(() async {
      final unmounted = Rig();
      await started(unmounted);
      await unmounted.engine.switchVideo(variant(720));
      expect(unmounted.slots, hasLength(1), reason: 'no surface, no standby');
      expect(unmounted.first.switched, [variant(720)]);
      await unmounted.engine.dispose();

      final off = Rig(enabled: false);
      await mount(tester, off.engine);
      await started(off);
      await off.engine.switchVideo(variant(720));
      expect(off.slots, hasLength(1));
      expect(off.first.switched, [variant(720)]);
      await off.engine.dispose();
    });
  });

  testWidgets('unsupported stays unsupported: nothing is touched', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      final other = PlaybackVariant(
        videoUrl: 'https://fake.invalid/720',
        audioUrl: 'https://fake.invalid/another-audio',
        height: 720,
        fps: 60,
        videoCodec: 'vp9',
        audioCodec: 'opus',
      );
      expect(rig.engine.canSwitchVideo(other), isFalse);
      expect(await rig.engine.switchVideo(other), VideoSwitch.unsupported);
      expect(rig.slots, hasLength(1));
      await rig.engine.dispose();
    });
  });

  testWidgets('the viewer seeking while the standby is aimed aims it again', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      rig.runClock();

      final switching = rig.engine.switchVideo(variant(720));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.engine.seek(const Duration(seconds: 200));
      await rig.first.seek(const Duration(seconds: 200));
      final result = await switching;

      expect(result, VideoSwitch.done);
      final standby = rig.slots[1];
      expect(standby.aimedAt.length, greaterThanOrEqualTo(2), reason: 'aimed, then aimed again');
      expect(standby.aimedAt.last, greaterThan(const Duration(seconds: 200)));
      expect(rig.engine.position, greaterThan(const Duration(seconds: 200)));

      rig.stopClock();
      await rig.engine.dispose();
    });
  });

  testWidgets('a pause pressed while the standby is aimed is a swap made paused', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      rig.runClock();

      final switching = rig.engine.switchVideo(variant(720));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.engine.pause();
      final result = await switching;

      expect(result, VideoSwitch.done);
      expect(rig.engine.active, same(rig.slots[1]));
      expect(rig.engine.playing, isFalse, reason: 'the pause stuck');

      rig.stopClock();
      await rig.engine.dispose();
    });
  });

  testWidgets('opening another media while a standby is being made drops it', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      rig.runClock();

      final switching = rig.engine.switchVideo(variant(720));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rig.engine.hasStandby, isTrue);
      await rig.engine.open(variant(480));
      final result = await switching;

      expect(rig.engine.hasStandby, isFalse);
      expect(rig.engine.active, same(rig.first), reason: 'the new media opened on the player that was there');
      expect(rig.slots[1].disposeCount, 1, reason: 'the standby was disposed, not left running');
      expect(result, VideoSwitch.done, reason: 'and the abandoned switch fell back to the in-place one');

      rig.stopClock();
      await rig.engine.dispose();
    });
  });

  testWidgets('volume and captions reach the standby, so the swap changes neither', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      await rig.engine.setVolume(35);
      await rig.engine.setSubtitle('[Script Info]');
      await rig.engine.setSubtitleVisible(true);
      rig.runClock();

      await rig.engine.switchVideo(variant(720));
      final standby = rig.slots[1];
      expect(standby.volume, 35);
      expect(standby.subtitle, '[Script Info]');
      expect(rig.engine.subtitle, '[Script Info]');
      expect(rig.engine.volume, 35);

      rig.stopClock();
      await rig.engine.dispose();
    });
  });

  testWidgets('turning the picture off in the middle of a switch ends the second player', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      rig.runClock();

      final switching = rig.engine.switchVideo(variant(720));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.engine.setVideoTrack(false);
      final result = await switching;

      expect(rig.engine.hasStandby, isFalse);
      expect(rig.engine.active, same(rig.first));
      expect(result, VideoSwitch.done, reason: 'audio-only records the choice, as the in-place switch does');
      expect(rig.first.switched, [variant(720)]);

      rig.stopClock();
      await rig.engine.dispose();
    });
  });

}
