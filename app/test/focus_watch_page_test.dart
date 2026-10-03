/// Tab order and focus on the watch page — Task 32 §3 (`docs/todo.md` 38).
///
/// The harness is `watch_actions_test.dart`'s: a fake sidecar and a fake engine,
/// the real `WatchPage` inside the real shell.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/audio_mode_controller.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/hide_queue_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/controls.dart';
import 'package:rill/ui/player/volume_bar.dart';
import 'package:rill/ui/player/settings_menu.dart' show playerMenuProvider, settingsMenuPanelKey;
import 'package:rill/ui/player/view_mode.dart';
import 'package:rill/ui/player/window_chrome.dart';
import 'package:rill/ui/page_wrapper.dart';
import 'package:rill/ui/player_shell.dart';
import 'package:rill/ui/queue_controller.dart';

import 'fake_engine.dart';
import 'focus_traversal_test.dart' show focused, tabThrough;

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

class _SignedIn extends AuthController {
  @override
  AuthState build() => const AuthState(status: AuthStatus.authenticated, accountHandle: '@tester');
}

/// The first route's page. A bare Scaffold unless a test needs the real shell around it.
Widget Function() testHome = () => const Scaffold(body: SizedBox.shrink());

class TestApp extends ConsumerWidget {
  const TestApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [ref.watch(routeTrackerProvider)],
      builder: (context, child) => PlayerShell(child: child ?? const SizedBox.shrink()),
      home: testHome(),
    );
  }
}

void main() {
  late FakeEngine engine;
  late ProviderContainer container;
  var disposed = false;

  void finish() {
    if (disposed) return;
    disposed = true;
    container.dispose();
  }

  setUpAll(() async {
    await RpcClient.instance.killForTestAndWait();
    RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
    await RpcClient.instance.start();
  });

  tearDownAll(() => RpcClient.instance.killForTestAndWait());

  setUp(() async {
    await RpcClient.instance.call('test.reset', {});
    engine = FakeEngine();
    disposed = false;
    container = ProviderContainer(
      overrides: [
        playbackEngineProvider.overrideWithValue(engine),
        windowChromeProvider.overrideWithValue(NoWindowChrome()),
        authProvider.overrideWith(_SignedIn.new),
      ],
    );
    container.read(playbackProvider);
  });

  tearDown(finish);

  Future<void> openWatch(WidgetTester tester, {List<String> alsoQueue = const []}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const TestApp()));
    await tester.pumpAndSettle();
    openWatchIn(container, video('vid-1'));
    for (final id in alsoQueue) {
      container.read(queueProvider.notifier).addToQueue(video(id));
    }
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await tester.pumpAndSettle();
  }

  /// Whether the controls bar is showing: its fade is at 1, not 0.
  bool barShowing(WidgetTester tester) => tester.widget<AnimatedOpacity>(find.byKey(playerControlsBarKey)).opacity == 1;

  group('the watch page', () {
    testWidgets('Tab walks the shell, then the player controls, then the metadata and its actions', (tester) async {
      await openWatch(tester);

      final walk = await tabThrough(tester, 31);
      // The relative order of the anchors, not the whole list: the metadata block
      // has several stops (channel, subscribe, description) and naming each one
      // here would pin the page's layout rather than the order of its surfaces.
      final anchors = [
        'Toggle menu', 'Back', 'home', 'history', 'field', 'Search', '@tester', // title bar, rail, search, account
        'player-scrubber', 'player-play-pause', 'player-mute', 'player-fullscreen', // the player controls, left to right
        'Like', 'Dislike', 'Share', 'Save to playlist', 'Watch Later', 'More', // the actions row
        'Toggle menu', // and round again
      ];
      var from = 0;
      for (final anchor in anchors) {
        final at = walk.indexOf(anchor, from);
        expect(at, greaterThanOrEqualTo(from), reason: '"$anchor" should come after the previous anchor in $walk');
        from = at + 1;
      }
      finish();
    });

    for (final fullscreen in [false, true]) {
      testWidgets('an error slate\'s Try again comes before the player controls${fullscreen ? ' in fullscreen' : ''}', (tester) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const TestApp()));
        await tester.pumpAndSettle();
        openWatchIn(container, video('ratelimited1'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
        await tester.pumpAndSettle();
        expect(find.text('Try again'), findsOneWidget, reason: 'the slate is showing');
        if (fullscreen) {
          container.read(playerViewProvider.notifier).toggleFullscreen();
          for (var i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 400));
          }
        }

        // Named by what has focus: the button is found by its widget, since a name is the
        // nearest keyed ancestor's and the slate sits under the page's own key.
        final walk = <String>[];
        for (var i = 0; i < 40 && !walk.contains('player-mute'); i++) {
          await tabThrough(tester, 1);
          await tester.pump();
          final onTryAgain = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<ElevatedButton>() != null ||
              FocusManager.instance.primaryFocus?.context?.widget is ElevatedButton;
          walk.add(onTryAgain ? 'TRY-AGAIN' : focused());
        }
        final mute = walk.indexOf('player-mute');
        expect(walk.indexOf('TRY-AGAIN'), allOf(greaterThanOrEqualTo(0), lessThan(mute)), reason: 'Try again before the controls: $walk');
        finish();
      });
    }

    testWidgets('a queue row is named on the node that takes focus, and its handle on its own', (tester) async {
      final semantics = tester.ensureSemantics();
      await openWatch(tester, alsoQueue: ['vid-2']);
      expect(find.bySemanticsLabel('Video vid-1, Fake Channel, now playing'), findsOneWidget);
      expect(find.bySemanticsLabel('Video vid-2, Fake Channel'), findsOneWidget);

      // The handle's focus is on the handle's node, not on the row's: a screen reader reads the
      // focused node's name, and it used to read the whole row when the handle had focus.
      for (var i = 0; i < 80; i++) {
        await tabThrough(tester, 1);
        await tester.pump();
        final reorder = tester.getSemantics(find.bySemanticsLabel('Use the up and down arrows to reorder').first);
        if (reorder.getSemanticsData().flagsCollection.isFocused == Tristate.isTrue) break;
        expect(i, lessThan(79), reason: 'the handle took focus at some point');
      }
      final rows = tester.getSemantics(find.bySemanticsLabel('Video vid-1, Fake Channel, now playing'));
      expect(rows.getSemanticsData().flagsCollection.isFocused, isNot(Tristate.isTrue), reason: 'and the row does not claim it too');
      semantics.dispose();
      finish();
    });

    testWidgets('every tap target on the watch page has a label', (tester) async {
      final semantics = tester.ensureSemantics();
      await openWatch(tester, alsoQueue: ['vid-2']);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
      finish();
    });

    testWidgets('player, then the queue, then the metadata, then the related videos', (tester) async {
      await openWatch(tester, alsoQueue: ['vid-2', 'vid-3']);

      final all = await tabThrough(tester, 90);
      // One lap: from the first stop to the one before it comes round again.
      final walk = all.sublist(0, all.indexOf('Toggle menu', 1));

      final player = walk.indexOf('player-fullscreen');
      final queue = walk.indexOf('Collapse queue');
      final meta = walk.indexOf('Like');
      final related = walk.indexWhere((stop) => stop.endsWith('tile-more'));
      expect([player, queue, meta].every((i) => i >= 0), isTrue, reason: 'every surface has a stop: $walk');
      expect(player, lessThan(queue), reason: 'the queue comes after the player controls: $walk');
      expect(queue, lessThan(meta), reason: 'and before the metadata: $walk');
      // (The fake sidecar sends no related videos; where there are some they come last.)
      if (related >= 0) expect(meta, lessThan(related), reason: 'the related videos come last: $walk');

      // The queue's row buttons are stops too: Remove (shown on focus) after each row.
      expect(walk.where((stop) => stop == 'Remove').length, 3, reason: 'a Remove stop per queue row: $walk');

      // The queue is walked header (Clear, collapse), then each row — one group,
      // nothing from another surface in between.
      final queueStops = [for (var i = 0; i < walk.length; i++) if (walk[i] == 'Clear' || walk[i] == 'Collapse queue' || walk[i].startsWith('Video vid-')) i];
      expect(queueStops.last - queueStops.first + 1, queueStops.length, reason: 'queue stops interleaved with another surface: $walk');
      finish();
    });

    testWidgets('a hidden control bar is still the first stop, and reaching it shows it', (tester) async {
      await openWatch(tester);
      expect(barShowing(tester), isTrue);

      // Playing starts the countdown; one second later the bar is gone.
      engine.setPlaying(true);
      await tester.pump();
      await tester.pump(autoHideDelay + const Duration(seconds: 1));
      expect(barShowing(tester), isFalse, reason: 'the bar has auto-hidden');

      // Tab through the shell to the player. The bar used to be excluded from
      // focus while hidden, and Tab ran in the same key event that woke it, so the
      // walk skipped the controls and started at the queue.
      // Stepped without a key event on purpose: a real Tab also wakes the bar by
      // itself (`_onKey`), which would hide whether *focus* reveals it.
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
      var seen = <String>[];
      while (seen.length < 15 && !seen.contains('player-play-pause')) {
        (FocusManager.instance.primaryFocus ?? FocusManager.instance.rootScope).nextFocus();
        await tester.pump();
        seen.add(focused());
      }
      expect(seen, contains('player-play-pause'), reason: 'the hidden controls are reachable: $seen');
      await tester.pump(const Duration(milliseconds: 500));
      expect(barShowing(tester), isTrue, reason: 'and focusing one shows the bar');
      finish();
    });
  });

  group('the controls and the queue, from the keyboard', () {
    /// Tab until [name] has focus (a key event each time, which also wakes the bar).
    Future<void> tabTo(WidgetTester tester, String name, {int limit = 60}) async {
      for (var i = 0; i < limit; i++) {
        await tabThrough(tester, 1);
        if (focused() == name) return;
      }
      fail('never reached "$name"');
    }

    testWidgets('the controls bar stays up while a control has keyboard focus', (tester) async {
      await openWatch(tester);
      engine.setPlaying(true);
      await tabTo(tester, 'player-play-pause');

      // Well past the hide delay, and the bar is still there.
      await tester.pump(autoHideDelay + const Duration(seconds: 3));
      expect(barShowing(tester), isTrue, reason: 'a focused control keeps the bar open');
      expect(focused(), 'player-play-pause');

      // Focus leaves the bar; now it hides as before.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.pump(autoHideDelay + const Duration(seconds: 1));
      expect(barShowing(tester), isFalse, reason: 'and hides once focus is gone');
      finish();
    });

    testWidgets('the bar stays up at every stop of the controls, not just the first', (tester) async {
      await openWatch(tester);
      engine.setPlaying(true);
      await tabTo(tester, 'player-play-pause');
      final seen = <String>[];
      for (var i = 0; i < 12; i++) {
        await tester.pump(autoHideDelay + const Duration(seconds: 2));
        seen.add('${focused()}:${barShowing(tester)}');
        expect(barShowing(tester), isTrue, reason: 'the bar closed at stop $i after $seen');
        await tabThrough(tester, 1);
        if (focused() == 'player-fullscreen') break;
      }
      finish();
    });

    testWidgets('a click, then Tab: the bar stays up for the keyboard selection', (tester) async {
      await openWatch(tester);
      engine.setPlaying(true);
      await tester.pump();
      // A real mouse click on Pause leaves focus on it, in touch mode.
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(playerPlayPauseKey)), kind: PointerDeviceKind.mouse);
      await gesture.up();
      await tester.pump();
      await tabThrough(tester, 1);
      await tester.pump(autoHideDelay + const Duration(seconds: 3));
      expect(barShowing(tester), isTrue, reason: 'Tab after a click is keyboard navigation again');
      finish();
    });

    testWidgets('Tab onto the speaker opens the volume slider, the next Tab lands on it, arrows change the volume', (tester) async {
      await openWatch(tester);
      await tabTo(tester, 'player-mute');
      await tester.pump(const Duration(milliseconds: 300));

      final slider = find.descendant(of: find.byKey(playerVolumeSliderKey), matching: find.byType(VolumeBar));
      expect(slider, findsOneWidget, reason: 'focusing the speaker opens the slider');

      await tabThrough(tester, 1);
      final onSlider = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<VolumeBar>() != null;
      expect(onSlider, isTrue, reason: 'the next Tab lands on the slider itself');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(engine.volumes, isNotEmpty, reason: 'an arrow key moved the slider, not the seek shortcut');
      finish();
    });

    testWidgets('the settings menu opens from the keyboard, holds Tab inside, and Escape gives focus back', (tester) async {
      await openWatch(tester);
      await tabTo(tester, 'Settings');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(playerMenuProvider).open, isTrue);
      expect(_inScope('player settings menu'), isTrue, reason: 'opening moves focus into the menu');

      final walk = await tabThrough(tester, 10);
      expect(_inScope('player settings menu'), isTrue, reason: 'Tab stays inside it: $walk');
      expect(walk, isNot(contains('Settings')));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(container.read(playerMenuProvider).open, isFalse);
      await tester.pumpAndSettle(); // the fade runs out and the menu unmounts
      expect(find.byKey(settingsMenuPanelKey), findsNothing, reason: 'the menu is gone');
      expect(_inScope('player settings menu'), isFalse);
      finish();
    });

    testWidgets('a queue row shows Remove on focus, and its handle reorders with the arrow keys', (tester) async {
      await openWatch(tester, alsoQueue: ['vid-2', 'vid-3']);
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);

      List<String> order() => container.read(queueProvider).entries.map((e) => e.item.id).toList();
      expect(order(), ['vid-1', 'vid-2', 'vid-3']);

      // The second row's handle takes focus; ArrowDown moves the row down one, and
      // the player's volume shortcut stays out of it.
      final handles = find.byIcon(Icons.drag_handle);
      expect(handles, findsNWidgets(3));
      Focus.of(tester.element(handles.at(1))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 300));
      expect(order(), ['vid-1', 'vid-3', 'vid-2'], reason: 'the row moved down one place');
      expect(engine.volumes, isEmpty, reason: 'the arrow key was not the player\'s volume shortcut');

      // And the handle still has focus, so another press keeps moving it.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 300));
      expect(order(), ['vid-1', 'vid-2', 'vid-3'], reason: 'focus stayed on the handle through the move');
      finish();
    });
  });

  group('shortcuts and focus agree', () {
    testWidgets('a shortcut never fires while a text field has focus', (tester) async {
      await openWatch(tester);
      engine.setPlaying(true);

      var seen = <String>[];
      while (seen.length < 12 && (seen.isEmpty || seen.last != 'field')) {
        seen += await tabThrough(tester, 1);
      }
      expect(seen.last, 'field');

      for (final key in [LogicalKeyboardKey.keyK, LogicalKeyboardKey.keyM, LogicalKeyboardKey.keyF, LogicalKeyboardKey.space]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pump();
      expect(engine.playing, isTrue, reason: 'k and space did not pause it');
      expect(engine.volumes, isEmpty, reason: 'm did not mute it');
      expect(container.read(playerViewProvider).fullscreen, isFalse, reason: 'f did not go fullscreen');
      finish();
    });

    testWidgets('a focused button does not swallow a shortcut', (tester) async {
      await openWatch(tester);
      engine.setPlaying(true);

      var seen = <String>[];
      while (seen.length < 40 && (seen.isEmpty || seen.last != 'Like')) {
        seen += await tabThrough(tester, 1);
      }
      expect(seen.last, 'Like', reason: 'focus is on a button: $seen');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(engine.playing, isFalse, reason: 'k paused it with a button focused');
      finish();
    });

    testWidgets('Space presses a control the keyboard walked onto, instead of pausing', (tester) async {
      await openWatch(tester);
      engine.setPlaying(true);

      var seen = <String>[];
      while (seen.length < 40 && (seen.isEmpty || seen.last != 'player-mute')) {
        seen += await tabThrough(tester, 1);
      }
      expect(seen.last, 'player-mute');

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(engine.playing, isTrue, reason: 'Space did not also pause');
      expect(engine.volumes, isNotEmpty, reason: 'Space pressed the focused Mute button');
      finish();
    });

    testWidgets('Space after a mouse click still pauses', (tester) async {
      await openWatch(tester);
      engine.setPlaying(true);

      // A click leaves the button focused, and Space after a click has always
      // meant pause — only a keyboard-reached focus yields it.
      await tester.tap(find.text('Fake Channel').first);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(engine.playing, isFalse);
      finish();
    });
  });

  group('fullscreen and the miniplayer', () {
    testWidgets('the miniplayer is the first Tab stop of a page, and Tab flows in and out of it', (tester) async {
      testHome = () => const PageWrapper(title: Text('Home'), body: SizedBox.shrink());
      addTearDown(() => testHome = () => const Scaffold(body: SizedBox.shrink()));
      await openWatch(tester);
      toMiniPlayerIn(container);
      await tester.pumpAndSettle();
      expect(find.text('Video vid-1'), findsOneWidget, reason: 'the miniplayer is showing');

      // The miniplayer is the first stop *of the page content*: after the title bar, rail,
      // search and account, not before them.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final before = <String>[];
      for (var i = 0; i < 14 && !_inScope('miniplayer'); i++) {
        await tabThrough(tester, 1);
        await tester.pump();
        if (!_inScope('miniplayer')) before.add(focused());
      }
      expect(before.first, 'Toggle menu', reason: 'the title bar still comes first: $before');
      expect(before, containsAll(['home', 'field', '@tester']), reason: 'and the rail, search and account: $before');
      expect(_inScope('miniplayer'), isTrue, reason: 'then the miniplayer: $before');

      // Its controls, then off the end of them into the page: the title bar.
      final walk = <String>[];
      for (var i = 0; i < 6 && _inScope('miniplayer'); i++) {
        walk.add(focused());
        await tabThrough(tester, 1);
        await tester.pump();
      }
      expect(walk, contains('Close'), reason: 'the button is reachable and named: $walk');
      expect(walk, contains('Video vid-1'), reason: 'and so is the open area: $walk');
      expect(_inScope('miniplayer'), isFalse, reason: 'Tab off the last control returns to the page');
      expect(focused(), 'Toggle menu', reason: 'the page continues at its first stop');

      // Shift+Tab from there goes back into the miniplayer, at its last control.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await tester.pump();
      expect(_inScope('miniplayer'), isTrue, reason: 'Shift+Tab from the first page stop re-enters it');
      expect(focused(), 'Close');

      // F6 still moves in and back.
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await tester.pump();
      expect(_inScope('miniplayer'), isFalse, reason: 'F6 gives focus back');
      finish();
    });

    for (final hidden in [true, false]) {
      testWidgets('fullscreen with the queue ${hidden ? 'closed' : 'open'}: progress bar, controls, queue toggle${hidden ? '' : ', then the queue'}', (tester) async {
        await openWatch(tester, alsoQueue: ['vid-2', 'vid-3']);
        await container.read(audioModeProvider.notifier).setMode(true);
        await container.read(hideQueueProvider.notifier).setMode(hidden);
        container.read(playerViewProvider.notifier).toggleFullscreen();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump(const Duration(milliseconds: 600));

        final walk = <String>[];
        for (var i = 0; i < 40; i++) {
          await tabThrough(tester, 1);
          await tester.pump();
          walk.add(focused());
          if (walk.length > 2 && walk.first == walk.last && walk.length > 6) break;
        }
        // One lap, from the first stop to where it comes round again.
        final lap = walk.sublist(0, walk.indexOf(walk.first, 1) < 0 ? walk.length : walk.indexOf(walk.first, 1));
        final toggle = lap.indexWhere((n) => n == 'Show queue' || n == 'Hide queue');
        expect(lap.first, 'player-scrubber', reason: 'the progress bar first: $lap');
        expect(toggle, greaterThan(lap.indexOf('player-fullscreen')), reason: 'the queue toggle after the controls: $lap');
        expect(toggle, isNot(-1), reason: 'and the toggle is reachable: $lap');
        if (hidden) {
          expect(lap.length, toggle + 1, reason: 'a hidden queue holds no stops: $lap');
        } else {
          expect(lap.length, greaterThan(toggle + 1), reason: 'an open queue follows its toggle: $lap');
        }
        finish();
      });
    }

    testWidgets('entering fullscreen puts focus in the player, Tab stays in, leaving puts it back', (tester) async {
      await openWatch(tester);

      // Focus something on the page first: the title bar's menu button.
      await tabThrough(tester, 1);
      expect(focused(), 'Toggle menu');

      container.read(playerViewProvider.notifier).toggleFullscreen();
      await tester.pump();
      await tester.pump();
      expect(_inScope('fullscreen player'), isTrue, reason: 'entering moves focus into the player');

      final walk = await tabThrough(tester, 20);
      expect(walk, isNot(contains('Toggle menu')), reason: 'the page behind it is not reachable');
      expect(walk, isNot(contains('Like')));
      expect(_inScope('fullscreen player'), isTrue);

      container.read(playerViewProvider.notifier).toggleFullscreen();
      await tester.pump();
      await tester.pump();
      expect(focused(), 'Toggle menu', reason: 'leaving puts focus back where it was');
      finish();
    });
  });
}

bool _inScope(String label) {
  final node = FocusManager.instance.primaryFocus;
  return node != null && (node.debugLabel == label || node.ancestors.any((a) => a.debugLabel == label));
}
