/// The player's settings menu, end to end — state machine, pages, transitions.
///
/// **No sidecar.** Every test here runs against an overridden `playbackProvider`
/// and a `FakeEngine`, so it needs neither `bun` nor `fake_sidecar.ts` and runs
/// under a plain `flutter test`.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/caption_style.dart';
import 'package:rill/domain/caption_track.dart';
import 'package:rill/domain/playback_source.dart';
import 'package:silky_scroll/silky_scroll.dart';

import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/captions_controller.dart';
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

const rootPlaceholders = ['Sleep timer', 'Audio track', 'Playback speed'];
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

    test('back walks out of subpages', () {
      final menu = container.read(playerMenuProvider.notifier);

      menu.go(SettingsPage.moreOptions);
      expect(menu.back(), isTrue);
      expect(container.read(playerMenuProvider),
          const PlayerMenuState(open: true, page: SettingsPage.root),
          reason: 'back leaves the menu open — it is not a close');

      expect(menu.back(), isFalse, reason: 'nothing above the root');

      // **Captions is a top level, not a subpage — and this assertion used to
      // say the opposite.** It was written when captions hung off the root
      // menu; Task 19 gave it its own CC button, which makes it a peer of
      // quality, and `back()`'s doc says so ("only `moreOptions` is under
      // anything"). The assertion was not updated, so it has been failing ever
      // since — the one red test in the suite, for a design decision that had
      // already been made and documented.
      //
      // The caption *sub*-pages do go back, but not through here: each one
      // names its own parent with `go(...)` (`forceStyle` → `captionStyle` →
      // `captions`, `settings_menu.dart`), and the widget test "back returns to
      // the track list, not to the root" is what covers that.
      menu.go(SettingsPage.captions);
      expect(menu.back(), isFalse, reason: 'captions is its own top level');
      expect(container.read(playerMenuProvider).page, SettingsPage.captions,
          reason: 'a back that had nowhere to go must not move the page either');

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

      // **No longer "one width for every page" unconditionally.** The panel
      // sizes to its widest row above a shared floor, so two pages match only
      // while both fit in it — which every page authored in this file does under
      // a normal UI font, and none does under the test font, whose glyphs are
      // one em wide. Asserting equality here would pin the test font rather than
      // the design. What the floor guarantees is asserted directly below, and
      // the growth rule has its own group.
      expect(moreSize.width, greaterThanOrEqualTo(248));
      expect(rootSize.width, greaterThanOrEqualTo(248));
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

  /// One wheel notch, with a stamp no other notch has.
  ///
  /// `silky_scroll` tells a wheel event that has already been handled from one
  /// that has not by its `timeStamp` — Flutter clones the event as it bubbles, so
  /// nothing else about it survives (`architecture.md` F44). `TestPointer` stamps
  /// every event zero, which makes every notch after the first the same event to
  /// it, already handled by somebody; a real device never does that.
  var wheelClock = 0;
  PointerScrollEvent notch(TestPointer pointer) =>
      pointer.scroll(const Offset(0, 120), timeStamp: Duration(milliseconds: ++wheelClock * 20));

  Future<void> wheelAt(WidgetTester tester, Offset where, {int times = 5}) async {
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(where));
    for (var i = 0; i < times; i++) {
      await tester.sendEventToBinding(notch(pointer));
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pumpAndSettle(
        const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
  }

  /// The panel's own scroll view — the ladder, or the root page's list.
  ScrollPosition panelScroll(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.descendant(of: find.byKey(settingsMenuPanelKey), matching: find.byType(Scrollable)).first,
      )
      .position;

  group('the wheel over a panel', () {
    // **The outer list must be a `SilkyListView`, not a `ListView`.** An earlier
    // version of these used a plain `ListView` and passed against a fix that did
    // nothing in the real app — `SilkyScroll` handles a vertical wheel straight
    // from its own `Listener` and never consults the `pointerSignalResolver`, so
    // a resolver claim stops a Flutter `Scrollable` and is invisible to the
    // page. The control has to be the widget the watch page actually uses.
    //
    // **What the panel does with a notch is `silky_scroll`'s own nesting rule,
    // not a hover flag of ours** (F44; `SilkyScrollAbsorber` is gone). The
    // innermost scroll view under the pointer takes a notch while it can move; at
    // its edge it hands the next one to the page; and a part of the panel that is
    // not a scroll view — the header — leaves it to the page. The ladder here
    // overflows its box by only 18 px, so one notch is enough to drive it to its
    // edge, and the tests are built on that.

    testWidgets('the list takes it first, and the page does not move while the list can', (tester) async {
      container.read(playerMenuProvider.notifier).go(SettingsPage.quality);
      final outer = await pumpOverPage(tester);
      expect(panelScroll(tester).pixels, 0);
      expect(panelScroll(tester).maxScrollExtent, greaterThan(0), reason: 'the ladder is long enough to scroll');

      await wheelAt(tester, tester.getRect(find.text('480p')).center, times: 1);
      expect(panelScroll(tester).pixels, panelScroll(tester).maxScrollExtent, reason: 'the ladder took the notch');
      expect(outer.offset, 0, reason: 'the page must not move under a list that could');
    });

    testWidgets('hands it to the page once the list is at its edge', (tester) async {
      container.read(playerMenuProvider.notifier).go(SettingsPage.quality);
      final outer = await pumpOverPage(tester);
      final over = tester.getRect(find.text('480p')).center;

      await wheelAt(tester, over, times: 1);
      expect(outer.offset, 0);

      // The ladder is at its end, so this one has nowhere to go but out.
      await wheelAt(tester, over, times: 1);
      expect(outer.offset, greaterThan(0), reason: 'the page takes what the list cannot');
      expect(panelScroll(tester).pixels, panelScroll(tester).maxScrollExtent, reason: 'and the ladder stays where it was');
    });

    testWidgets('over the header, which is not a scroll view, the page takes it', (tester) async {
      // The sticky header sits outside the scroll view, so there is nothing for
      // the panel to hold it with. **One notch only**: the page moves and the
      // panel with it, so a second notch would land on the list under a pointer
      // that has not moved.
      container.read(playerMenuProvider.notifier).go(SettingsPage.quality);
      final outer = await pumpOverPage(tester);

      await wheelAt(tester, tester.getRect(find.text('Quality')).center, times: 1);
      expect(outer.offset, greaterThan(0), reason: 'the page took it');
      expect(panelScroll(tester).pixels, 0, reason: 'the list was not under the pointer');
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

    testWidgets('a list that appears under a stationary pointer takes the wheel from then on', (tester) async {
      // Walking from the settings list to the quality ladder turns a panel with
      // nothing to scroll into one with plenty, under a pointer that never moved
      // — a metrics change with no scroll. Each notch is routed to whichever
      // scroll view is under the pointer when it arrives, so nothing has to
      // notice the change; this is the case that would break if something did.
      final menu = container.read(playerMenuProvider.notifier);
      menu.open();
      final outer = await pumpOverPage(tester);

      final over = tester.getRect(find.byKey(settingsMenuPanelKey)).center;
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(over));
      await tester.pumpAndSettle();
      expect(panelScroll(tester).maxScrollExtent, 0, reason: 'the root page fits');

      menu.go(SettingsPage.quality);
      await tester.pumpAndSettle();
      expect(panelScroll(tester).maxScrollExtent, greaterThan(0));

      await tester.sendEventToBinding(notch(pointer));
      await tester.pumpAndSettle(
          const Duration(milliseconds: 16), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
      expect(panelScroll(tester).pixels, panelScroll(tester).maxScrollExtent, reason: 'the ladder took it');
      expect(outer.offset, 0, reason: 'so the page did not');
    });

    testWidgets('still reaches the page everywhere else', (tester) async {
      container.read(playerMenuProvider.notifier).open();
      final outer = await pumpOverPage(tester);
      final panel = tester.getRect(find.byKey(settingsMenuPanelKey));

      await wheelAt(tester, Offset(20, panel.center.dy));
      expect(outer.offset, greaterThan(0), reason: 'nothing was over-claimed');
    });

    testWidgets('a panel closed under the cursor does not strand the page', (tester) async {
      // The failure mode any hover bookkeeping has to be designed against:
      // `MouseRegion.onExit` may never fire for a region unmounted with the
      // pointer inside it, and a key left on silky_scroll's stack outranks the
      // page until the app restarts. It has to be released in `dispose` as well
      // as on exit.
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
    /// Where a page's content sits, **measured from the panel's own left edge**.
    ///
    /// Relative rather than absolute because the panel is no longer one fixed
    /// width: it sizes to its widest row and is anchored on the right, so a page
    /// whose content needs more room puts its left edge somewhere else on
    /// screen. An absolute reading then moves for a reason that has nothing to
    /// do with the slide these tests are about — and it does so only under a
    /// font wide enough to push a page past the floor, which is exactly the kind
    /// of failure that shows up on one machine and not another.
    double offsetOf(WidgetTester tester, String text) =>
        tester.getTopLeft(find.text(text)).dx -
        tester.getRect(find.byKey(settingsMenuPanelKey)).left;

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

      menu.go(SettingsPage.root);
      await tester.pumpAndSettle();

      menu.go(SettingsPage.quality);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));

      expect(find.text('Sleep timer'), findsOneWidget, reason: 'both are live, it is a fade');

      // **The slide itself, not where the glyphs land.** Since the panel sizes
      // to its content it can also be morphing *width* through this frame, and
      // that moves a right-anchored page's contents sideways for a reason that
      // is not a slide. Reading the `SlideTransition` asks the question the test
      // is named for: both pages are at zero offset, so neither travelled.
      final slides = tester.widgetList<SlideTransition>(find.byType(SlideTransition));
      expect(slides, isNotEmpty, reason: 'both pages are wrapped, moving or not');
      for (final slide in slides) {
        expect(slide.position.value, Offset.zero);
      }
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

  /// The panel widens to fit a caption row rather than truncating it.
  ///
  /// Measured through the real widget rather than argued about: the width comes
  /// from `IntrinsicWidth` asking the rows, so the only way to know a badge and
  /// a sub-name are counted is to put them on a row and read the panel back.
  group('the panel grows to fit its widest row', () {
    Future<void> pumpCaptions(WidgetTester tester, List<CaptionTrack> tracks) async {
      container.dispose();
      container = ProviderContainer(
        overrides: [
          playbackProvider.overrideWith(FakePlayback.new),
          playbackEngineProvider.overrideWithValue(FakeEngine()),
          captionsProvider.overrideWith(() => _FixedCaptions(tracks)),
        ],
      );
      container.read(playerMenuProvider.notifier).go(SettingsPage.captions);
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
    }

    CaptionTrack track(String label, {String badge = '', String name = ''}) => CaptionTrack(
          id: '.$label',
          languageCode: 'en',
          label: label,
          isAutoGenerated: false,
          trackName: name,
          styled: badge.isEmpty ? 'plain' : badge,
        );

    testWidgets('Off is the last row, under a divider, as Auto is on quality',
        (tester) async {
      await pumpCaptions(tester, [track('English'), track('German')]);
      final off = tester.getTopLeft(find.byKey(playerCaptionsOffKey)).dy;
      for (final label in ['English', 'German']) {
        expect(tester.getTopLeft(find.text(label)).dy, lessThan(off),
            reason: '$label is a choice; Off comes after all of them');
      }
      // The page carries three rules — under the header, above Off, and above
      // the *Style* row — so this picks the one it is about by position rather
      // than by index. `.last` used to work and stopped the moment task 19 added
      // a row after Off, which is the kind of silent drift an index invites.
      final german = tester.getTopLeft(find.text('German')).dy;
      final between = tester
          .widgetList<Divider>(find.byType(Divider))
          .map((divider) => tester.getTopLeft(find.byWidget(divider)).dy)
          .where((dy) => dy > german && dy < off);
      expect(between, isNotEmpty, reason: 'a rule separates the languages from Off');
    });

    testWidgets('short labels leave it at the shared width', (tester) async {
      await pumpCaptions(tester, [track('English'), track('German')]);
      expect(tester.getSize(find.byKey(settingsMenuPanelKey)).width, 248);
    });

    testWidgets('a long label widens it, and the label is not truncated', (tester) async {
      // 'English (Ireland)' plus a badge sits between the floor and the ceiling
      // under the test font, which is what makes the two bounds below real
      // assertions rather than either one being trivially satisfied.
      await pumpCaptions(tester, [
        track('English'),
        track('English (Ireland)', badge: 'styled'),
      ]);
      final width = tester.getSize(find.byKey(settingsMenuPanelKey)).width;
      expect(width, greaterThan(248), reason: 'the row does not fit in the floor width');
      expect(width, lessThanOrEqualTo(380));

      // The claim that matters: the text is laid out at its full width, so no
      // ellipsis is reached. `didExceedMaxLines` is false when it all fits.
      final text = tester.renderObject<RenderParagraph>(find.text('English (Ireland)'));
      expect(text.didExceedMaxLines, isFalse);
    });

    testWidgets(
        'MUTATION: the badge and the sub-name are counted, and a name suppresses the badge',
        (tester) async {
      // The failure this guards is two-sided now. The first is the original
      // one: a *manual* width calculation that adds up the label and forgets
      // what sits beside it — the panel then looks right until a track
      // carries a badge or a sub-name, and truncates the language rather than
      // growing. The second is the priority rule itself: a `trackName` is the
      // uploader's own answer to "how is this track different", and it wins
      // over the app's own guess — the badge exists only for when the
      // uploader never said, so it must disappear the moment a name shows up
      // rather than stacking additional width on top of it.
      await pumpCaptions(tester, [track('English (Ireland)')]);
      final bare = tester.getSize(find.byKey(settingsMenuPanelKey)).width;

      await pumpCaptions(tester, [track('English (Ireland)', badge: 'styled')]);
      final badgeOnly = tester.getSize(find.byKey(settingsMenuPanelKey)).width;

      await pumpCaptions(tester, [track('English (Ireland)', name: 'X')]);
      final nameOnly = tester.getSize(find.byKey(settingsMenuPanelKey)).width;

      await pumpCaptions(tester, [track('English (Ireland)', badge: 'styled', name: 'X')]);
      final both = tester.getSize(find.byKey(settingsMenuPanelKey)).width;

      expect(badgeOnly, greaterThan(bare),
          reason: 'the badge takes room when nothing else distinguishes the track');
      expect(nameOnly, greaterThan(bare), reason: 'so does the sub-name, on its own');
      expect(both, nameOnly,
          reason: 'a trackName suppresses the badge — width with both must equal name-only, '
              'not grow further');

      // Inside the band, so neither bound is doing the work: at the floor
      // every reading would be 248, at the ceiling every reading 380, and the
      // test would pass while measuring nothing.
      expect(bare, greaterThan(248));
      expect(both, lessThan(380));
    });

    testWidgets('a pathological label stops at the ceiling and ellipsises', (tester) async {
      await pumpCaptions(tester, [track('E' * 200, badge: 'styled')]);
      expect(tester.getSize(find.byKey(settingsMenuPanelKey)).width, 380);
      expect(tester.renderObject<RenderParagraph>(find.text('E' * 200)).didExceedMaxLines, isTrue);
    });

    testWidgets('the style page is reachable, and offers only the edges ASS can draw',
        (tester) async {
      await pumpCaptions(tester, [track('English')]);
      await tester.tap(find.byKey(playerCaptionStyleRowKey));
      await tester.pumpAndSettle();

      expect(find.byKey(playerCaptionStyleMenuKey), findsOneWidget);
      // **Three, not five.** ASS has `\bord` and `\shad` and no bevel, so
      // YouTube's *Raised* and *Depressed* are one result — offering both would
      // be two entries that do the same thing. `architecture.md` §2.9 records it
      // as knowingly dropped rather than quietly missed.
      expect(find.text('Drop shadow'), findsOneWidget);
      expect(find.text('Outline'), findsOneWidget);
      expect(find.text('Raised'), findsNothing);
      expect(find.text('Depressed'), findsNothing);
    });

    testWidgets('reset is disabled until there is something to reset', (tester) async {
      await pumpCaptions(tester, [track('English')]);
      await tester.tap(find.byKey(playerCaptionStyleRowKey));
      await tester.pumpAndSettle();

      final ink = tester.widget<InkWell>(
        find.descendant(
          of: find.byKey(playerCaptionStyleResetKey),
          matching: find.byType(InkWell),
        ),
      );
      expect(ink.onTap, isNull,
          reason: 'a fresh session has nothing to undo, and a live Reset would say otherwise');
    });

    testWidgets('a discrete control commits at once, without a debounce', (tester) async {
      await pumpCaptions(tester, [track('English')]);
      await tester.tap(find.byKey(playerCaptionStyleRowKey));
      await tester.pumpAndSettle();

      // **The style page is the longest in the menu** — four sections and a
      // reset, against a 400 px panel — so it scrolls, and the edge chips are
      // below the fold. Scrolling to a control before using it is what a user
      // does too.
      await tester.ensureVisible(find.text('Outline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Outline'));
      await tester.pumpAndSettle();

      final captions = container.read(captionsProvider.notifier) as _FixedCaptions;
      expect(captions.applied.single.edgeStyle, CaptionEdgeStyle.outline);
      expect(captions.appliedImmediately.single, isTrue,
          reason: 'a chip has nothing to debounce — a delay there is only a delay');
    });

    testWidgets('a slider is debounced instead', (tester) async {
      await pumpCaptions(tester, [track('English')]);
      await tester.tap(find.byKey(playerCaptionStyleRowKey));
      await tester.pumpAndSettle();

      // Any slider on the page; they all take the same path, and each frame of a
      // drag is a re-render plus a `sub-add` on the other side of it.
      await tester.ensureVisible(find.byType(Slider).first);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Slider).first, const Offset(30, 0));
      await tester.pumpAndSettle();

      final captions = container.read(captionsProvider.notifier) as _FixedCaptions;
      expect(captions.appliedImmediately, isNotEmpty);
      expect(captions.appliedImmediately.every((immediate) => !immediate), isTrue);
    });

    testWidgets('two separate, fully-settled taps each carry their own target, not the one before',
        (tester) async {
      // Reported: a slider commit is one step behind the one before it —
      // opacity 100 -> 0 does nothing, then 0 -> 50 shows 0. Absolute taps at
      // known positions, rather than relative drags (whose synthesized start
      // point is a test-harness detail, not app behaviour), so the expected
      // target of each tap is known independently of what the previous one did.
      await pumpCaptions(tester, [track('English')]);
      await tester.tap(find.byKey(playerCaptionStyleRowKey));
      await tester.pumpAndSettle();

      final sizeSlider = find.byType(Slider).first; // 'Size' — fontSizePercent, 50..300
      await tester.ensureVisible(sizeSlider);
      await tester.pumpAndSettle();
      final trackRect = tester.getRect(sizeSlider);

      await tester.tapAt(Offset(trackRect.left + trackRect.width * 0.05, trackRect.center.dy));
      await tester.pumpAndSettle();
      final captions = container.read(captionsProvider.notifier) as _FixedCaptions;
      expect(captions.applied, isNotEmpty);
      final firstTarget = captions.applied.last.fontSizePercent!;
      expect(firstTarget, lessThan(100), reason: 'a tap near the left edge must land near the low end');

      await tester.tapAt(Offset(trackRect.left + trackRect.width * 0.95, trackRect.center.dy));
      await tester.pumpAndSettle();
      final secondTarget = captions.applied.last.fontSizePercent!;
      expect(secondTarget, greaterThan(200),
          reason: 'a tap near the right edge must land near the high end, not repeat the first tap\'s target');
    });

    testWidgets('back returns to the track list, not to the root', (tester) async {
      await pumpCaptions(tester, [track('English')]);
      await tester.tap(find.byKey(playerCaptionStyleRowKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(playerSettingsBackKey));
      await tester.pumpAndSettle();
      expect(find.byKey(playerCaptionsMenuKey), findsOneWidget);
    });

    testWidgets('it grows leftward — the right edge does not move', (tester) async {
      // The panel hangs off a button at its bottom-right, so that corner is the
      // anchor. A wider panel that moved it would drag the menu off its control.
      await pumpCaptions(tester, [track('English')]);
      final narrow = tester.getRect(find.byKey(settingsMenuPanelKey));

      await pumpCaptions(tester, [track('English (Ireland)', badge: 'styled')]);
      final wide = tester.getRect(find.byKey(settingsMenuPanelKey));

      expect(wide.right, narrow.right);
      expect(wide.left, lessThan(narrow.left));
    });
  });
}

/// A `CaptionsController` that never talks to a sidecar.
class _FixedCaptions extends CaptionsController {
  _FixedCaptions(this._tracks);

  final List<CaptionTrack> _tracks;

  /// Every style the menu handed over, and whether it asked for it immediately.
  ///
  /// The debounce lives in the real controller, so a menu test cannot observe it
  /// by counting round trips — what it *can* observe is which of the two the
  /// control asked for, which is the decision the menu owns.
  final List<CaptionStyle> applied = [];
  final List<bool> appliedImmediately = [];

  @override
  CaptionsState build() => CaptionsState(tracks: _tracks);

  @override
  Future<void> loadStyled() async {}

  @override
  Future<void> setStyle(CaptionStyle style, {bool immediate = false}) async {
    applied.add(style);
    appliedImmediately.add(immediate);
    state = state.copyWith(style: style);
  }

  @override
  Future<void> resetStyle() async {
    state = state.copyWith(style: CaptionStyle.none, offset: CaptionOffset.zero);
  }
}
