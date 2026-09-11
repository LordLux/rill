/// Task 16 — the player's controls, keyboard and modes.
///
/// Three of these are marked in the task as "the shape that passes against
/// deleted code", and each one carries the mutation that was actually run
/// against it:
///
/// - **the auto-hide timer** — a test that only ever pumps once passes with the
///   timer deleted, because the controls start visible;
/// - **the text-field focus guard** — a test that never focuses anything passes
///   with the guard deleted, because nothing was focused to begin with;
/// - **the single-vs-double click resolution** — a test that only counts the
///   final play state passes against `onTap` + `onDoubleTap`, which is the exact
///   implementation the task forbids.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/captions_controller.dart';
import 'package:rill/ui/pages/watch.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/controls.dart';
import 'package:rill/ui/player/settings_menu.dart';
import 'package:rill/ui/player/shortcuts.dart';
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/player_shell.dart';
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
late NoWindowChrome window;
late ProviderContainer container;
bool _containerDisposed = false;

void disposeContainer() {
  if (_containerDisposed) return;
  _containerDisposed = true;
  container.dispose();
}

/// Step outside the fake-async zone for as long as a real sidecar round trip
/// needs. Same reason as `player_shell_test.dart`.
/// Open the ladder.
///
/// One tap again: quality has its own button on the bar, beside the gear. It was
/// briefly a row two taps inside the settings menu, and this helper is what kept
/// that from being a dozen edits in each direction — which is the reason to keep
/// it now that the ladder is one tap away, rather than to inline it back.
Future<void> openQuality(WidgetTester tester) async {
  await tester.tap(find.byKey(playerQualityButtonKey));
  await tester.pumpAndSettle();
}

Future<void> settleReal(WidgetTester tester, [int millis = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: millis)));
  await tester.pumpAndSettle();
}

/// Reset for one test. **The sidecar is not restarted** — see [main]'s
/// `setUpAll`.
Future<void> boot() async {
  await RpcClient.instance.call('test.reset', {});

  engine = FakeEngine();
  window = NoWindowChrome();
  _containerDisposed = false;
  container = ProviderContainer(
    overrides: [
      playbackEngineProvider.overrideWithValue(engine),
      windowChromeProvider.overrideWithValue(window),
    ],
  );
  container.read(playbackProvider);
}

/// `main.dart`'s structure: the shell mounted through `MaterialApp.builder`, so
/// its child is the `Navigator`. The search field is here because one of these
/// tests is about typing into it.
class TestApp extends ConsumerWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      builder: (context, child) => PlayerShell(child: child ?? const SizedBox.shrink()),
      home: const _HomePage(),
    );
  }
}

class _HomePage extends ConsumerWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Column(
        children: [
          ElevatedButton(
            onPressed: () => openWatch(ref, video('aaa')),
            child: const Text('open aaa'),
          ),
          const SizedBox(
            width: 300,
            child: TextField(key: ValueKey('search'), decoration: InputDecoration()),
          ),
        ],
      ),
    );
  }
}

Future<void> pumpWatching(WidgetTester tester, {List<String> queue = const ['aaa']}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const TestApp()),
  );
  await tester.pumpAndSettle();

  container.read(queueProvider.notifier).play(video(queue.first));
  for (final id in queue.skip(1)) {
    container.read(queueProvider.notifier).addToQueue(video(id));
  }
  showWatchPageIn(container);
  await tester.pump();
  await settleReal(tester);
}

/// The scrubber's `Slider`, which is what actually carries the position — the
/// key is on the wrapper.
final Finder scrubber = find.descendant(
  of: find.byKey(playerScrubberKey),
  matching: find.byType(Slider),
);

double barOpacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byKey(playerControlsBarKey)).opacity;

/// The controls' own `MouseRegion`, found by the widget that owns it rather than
/// by position — `moveTo` on a coordinate would also cross the buttons.
Future<void> movePointer(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(find.byType(PlayerControls).first));
  await tester.pump();
}

void main() {
  // **One sidecar for the whole file, reset between tests.**
  //
  // It used to be one per test, and that is what made this file fail about one
  // run in three: killing and respawning close behind each other races Windows
  // tearing down the previous process's pipes, and `Process.start` then fails
  // with `SocketException: … The pipe is being closed`. The failure arrives as
  // an unhandled async error, so it lands on whichever test happens to be
  // running — it read as a flaky double-click for a while. Retrying the spawn
  // helps and is kept (`RpcClient._spawn`), but 35 restarts a file is the thing
  // actually generating the race, and one is not.
  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() async {
    await RpcClient.instance.killForTestAndWait();
  });

  setUp(() async {
    await boot();
  });

  tearDown(() async {
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Auto-hide
  // -------------------------------------------------------------------------

  testWidgets('the controls hide while playing, stay while paused, and come back on movement',
      (tester) async {
    // MUTATION: delete the `Timer` in `_restartHideTimer` and this test fails at
    // the first `expect` after the 4 s pump. A version that only asserted the
    // controls are visible at the start would pass against that deletion, which
    // is why the hidden assertion comes first and is timed.
    await pumpWatching(tester);

    engine.setPlaying(true);
    await tester.pump();
    expect(barOpacity(tester), 1.0, reason: 'the controls start up');

    // Just under the threshold: still up.
    await tester.pump(const Duration(milliseconds: 400));
    expect(barOpacity(tester), 1.0, reason: 'they do not go early');

    // Past it: gone.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(barOpacity(tester), 0.0, reason: 'one second of a still pointer hides them');

    // Movement brings them back.
    await movePointer(tester);
    await tester.pumpAndSettle();
    expect(barOpacity(tester), 1.0, reason: 'the pointer moved');

    // Pausing keeps them up indefinitely.
    engine.setPlaying(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(barOpacity(tester), 1.0, reason: 'a paused player keeps its controls');

    disposeContainer();
  });

  testWidgets('the busy spinner being on screen keeps the controls up, and its own grace period still applies',
      (tester) async {
    // MUTATION: read the raw buffering signal instead of `_BusySpinner`'s own
    // `_shown` callback and this still passes the "stays up" half — it is the
    // 200 ms assertion below, taken before the spinner's 250 ms grace period
    // elapses, that pins the bar to the spinner's on-screen state rather than
    // to buffering starting.
    await pumpWatching(tester);

    engine.setPlaying(true);
    await tester.pump();
    engine.setBuffering(true);

    // Short of the spinner's own grace period: nothing shown yet, but the bar
    // has not hidden either — too little time for its own 1 s delay.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(playerBusySpinnerKey), findsNothing);
    expect(barOpacity(tester), 1.0);

    // Past the spinner's grace period.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(playerBusySpinnerKey), findsOneWidget, reason: 'buffering long enough to show it');

    // Well past where the bar would otherwise have auto-hidden.
    //
    // `pump`, not `pumpAndSettle` — the spinner is an indeterminate
    // `CircularProgressIndicator`, which schedules a frame forever while it
    // is in the tree, so `pumpAndSettle` here would just time out. `opacity`
    // is `AnimatedOpacity`'s target value, set synchronously on rebuild, so a
    // plain pump is enough to read it correctly without waiting the fade out.
    await tester.pump(const Duration(seconds: 2));
    expect(barOpacity(tester), 1.0,
        reason: 'a stall must not hide the controls out from under someone reaching for mute or pause');

    // Buffering clears: the ordinary countdown resumes from here.
    engine.setBuffering(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(barOpacity(tester), 0.0, reason: 'once the stall clears, the bar auto-hides again');

    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Click vs double-click
  // -------------------------------------------------------------------------

  testWidgets('a single click toggles play/pause immediately, with no double-click wait',
      (tester) async {
    // MUTATION: replace the hand-rolled resolution with
    // `GestureDetector(onTap:…, onDoubleTap:…)` and this fails — `onTap` is then
    // withheld for `kDoubleTapTimeout` and the state after `pump()` is unchanged.
    // That is the naive fix the task names, and it is the one this pins out.
    await pumpWatching(tester);
    engine.setPlaying(true);
    await tester.pump();

    await tester.tapAt(tester.getCenter(find.byType(PlayerControls).first));
    // A single `pump` — no time is allowed to pass. The point is that the
    // toggle has already happened.
    await tester.pump();

    expect(engine.playing, isFalse, reason: 'the click paused it there and then');
    disposeContainer();
  });

  testWidgets('a double click reaches fullscreen and leaves the play state as it started',
      (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    await tester.pump();

    final centre = tester.getCenter(find.byType(PlayerControls).first);
    await tester.tapAt(centre);
    await tester.pump();
    expect(engine.playing, isFalse, reason: 'the first click acted immediately');

    // Inside the double-click window.
    await tester.tapAt(centre);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(container.read(playerViewProvider).fullscreen, isTrue);
    expect(engine.playing, isTrue,
        reason: 'the second click undid the first — the play state is where it started');
    disposeContainer();
  });

  testWidgets('two clicks far apart are two single clicks, not a double', (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    await tester.pump();

    final centre = tester.getCenter(find.byType(PlayerControls).first);
    await tester.tapAt(centre);
    await tester.pump();
    // Well outside `doubleClickWindow`.
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tapAt(centre);
    await tester.pump();

    expect(container.read(playerViewProvider).fullscreen, isFalse,
        reason: 'two separate clicks must not go fullscreen');
    expect(engine.playing, isTrue, reason: 'pause then play');
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Scrubber
  // -------------------------------------------------------------------------

  testWidgets('dragging the scrubber seeks once, on release', (tester) async {
    await pumpWatching(tester);
    engine.emitPosition(const Duration(seconds: 10));
    await tester.pump();
    engine.seeks.clear();

    final start = tester.getCenter(scrubber);

    final gesture = await tester.startGesture(start);
    // Several moves — the whole point is that none of them seeks. F15 measured
    // a 1.2–1.3 s stall per seek, so a continuous drag would fire dozens.
    for (var i = 1; i <= 5; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    expect(engine.seeks, isEmpty, reason: 'nothing seeks mid-drag');

    await gesture.up();
    await tester.pumpAndSettle();

    expect(engine.seeks, hasLength(1), reason: 'exactly one seek, on release');
    expect(engine.seeks.single, greaterThan(const Duration(seconds: 10)),
        reason: 'and it lands where the thumb was dragged to');
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------------

  testWidgets('each shortcut fires its action', (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 2));
    await tester.pump();

    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    // Space and K.
    await press(LogicalKeyboardKey.space);
    expect(engine.playing, isFalse);
    await press(LogicalKeyboardKey.keyK);
    expect(engine.playing, isTrue);

    // ∓5 s, then ∓10 s. Position is asserted rather than the seek count,
    // because the arithmetic is the part that goes wrong.
    engine.seeks.clear();
    engine.emitPosition(const Duration(minutes: 2));
    await press(LogicalKeyboardKey.arrowRight);
    expect(engine.seeks.last, const Duration(minutes: 2, seconds: 5));
    await press(LogicalKeyboardKey.arrowLeft);
    expect(engine.seeks.last, const Duration(minutes: 2));
    await press(LogicalKeyboardKey.keyL);
    expect(engine.seeks.last, const Duration(minutes: 2, seconds: 10));
    await press(LogicalKeyboardKey.keyJ);
    expect(engine.seeks.last, const Duration(minutes: 2));

    // Volume, then mute and back.
    engine.volumes.clear();
    await press(LogicalKeyboardKey.arrowDown);
    expect(engine.volumes.last, 95);
    await press(LogicalKeyboardKey.arrowUp);
    expect(engine.volumes.last, 100);
    await press(LogicalKeyboardKey.keyM);
    expect(engine.volumes.last, 0);
    await press(LogicalKeyboardKey.keyM);
    expect(engine.volumes.last, 100, reason: 'unmute returns to the level before the mute');

    // Modes.
    await press(LogicalKeyboardKey.keyT);
    expect(container.read(playerViewProvider).theatre, isTrue);
    await press(LogicalKeyboardKey.keyF);
    expect(container.read(playerViewProvider).fullscreen, isTrue);

    // Esc unwinds fullscreen first, then theatre.
    await press(LogicalKeyboardKey.escape);
    expect(container.read(playerViewProvider).fullscreen, isFalse);
    expect(container.read(playerViewProvider).theatre, isTrue,
        reason: 'the first Esc took fullscreen only');
    await press(LogicalKeyboardKey.escape);
    expect(container.read(playerViewProvider).theatre, isFalse);

    // Deciles. The fake reports a 10-minute duration.
    engine.seeks.clear();
    await press(LogicalKeyboardKey.digit5);
    expect(engine.seeks.last, const Duration(minutes: 5));
    await press(LogicalKeyboardKey.digit0);
    expect(engine.seeks.last, Duration.zero);
    await press(LogicalKeyboardKey.digit9);
    expect(engine.seeks.last, const Duration(minutes: 9));

    disposeContainer();
  });

  testWidgets('comma and period step a frame; with Shift they seek a second', (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 2));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await tester.pumpAndSettle();
    expect(engine.frameSteps, [1]);
    expect(engine.playing, isFalse, reason: 'stepping a frame leaves a still picture');

    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    expect(engine.frameSteps, [1, -1]);

    engine.seeks.clear();
    engine.emitPosition(const Duration(minutes: 2));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await tester.pumpAndSettle();
    expect(engine.seeks.last, const Duration(minutes: 2, seconds: 1));
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.pumpAndSettle();
    expect(engine.seeks.last, const Duration(minutes: 2));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(engine.frameSteps, [1, -1], reason: 'and Shift did not also step frames');
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Keyboard + mouse
  // -------------------------------------------------------------------------

  testWidgets('Shift + scroll changes the volume, and a bare scroll does not', (tester) async {
    await pumpWatching(tester);
    final centre = tester.getCenter(find.byType(PlayerControls).first);

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    Future<void> scroll(Offset delta) async {
      await tester.sendEventToBinding(pointer.hover(centre));
      await tester.sendEventToBinding(pointer.scroll(delta));
      await tester.pumpAndSettle();
    }

    engine.volumes.clear();
    await scroll(const Offset(0, -40));
    expect(engine.volumes, isEmpty, reason: 'a bare wheel has to scroll the page, not the volume');

    // Where the player sits on the page: adjusting the volume must not also
    // scroll the page out from under it. Recorded as a property rather than as a
    // mutation check — it survives removing the `pointerSignalResolver`
    // registration, because Flutter's `Scrollable` flips its axis under Shift and
    // then reads a `dx` the wheel leaves at zero.
    final playerTop = tester.getTopLeft(find.byType(PlayerControls).first).dy;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await scroll(const Offset(0, -40));
    expect(engine.volumes.last, 100, reason: 'already at 100 and clamped there');

    await scroll(const Offset(0, 40));
    expect(engine.volumes.last, 95, reason: 'scrolling down is quieter');
    await scroll(const Offset(0, 40));
    expect(engine.volumes.last, 90);
    await scroll(const Offset(0, -40));
    expect(engine.volumes.last, 95, reason: 'and scrolling up is louder again');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(tester.getTopLeft(find.byType(PlayerControls).first).dy, playerTop,
        reason: 'and the page stayed put while it happened');

    disposeContainer();
  });

  testWidgets('no shortcut fires while a text field has focus', (tester) async {
    // MUTATION: delete the `textEntryHasFocus()` early return in
    // `_PlayerShortcutsState._onKey` and every expectation below flips —
    // `f` goes fullscreen, `space` pauses, `m` mutes. All while the user is
    // typing "fast" into the search box.
    //
    // The focus is real, not simulated: the shortcut layer is global, so what is
    // under test is whether it *asks* about focus, and a test that never focused
    // anything would pass against the deleted guard.
    await pumpWatching(tester);
    engine.setPlaying(true);
    await tester.pump();

    // Back to the feed, where the search field lives, with the video still
    // playing in the mini-player — which is exactly the situation in which the
    // shortcuts are live and the search box is reachable.
    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('search')));
    await tester.pumpAndSettle();
    expect(textEntryHasFocus(), isTrue, reason: 'the field really has focus');

    // `captions.list` is a real round trip to the fake sidecar, and
    // `pumpAndSettle` does not wait for one. Without this the caption
    // assertions below would pass because the list had not arrived yet —
    // vacuously, which is the failure mode this whole test is about.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    engine.volumes.clear();
    engine.seeks.clear();
    final playingBefore = engine.playing;

    for (final key in [
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.keyT,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.keyJ,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.keyC,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    expect(container.read(playerViewProvider).fullscreen, isFalse, reason: 'typing "f"');
    expect(container.read(playerViewProvider).theatre, isFalse, reason: 'typing "t"');
    expect(engine.volumes, isEmpty, reason: 'typing "m"');
    expect(engine.seeks, isEmpty, reason: 'typing "j", "l", "5" and pressing →');
    expect(engine.playing, playingBefore, reason: 'typing "k" and pressing space');
    // **Not vacuous**: this sidecar serves two caption tracks for this video, so
    // the `C` handler's own "no tracks, decline" branch is not what is stopping
    // it — the focus guard is. Asserted alongside, because a caption toggle that
    // fired while the user typed "coding" into the search box would be the same
    // bug wearing a new key.
    expect(container.read(captionsProvider).hasTracks, isTrue,
        reason: 'the C key has something to toggle, so the guard is what stops it');
    expect(container.read(captionsProvider).isOn, isFalse, reason: 'typing "c"');

    disposeContainer();
  });

  testWidgets('shortcuts do nothing when there is no video', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();

    expect(container.read(playerViewProvider).fullscreen, isFalse);
    expect(window.requests, isEmpty, reason: 'and the OS window was never touched');
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Theatre and fullscreen
  // -------------------------------------------------------------------------

  testWidgets('theatre and fullscreen enter and exit, and exit asks for the window back',
      (tester) async {
    await pumpWatching(tester);

    await tester.tap(find.byKey(playerTheatreKey));
    await tester.pumpAndSettle();
    expect(container.read(playerViewProvider).theatre, isTrue);
    expect(window.requests, isEmpty, reason: 'theatre is a layout change — the window is not touched');

    await tester.tap(find.byKey(playerTheatreKey));
    await tester.pumpAndSettle();
    expect(container.read(playerViewProvider).theatre, isFalse);

    await tester.tap(find.byKey(playerFullscreenKey));
    await tester.pumpAndSettle();
    expect(container.read(playerViewProvider).fullscreen, isTrue);
    expect(window.requests, [true], reason: 'fullscreen is an OS window change');
    expect(window.isFullscreen, isTrue);

    // The surface moved to the shell rather than being duplicated. Exactly one,
    // as in `player_shell_test.dart` — two would be two `Texture` widgets on one
    // id, and rebuilding it is what the task's stop condition forbids.
    expect(find.byKey(FakeEngine.surfaceKey), findsOneWidget);
    expect(engine.opened, hasLength(1), reason: 'a mode change does not reopen the media');
    expect(engine.stopCount, 0);
    expect(engine.disposeCount, 0, reason: 'and does not tear the video output down');

    await tester.tap(find.byKey(playerFullscreenKey));
    await tester.pumpAndSettle();
    expect(container.read(playerViewProvider).fullscreen, isFalse);
    expect(window.requests, [true, false], reason: 'and asks for the previous bounds back');
    expect(window.isFullscreen, isFalse);
    expect(find.byKey(FakeEngine.surfaceKey), findsOneWidget, reason: 'still one surface');
    expect(engine.opened, hasLength(1));

    disposeContainer();
  });

  testWidgets('fullscreen survives a route change without stranding the app', (tester) async {
    await pumpWatching(tester);

    await tester.tap(find.byKey(playerFullscreenKey));
    await tester.pumpAndSettle();
    expect(container.read(playerViewProvider).fullscreen, isTrue);

    // Leave the watch page while fullscreen. Without the reset in
    // `PlayerViewController.build`, the app is left borderless over the monitor
    // showing a feed, with no player on screen to press Esc at.
    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(container.read(playerViewProvider).fullscreen, isFalse);
    expect(window.requests, [true, false], reason: 'the OS window came back too');
    expect(find.byType(MiniPlayer), findsOneWidget, reason: 'and playback carried on');
    expect(engine.stopCount, 0);

    disposeContainer();
  });

  testWidgets('stopping playback while fullscreen releases the window', (tester) async {
    await pumpWatching(tester);
    await tester.tap(find.byKey(playerFullscreenKey));
    await tester.pumpAndSettle();

    await container.read(playbackProvider.notifier).stop();
    await tester.pumpAndSettle();

    expect(container.read(playerViewProvider).fullscreen, isFalse);
    expect(window.isFullscreen, isFalse);
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Quality
  // -------------------------------------------------------------------------

  testWidgets('a quality switch preserves position and play state, and issues no RPC',
      (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 3));
    await tester.pump();

    expect(engine.opened.single.height, 2160, reason: 'the ladder is taken best-first by default');

    await openQuality(tester);
    expect(find.byKey(playerSettingsMenuKey), findsOneWidget);
    // Present and dead, on purpose (§3): the stepper it would drive is out of
    // scope, and the row is here so the menu keeps its shape when it lands.
    expect(find.byKey(playerQualityAutoKey), findsOneWidget);
    // At the bottom, below every rung — "let the player decide" is the end of a
    // best-first list, not a rung above 2160p.
    expect(
      tester.getTopLeft(find.byKey(playerQualityAutoKey)).dy,
      greaterThan(tester.getTopLeft(find.text('360p')).dy),
    );
    // Every rung, ranked.
    expect(find.text('2160p60'), findsOneWidget);
    expect(find.text('1080p60'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('360p'), findsOneWidget);

    await tester.tap(find.text('1080p60'));
    await tester.pump();
    // Playback resuming past the seek target — what lifts the cover, and what a
    // real player does seconds after the seek is accepted.
    engine.emitPosition(const Duration(minutes: 3, milliseconds: 100));
    await settleReal(tester);

    expect(engine.opened, hasLength(2));
    expect(engine.opened.last.height, 1080);
    expect(engine.seeks.last, const Duration(minutes: 3),
        reason: 'the position is put back after the reopen');
    expect(engine.playing, isTrue, reason: 'it was playing, so it is playing');
    expect(container.read(playbackProvider).variant?.height, 1080);

    // §3.5: all variants come from one `/player` response, so switching costs no
    // round trip. A second `playback.open` would also mint a second session and
    // put one watch into the account's history twice.
    // `runAsync`, because a real subprocess round trip never progresses inside
    // the fake-async zone `testWidgets` runs in — the same reason `settleReal`
    // exists.
    final log = await tester.runAsync(
      () => RpcClient.instance.call('test.playbackLog', {}),
    );
    final opens = (log! as Map)['opens'] as List<Object?>;
    expect(opens.where((o) => (o! as Map)['preload'] != true), hasLength(1),
        reason: 'one non-preload playback.open for the whole watch');

    disposeContainer();
  });

  testWidgets('the Auto row does nothing when clicked', (tester) async {
    await pumpWatching(tester);
    await openQuality(tester);

    // Disabled, not merely inert: there is no `InkWell` under this row, so it
    // does not even take the ripple. That is also why the tap below is allowed
    // to miss — the miss *is* the assertion.
    expect(
      find.descendant(of: find.byKey(playerQualityAutoKey), matching: find.byType(InkWell)),
      findsNothing,
    );

    final openedBefore = engine.opened.length;
    final playingBefore = engine.playing;
    await tester.tap(find.byKey(playerQualityAutoKey), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(engine.opened, hasLength(openedBefore), reason: 'no reopen');
    expect(find.byKey(playerSettingsMenuKey), findsOneWidget,
        reason: 'and the menu does not close, because nothing was chosen');
    expect(engine.playing, playingBefore,
        reason: 'nor does the click fall through to the video and pause it');
    disposeContainer();
  });

  testWidgets('a quality switch while paused stays paused', (tester) async {
    await pumpWatching(tester);
    engine.emitPosition(const Duration(minutes: 1));
    engine.setPlaying(false);
    await tester.pump();

    await openQuality(tester);
    await tester.tap(find.text('720p'));
    await tester.pump();
    await settleReal(tester);

    expect(engine.opened.last.height, 720);
    expect(engine.playing, isFalse, reason: 'a paused video does not start playing on a switch');
    disposeContainer();
  });

  testWidgets('the chosen height is remembered for the rest of the session', (tester) async {
    await pumpWatching(tester);
    await openQuality(tester);
    await tester.tap(find.text('720p'));
    await tester.pump();
    await settleReal(tester);

    // A different video, opened the ordinary way.
    container.read(queueProvider.notifier).play(video('bbb'));
    await tester.pump();
    await settleReal(tester);

    expect(engine.opened.last.height, 720,
        reason: 'the next video opens at the height the user chose, not at variants[0]');
    disposeContainer();
  });

  testWidgets('the quality panel shows the height mpv is actually decoding', (tester) async {
    await pumpWatching(tester);
    await tester.pump();

    // Requested 2160; mpv says it is serving 1080. The readout reports mpv.
    //
    // The number has moved twice — the quality button's face, then a row in the
    // settings menu, now the quality panel's header — and the claim being pinned
    // has not moved at all: it is the *decoded* height, not the requested one.
    // Asserting on the claim rather than on the widget is why this test survived
    // both moves.
    engine.setHeight(1080);
    await tester.pumpAndSettle();

    await openQuality(tester);

    expect(
      find.byKey(playerQualityHeaderKey),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(find.byKey(playerQualityHeaderKey)).data,
      '1080p',
      reason: 'the requested height would have said 2160p, confidently and wrongly',
    );
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Queue ends
  // -------------------------------------------------------------------------

  testWidgets('previous and next are absent at the ends of the queue, not wrapping',
      (tester) async {
    await pumpWatching(tester, queue: ['aaa', 'bbb']);

    expect(find.byKey(playerPreviousKey), findsNothing, reason: 'nothing before the first');
    expect(find.byKey(playerNextKey), findsOneWidget);

    await tester.tap(find.byKey(playerNextKey));
    await tester.pump();
    await settleReal(tester);

    expect(container.read(queueProvider).current?.id, 'bbb');
    expect(find.byKey(playerNextKey), findsNothing, reason: 'nothing after the last');
    expect(find.byKey(playerPreviousKey), findsOneWidget);

    await tester.tap(find.byKey(playerPreviousKey));
    await tester.pump();
    await settleReal(tester);
    expect(container.read(queueProvider).current?.id, 'aaa');

    // The cursor did not wrap in either direction.
    expect(container.read(queueProvider).currentIndex, 0);
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Mini-player, captions, theatre icon
  // -------------------------------------------------------------------------

  testWidgets('"i" sends the video to the mini-player and goes back a page', (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    await tester.pump();
    expect(find.byType(WatchPage), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pumpAndSettle();

    expect(find.byType(WatchPage), findsNothing, reason: 'back to where the user came from');
    expect(find.byType(MiniPlayer), findsOneWidget);
    expect(engine.playing, isTrue, reason: 'and it is still playing');
    expect(engine.stopCount, 0);
    expect(engine.opened, hasLength(1), reason: 'nothing was reopened to get here');
    disposeContainer();
  });

  testWidgets('the mini-player button does the same as "i", and leaves fullscreen first',
      (tester) async {
    await pumpWatching(tester);
    await tester.tap(find.byKey(playerFullscreenKey));
    await tester.pumpAndSettle();
    expect(container.read(playerViewProvider).fullscreen, isTrue);

    await tester.tap(find.byKey(playerMiniPlayerKey));
    await tester.pumpAndSettle();

    expect(container.read(playerViewProvider).fullscreen, isFalse,
        reason: 'popping while borderless would leave the window covering the monitor');
    expect(window.requests, [true, false], reason: 'and the OS window was handed back');
    expect(find.byType(WatchPage), findsNothing);
    expect(find.byType(MiniPlayer), findsOneWidget);
    disposeContainer();
  });

  testWidgets('the captions button appears once the track list has, and opens its page',
      (tester) async {
    // Not `pumpWatching` — it ends with `settleReal`, a real 400ms wait that
    // is plenty of time for the fake sidecar's `captions.list` round trip to
    // land, so by the time it returns the "before the list arrives" moment
    // this test wants to check has already passed. Opening by hand and
    // stopping at a plain `pump()` (no `runAsync`) keeps the check honest: a
    // real subprocess response cannot land inside the fake-async test zone
    // without `runAsync` stepping outside it, so the button's absence here is
    // guaranteed by construction, not by outrunning a race.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TestApp()),
    );
    await tester.pumpAndSettle();
    container.read(queueProvider.notifier).play(video('aaa'));
    showWatchPageIn(container);
    await tester.pump();

    // Absent before the list arrives — not disabled. An empty list is settled
    // once `captions.list` answers (`protocol.md` §3.8), so the button is drawn
    // only when there is something behind it.
    expect(find.byKey(playerCaptionsKey), findsNothing,
        reason: 'nothing to show until the list is back');

    await settleReal(tester);
    expect(find.byKey(playerCaptionsKey), findsOneWidget);

    await tester.tap(find.byKey(playerCaptionsKey));
    await tester.pumpAndSettle();
    expect(container.read(playerMenuProvider).page, SettingsPage.captions);
    expect(find.byKey(playerCaptionsOffKey), findsOneWidget);

    // The gear stays unlit while the caption panel is up: they are two doors
    // into one panel, and both lighting at once reads as two menus.
    expect(
      tester.widget<IconButton>(find.descendant(
        of: find.byKey(playerSettingsButtonKey),
        matching: find.byType(IconButton),
      )).onPressed,
      isNotNull,
    );
    disposeContainer();
  });

  testWidgets('a video with no caption tracks draws no CC button at all', (tester) async {
    await pumpWatching(tester, queue: const ['nocaps1']);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(container.read(captionsProvider).isLoadingTracks, isFalse,
        reason: 'the list has answered, so this is a settled absence');
    expect(find.byKey(playerCaptionsKey), findsNothing);
    disposeContainer();
  });

  testWidgets('the theatre icon reports the state it is in, not the action', (tester) async {
    await pumpWatching(tester);

    IconData theatreIcon() =>
        tester.widget<Icon>(find.descendant(
          of: find.byKey(playerTheatreKey),
          matching: find.byType(Icon),
        )).icon!;

    final normal = theatreIcon();
    await tester.tap(find.byKey(playerTheatreKey));
    await tester.pumpAndSettle();
    expect(container.read(playerViewProvider).theatre, isTrue);

    final inTheatre = theatreIcon();
    expect(inTheatre, isNot(normal), reason: 'the icon changed with the mode');
    expect(inTheatre, Icons.crop_7_5,
        reason: 'the wide glyph means "you are in theatre", not "press to widen"');
    expect(normal, Icons.crop_16_9);
    disposeContainer();
  });

  testWidgets('fullscreen names what is playing, and only fullscreen does', (tester) async {
    await pumpWatching(tester);
    expect(find.text('Video aaa'), findsNothing,
        reason: 'the page already says, so the overlay does not');

    await tester.tap(find.byKey(playerFullscreenKey));
    await tester.pumpAndSettle();

    expect(find.text('Video aaa'), findsOneWidget, reason: 'fullscreen hid the page that said');
    expect(find.text('Channel'), findsOneWidget);

    await tester.tap(find.byKey(playerFullscreenKey));
    await tester.pumpAndSettle();
    expect(find.text('Video aaa'), findsNothing);
    disposeContainer();
  });

  testWidgets('an ordinary video has no previous or next button at all', (tester) async {
    await pumpWatching(tester);

    expect(find.byKey(playerPreviousKey), findsNothing);
    expect(find.byKey(playerNextKey), findsNothing,
        reason: 'a single video is not a playlist — two dead arrows are two dead controls');
    // The rest of the left cluster is still there, so this is absence rather
    // than the whole bar having failed to build.
    expect(find.byKey(playerPlayPauseKey), findsOneWidget);
    disposeContainer();
  });

  testWidgets('Shift + N and Shift + P move the queue with no buttons on screen',
      (tester) async {
    await pumpWatching(tester, queue: ['aaa', 'bbb']);
    expect(find.byKey(playerPreviousKey), findsNothing, reason: 'at the front, so no button');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pump();
    await settleReal(tester);
    expect(container.read(queueProvider).current?.id, 'bbb');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    await settleReal(tester);
    expect(container.read(queueProvider).current?.id, 'aaa');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    // Unshifted they are somebody else's keys.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(container.read(queueProvider).current?.id, 'aaa', reason: 'a bare "n" is not next');
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // Volume slider on hover
  // -------------------------------------------------------------------------

  testWidgets('the volume slider opens on hover, closes after a delay, and pushes the clock',
      (tester) async {
    // MUTATION: drop the `_closeTimer` and close on `onExit` directly — the
    // "still open just after leaving" expectation fails, and in the app the
    // slider collapses out from under a pointer travelling towards it.
    await pumpWatching(tester);

    double sliderWidth() => tester.widget<SizedBox>(find.byKey(playerVolumeSliderKey)).width!;
    // The clock is the only text on the bar shaped `position / duration`.
    double clockLeft() => tester.getTopLeft(find.textContaining(' / ')).dx;

    expect(sliderWidth(), 0, reason: 'closed until the pointer arrives');
    final closedClock = clockLeft();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.byKey(playerMuteKey)));
    await tester.pumpAndSettle();

    expect(sliderWidth(), 120, reason: 'hovering the speaker opens it');
    expect(clockLeft(), greaterThan(closedClock),
        reason: 'and the clock is pushed right to make room, not covered over');

    // Away, but inside the delay.
    await gesture.moveTo(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 100));
    expect(sliderWidth(), 120, reason: 'the pointer gets a moment to come back');

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(sliderWidth(), 0, reason: 'and then it closes');
    expect(clockLeft(), closedClock, reason: 'the clock comes back with it');
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // The busy spinner
  // -------------------------------------------------------------------------

  testWidgets('a wait long enough to notice shows a spinner; a fast one does not',
      (tester) async {
    // MUTATION: drop the grace `Timer` and show the spinner the instant
    // `buffering` goes true — the "brief" case below fails, and every fast seek
    // gets a two-frame flash of a spinner, which reads as a glitch.
    await pumpWatching(tester);
    engine.setPlaying(true);
    await tester.pump();
    expect(find.byKey(playerBusySpinnerKey), findsNothing);

    // A blip: over well inside the grace period.
    engine.setBuffering(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(playerBusySpinnerKey), findsNothing,
        reason: 'too short to be worth telling anyone about');
    engine.setBuffering(false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(playerBusySpinnerKey), findsNothing,
        reason: 'and it must not appear after the fact either');

    // A real one: past the grace period.
    engine.setBuffering(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(playerBusySpinnerKey), findsOneWidget);

    engine.setBuffering(false);
    await tester.pump();
    expect(find.byKey(playerBusySpinnerKey), findsNothing, reason: 'and it leaves at once');
    disposeContainer();
  });

  testWidgets('the spinner does not swallow the click that toggles play/pause', (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.setBuffering(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(playerBusySpinnerKey), findsOneWidget);

    // Straight through the middle, where the spinner is.
    await tester.tapAt(tester.getCenter(find.byType(PlayerControls).first));
    await tester.pump();
    expect(engine.playing, isFalse,
        reason: 'a spinner that ate the click would take the control away exactly '
            'when the player is least responsive');
    disposeContainer();
  });

  testWidgets('a quality switch shows the spinner over the cover', (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 3));
    await tester.pumpAndSettle();

    final gate = Completer<void>();
    engine.openGate = gate.future;

    await openQuality(tester);
    await tester.tap(find.text('720p'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(playerSwitchCoverKey), findsOneWidget);
    expect(find.byKey(playerBusySpinnerKey), findsOneWidget,
        reason: 'black alone does not say "working on it"');

    gate.complete();
    engine.openGate = null;
    await tester.pump();
    engine.emitPosition(const Duration(minutes: 3, milliseconds: 100));
    await settleReal(tester);
    expect(find.byKey(playerBusySpinnerKey), findsNothing);
    disposeContainer();
  });

  // -------------------------------------------------------------------------
  // The quality-switch cover
  // -------------------------------------------------------------------------

  testWidgets('the video is covered from the switch until the picture is back', (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 3));
    await tester.pump();
    expect(find.byKey(playerSwitchCoverKey), findsNothing, reason: 'nothing to cover yet');

    // Hold the reopen open, so the switch is observable mid-flight rather than
    // over before the first pump — which is what a test of a *transient* cover
    // otherwise measures, and it would pass with the cover deleted.
    final gate = Completer<void>();
    engine.openGate = gate.future;

    await openQuality(tester);
    await tester.tap(find.text('720p'));
    await tester.pump();

    expect(find.byKey(playerSwitchCoverKey), findsOneWidget,
        reason: 'covered while the new stream opens');

    gate.complete();
    engine.openGate = null;
    await tester.pump();
    engine.emitPosition(const Duration(minutes: 3, milliseconds: 100));
    await settleReal(tester);

    expect(find.byKey(playerSwitchCoverKey), findsNothing,
        reason: 'and uncovered once the position is back where it was');
    expect(engine.seeks.last, const Duration(minutes: 3));
    disposeContainer();
  });

  testWidgets('the scrubber and clock hold the position instead of snapping to zero',
      (tester) async {
    // MUTATION: drop `holdPosition` from `_Scrubber`/`_Clock` and this fails at
    // the first expect — the engine really is reporting zero at that moment,
    // which is exactly what the user saw.
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 3));
    await tester.pumpAndSettle();
    expect(find.textContaining('3:00'), findsOneWidget);

    final gate = Completer<void>();
    engine.openGate = gate.future;

    await openQuality(tester);
    await tester.tap(find.text('720p'));
    await tester.pump();

    // What the engine is saying mid-reopen: back at the start.
    //
    // Settled in real time rather than with `pumpAndSettle`, which cannot
    // settle here at all: the quality button shows a `CircularProgressIndicator`
    // while the switch is in flight, and an animation that never ends is a tree
    // that is never idle.
    engine.emitPosition(Duration.zero);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();

    expect(engine.position, Duration.zero, reason: 'the engine really is reporting zero');
    expect(engine.duration, Duration.zero,
        reason: 'and so is its duration — `open` clears both');
    expect(find.textContaining('3:00'), findsOneWidget,
        reason: 'and the clock is still showing where the user is');

    final slider = tester.widget<Slider>(scrubber);
    expect(slider.value, const Duration(minutes: 3).inMilliseconds.toDouble(),
        reason: 'so is the scrubber');
    // **The far-right bug, pinned.** Holding the position without the duration
    // collapses `max` to 1 ms, and a held 3:00 clamps into it — so `value ==
    // max` and the thumb pins to the *end* of the bar for half a second. The
    // position assertion above passes in that state; only this one fails.
    expect(slider.max, const Duration(minutes: 10).inMilliseconds.toDouble(),
        reason: 'the range is held too, or the thumb clamps to the end of a 1 ms bar');
    expect(slider.value, lessThan(slider.max), reason: 'the thumb is not at the end');

    gate.complete();
    engine.openGate = null;
    await tester.pump();
    engine.emitPosition(const Duration(minutes: 3, milliseconds: 100));
    await settleReal(tester);

    expect(container.read(playbackProvider).hold, isNull, reason: 'and the hold is let go');
    disposeContainer();
  });

  testWidgets('scrubbing during a switch moves the hold and retargets the cover', (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 3));
    await tester.pump();

    // A switch that will not resume on its own.
    engine.swallowSeeks = true;

    Future<void> tick() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }

    await openQuality(tester);
    await tester.tap(find.text('720p'));
    await tester.pump();
    await tick();
    expect(container.read(playbackProvider).hold?.position, const Duration(minutes: 3));

    // The user seeks *backwards* while the switch is in flight. This is the case
    // that hangs if the wait captured its target instead of re-reading it: the
    // cover would sit there waiting to pass 3:00, a point the user has just
    // chosen to be behind, until the 25 s deadline.
    await container.read(playbackProvider.notifier).seekBy(const Duration(seconds: -30));
    await tick();

    expect(engine.seeks.last, const Duration(minutes: 2, seconds: 30),
        reason: 'relative to the held position, not to the engine\'s zero');
    expect(container.read(playbackProvider).hold?.position,
        const Duration(minutes: 2, seconds: 30),
        reason: 'the hold moved with the user');
    expect(find.textContaining('2:30'), findsOneWidget);
    expect(find.byKey(playerSwitchCoverKey), findsOneWidget, reason: 'still covered');

    // Resuming past the *new* target lifts it.
    engine.emitPosition(const Duration(minutes: 2, seconds: 30, milliseconds: 100));
    await tick();
    expect(find.byKey(playerSwitchCoverKey), findsNothing);
    expect(container.read(playbackProvider).hold, isNull);
    disposeContainer();
  });

  testWidgets('a report during a switch carries the held position, not zero', (tester) async {
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 3));
    await tester.pump();

    final gate = Completer<void>();
    engine.openGate = gate.future;
    await openQuality(tester);
    await tester.tap(find.text('720p'));
    await tester.pump();
    engine.emitPosition(Duration.zero);
    await tester.pump();

    // Real time and a bare `pump` — `settleReal` ends in `pumpAndSettle`, which
    // cannot settle while the quality button's spinner is running.
    await tester.runAsync(() => container.read(playbackProvider.notifier).reportNow());
    await tester.pump();

    final log = await tester.runAsync(() => RpcClient.instance.call('test.playbackLog', {}));
    final reports = (log! as Map)['reports'] as List<Object?>;
    expect((reports.last! as Map)['positionMs'], 180000,
        reason: 'a report of zero mid-watch tells YouTube the viewer went back to the start');

    gate.complete();
    engine.openGate = null;
    engine.emitPosition(const Duration(minutes: 3, milliseconds: 100));
    await settleReal(tester);
    disposeContainer();
  });

  testWidgets('a scrub during a switch survives the reopen', (tester) async {
    // MUTATION: seek to the captured `position` local instead of the hold, as it
    // was — this fails. The reopen takes seconds (F19), and anyone who scrubs
    // during it was being dragged back to where they started.
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 3));
    await tester.pumpAndSettle();

    // Hold the reopen open so the scrub lands in the middle of it, which is the
    // only window where this can go wrong.
    final gate = Completer<void>();
    engine.openGate = gate.future;

    await openQuality(tester);
    await tester.tap(find.text('720p'));
    await tester.pump();

    await container.read(playbackProvider.notifier).seek(const Duration(minutes: 5));
    await tester.pump();

    gate.complete();
    engine.openGate = null;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    engine.emitPosition(const Duration(minutes: 5, milliseconds: 100));
    await settleReal(tester);

    expect(engine.seeks.last, const Duration(minutes: 5),
        reason: 'the switch resumed where the user scrubbed to, not where it began');
    disposeContainer();
  });

  testWidgets('a second quality pick supersedes the first', (tester) async {
    // MUTATION: `final generation = _generation;` without the increment — both
    // switches then run with the same generation, neither guard fires, and both
    // reopen the player. The last `opened` entry becomes whichever race won.
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 2));
    await tester.pumpAndSettle();

    // Past this point `pumpAndSettle` is unusable: the quality button shows a
    // `CircularProgressIndicator` while a switch is in flight, and a tree with a
    // running animation is never idle.
    Future<void> tick() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump();
    }

    final firstOpen = Completer<void>();
    engine.openGate = firstOpen.future;

    await openQuality(tester);
    await tester.tap(find.text('1080p60'));
    await tester.pump();

    // A second pick while the first reopen is still in flight.
    engine.openGate = null;
    await tester.tap(find.byKey(playerQualityButtonKey));
    await tick();
    await tester.tap(find.text('360p'));
    await tick();
    firstOpen.complete();
    engine.emitPosition(const Duration(minutes: 2, milliseconds: 100));
    await settleReal(tester);

    expect(container.read(playbackProvider).variant?.height, 360,
        reason: 'the newer pick wins; the older one aborts at its generation guard');
    expect(container.read(playbackProvider).isSwitchingQuality, isFalse,
        reason: 'and the superseded switch does not leave the cover up');
    disposeContainer();
  });

  testWidgets('seeking forward at the very end does not skip to the next video',
      (tester) async {
    // MUTATION: `target > duration` instead of `>=` — a seek that lands exactly
    // on the duration ends the media, `completedStream` fires and the queue
    // advances, so `→` near the end skips the video instead of reaching its end.
    await pumpWatching(tester, queue: ['aaa', 'bbb']);
    engine.setPlaying(true);
    // The fake reports a 10-minute duration. Five seconds short of it, so `→`
    // lands exactly on the end.
    engine.emitPosition(const Duration(minutes: 9, seconds: 55));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(engine.seeks.last, lessThan(const Duration(minutes: 10)),
        reason: 'clamped short of the end rather than onto it');
    expect(container.read(queueProvider).current?.id, 'aaa',
        reason: 'still the same video — the seek was not an accidental "next"');
    disposeContainer();
  });

  testWidgets('unmuting a video that started silent restores audible volume', (tester) async {
    await pumpWatching(tester);
    await tester.runAsync(() => container.read(playbackProvider.notifier).setVolume(0));
    engine.volumes.clear();

    // First mute toggle ever, on a player already at zero: there is no
    // remembered level to come back to, so restoring it literally would be a
    // mute toggle that never unmutes.
    await tester.tap(find.byKey(playerMuteKey));
    await tester.pumpAndSettle();

    expect(engine.volumes.last, greaterThan(0),
        reason: 'unmute has to produce sound, even with nothing to restore');
    disposeContainer();
  });

  testWidgets('the cover outlives the reopen, which is the whole point', (tester) async {
    // MUTATION: clear `isSwitchingQuality` in a `finally` around the reopen —
    // where it was before — and this fails. That is exactly the version that
    // uncovers while mpv is still playing the new stream from zero, which is the
    // frame the user saw as "the thumbnail".
    await pumpWatching(tester);
    engine.setPlaying(true);
    engine.emitPosition(const Duration(minutes: 3));
    await tester.pump();

    // A fake that does *not* honour the seek: the position never comes back, so
    // the reopen finishing is the only thing that could uncover — and it must
    // not be enough.
    engine.swallowSeeks = true;

    // `pumpAndSettle` is deliberately not used past this point. It advances the
    // fake clock in 100 ms steps until the tree is idle, which walks straight
    // through the controller's 25 s uncover deadline and takes the cover down
    // for a reason that has nothing to do with what is under test. Real time
    // plus a single `pump` lets the reopen complete without the clock moving.
    Future<void> tick() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }

    await openQuality(tester);
    await tester.tap(find.text('720p'));
    await tester.pump();
    await tick();

    expect(engine.opened.last.height, 720, reason: 'the reopen really did finish');
    expect(find.byKey(playerSwitchCoverKey), findsOneWidget,
        reason: 'and the cover is still up, because the picture is not back');

    // Reaching the resume point is *not* enough while playing — mpv reports the
    // seek target as soon as it accepts the seek, seconds before it decodes
    // there. Measured 2026-08-12: one switch reported the target at 448 ms and
    // did not move past it until 5343 ms.
    engine.emitPosition(const Duration(minutes: 3));
    await tick();
    expect(find.byKey(playerSwitchCoverKey), findsOneWidget,
        reason: 'the target being reported is mpv accepting the seek, not resuming');

    // Moving past it is.
    engine.emitPosition(const Duration(minutes: 3, milliseconds: 100));
    await tick();
    expect(find.byKey(playerSwitchCoverKey), findsNothing);
    disposeContainer();
  });
}
