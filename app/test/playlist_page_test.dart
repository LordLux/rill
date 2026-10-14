import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rill/domain/artist_panel.dart' show ThemedColor;
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/focus_surface.dart';
import 'package:rill/ui/page_wrapper.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/widgets/share_dialog.dart';
import 'package:rill/ui/queue_controller.dart';

import 'package:rill/ui/pages/playlist.dart';

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

class FakeMixService implements MixService {
  FakeMixService({this.tint, this.description, this.delay = Duration.zero});

  /// The header's description; null is a playlist with none.
  final String? description;

  /// How long the page takes to arrive. Past the route transition, the page
  /// underneath is off stage by the time the tint lands.
  final Duration delay;

  /// The header's `backgroundColor`; null is a playlist YouTube sent no tint for.
  final ThemedColor? tint;

  @override
  Future<MixStart> start(String playlistId, {String? videoId, String? params}) async => MixStart(playlistId: playlistId, items: []);
  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) async => MixExtension(items: [], exhausted: true);
  @override
  Future<PlaylistResult> getPlaylist(String playlistId, {String? continuation}) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return PlaylistResult(
      header: PlaylistHeader(
        thumbnailUrl: null,
        ownerName: 'Owner',
        ownerChannelId: null,
        ownerAvatarUrl: null,
        viewCountText: null,
        description: description,
        visibility: 'public',
        backgroundColor: tint,
        isOwnedByViewer: false,
      ),
      title: 'My Playlist',
      items: [video('v0'), video('v1'), video('v2')],
    );
  }
}

class _SilentPlayback extends PlaybackController {
  @override
  PlaybackState build() => const PlaybackState();
}

void main() {
  testWidgets('clicking row N in the playlist detail page starts the playlist at N', (tester) async {
    final container = ProviderContainer(
      overrides: [
        mixServiceProvider.overrideWithValue(FakeMixService()),
        // A row starts the playlist the way a tile does, which asks playback
        // where it is; the real controller would go looking for an engine.
        playbackProvider.overrideWith(_SilentPlayback.new),
      ],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => tester.view.reset());

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: PlaylistPage(playlistId: 'PL123')),
      ),
    ));

    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    
    // Click on row 1 (Video v1)
    await tester.tap(find.text('Video v1'));
    await tester.pump(const Duration(seconds: 1));

    final queueState = container.read(queueProvider);
    // Assert that the queue now contains the playlist items, and the current index is 1.
    expect(queueState.mix?.isPlaylist, true, reason: 'should start as a playlist mix');
    expect(queueState.currentIndex, 1, reason: 'should start at row N');
  });

  group('the header', () {
    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => tester.view.reset());
      await tester.pumpWidget(ProviderScope(
        overrides: [mixServiceProvider.overrideWithValue(FakeMixService())],
        child: const MaterialApp(home: PlaylistPage(playlistId: 'PL123')),
      ));
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // A bare `SelectionArea` is a Tab stop with no action and no ring: three of
    // them sat between the rail and "Play all".
    testWidgets('has selectable text that Tab walks past', (tester) async {
      await open(tester);
      final areas = find.byType(SelectionArea);
      expect(areas, findsWidgets);
      for (final area in areas.evaluate()) {
        expect(
          find.ancestor(of: find.byElementPredicate((element) => element == area), matching: find.byType(NoTabSelectionArea)),
          findsOneWidget,
        );
      }
    });

    testWidgets('puts the description between the owner and the actions, as youtube.com does', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => tester.view.reset());
      await tester.pumpWidget(ProviderScope(
        overrides: [mixServiceProvider.overrideWithValue(FakeMixService(description: 'What this is'))],
        child: const MaterialApp(home: PlaylistPage(playlistId: 'PL123')),
      ));
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final owner = tester.getRect(find.text('Owner'));
      final description = tester.getRect(find.text('What this is'));
      final actions = tester.getRect(find.text('Play all'));
      expect(description.top, greaterThanOrEqualTo(owner.bottom));
      expect(description.bottom, lessThanOrEqualTo(actions.top));
    });

    testWidgets('shares the playlist through the share dialog, with its own address', (tester) async {
      await open(tester);
      await tester.tap(find.byIcon(Icons.reply));
      for (int i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ShareDialog), findsOneWidget);
      expect(find.text('https://www.youtube.com/playlist?list=PL123'), findsOneWidget);
      expect(find.text('Start at'), findsNothing, reason: 'a playlist has no position to start at');
    });
  });

  group('the title bar and the rail', () {
    Future<void> open(WidgetTester tester, {ThemedColor? tint, Duration delay = Duration.zero}) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() => tester.view.reset());

      await tester.pumpWidget(ProviderScope(
        overrides: [mixServiceProvider.overrideWithValue(FakeMixService(tint: tint, delay: delay))],
        child: MaterialApp(theme: ThemeData.dark(), home: const PlaylistPage(playlistId: 'PL123')),
      ));
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// What the page on top has behind its title bar and rail this frame,
    /// mid-fade included: the first thing it paints.
    Color chrome(WidgetTester tester) {
      final ground = tester.widget(find
          .descendant(
            of: find.byType(PageWrapper).last,
            matching: find.byWidgetPredicate((widget) => widget is ColoredBox || widget is DecoratedBox),
          )
          .first);
      return ground is ColoredBox ? ground.color : ((ground as DecoratedBox).decoration as BoxDecoration).color!;
    }

    /// The page's own ground is drawn from the same value as the chrome, this
    /// frame: a different one shows a seam under the title bar, and one that
    /// does not move with it pops in while the chrome fades.
    void expectGroundFollowsChrome(WidgetTester tester, String what) {
      final want = pageGroundFor(chrome(tester), ThemeData.dark().scaffoldBackgroundColor);
      expect(
        find.descendant(
          of: find.byType(PageWrapper).last,
          matching: find.byWidgetPredicate((widget) => widget is DecoratedBox && widget.decoration == want),
        ),
        findsOneWidget,
        reason: what,
      );
    }

    testWidgets("take the playlist's tint, the same one the page starts from", (tester) async {
      await open(tester, tint: const ThemedColor(light: 0xFFB8D0F0, dark: 0xFF234472));

      final ground = ThemeData.dark().scaffoldBackgroundColor;
      expect(chrome(tester), isNot(ground));
      expect(chrome(tester).a, 1.0, reason: 'the chrome is the bottom layer of the window');
      expectGroundFollowsChrome(tester, 'at rest on the playlist');
    });

    testWidgets("stay the theme's own when the playlist has no tint", (tester) async {
      await open(tester);
      expect(chrome(tester), ThemeData.dark().scaffoldBackgroundColor);
    });

    // Each page builds its own title bar and rail and routes swap with no
    // transition, so a colour that belonged to one page cut in and out. And a
    // fade owned by one page is cut short when that page goes: on a Back the
    // outgoing page is drawn for the length of the route transition, then the
    // page under it shows whatever it had.
    testWidgets('fade between pages without a cut, both ways', (tester) async {
      await open(tester, tint: const ThemedColor(light: 0xFFB8D0F0, dark: 0xFF234472), delay: const Duration(milliseconds: 600));
      final ground = ThemeData.dark().scaffoldBackgroundColor;
      final tint = chrome(tester);
      expect(tint, isNot(ground));

      double distance(Color a, Color b) => (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();

      /// Watches the chrome go [from] to [to] in 25 ms frames: it has to start
      /// where the last page left it, only ever get closer, and never jump.
      Future<void> expectFade(Color from, Color to, String what) async {
        final whole = distance(from, to);
        expect(distance(chrome(tester), from), lessThan(whole * 0.02), reason: '$what: starts on the colour before it');
        var last = chrome(tester);
        var steps = 0;
        while (chrome(tester) != to) {
          await tester.pump(const Duration(milliseconds: 25));
          final now = chrome(tester);
          expectGroundFollowsChrome(tester, '$what: the page behind did not fade with it at step $steps');
          expect(distance(now, to), lessThanOrEqualTo(distance(last, to)), reason: '$what: went backwards at step $steps');
          expect(distance(now, last), lessThan(whole * 0.2), reason: '$what: cut at step $steps');
          last = now;
          expect(++steps, lessThan(100), reason: '$what: never arrived');
        }
        expect(steps, greaterThan(5), reason: '$what: that was a cut, not a fade');
      }

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute<void>(
        builder: (_) => const PageWrapper(title: Text('Other'), body: Center(child: Text('Other page'))),
      ));
      // Two frames, no time: a route is built one frame before it is on stage.
      await tester.pump();
      await tester.pump();
      expect(find.text('Other page'), findsOneWidget);
      await expectFade(tint, ground, 'opening a page over the playlist');
      await tester.pump(const Duration(seconds: 1));

      navigator.pop();
      await tester.pump();
      await expectFade(ground, tint, 'going back to the playlist');
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Other page'), findsNothing);
      expect(chrome(tester), tint);

      // And away from it by a Back: the playlist is the page that goes.
      navigator.pushReplacement(MaterialPageRoute<void>(
        builder: (_) => const PageWrapper(title: Text('Home'), body: Center(child: Text('Home page'))),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      navigator.push(MaterialPageRoute<void>(builder: (_) => const PlaylistPage(playlistId: 'PL123')));
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(chrome(tester), tint);
      navigator.pop();
      await tester.pump();
      await expectFade(tint, ground, 'leaving the playlist with Back');
    });
  });
}
