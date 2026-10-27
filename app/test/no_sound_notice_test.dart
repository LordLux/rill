/// The "no sound" notice: a video whose audio did not load plays in silence, and the player says
/// so (issue #22). The harness is `loading_controls_test.dart`'s — the real watch page in the real
/// shell, a fake sidecar and a fake engine.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/focus_ring.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/player_slates.dart';
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
