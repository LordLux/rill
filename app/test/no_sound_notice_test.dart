/// The "no sound" notice: a video whose audio did not load plays in silence, and the player says
/// so (issue #22). The harness is `loading_controls_test.dart`'s — the real watch page in the real
/// shell, a fake sidecar and a fake engine.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/focus_ring.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/data/playback/engine.dart' show VideoSwitch;
import 'package:rill/ui/player/controls.dart' show PlayerControls, menuButtonPulseKey, playerBusySpinnerKey, playerScrubberKey;
import 'package:rill/ui/player/settings_menu.dart' show playerQualityButtonKey;
import 'package:rill/ui/player/player_slates.dart';
import 'package:rill/ui/player/video_load_cover.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';

import 'fake_engine.dart';
import 'sidecar_idle.dart';

VideoItem video(String id) => VideoItem(
      kind: 'video',
      id: id,
      title: 'Video $id',
      channelName: 'Fake Channel',
      thumbnailUrl: '',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

class _TestApp extends ConsumerWidget {
  const _TestApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      builder: (context, child) => FocusRing(child: PlayerShell(child: child ?? const SizedBox.shrink())),
      home: const Scaffold(body: SizedBox.shrink()),
    );
  }
}

void main() {
  late FakeEngine engine;
  late ProviderContainer container;
  var disposed = false;

  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() => RpcClient.instance.killForTestAndWait());

  setUp(() async {
    await RpcClient.instance.call('test.reset', {});
    disposed = false;
    engine = FakeEngine();
    container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
      ],
    );
    container.read(playbackProvider);
  });

  void finish() {
    if (disposed) return;
    disposed = true;
    container.dispose();
  }

  tearDown(finish);

  Future<void> openVideo(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const _TestApp()));
    await tester.pump();
    openWatchIn(container, video('vid-1'));
    await tester.pump();
    await settleWithSidecar(tester);
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('a video with no audio shows the notice, over a picture that keeps playing', (tester) async {
    engine.audioLoads = false;
    await openVideo(tester);

    expect(container.read(playbackProvider).audioMissing, isTrue);
    expect(find.byKey(noSoundNoticeKey), findsOneWidget);
    expect(find.text("No sound: the audio didn't load"), findsOneWidget);
    expect(find.byKey(noSoundRetryKey), findsOneWidget);
    expect(find.text('This video would not open.'), findsNothing, reason: 'the picture is fine; this is not a slate');
    expect(engine.playing, isTrue);
    finish();
  });

  testWidgets('a video with its audio shows no notice', (tester) async {
    await openVideo(tester);

    expect(find.byKey(noSoundNoticeKey), findsNothing);
    finish();
  });

  testWidgets('the notice leaves the page when the audio arrives late', (tester) async {
    engine.audioLoads = false;
    await openVideo(tester);
    expect(find.byKey(noSoundNoticeKey), findsOneWidget);

    engine.audioArrivesLate();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(noSoundNoticeKey), findsNothing);
    finish();
  });

  testWidgets('a switch in place says so on the picture, and takes it down when it ends', (tester) async {
    engine.inPlaceSwitch = true;
    await openVideo(tester);
    final gate = Completer<void>();
    engine.switchGate = gate.future;

    final done = container.read(playbackProvider.notifier).switchQuality(container.read(playbackProvider).source!.variants.last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // MUTATION: drop the `SwitchingNote` line in `PlayerSlates` and this fails: the picture
    // would just stop with nothing said.
    expect(find.byKey(switchingNoteKey), findsOneWidget);
    expect(find.text('Switching to 360p…'), findsOneWidget);
    // Under the progress bar, in the control bar's row, and not over the picture where the
    // captions are: the bar is 64 px with the 12 px scrubber at its top.
    final note = tester.getRect(find.byKey(switchingNoteKey));
    final player = tester.getRect(find.byType(PlayerControls));
    expect(note.top, greaterThanOrEqualTo(player.bottom - 52), reason: 'below the scrubber');
    expect(note.bottom, lessThanOrEqualTo(player.bottom), reason: 'inside the player');
    // And painted over the bar's gradient, not under it: later in the tree is later in paint order.
    final elements = tester.allElements.toList();
    final barAt = elements.indexOf(find.byKey(playerScrubberKey).evaluate().first);
    final noteAt = elements.indexOf(find.byKey(switchingNoteKey).evaluate().first);
    expect(noteAt, greaterThan(barAt), reason: 'the note paints after the bar');
    expect(find.byKey(videoLoadCoverKey), findsNothing, reason: 'the old frame stays, nothing covers it');

    gate.complete();
    await tester.runAsync(() => done);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(switchingNoteKey), findsNothing);
    finish();
  });

  testWidgets('a switch in place does not put the busy spinner over the picture, but a real stall during it still does', (tester) async {
    engine.inPlaceSwitch = true;
    await openVideo(tester);
    engine.setPlaying(true);
    final gate = Completer<void>();
    engine.switchGate = gate.future;

    final done = container.read(playbackProvider.notifier).switchQuality(container.read(playbackProvider).source!.variants.last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // MUTATION: put `isChangingQuality` back into `_BusySpinner._busy` and this fails: the picture is
    // still playing, and the spinner over it says it is not. The quality button already says it.
    expect(container.read(playbackProvider).isSwitchingTrack, isTrue);
    expect(find.byKey(playerBusySpinnerKey), findsNothing, reason: 'the old picture keeps playing; nothing is stuck');

    // Something that is stuck is another matter, switch or no switch.
    engine.setBuffering(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(playerBusySpinnerKey), findsOneWidget, reason: 'buffering long enough is a stall');
    engine.setBuffering(false);
    await tester.pump();
    expect(find.byKey(playerBusySpinnerKey), findsNothing);

    gate.complete();
    await tester.runAsync(() => done);
    await tester.pump(const Duration(milliseconds: 50));
    finish();
  });

  testWidgets('the quality button keeps its icon during a switch and pulses it, instead of swapping in a spinner', (tester) async {
    engine.inPlaceSwitch = true;
    await openVideo(tester);
    final button = find.byKey(playerQualityButtonKey);
    expect(find.descendant(of: button, matching: find.byIcon(Icons.hd_outlined)), findsOneWidget);
    expect(find.descendant(of: button, matching: find.byKey(menuButtonPulseKey)), findsNothing, reason: 'nothing pulses at rest');

    final gate = Completer<void>();
    engine.switchGate = gate.future;
    final done = container.read(playbackProvider.notifier).switchQuality(container.read(playbackProvider).source!.variants.last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // MUTATION: put the `CircularProgressIndicator` back in `_MenuButton` and this fails: the quality
    // icon would be gone for the length of the switch, and with it what is changing.
    expect(find.descendant(of: button, matching: find.byIcon(Icons.hd_outlined)), findsOneWidget, reason: 'the icon stays: it says what is changing');
    expect(find.descendant(of: button, matching: find.byType(CircularProgressIndicator)), findsNothing);
    final pulse = find.descendant(of: button, matching: find.byKey(menuButtonPulseKey));
    expect(pulse, findsOneWidget);
    // Its lightness moves: two frames half a pulse apart are not the same.
    double opacity() => tester.widget<FadeTransition>(pulse).opacity.value;
    final first = opacity();
    await tester.pump(const Duration(milliseconds: 450));
    expect(opacity(), isNot(closeTo(first, 0.05)), reason: 'it pulses');
    expect(opacity(), greaterThan(0.2), reason: 'and never goes dark enough to lose the icon');

    gate.complete();
    await tester.runAsync(() => done);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.descendant(of: button, matching: find.byKey(menuButtonPulseKey)), findsNothing, reason: 'and it stops when the switch does');
    finish();
  });

  testWidgets('and when the switch falls back to the reopen the note goes (the reopen has its own cover)', (tester) async {
    engine.inPlaceSwitch = true;
    await openVideo(tester);
    engine.nextSwitchResult = VideoSwitch.refused;
    final gate = Completer<void>();
    engine.switchGate = gate.future;

    final done = container.read(playbackProvider.notifier).switchQuality(container.read(playbackProvider).source!.variants.last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(switchingNoteKey), findsOneWidget);

    gate.complete();
    await tester.runAsync(() => done);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(switchingNoteKey), findsNothing);
    expect(engine.opened, hasLength(2), reason: 'reopened');
    finish();
  });

  testWidgets('Try again opens it again and the notice goes away once the audio is there', (tester) async {
    engine.audioLoads = false;
    await openVideo(tester);
    expect(find.byKey(noSoundNoticeKey), findsOneWidget);

    engine.audioLoads = true;
    await tester.tap(find.byKey(noSoundRetryKey));
    await tester.pump();
    await settleWithSidecar(tester);
    await tester.pump(const Duration(milliseconds: 50));

    expect(engine.opened, hasLength(2));
    expect(find.byKey(noSoundNoticeKey), findsNothing);
    expect(container.read(playbackProvider).audioMissing, isFalse);
    finish();
  });
}
