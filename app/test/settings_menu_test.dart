/// The player's settings menu, end to end — state machine, pages, transitions.
///
/// **No sidecar.** Every test here runs against an overridden `playbackProvider`
/// and a `FakeEngine`, so it needs neither `bun` nor `fake_sidecar.ts` and runs
/// under a plain `flutter test`.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/playback_source.dart';
import 'package:silky_scroll/silky_scroll.dart';

import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/settings_menu.dart';

import 'fake_engine.dart';

PlaybackVariant v(int height, int fps) => PlaybackVariant(
  videoUrl: 'https://example.invalid/$height',
  height: height,
  fps: fps,
  videoCodec: 'avc1',
  audioCodec: 'mp4a',
);

// A long ladder, the shape the F-series measurements found on a real video.
final ladder = [
  for (final h in [2160, 1440, 1080, 1080, 720, 720, 480, 360, 240, 144]) v(h, h >= 720 ? 60 : 30),
  for (final h in [2160, 1440, 1080, 720, 480, 360, 240, 144]) v(h, h >= 720 ? 60 : 30),
];

class FakePlayback extends PlaybackController {
  @override
  PlaybackState build() => PlaybackState(
    source: PlaybackSource(sessionId: 's', durationMs: 100000, variants: ladder),
    variant: ladder[2],
  );
}

const rootPlaceholders = ['Sleep timer', 'Audio track', 'Subtitle track / CC', 'Playback speed'];
const morePlaceholders = ['Audio channel', 'Sticky player', 'Annotations', 'Ambient mode'];

late ProviderContainer container;

Widget host({ValueChanged<PlaybackVariant>? onPicked, double maxHeight = 900}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildRillTheme(const Color(0xFF7C4DFF)),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: maxHeight,
              child: PlayerSettingsMenu(onPicked: onPicked ?? (_) {}),
            ),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    container = ProviderContainer(
      overrides: [
        playbackProvider.overrideWith(FakePlayback.new),
        playbackEngineProvider.overrideWithValue(FakeEngine()),
      ],
    );
  });
  tearDown(() => container.dispose());

  group('the state machine', () {
    test('each button toggles its own page rather than the menu', () {
      final menu = container.read(playerMenuProvider.notifier);

      menu.toggleAt(SettingsPage.root);
      expect(container.read(playerMenuProvider),
          const PlayerMenuState(open: true, page: SettingsPage.root));

      // The quality button over an open settings list means "show me quality",
      // not "go away".
      menu.toggleAt(SettingsPage.quality);
      expect(container.read(playerMenuProvider),
          const PlayerMenuState(open: true, page: SettingsPage.quality));

      // And over its own page it means the second thing.
      menu.toggleAt(SettingsPage.quality);
      expect(container.read(playerMenuProvider).open, isFalse);
    });

    test('every open starts at the page asked for, whatever it was left on', () {
      final menu = container.read(playerMenuProvider.notifier);
      menu.toggleAt(SettingsPage.root);
      menu.go(SettingsPage.moreOptions);
      menu.close();

      // The page deliberately survives the close — the panel is still fading and
      // is still reading this, so resetting here would flash the root list on the
      // way out. The reset is on the way *in*.
      expect(container.read(playerMenuProvider).page, SettingsPage.moreOptions);

      menu.toggleAt(SettingsPage.root);
      expect(container.read(playerMenuProvider),
          const PlayerMenuState(open: true, page: SettingsPage.root),
          reason: 'reopening must not land on the subpage it was left in');
    });

    test('back walks out of More options only', () {
      final menu = container.read(playerMenuProvider.notifier);

      menu.go(SettingsPage.moreOptions);
      expect(menu.back(), isTrue);
      expect(container.read(playerMenuProvider),
          const PlayerMenuState(open: true, page: SettingsPage.root),
          reason: 'back leaves the menu open — it is not a close');

      expect(menu.back(), isFalse, reason: 'nothing above the root');

      // Quality is a top level of its own, reached from its own button.
      menu.go(SettingsPage.quality);
      expect(menu.back(), isFalse, reason: 'quality is not under the root');
      expect(container.read(playerMenuProvider).page, SettingsPage.quality);
    });
  });

  group('the root page', () {
    testWidgets('is More options over a divider; only it navigates', (tester) async {
      container.read(playerMenuProvider.notifier).open();
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.text('More options'), findsOneWidget);
      for (final label in rootPlaceholders) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Quality'), findsNothing, reason: 'quality left for its own button');
      expect(find.byType(Divider), findsOneWidget);

      // More options is above the divider; every setting is below it.
      final divider = tester.getTopLeft(find.byType(Divider)).dy;
      expect(tester.getTopLeft(find.text('More options')).dy, lessThan(divider));
      for (final label in rootPlaceholders) {
        expect(tester.getTopLeft(find.text(label)).dy, greaterThan(divider));
      }

      // **Asserted by what a tap does, not by whether `onTap` is null.**
      // Whether a placeholder is drawn dimmed-and-dead or live-but-inert is a
      // design call and has changed once already; that it goes nowhere is the
      // part worth pinning.
      for (final label in rootPlaceholders) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(container.read(playerMenuProvider).page, SettingsPage.root,
            reason: '$label is a placeholder and must not navigate');
      }
      await tester.tap(find.byKey(playerSettingsMoreRowKey));
      await tester.pumpAndSettle();
      expect(container.read(playerMenuProvider).page, SettingsPage.moreOptions);
    });

    testWidgets('morphs into More options and back, header sticky', (tester) async {
      container.read(playerMenuProvider.notifier).open();
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final rootSize = tester.getSize(find.byKey(settingsMenuPanelKey));

      await tester.tap(find.byKey(playerSettingsMoreRowKey));
      await tester.pumpAndSettle();
      final moreSize = tester.getSize(find.byKey(settingsMenuPanelKey));

      expect(moreSize.width, rootSize.width, reason: 'one width for every page');
      // No claim about the height *changing*: these two pages happen to be the
      // same length, and whether they are is a content decision. The panel's
      // resize is pinned on the root/quality pair instead, where the difference
      // is structural — see 'the panel resizes alongside the slide'.
      for (final label in morePlaceholders) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.byKey(playerSettingsBackKey), findsOneWidget);

      await tester.tap(find.byKey(playerSettingsBackKey));
      await tester.pumpAndSettle();
      expect(find.text('More options'), findsOneWidget);
      expect(tester.getSize(find.byKey(settingsMenuPanelKey)), rootSize);
    });
  });

  /// A page-sized `SilkyListView` with the menu pinned at the top of it, which
  /// is the arrangement the watch page actually has.
  Future<ScrollController> pumpOverPage(WidgetTester tester, {bool menu = true}) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildRillTheme(const Color(0xFF7C4DFF)),
          home: Scaffold(
            body: SilkyListView(
              controller: outer,
              children: [
                // First, so it is on screen at offset zero — a list culls
                // children below the viewport and the panel would not be built.
                SizedBox(
                  height: 520,
                  child: menu
                      ? Consumer(
                          builder: (context, ref, _) => SettingsMenuFade(
                            visible: ref.watch(playerMenuProvider.select((m) => m.open)),
                            child: PlayerSettingsMenu(onPicked: (_) {}),
                          ),
                        )
                      : const SizedBox.expand(),
                ),
                const SizedBox(height: 4000),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return outer;
  }

  Future<void> wheelAt(WidgetTester tester, Offset where, {int times = 5}) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(where));
    for (var i = 0; i < times; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle(
        const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
  }

  group('the wheel over a panel', () {
    // **The outer list must be a `SilkyListView`, not a `ListView`.** An earlier
    // version of these used a plain `ListView` and passed against a fix that did
    // nothing in the real app — `SilkyScroll` handles a vertical wheel straight
    // from its own `Listener` and never consults the `pointerSignalResolver`, so
    // a resolver claim stops a Flutter `Scrollable` and is invisible to the
    // page. The control has to be the widget the watch page actually uses.

    testWidgets('does not reach the page, over the list or the header', (tester) async {
      container.read(playerMenuProvider.notifier).go(SettingsPage.quality);
      final outer = await pumpOverPage(tester);

      // Over the ladder — covered by the list being a `SilkyScroll`.
      await wheelAt(tester, tester.getRect(find.text('480p')).center);
      expect(outer.offset, 0, reason: 'the page must not move under the list');

      // Over the sticky header — outside the scroll view, and the case that was
      // still leaking after the list was fixed.
      await wheelAt(tester, tester.getRect(find.text('Quality')).center);
      expect(outer.offset, 0, reason: 'the page must not move under the header either');
    });

    testWidgets('passes through when the panel has nothing to scroll', (tester) async {
      // A list shorter than its own box cannot move, so blocking the page gives
      // a wheel that does nothing anywhere — which reads as a hang, not as a
      // boundary. Narrower than "at the edge": a list that *can* scroll and has
      // been driven to its end still holds.
      container.read(playerMenuProvider.notifier).open();
      final outer = await pumpOverPage(tester);

      // The root page fits entirely — no scroll extent.
      final scrollable = find.descendant(
        of: find.byKey(settingsMenuPanelKey),
        matching: find.byType(Scrollable),
      );
      expect(
        tester.state<ScrollableState>(scrollable.first).position.maxScrollExtent,
        0,
        reason: 'this test is only meaningful while the root page fits',
      );

      await wheelAt(tester, tester.getRect(find.text('Sleep timer')).center);
      expect(outer.offset, greaterThan(0), reason: 'the page takes it instead');
    });

    testWidgets('starts holding again once the page it shows can scroll', (tester) async {
      // And the reverse, under a stationary pointer: walking from the settings
      // list to the quality ladder turns a panel with nothing to scroll into one
      // with plenty. That is a metrics change without a scroll, which is what
      // the `ScrollMetricsNotification` listener is for.
      final menu = container.read(playerMenuProvider.notifier);
      menu.open();
      final outer = await pumpOverPage(tester);

      final over = tester.getRect(find.byKey(settingsMenuPanelKey)).center;
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(over));
      await tester.pumpAndSettle();

      menu.go(SettingsPage.quality);
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(find.descendant(
          of: find.byKey(settingsMenuPanelKey),
          matching: find.byType(Scrollable),
        ).first).position.maxScrollExtent,
        greaterThan(0),
      );

      final before = outer.offset;
      for (var i = 0; i < 5; i++) {
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pumpAndSettle(
          const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      expect(outer.offset, before, reason: 'the ladder can scroll, so the panel holds again');
    });

    testWidgets('still reaches the page everywhere else', (tester) async {
      container.read(playerMenuProvider.notifier).open();
      final outer = await pumpOverPage(tester);
      final panel = tester.getRect(find.byKey(settingsMenuPanelKey));

      await wheelAt(tester, Offset(20, panel.center.dy));
      expect(outer.offset, greaterThan(0), reason: 'nothing was over-claimed');
    });

    testWidgets('a panel closed under the cursor does not strand the page', (tester) async {
      // The failure mode a hover flag or a hover count has to be designed
      // against: `MouseRegion.onExit` may never fire for a region unmounted with
      // the pointer inside it, and a key left on silky_scroll's stack outranks
      // the page until the app restarts. `SilkyScrollAbsorber` pops in `dispose`
      // as well as on exit.
      final menu = container.read(playerMenuProvider.notifier);
      menu.open();
      final outer = await pumpOverPage(tester);
      final panel = tester.getRect(find.byKey(settingsMenuPanelKey));

      // Park the pointer inside the panel, then close it out from under.
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(panel.center));
      await tester.pump();
      menu.close();
      await tester.pumpAndSettle();
      expect(find.byKey(settingsMenuPanelKey), findsNothing);

      await wheelAt(tester, panel.center);
      expect(outer.offset, greaterThan(0), reason: 'the page scrolls again once the panel is gone');
    });
  });

  group('page transitions', () {
    /// Where a page's content sits relative to where it settles.
    double offsetOf(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text)).dx;

    testWidgets('a push brings the new page in from the right and takes the old out left',
        (tester) async {
      container.read(playerMenuProvider.notifier).open();
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final rootAtRest = offsetOf(tester, 'Sleep timer');

      await tester.tap(find.byKey(playerSettingsMoreRowKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));

      // Both pages are live mid-transition — that is the point of the pair.
      expect(find.text('Sleep timer'), findsOneWidget, reason: 'the old page is still leaving');
      expect(find.text('Audio channel'), findsOneWidget, reason: 'the new page is arriving');

      final incoming = offsetOf(tester, 'Audio channel');
      final outgoing = offsetOf(tester, 'Sleep timer');
      expect(incoming, greaterThan(rootAtRest), reason: 'the new page comes from the right');
      expect(outgoing, lessThan(rootAtRest), reason: 'and the old one leaves to the left');

      await tester.pumpAndSettle();
      expect(find.text('Sleep timer'), findsNothing);
      expect(offsetOf(tester, 'Audio channel'), rootAtRest, reason: 'it settles where it belongs');
    });

    testWidgets('going back reverses both halves', (tester) async {
      container.read(playerMenuProvider.notifier).go(SettingsPage.moreOptions);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final atRest = offsetOf(tester, 'Audio channel');

      await tester.tap(find.byKey(playerSettingsBackKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));

      expect(offsetOf(tester, 'Sleep timer'), lessThan(atRest),
          reason: 'the root comes back from the left');
      expect(offsetOf(tester, 'Audio channel'), greaterThan(atRest),
          reason: 'and More options leaves to the right');
      await tester.pumpAndSettle();
    });

    testWidgets('root to quality is sideways, so it only cross-fades', (tester) async {
      // Neither is under the other — quality has its own button — so a slide
      // would be claiming a hierarchy that does not exist.
      //
      // Each page is compared against *its own* resting position, not against
      // the other's: the ladder indents differently from the settings rows
      // (a tick column instead of an icon), so the two never line up and the
      // question being asked is only "did this move?".
      final menu = container.read(playerMenuProvider.notifier);
      menu.go(SettingsPage.quality);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final qualityAtRest = offsetOf(tester, '480p');

      menu.go(SettingsPage.root);
      await tester.pumpAndSettle();
      final rootAtRest = offsetOf(tester, 'Sleep timer');

      menu.go(SettingsPage.quality);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));

      expect(find.text('Sleep timer'), findsOneWidget, reason: 'both are live, it is a fade');
      expect(offsetOf(tester, 'Sleep timer'), rootAtRest, reason: 'the old page does not travel');
      expect(offsetOf(tester, '480p'), qualityAtRest, reason: 'nor does the new one');
      await tester.pumpAndSettle();
    });

    testWidgets('the panel resizes alongside the slide, not after it', (tester) async {
      // The regression the custom `layoutBuilder` exists to stop: sized to the
      // largest live child, the panel would hold the tall page's height for the
      // whole transition and snap at the end.
      container.read(playerMenuProvider.notifier).go(SettingsPage.quality);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      final tall = tester.getSize(find.byKey(settingsMenuPanelKey)).height;

      container.read(playerMenuProvider.notifier).open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final midway = tester.getSize(find.byKey(settingsMenuPanelKey)).height;
      await tester.pumpAndSettle();
      final short = tester.getSize(find.byKey(settingsMenuPanelKey)).height;

      expect(short, lessThan(tall));
      expect(midway, lessThan(tall), reason: 'already shrinking while the pages are still moving');
      expect(midway, greaterThan(short), reason: 'and not there yet either');
    });
  });

  group('the quality page', () {
    testWidgets('is a top level: header, no chevron, decoded height on the right',
        (tester) async {
      container.read(playerMenuProvider.notifier).go(SettingsPage.quality);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.text('Quality'), findsOneWidget);
      expect(find.byKey(playerSettingsBackKey), findsNothing,
          reason: 'nothing above it to go back to');
      expect(find.byIcon(Icons.chevron_left), findsNothing);
      expect(find.byKey(playerQualityHeaderKey), findsOneWidget);
    });

    testWidgets('stays under the cap, keeps its header, and picks', (tester) async {
      PlaybackVariant? picked;
      container.read(playerMenuProvider.notifier).go(SettingsPage.quality);
      await tester.pumpWidget(host(onPicked: (variant) => picked = variant));
      await tester.pumpAndSettle();

      final size = tester.getSize(find.byKey(settingsMenuPanelKey));
      expect(size.height, lessThanOrEqualTo(settingsMenuMaxHeight));

      final headerBefore = tester.getTopLeft(find.text('Quality'));
      await tester.drag(find.text('720p60').first, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Quality')), headerBefore,
          reason: 'sticky: the header is not in the scrollable');

      expect(find.text('4K'), findsOneWidget, reason: '2160 and nothing else');
      expect(find.text('HD'), findsNWidgets(3), reason: '1440, 1080, 720 — not 480 and down');
      expect(
        find.descendant(of: find.byKey(playerQualityAutoKey), matching: find.byType(InkWell)),
        findsNothing,
        reason: 'Auto is disabled, not merely inert',
      );

      await tester.tap(find.text('720p60'));
      await tester.pumpAndSettle();
      expect(picked?.height, 720);
    });
  });

  group('the panel', () {
    testWidgets('fades in on open and out on close, and survives a double toggle',
        (tester) async {
      final menu = container.read(playerMenuProvider.notifier);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildRillTheme(const Color(0xFF7C4DFF)),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  height: 900,
                  child: Consumer(
                    builder: (context, ref, _) => SettingsMenuFade(
                      visible: ref.watch(playerMenuProvider.select((m) => m.open)),
                      child: PlayerSettingsMenu(onPicked: (_) {}),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(settingsMenuPanelKey), findsNothing, reason: 'not mounted while closed');

      double opacity() => tester
          .widgetList<Opacity>(find.ancestor(
            of: find.byKey(settingsMenuPanelKey),
            matching: find.byType(Opacity),
          ))
          .first
          .opacity;

      menu.open();
      await tester.pump();
      expect(opacity(), 0, reason: 'the first frame starts from nothing, not from 1');
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacity(), greaterThan(0));
      expect(opacity(), lessThan(1));
      await tester.pumpAndSettle();
      expect(opacity(), 1);

      menu.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(opacity(), lessThan(1), reason: 'still painted, on its way out');
      expect(find.byKey(settingsMenuPanelKey), findsOneWidget,
          reason: 'and still mounted, or there would be nothing to fade');

      // **The case `AnimatedSwitcher` could not survive.** Reopening mid-fade
      // must reuse the one panel; a second instance would put two widgets on
      // `settingsMenuPanelKey` and throw.
      menu.open();
      await tester.pump();
      expect(find.byKey(settingsMenuPanelKey), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(opacity(), 1);

      menu.close();
      await tester.pumpAndSettle();
      expect(find.byKey(settingsMenuPanelKey), findsNothing);
    });

    testWidgets('both buttons count as on the menu, so a second press only closes',
        (tester) async {
      // The bug this pins: an anchor that is "outside" gets closed on
      // pointer-down and reopened on pointer-up, and looks like a dead button.
      container.read(playerMenuProvider.notifier).open();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildRillTheme(const Color(0xFF7C4DFF)),
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    right: 12,
                    top: 8,
                    bottom: 96,
                    child: PlayerSettingsMenu(onPicked: (_) {}),
                  ),
                  Positioned(
                    right: 60,
                    bottom: 20,
                    child: KeyedSubtree(
                      key: qualityButtonAnchorKey,
                      child: const Icon(Icons.hd_outlined, size: 40),
                    ),
                  ),
                  Positioned(
                    right: 12,
                    bottom: 20,
                    child: KeyedSubtree(
                      key: settingsMenuAnchorKey,
                      child: const Icon(Icons.settings, size: 40),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(pointerIsOnSettingsMenu(tester.getRect(find.byIcon(Icons.settings)).center), isTrue);
      expect(pointerIsOnSettingsMenu(tester.getRect(find.byIcon(Icons.hd_outlined)).center), isTrue);
      expect(pointerIsOnSettingsMenu(tester.getRect(find.byKey(settingsMenuPanelKey)).center), isTrue);
      // And the far side of the window still is an outside click.
      expect(pointerIsOnSettingsMenu(const Offset(20, 20)), isFalse);
    });
  });
}
