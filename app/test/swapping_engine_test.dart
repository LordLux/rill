import 'dart:async';
import 'dart:io';

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

  Key get pictureKey => ValueKey('picture-$name');

  @override
  Widget videoWidget({BoxFit fit = BoxFit.contain}) => SizedBox.expand(key: pictureKey);
  int prepared = 0;
  final List<Duration> aimedAt = [];

  /// Makes the next open throw, as a stream that would not open does.
  Object? openFails;

  /// Held by a test that needs the standby's seek still in flight.
  Future<void>? seekGate;

  /// Makes `play` throw, as a player that has been disposed does.
  Object? playFails;

  @override
  Future<void> play() {
    final failure = playFails;
    if (failure != null) return Future<void>.error(failure);
    return super.play();
  }

  @override
  PlaybackVariant? get lastOpened => _last;

  @override
  bool get videoEnabled => videoTrackEnabled;

  @override
  int droppedFrames = 0;

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
  openTimeout: Duration(seconds: 15),
  prepareTimeout: Duration(seconds: 5),
  maxReaims: 2,
  maxFailures: 2,
);

class Rig {
  Rig({bool enabled = true, bool standbyPlayFails = false}) {
    engine = SwappingEngine(
      () {
        final slot = FakeSlot('p${slots.length}');
        if (slots.isNotEmpty) slot.openGate = standbyGate?.future;
        if (slots.isNotEmpty && standbyPlayFails) slot.playFails = StateError('[Player] has been disposed');
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

  /// Holds the standby's open, so a test can look at the tree while it is still being made.
  Completer<void>? standbyGate;

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
  testWidgets('the active picture is on stage and the standby one is not, before and after a swap', (tester) async {
    final rig = Rig();
    await mount(tester, rig.engine);
    await rig.engine.open(variant(1080));
    expect(find.byKey(rig.first.pictureKey), findsOneWidget, reason: 'the picture is on stage');

    await tester.runAsync(() async {
      // Made here, in the real zone: a future from the test's own zone would not wake the engine.
      rig.standbyGate = Completer<void>();
      rig.first.emitPosition(const Duration(seconds: 100));
      await rig.engine.pause();
      final switching = rig.engine.switchVideo(variant(720));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
      final standby = rig.slots[1];
      expect(rig.engine.hasStandby, isTrue);
      expect(find.byKey(rig.first.pictureKey), findsOneWidget);
      expect(find.byKey(standby.pictureKey), findsNothing, reason: 'the standby is mounted but off stage');
      expect(find.byKey(standby.pictureKey, skipOffstage: false), findsOneWidget);
      rig.standbyGate!.complete();
      await switching;
      await tester.pump();
      expect(find.byKey(standby.pictureKey), findsOneWidget, reason: 'after the swap it is the one on stage');
      expect(find.byKey(rig.first.pictureKey, skipOffstage: false), findsNothing, reason: 'and the old one is out of the tree');
      await rig.engine.dispose();
    });
  });

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

  testWidgets('the frames the viewed player dropped while the standby was made are in the log', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      final lines = <String>[];
      rig.engine.trace = lines.add;
      await mount(tester, rig.engine);
      await started(rig);
      rig.runClock();

      final switching = rig.engine.switchVideo(variant(720));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      rig.first.droppedFrames += 7;
      await switching;

      expect(lines.where((l) => l.contains('dropped 7 frames')), hasLength(1));

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

  testWidgets('play at the end, after a switch made there, starts the media again from its start', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      // The standby is parked at the end while paused, so mpv says `eof-reached` but media_kit never
      // sees `completed`; unpausing there sets the button to playing and mpv pauses again.
      await started(rig, at: const Duration(minutes: 10));
      await rig.engine.pause();
      expect(await rig.engine.switchVideo(variant(720)), VideoSwitch.done);
      final standby = rig.slots[1];
      expect(standby.seeks.last, const Duration(minutes: 10));

      await rig.engine.play();
      expect(standby.seeks.last, Duration.zero, reason: 'it starts again, as it does for a media that played to its end');
      expect(standby.playing, isTrue);

      await rig.engine.pause();
      standby.emitPosition(const Duration(minutes: 10));
      await rig.engine.playOrPause();
      expect(standby.seeks.last, Duration.zero, reason: 'the play button does the same');
      expect(standby.playing, isTrue);
      await rig.engine.dispose();
    });
  });

  testWidgets('play in the middle of the media does not seek', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      await rig.engine.pause();
      expect(await rig.engine.switchVideo(variant(720)), VideoSwitch.done);
      final standby = rig.slots[1];
      final seeksBefore = standby.seeks.length;

      await rig.engine.play();
      expect(standby.seeks, hasLength(seeksBefore), reason: 'only the end restarts');
      expect(standby.playing, isTrue);
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

  testWidgets('a standby whose seek never finishes is given up on at the seek timeout, and is not counted as a failure', (tester) async {
    await tester.runAsync(() async {
      // A range request that gets no answer (`architecture.md` §2.16, 2026-11-04) leaves the standby's
      // seek hanging; waiting out the 20 s inside the engine made one switch take 31 s.
      var made = 0;
      final engine = SwappingEngine(
        () {
          final slot = FakeSlot('p${made++}');
          if (made > 1) slot.seekGate = Completer<void>().future;
          return slot;
        },
        tuning: const SwapTuning(
          firstLead: Duration(milliseconds: 400),
          reaimLead: Duration(milliseconds: 300),
          trigger: Duration(milliseconds: 20),
          tooClose: Duration(milliseconds: 100),
          openTimeout: Duration(seconds: 15),
          prepareTimeout: Duration(seconds: 5),
          seekTimeout: Duration(milliseconds: 300),
          maxReaims: 2,
          maxFailures: 1,
        ),
        settle: () async {},
      );
      final lines = <String>[];
      engine.trace = lines.add;
      await mount(tester, engine);
      final first = engine.active as FakeSlot;
      await engine.open(variant(1080));
      first.emitPosition(const Duration(seconds: 100));

      final started = DateTime.now();
      expect(await engine.switchVideo(variant(720)), VideoSwitch.done);
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 3)), reason: 'it did not wait for the standby');
      expect(first.switched, [variant(720)], reason: 'the active player switched in place');
      expect(engine.active, same(first));
      expect(engine.hasStandby, isFalse);
      expect(lines.join('\n'), contains('did not finish its seek'));

      // One stalled request is the network's, not the engine's: with maxFailures at 1 a counted
      // failure would have ended the second player for the session, and this one would not try.
      expect(await engine.switchVideo(variant(480)), VideoSwitch.done);
      expect(made, 3, reason: 'a second standby was made');
      expect(first.switched, [variant(720), variant(480)]);

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

  testWidgets('the picture turned off and on again during a switch does not let the swap use the dropped standby', (tester) async {
    await tester.runAsync(() async {
      // Audio-only drops the standby (it disposes it) and the picture coming back is no reason to
      // swap to it: on 2026-11-04 that made a disposed player the active one, and the player died.
      final rig = Rig();
      await mount(tester, rig.engine);
      await started(rig);
      rig.runClock();
      final lines = <String>[];
      rig.engine.trace = lines.add;

      rig.standbyGate = Completer<void>();
      final switching = rig.engine.switchVideo(variant(720));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await rig.engine.setVideoTrack(false);
      await rig.engine.setVideoTrack(true);
      rig.standbyGate!.complete();
      final result = await switching;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(result, VideoSwitch.done);
      expect((rig.engine.active as FakeSlot).disposeCount, 0, reason: 'the active player is not a disposed one');
      expect(rig.engine.active, same(rig.first));
      expect(rig.first.switched, [variant(720)], reason: 'the switch was made in place');
      expect(rig.slots[1].disposeCount, 1);
      expect(lines.join('\n'), contains('the standby was dropped'));
      expect(lines.join('\n'), isNot(contains('second player failed')), reason: 'dropping it on purpose is not a failure');

      rig.stopClock();
      await rig.engine.dispose();
    });
  });

  testWidgets('a swap whose commands fail leaves the picture with the old player, playing', (tester) async {
    await tester.runAsync(() async {
      final rig = Rig(standbyPlayFails: true);
      await mount(tester, rig.engine);
      await started(rig);
      rig.runClock();
      final lines = <String>[];
      rig.engine.trace = lines.add;

      final result = await rig.engine.switchVideo(variant(720));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(result, VideoSwitch.done);
      expect(rig.engine.active, same(rig.first), reason: 'the old player kept the picture');
      expect(rig.first.playing, isTrue, reason: 'and kept playing');
      expect(rig.first.switched, [variant(720)]);
      expect(rig.slots[1].disposeCount, 1, reason: 'the standby was retired, not leaked');
      expect(lines.join('\n'), contains('second player failed'));

      rig.stopClock();
      await rig.engine.dispose();
    });
  });

  // The guard for the forwarding (`architecture.md` §2.16). A stream written as `_active.xStream` reads
  // fine and works until the first swap, when every listener that attached before it is left on the
  // retired player: nothing throws, the position just stops. Two checks, so that it cannot come back
  // either way round: every stream arrives from the new player after a swap, and every stream on
  // `PlaybackEngine` is one of the rows below and is routed through a `_Forward`.
  group('every stream of PlaybackEngine follows the active player across a swap', () {
    for (final row in _streamRows) {
      testWidgets(row.name, (tester) async {
        await tester.runAsync(() async {
          final rig = Rig();
          await mount(tester, rig.engine);
          await started(rig);
          await rig.engine.pause();

          // Listening before the swap, as the UI does: that is the listener a stale stream strands.
          final seen = <Object?>[];
          final subscription = row.stream(rig.engine).listen(seen.add);
          expect(await rig.engine.switchVideo(variant(720)), VideoSwitch.done);
          final standby = rig.slots[1];
          expect(rig.engine.active, same(standby));
          // What the swap itself announces is not what is being asked.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          seen.clear();

          row.emit(standby);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await subscription.cancel();
          expect(seen, contains(row.value), reason: '${row.name} did not arrive from the new player');

          await rig.engine.dispose();
        });
      });
    }

    test('every stream on PlaybackEngine is a row above and goes through a _Forward', () {
      final iface = File('lib/data/playback/engine.dart').readAsStringSync();
      final start = iface.indexOf('abstract class PlaybackEngine');
      expect(start, greaterThan(-1));
      final block = iface.substring(start, iface.indexOf('\n}\n', start));
      final declared = RegExp(r'^\s+Stream<[^;]*?>\s+get\s+(\w+);', multiLine: true).allMatches(block).map((m) => m.group(1)!).toSet();
      expect(declared, isNotEmpty, reason: 'the scan found no streams: did the interface move?');

      final rowNames = _streamRows.map((row) => row.name).toSet();
      expect(rowNames, declared, reason: 'a stream was added to or removed from PlaybackEngine: add or remove its row, and route it');

      final source = File('lib/data/playback/swapping_engine.dart').readAsStringSync();
      for (final name in declared) {
        expect(
          RegExp('_Forward<[^>]*>\\(\\(s\\) => s\\.$name\\)').hasMatch(source),
          isTrue,
          reason: '$name has no _Forward in SwappingEngine',
        );
        final getter = RegExp('Stream<[^;]*?>\\s+get\\s+$name\\s+=>\\s+(\\w+)\\.stream;').firstMatch(source);
        expect(getter, isNotNull, reason: '$name is not returned from a _Forward\'s stream (written as _active.$name?)');
        expect(source, contains('${getter!.group(1)}.bind(slot);'), reason: '$name\'s _Forward is never bound to the active player');
      }
    });
  });
}

/// One stream of [PlaybackEngine]: how to reach it, how to make a [FakeSlot] emit on it, and what
/// should then arrive.
class _StreamRow {
  const _StreamRow(this.name, this.stream, this.emit, this.value);

  final String name;
  final Stream<Object?> Function(PlaybackEngine engine) stream;
  final void Function(FakeSlot slot) emit;
  final Object? value;
}

final List<_StreamRow> _streamRows = [
  _StreamRow('positionStream', (e) => e.positionStream, (s) => s.emitPosition(const Duration(milliseconds: 7777)), const Duration(milliseconds: 7777)),
  _StreamRow('durationStream', (e) => e.durationStream, (s) => s.emitDuration(const Duration(seconds: 1234)), const Duration(seconds: 1234)),
  _StreamRow('playingStream', (e) => e.playingStream, (s) => s.setPlaying(true), true),
  _StreamRow('bufferingStream', (e) => e.bufferingStream, (s) => s.setBuffering(true), true),
  _StreamRow('bufferStream', (e) => e.bufferStream, (s) => s.emitBuffer(const Duration(milliseconds: 4321)), const Duration(milliseconds: 4321)),
  _StreamRow('widthStream', (e) => e.widthStream, (s) => s.setWidth(1234), 1234),
  _StreamRow('heightStream', (e) => e.heightStream, (s) => s.setHeight(567), 567),
  _StreamRow('volumeStream', (e) => e.volumeStream, (s) => unawaited(s.setVolume(33)), 33.0),
  _StreamRow('completedStream', (e) => e.completedStream, (s) => s.complete(), true),
  _StreamRow('videoOutputStream', (e) => e.videoOutputStream, (s) => s.setVideoOutputReady(false), false),
  _StreamRow('subtitleTextStream', (e) => e.subtitleTextStream, (s) => s.subtitleText.add('a line from the new player'), 'a line from the new player'),
  _StreamRow('audioMissingStream', (e) => e.audioMissingStream, (s) => s.emitAudioMissing(true), true),
  _StreamRow('seekingStream', (e) => e.seekingStream, (s) => s.setSeeking(true), true),
];
