/// The sleep timer's fade, its end actions and its menu pages (Task 38, `architecture.md` §2.18).
///
/// **No sidecar.** Nothing here opens a video: a duration needs none, and the fade and the end
/// actions are the same for every kind. Fake time drives the timer's ticks, and the timer's own
/// clock is a value the test moves ([sleepClockProvider]).
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/audio_mode_controller.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/controls.dart';
import 'package:rill/ui/player/settings_menu.dart';
import 'package:rill/ui/player/shortcuts.dart' show textEntryHasFocus;
import 'package:rill/ui/player/sleep_timer_widgets.dart';
import 'package:rill/ui/sleep_timer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_engine.dart';
import 'sleep_timer_test.dart' show FakePower;

late FakeEngine engine;
late FakePower power;
late ProviderContainer container;
var clock = Duration.zero;

SleepTimerState get timer => container.read(sleepTimerProvider);
SleepTimerController get sleep => container.read(sleepTimerProvider.notifier);

void boot({bool canSleep = true, bool canHibernate = true}) {
  engine = FakeEngine();
  power = FakePower(canSleep: canSleep, canHibernate: canHibernate);
  clock = Duration.zero;
  container = ProviderContainer(overrides: [
    playbackEngineProvider.overrideWithValue(engine),
    sleepClockProvider.overrideWithValue(() => clock),
    systemPowerProvider.overrideWithValue(power),
  ]);
  container.read(playbackProvider);
  container.read(sleepTimerProvider);
}

/// A window with the countdown banner in it, and (when [menu]) the settings panel.
Future<void> pumpHost(WidgetTester tester, {bool menu = false}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildRillTheme(const Color(0xFF7C4DFF)),
        home: Scaffold(
          body: Stack(
            children: [
              if (menu) Align(alignment: Alignment.bottomRight, child: SizedBox(height: 700, child: PlayerSettingsMenu(onPicked: (_) {}))),
              const Align(alignment: Alignment.bottomLeft, child: SleepTimerIndicator()),
              const Positioned.fill(child: SleepCountdownBanner()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Playing, with a one-minute timer five seconds from its end: halfway down the fade.
Future<void> intoFade(WidgetTester tester) async {
  engine.setPlaying(true);
  sleep.startDuration(const Duration(minutes: 1));
  clock = const Duration(seconds: 55);
  await tester.pump(const Duration(milliseconds: 150));
  expect(timer.fading, isTrue);
  expect(engine.outputGain, closeTo(0.5, 0.02), reason: 'five of ten seconds left');
}

/// Back to the state a stopped fade leaves: control is the viewer's.
void expectHandedBack() {
  expect(timer.isOn, isFalse, reason: 'the timer turned off');
  expect(engine.outputGain, 1, reason: 'the volume went straight back');
  expect(engine.playing, isTrue, reason: 'nothing paused');
  expect(power.runs, isEmpty, reason: 'and no end action ran');
}

/// Moves the clock well past where the stopped timer would have ended, to show nothing fires late.
Future<void> runPastTheEnd(WidgetTester tester) async {
  clock = const Duration(minutes: 5);
  await tester.pump(const Duration(seconds: 1));
  expect(engine.playing, isTrue);
  expect(container.read(sleepNoteProvider), isNull);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    boot();
  });
  tearDown(() => container.dispose());

  group('the fade', () {
    testWidgets('fades the output and never the setting', (tester) async {
      await pumpHost(tester);
      await engine.setVolume(80);
      engine.volumes.clear();
      await intoFade(tester);
      clock = const Duration(seconds: 58);
      await tester.pump(const Duration(milliseconds: 150));
      expect(engine.outputGain, closeTo(0.2, 0.02));
      expect(engine.volume, 80, reason: 'the setting is untouched');
      expect(engine.volumes, isEmpty, reason: 'the fade never set a volume');
      sleep.off();
    });

    testWidgets('the volume is restored the moment playback pauses, and the fade picks up on play', (tester) async {
      await pumpHost(tester);
      await intoFade(tester);
      // A pause that is not input in Rill's window — a media key, the taskbar button.
      // MUTATION 3: drop the `if (!...playing) return 1;` in `_targetGain` and this fails: the
      // output stays at half while paused, and the next play starts quiet.
      engine.setPlaying(false);
      await tester.pump();
      expect(engine.outputGain, 1, reason: 'restored at once, before any tick');
      expect(timer.isOn, isTrue, reason: 'a pause from outside the window is not the viewer waking it');

      engine.setPlaying(true);
      await tester.pump(const Duration(milliseconds: 150));
      expect(engine.outputGain, closeTo(0.5, 0.02), reason: 'the fade goes on from where the clock is');
      sleep.off();
    });

    testWidgets('when it runs out it pauses, restores the volume, turns off and says so', (tester) async {
      await pumpHost(tester);
      await intoFade(tester);
      clock = const Duration(seconds: 61);
      await tester.pump(const Duration(milliseconds: 150));
      expect(engine.playing, isFalse);
      expect(engine.outputGain, 1, reason: 'never silent at the next play');
      expect(timer.isOn, isFalse);
      expect(container.read(sleepNoteProvider), 'Sleep timer: paused');
      await tester.pump(const Duration(seconds: 6));
      expect(container.read(sleepNoteProvider), isNull, reason: 'a short note');
    });

    // MUTATION 4: make `_interrupted` restore the gain without calling `off()` and the four tests
    // below fail on "the timer turned off" — and then fire at the old deadline.
    testWidgets('a key press during it stops it', (tester) async {
      await pumpHost(tester);
      await intoFade(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expectHandedBack();
      await runPastTheEnd(tester);
    });

    testWidgets('a click during it stops it', (tester) async {
      await pumpHost(tester);
      await intoFade(tester);
      await tester.tapAt(const Offset(500, 300));
      await tester.pump();
      expectHandedBack();
      await runPastTheEnd(tester);
    });

    testWidgets('a scroll during it stops it', (tester) async {
      await pumpHost(tester);
      await intoFade(tester);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(500, 300)));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
      await tester.pump();
      expectHandedBack();
      await runPastTheEnd(tester);
    });

    testWidgets('a volume change during it stops it, and the new volume stands', (tester) async {
      await pumpHost(tester);
      await intoFade(tester);
      await container.read(playbackProvider.notifier).setVolume(40);
      await tester.pump();
      expectHandedBack();
      expect(engine.volume, 40);
      await runPastTheEnd(tester);
    });

    testWidgets('mouse movement alone does not stop it', (tester) async {
      await pumpHost(tester);
      await intoFade(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(100, 100));
      for (var x = 100.0; x < 600; x += 50) {
        await mouse.moveTo(Offset(x, x / 2));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(timer.isOn, isTrue);
      expect(timer.fading, isTrue);
      expect(engine.outputGain, lessThan(1));
      await mouse.removePointer();
      sleep.off();
    });

    testWidgets('input before the fade does not stop the timer', (tester) async {
      await pumpHost(tester);
      engine.setPlaying(true);
      sleep.startDuration(const Duration(minutes: 1));
      clock = const Duration(seconds: 20);
      await tester.pump(const Duration(milliseconds: 150));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.tapAt(const Offset(500, 300));
      await tester.pump();
      expect(timer.isOn, isTrue);
      sleep.off();
    });
  });

  group('the end actions', () {
    /// A paused one-minute timer run out, so it fires at once.
    Future<void> fireWith(WidgetTester tester, SleepEndAction action) async {
      container.read(sleepEndActionProvider.notifier).set(action);
      sleep.startDuration(const Duration(minutes: 1));
      clock = const Duration(minutes: 2);
      await tester.pump(const Duration(milliseconds: 150));
      expect(timer.isOn, isFalse);
    }

    testWidgets('Do nothing calls nothing', (tester) async {
      await pumpHost(tester);
      await fireWith(tester, SleepEndAction.nothing);
      await tester.pump(const Duration(seconds: 40));
      expect(power.runs, isEmpty);
      expect(find.byKey(sleepCountdownKey), findsNothing);
    });

    testWidgets('Close Rill runs at once, with no countdown', (tester) async {
      await pumpHost(tester);
      await fireWith(tester, SleepEndAction.closeRill);
      await tester.pump();
      expect(power.runs, [SleepEndAction.closeRill]);
      expect(find.byKey(sleepCountdownKey), findsNothing);
      await tester.pump(const Duration(seconds: 6)); // the note's own timer
    });

    for (final action in [SleepEndAction.sleep, SleepEndAction.hibernate, SleepEndAction.shutDown, SleepEndAction.restart]) {
      testWidgets('${action.label} waits out the 30 s countdown, then calls the fake with ${action.name}', (tester) async {
        await pumpHost(tester);
        await fireWith(tester, action);
        await tester.pump();
        expect(find.byKey(sleepCountdownKey), findsOneWidget);
        expect(find.text('${container.read(sleepEndProvider)!.verb} in 30 s'), findsOneWidget);
        await tester.pump(const Duration(seconds: 29));
        expect(power.runs, isEmpty, reason: 'not before the countdown is out');
        await tester.pump(const Duration(seconds: 1));
        expect(power.runs, [action]);
        await tester.pump();
        expect(find.byKey(sleepCountdownKey), findsNothing);
      });
    }

    testWidgets("the countdown's Cancel stops the action", (tester) async {
      await pumpHost(tester);
      await fireWith(tester, SleepEndAction.shutDown);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Shutting down in 25 s'), findsOneWidget);
      await tester.tap(find.byKey(sleepCountdownCancelKey));
      await tester.pump();
      expect(find.byKey(sleepCountdownKey), findsNothing);
      await tester.pump(const Duration(seconds: 40));
      expect(power.runs, isEmpty);
    });

    testWidgets('Escape cancels it too, from anywhere', (tester) async {
      await pumpHost(tester);
      await fireWith(tester, SleepEndAction.restart);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(seconds: 40));
      expect(power.runs, isEmpty);
      expect(find.byKey(sleepCountdownKey), findsNothing);
    });

    testWidgets('the countdown takes focus for its Cancel, and gives it back when it ends', (tester) async {
      final before = FocusNode(debugLabel: 'before');
      addTearDown(before.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  TextButton(focusNode: before, onPressed: () {}, child: const Text('elsewhere')),
                  const Expanded(child: SleepCountdownBanner()),
                ],
              ),
            ),
          ),
        ),
      );
      before.requestFocus();
      await tester.pump();
      container.read(sleepEndProvider.notifier).begin(SleepEndAction.sleep);
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'sleep countdown cancel');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(sleepCountdownKey), findsNothing);
      expect(before.hasFocus, isTrue, reason: 'focus went back where it was');
      await tester.pump(const Duration(seconds: 40));
      expect(power.runs, isEmpty);
    });

    testWidgets('the choice is not remembered by a new run of Rill', (tester) async {
      container.read(sleepEndActionProvider.notifier).set(SleepEndAction.shutDown);
      container.dispose();
      boot();
      expect(container.read(sleepEndActionProvider), SleepEndAction.nothing);
    });
  });

  group('the menu', () {
    Future<void> openAt(WidgetTester tester, SettingsPage page) async {
      container.read(playerMenuProvider.notifier).go(page);
      await pumpHost(tester, menu: true);
      await tester.pumpAndSettle();
    }

    testWidgets('Sleep and Hibernate are offered only when the system allows them', (tester) async {
      container.dispose();
      boot(canSleep: false, canHibernate: false);
      await openAt(tester, SettingsPage.sleepTimerAction);
      expect(find.text('Do nothing'), findsOneWidget);
      expect(find.text('Close Rill'), findsOneWidget);
      expect(find.text('Sleep'), findsNothing);
      expect(find.text('Hibernate'), findsNothing);
      expect(find.text('Shut down'), findsOneWidget);
      expect(find.text('Restart'), findsOneWidget);
    });

    testWidgets('and shown when it does; picking one goes back and the root row says it', (tester) async {
      await openAt(tester, SettingsPage.sleepTimerAction);
      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('Hibernate'), findsOneWidget);
      await tester.tap(find.text('Sleep'));
      await tester.pumpAndSettle();
      expect(container.read(sleepEndActionProvider), SleepEndAction.sleep);
      expect(container.read(playerMenuProvider).page, SettingsPage.sleepTimer);
      expect(find.text('When it ends: Sleep'), findsOneWidget);

      await tester.tap(find.text('5 minutes'));
      await tester.pumpAndSettle();
      expect(timer.total, const Duration(minutes: 5));
      container.read(playerMenuProvider.notifier).go(SettingsPage.root);
      await tester.pumpAndSettle();
      expect(find.text('5:00 · then Sleep'), findsOneWidget);
      sleep.off();
    });

    testWidgets('the timer page lists its choices in order, ticks the current one, and Off stops it', (tester) async {
      await openAt(tester, SettingsPage.sleepTimer);
      final labels = ['Off', '1 minute', '2 minutes', '5 minutes', '10 minutes', '15 minutes', '30 minutes', '45 minutes', '60 minutes', 'End of video', 'Custom…'];
      var last = -1.0;
      for (final label in labels) {
        final y = tester.getTopLeft(find.text(label)).dy;
        expect(y, greaterThan(last), reason: '$label in order');
        last = y;
      }
      expect(find.text('End of chapter'), findsNothing, reason: 'nothing open has chapters');

      Color? tickOf(String label) {
        final row = find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;
        return tester.widget<Icon>(find.descendant(of: row, matching: find.byIcon(Icons.check))).color;
      }

      expect(tickOf('Off'), isNot(Colors.transparent));
      await tester.tap(find.text('15 minutes'));
      await tester.pumpAndSettle();
      expect(timer.total, const Duration(minutes: 15));
      expect(container.read(playerMenuProvider).open, isFalse, reason: 'a pick closes the menu, as a quality pick does');

      container.read(playerMenuProvider.notifier).go(SettingsPage.sleepTimer);
      await tester.pumpAndSettle();
      expect(tickOf('15 minutes'), isNot(Colors.transparent));
      expect(tickOf('Off'), Colors.transparent);
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      expect(timer.isOn, isFalse);
    });

    testWidgets('Custom: a typed duration starts on Enter, and the next Custom opens on it', (tester) async {
      await openAt(tester, SettingsPage.sleepTimerCustom);
      await tester.tap(find.byKey(sleepCustomMinutesKey));
      await tester.pump();
      expect(textEntryHasFocus(), isTrue, reason: 'the field takes focus, which is what holds the player shortcuts off');
      await tester.enterText(find.byKey(sleepCustomMinutesKey), '0');
      await tester.enterText(find.byKey(sleepCustomSecondsKey), '30');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(timer.kind, SleepKind.duration);
      expect(timer.total, const Duration(seconds: 30));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(SleepCustomValues.secondsKey), 30, reason: 'remembered');
      sleep.off();
      container.read(playerMenuProvider.notifier).go(SettingsPage.sleepTimerCustom);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(sleepCustomMinutesKey)).controller!.text, '0');
      expect(tester.widget<TextField>(find.byKey(sleepCustomSecondsKey)).controller!.text, '30');
    });

    testWidgets('Custom: out of range is refused, and Escape in a field goes back a page', (tester) async {
      await openAt(tester, SettingsPage.sleepTimerCustom);
      await tester.enterText(find.byKey(sleepCustomMinutesKey), '0');
      await tester.enterText(find.byKey(sleepCustomSecondsKey), '0');
      await tester.tap(find.byKey(sleepCustomStartKey));
      await tester.pumpAndSettle();
      expect(timer.isOn, isFalse, reason: '0:00 is not a timer');
      expect(find.text('From 0:01 to 23:59:59'), findsOneWidget);

      await tester.tap(find.byKey(sleepCustomSecondsKey));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(container.read(playerMenuProvider).page, SettingsPage.sleepTimer);
      expect(container.read(playerMenuProvider).open, isTrue, reason: 'back a page, not closed');
    });

    testWidgets('Custom: after N videos, with the stepper', (tester) async {
      await openAt(tester, SettingsPage.sleepTimerCustom);
      expect(find.text('After chapters'), findsNothing, reason: 'nothing open has chapters');
      await tester.tap(find.byKey(const ValueKey('sleep-videos-more')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byKey(const ValueKey('sleep-videos-more')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('sleep-videos-value')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('sleep-videos-value'))).data, '4');
      await tester.tap(find.byKey(sleepCustomVideosStartKey));
      await tester.pumpAndSettle();
      expect(timer.kind, SleepKind.videos);
      expect(timer.target, 4);
      sleep.off();
    });

    testWidgets('Custom: a stepper button stays enabled at its limit, so it keeps the focus of a keyboard user', (tester) async {
      await openAt(tester, SettingsPage.sleepTimerCustom);
      final fewer = find.byKey(const ValueKey('sleep-videos-fewer'));
      await tester.tap(fewer);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<Text>(find.byKey(const ValueKey('sleep-videos-value'))).data, '1');
      // MUTATION: put back `onPressed: value > 1 ? ... : null` and this fails: disabled at 1, the
      // button drops the focus of whoever pressed it down there.
      expect(tester.widget<IconButton>(fewer).onPressed, isNotNull);
      await tester.tap(fewer);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<Text>(find.byKey(const ValueKey('sleep-videos-value'))).data, '1', reason: 'the press at the limit does nothing');
    });

    testWidgets('the root row says the time left in words, not digits', (tester) async {
      final semantics = tester.ensureSemantics();
      sleep.startDuration(const Duration(minutes: 12, seconds: 34));
      await openAt(tester, SettingsPage.root);
      expect(find.text('12:34'), findsWidgets, reason: 'shown as a clock');
      expect(find.bySemanticsLabel(RegExp('12 minutes and 34 seconds left')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp(r'12:34')), findsNothing, reason: 'never read as digits');
      sleep.off();
      semantics.dispose();
    });
  });

  group('the moon', () {
    testWidgets('shows the time left for a countdown, alone for the other kinds, and nothing when off', (tester) async {
      await pumpHost(tester);
      expect(find.byKey(sleepTimerIndicatorKey), findsNothing);
      sleep.startDuration(const Duration(minutes: 12, seconds: 34));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('12:34'), findsOneWidget);
      sleep.endOfVideo();
      await tester.pump();
      expect(find.byKey(sleepTimerIndicatorKey), findsOneWidget);
      expect(find.byIcon(Icons.bedtime), findsOneWidget);
      expect(find.text('12:34'), findsNothing);
      sleep.off();
      await tester.pump();
      expect(find.byKey(sleepTimerIndicatorKey), findsNothing);
    });
  });

  // A `RenderFlex` overflow is silent in a release build: controls cut off past the edge. Every other
  // layout test runs with the timer off, where the moon takes no width.
  group('the bars with the moon showing', () {
    Future<void> pumpBar(WidgetTester tester, Size size, {double? aspect}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildRillTheme(const Color(0xFF7C4DFF)),
            home: Scaffold(body: SizedBox.expand(child: PlayerControls(engine: engine, actualAspectRatio: aspect))),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
    }

    for (final (name, size, aspect, audio) in [
      ('normal bar, compact', const Size(560, 315), null, false),
      ('normal bar, just under the compact threshold', const Size(639, 360), null, false),
      ('normal bar, wide', const Size(1000, 560), null, false),
      ('audio-only bar, compact', const Size(560, 315), null, true),
      ('vertical bar, narrow', const Size(300, 534), 0.5625, false),
    ]) {
      testWidgets('$name: no overflow with an hour-long countdown', (tester) async {
        if (audio) await container.read(audioModeProvider.notifier).setMode(true);
        sleep.startDuration(const Duration(hours: 1, minutes: 2, seconds: 3));
        await pumpBar(tester, size, aspect: aspect);
        expect(find.byKey(sleepTimerIndicatorKey), findsOneWidget);
        // The vertical bar shows the moon alone; the others show the time.
        expect(find.text('1:02:03'), aspect == null ? findsOneWidget : findsNothing);
        expect(tester.takeException(), isNull);
        sleep.off();
        await tester.pump();
      });
    }
  });

}
