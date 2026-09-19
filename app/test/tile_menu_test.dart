/// The tile's 3-dot menu.
///
/// `MediaTile.onMore` was wired to nothing from the day it was added, so every
/// 3-dot button in the app was drawn disabled and nothing noticed: the button
/// looked like a control, and no test asked whether it did anything. These do.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/open_video.dart';
import 'package:rill/ui/queue_controller.dart';
import 'package:rill/ui/widgets/media_tile.dart';
import 'package:rill/ui/widgets/save_dialog.dart';

const TileSpec spec = TileSpec(
  title: 'A video',
  thumbnailUrl: 'https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg',
  isStackedCards: false,
  durationText: '4:20',
  durationTone: DurationBadgeTone.normal,
  badges: [],
  canWatchLater: true,
  canAddToQueue: true,
  primaryLine: 'Channel',
);

FeedItem video({bool canWatchLater = true, bool canAddToQueue = true}) => FeedItem.video(
      kind: 'video',
      id: 'aaaaaaaaaaa',
      title: 'A video',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg',
      isLive: false,
      durationSeconds: 260,
      canWatchLater: canWatchLater,
      canAddToQueue: canAddToQueue,
    );

final FeedItem mixWithSeed = FeedItem.mix(
  kind: 'mix',
  id: 'RDaaaaaaaaaaa',
  title: 'A mix',
  thumbnailUrl: 'https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg',
  seedVideoId: 'aaaaaaaaaaa',
);

final FeedItem mixWithoutSeed = FeedItem.mix(
  kind: 'mix',
  id: 'RDaaaaaaaaaaa',
  title: 'A mix',
  thumbnailUrl: 'https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg',
);

final FeedItem playlist = FeedItem.playlist(
  kind: 'playlist',
  id: 'PLbbbbbbbbbbbbbbbbbb',
  title: 'A playlist',
  thumbnailUrl: 'https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg',
);

final FeedItem channel = FeedItem.channel(kind: 'channel', id: 'UCcccccccccccccccccccccc', name: 'A channel', avatarUrl: 'https://fake.url/a.jpg');

/// A tile drawn the way every call site draws one: its menu from [menuForTile].
class TileFor extends ConsumerWidget {
  const TileFor(this.item, {super.key, this.onTap});

  final FeedItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemSpec = specFor(item)!;
    return MediaTile(spec: itemSpec, onTap: onTap, menu: menuForTile(context, ref, item, itemSpec));
  }
}

Widget harness(Widget tile) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: Center(child: SizedBox(width: 320, child: tile))),
      ),
    );

/// The labels of [item]'s menu, in order, with which are pressable.
Future<List<(String, bool)>> menuOf(WidgetTester tester, FeedItem item) async {
  late List<TileMenuItem> menu;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            menu = menuForTile(context, ref, item, specFor(item)!);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return [for (final entry in menu) (entry.label, entry.onPressed != null)];
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(tileMoreButtonKey));
  await tester.pumpAndSettle();
}

String? clipboardText;

/// Records what is written to the clipboard, for the tests that copy something —
/// and only those: the handler replaces the whole platform channel's.
void recordClipboard() {
  setUp(() {
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboardText = (call.arguments as Map)['text'] as String?;
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });
}

void main() {
  group('the button', () {
    testWidgets('a tile with no menu draws the 3-dot button disabled, and it opens nothing', (tester) async {
      await tester.pumpWidget(harness(const MediaTile(spec: spec)));

      final button = tester.widget<IconButton>(find.byKey(tileMoreButtonKey));
      expect(button.onPressed, isNull);
      await tester.tap(find.byKey(tileMoreButtonKey), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
    });

    testWidgets('a tile with a menu draws it enabled, and pressing it opens the menu without opening the tile', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        harness(
          MediaTile(
            spec: spec,
            onTap: () => opened++,
            menu: [TileMenuItem(icon: Icons.link, label: 'Copy link', onPressed: () {})],
          ),
        ),
      );
      expect(tester.widget<IconButton>(find.byKey(tileMoreButtonKey)).onPressed, isNotNull);
      expect(find.text('Copy link'), findsNothing, reason: 'closed until pressed');

      await openMenu(tester);

      expect(find.text('Copy link'), findsOneWidget);
      expect(opened, 0, reason: 'the button wins the gesture arena, as the hover buttons do');
    });

    // The button used to hang off the *title row*, and a `Stack` hit-tests its
    // children only inside its own bounds. A one-line title is about 20 px tall against
    // a 48 px tap target, so a click on the lower half of the button hit nothing — and
    // nothing showed it while the button was disabled. This taps a point that is inside
    // the button and below the title.
    for (final (name, tile) in <(String, Widget Function(List<TileMenuItem>))>[
      ('standard', (menu) => MediaTile(spec: spec, menu: menu)),
      ('wide', (menu) => MediaTile.wide(spec: spec, menu: menu)),
    ]) {
      testWidgets('the whole of the button answers, below a one-line title too ($name layout)', (tester) async {
        await tester.pumpWidget(
          harness(tile([TileMenuItem(icon: Icons.link, label: 'Copy link', onPressed: () {})])),
        );
        final button = tester.getRect(find.byKey(tileMoreButtonKey));
        final title = tester.getRect(find.text('A video'));
        final below = Offset(button.center.dx, (title.bottom + button.bottom) / 2);
        expect(button.contains(below), isTrue);
        expect(below.dy, greaterThan(title.bottom), reason: 'the point must be where the title row ends before it does');

        await tester.tapAt(below);
        await tester.pumpAndSettle();

        expect(find.text('Copy link'), findsOneWidget);
      });
    }

    testWidgets('pressing an entry runs it once and closes the menu', (tester) async {
      var ran = 0;
      await tester.pumpWidget(
        harness(MediaTile(spec: spec, menu: [TileMenuItem(icon: Icons.link, label: 'Copy link', onPressed: () => ran++)])),
      );
      await openMenu(tester);

      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      expect(ran, 1);
      expect(find.text('Copy link'), findsNothing);
    });

    testWidgets('an entry with no action is shown, and cannot be pressed', (tester) async {
      await tester.pumpWidget(harness(MediaTile(spec: spec, menu: const [TileMenuItem(icon: Icons.schedule, label: 'Save to Watch Later')])));
      await openMenu(tester);

      final entry = tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Save to Watch Later'));
      expect(entry.onPressed, isNull);
    });
  });

  group('what each kind of tile offers', () {
    testWidgets('a video: save, save to a playlist, queue and link, in that order, all pressable', (tester) async {
      expect(await menuOf(tester, video()), [
        ('Save to Watch Later', true),
        ('Save to playlist…', true),
        ('Add to queue', true),
        ('Copy link', true),
      ]);
    });

    testWidgets("a video that cannot be saved or queued shows those entries disabled, as the hover buttons hide", (tester) async {
      expect(await menuOf(tester, video(canWatchLater: false, canAddToQueue: false)), [
        ('Save to Watch Later', false),
        ('Save to playlist…', true),
        ('Add to queue', false),
        ('Copy link', true),
      ]);
    });

    testWidgets('a mix and a playlist are not videos: they offer the link and nothing to save or queue', (tester) async {
      expect(await menuOf(tester, mixWithSeed), [('Copy link', true)]);
      expect(await menuOf(tester, playlist), [('Copy link', true)]);
    });

    test('a kind with no link has no menu at all, so its button stays disabled', () {
      expect(tileLinkFor(channel), isNull);
      expect(tileLinkFor(const FeedItem.unknown(kind: 'unknown')), isNull);
    });
  });

  group('the link', () {
    recordClipboard();

    test('a video is watch?v=, a mix carries its seed, a playlist is a playlist', () {
      expect(tileLinkFor(video()), 'https://www.youtube.com/watch?v=aaaaaaaaaaa');
      expect(tileLinkFor(mixWithSeed), 'https://www.youtube.com/watch?v=aaaaaaaaaaa&list=RDaaaaaaaaaaa');
      expect(tileLinkFor(mixWithoutSeed), 'https://www.youtube.com/playlist?list=RDaaaaaaaaaaa');
      expect(tileLinkFor(playlist), 'https://www.youtube.com/playlist?list=PLbbbbbbbbbbbbbbbbbb');
    });

    testWidgets('Copy link puts it on the clipboard and says so', (tester) async {
      await tester.pumpWidget(harness(TileFor(video())));
      await openMenu(tester);

      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      expect(clipboardText, 'https://www.youtube.com/watch?v=aaaaaaaaaaa');
      expect(find.text('Link copied'), findsOneWidget);
    });

    testWidgets("a mix tile's Copy link is the mix's, not its seed video's alone", (tester) async {
      await tester.pumpWidget(harness(TileFor(mixWithSeed)));
      await openMenu(tester);

      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();

      expect(clipboardText, 'https://www.youtube.com/watch?v=aaaaaaaaaaa&list=RDaaaaaaaaaaa');
    });
  });

  group('the actions', () {
    testWidgets('Add to queue queues this video, and does not open it', (tester) async {
      var opened = 0;
      await tester.pumpWidget(harness(TileFor(video(), onTap: () => opened++)));
      final container = ProviderScope.containerOf(tester.element(find.byType(MediaTile)));
      expect(container.read(queueProvider).items, isEmpty);

      await openMenu(tester);
      await tester.tap(find.text('Add to queue'));
      await tester.pumpAndSettle();

      expect(container.read(queueProvider).items.map((v) => v.id), ['aaaaaaaaaaa']);
      expect(opened, 0);
    });

    group('against the fake sidecar', () {
      setUpAll(() async {
        await RpcClient.instance.killForTestAndWait();
        RpcClient.instance.mockCommand = ['run', 'app/test/fake_sidecar.ts', '1'];
        await RpcClient.instance.start();
      });
      tearDownAll(() => RpcClient.instance.killForTestAndWait());
      setUp(() => RpcClient.instance.call('test.reset', {}));

      /// Waits, in real time, until [done] holds. A real subprocess answers over real
      /// pipes, which the fake clock `testWidgets` runs under does not advance, so
      /// something has to let the real event loop turn — and a fixed sleep is the
      /// wrong tool for it: 400 ms was enough for `save_dialog_test.dart` and not for
      /// the first round trip here. Bounded at five seconds so a dead sidecar fails
      /// the test instead of hanging it.
      Future<void> waitReal(WidgetTester tester, bool Function() done) async {
        for (var i = 0; i < 25 && !done(); i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 350));
      }

      testWidgets('Save to Watch Later asks the sidecar and says it saved', (tester) async {
        await tester.pumpWidget(harness(TileFor(video())));
        await openMenu(tester);

        await tester.tap(find.text('Save to Watch Later'));
        await waitReal(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);

        expect(find.text('Saved to Watch Later'), findsOneWidget);
      });

      testWidgets('Save to playlist… opens the save dialog for this video — the wiring the review found missing', (tester) async {
        await tester.pumpWidget(harness(TileFor(video())));
        await openMenu(tester);

        await tester.tap(find.text('Save to playlist…'));
        await waitReal(tester, () => find.text('My Mix').evaluate().isNotEmpty);

        expect(find.byType(SaveDialog), findsOneWidget);
        expect(tester.widget<SaveDialog>(find.byType(SaveDialog)).videoId, 'aaaaaaaaaaa');
        expect(find.text('My Mix'), findsOneWidget, reason: "the dialog loaded this video's playlists");
      });
    });
  });
}
