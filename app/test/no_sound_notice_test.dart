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
    final slates = tester.getRect(find.byType(PlayerSlates));
    expect(note.top, greaterThanOrEqualTo(slates.bottom - 52), reason: 'below the scrubber');
    expect(note.bottom, lessThanOrEqualTo(slates.bottom), reason: 'inside the player');
    expect(find.byKey(videoLoadCoverKey), findsNothing, reason: 'the old frame stays, nothing covers it');

    gate.complete();
    await tester.runAsync(() => done);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(switchingNoteKey), findsNothing);
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
