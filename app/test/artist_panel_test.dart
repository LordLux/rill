/// The artist panel (Task 23) — the tinted hero above artist search results.
///
/// Two halves, and the first is the one that would fail silently. `fromJson`
/// ignores keys it does not know, so a field the sidecar starts shipping is
/// simply absent client-side with nothing thrown — which is exactly how the
/// tint and the shelf would arrive as "the panel just looks the same as
/// before". The strict-key check below is the same pattern `contract_test.dart`
/// applies to `VideoDetail`, extended to this model.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silky_scroll/silky_scroll.dart';

import 'package:rill/domain/artist_panel.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/theme/accent.dart';
import 'package:rill/theme/app_theme.dart';
import 'package:rill/ui/widgets/artist_panel_card.dart';
import 'package:rill/ui/widgets/media_tile.dart';
import 'package:rill/ui/widgets/subscribe_button.dart';

/// Every key `ArtistPanel` can consume. Hand-written from
/// `lib/domain/artist_panel.dart`, never derived from the payload — deriving
/// it would let the corpus define its own expectation and make this unfailable.
const artistPanelKeys = <String>{
  'channelId',
  'name',
  'handle',
  'avatarUrl',
  'backdropUrl',
  'subscriberText',
  'videoCountText',
  'description',
  'isSubscribed',
  'mixPlaylistId',
  'backgroundColor',
  'baseBackgroundColor',
  'shelfItems',
};

ArtistPanel _panel({
  ThemedColor? backgroundColor = const ThemedColor(light: 0xFF94DBF4, dark: 0xFF0C5B78),
  List<FeedItem> shelfItems = const <FeedItem>[],
  String? mixPlaylistId,
  String? description = 'Sanitised Description 1',
  String? backdropUrl,
}) => ArtistPanel(
  channelId: 'chan_001',
  name: 'Sanitised Channel 1',
  handle: '@sanitised_handle_1',
  avatarUrl: '',
  subscriberText: 'Sanitised Subscribers 1',
  videoCountText: 'Sanitised Videos 1',
  description: description,
  isSubscribed: false,
  mixPlaylistId: mixPlaylistId,
  backdropUrl: backdropUrl,
  backgroundColor: backgroundColor,
  shelfItems: shelfItems,
);

const _shelfVideo = FeedItem.video(
  kind: 'video',
  id: 'F_00000001',
  title: 'Sanitised Title 2',
  channelName: 'Sanitised Channel 2',
  channelAvatarUrl: 'https://fake.url/avatar1.jpg',
  thumbnailUrl: 'https://fake.url/thumb2.jpg',
  durationSeconds: 194,
  isLive: false,
  viewCountText: '4.5M views',
  publishedText: '3 weeks ago',
  canWatchLater: true,
  canAddToQueue: true,
);

Widget _harness(Widget child, {Brightness brightness = Brightness.dark}) => ProviderScope(
  child: MaterialApp(
    theme: buildRillTheme(kDefaultAccent).copyWith(brightness: brightness),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  group('the wire contract', () {
    final file = File('../corpus/search-artist.json');

    test('every key the corpus ships maps to a field on the model', () {
      expect(
        file.existsSync(),
        isTrue,
        reason: 'corpus/search-artist.json missing. Run bun run export-contract-corpus.',
      );

      final payload = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final panel = payload['artistPanel'] as Map<String, Object?>?;
      expect(panel, isNotNull, reason: 'the artist fixture must carry a panel');

      final unknown = panel!.keys.toSet().difference(artistPanelKeys);
      expect(unknown, isEmpty, reason: 'the sidecar ships keys this model would silently drop');

      final missing = artistPanelKeys.difference(panel.keys.toSet());
      expect(missing, isEmpty, reason: 'the model declares fields the sidecar never sends');
    });

    test('it round-trips, tint and shelf included', () {
      final payload = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final panel = ArtistPanel.fromJson(payload['artistPanel'] as Map<String, Object?>);

      // The tint is what the whole redesign hangs on, and an ARGB int that
      // arrived as null would just render as an ordinary card — a downgrade
      // no exception announces.
      expect(panel.backgroundColor, isNotNull);
      expect(panel.backgroundColor!.dark, isA<int>());
      expect(Color(panel.backgroundColor!.dark).a, 1.0, reason: 'opaque ARGB');

      expect(panel.shelfItems, isNotEmpty);
      expect(panel.shelfItems.first, isA<MixItem>());
      expect(panel.shelfItems.whereType<VideoItem>(), isNotEmpty);
      // The one-row metadata fix, asserted from the client's side of the wire.
      expect(
        panel.shelfItems.whereType<VideoItem>().every((v) => v.viewCountText != null),
        isTrue,
      );
    });

    test('MUTATION: an unknown key would fail the strict-key check', () {
      final payload = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final panel = Map<String, Object?>.from(payload['artistPanel'] as Map<String, Object?>)
        ..['bannerUrl'] = 'https://fake.url/banner.jpg';
      expect(panel.keys.toSet().difference(artistPanelKeys), equals({'bannerUrl'}));
    });
  });

  group('the tint', () {
    testWidgets('paints the colour YouTube shipped, not a scheme role', (tester) async {
      await tester.pumpWidget(_harness(ArtistPanelCard(artist: _panel())));
      await tester.pump();

      final container = tester.widget<Container>(
        find
            .descendant(of: find.byType(ArtistPanelCard), matching: find.byType(Container))
            .first,
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, const Color(0xFF0C5B78), reason: 'the dark half of the pair');
    });

    testWidgets('falls back to a scheme surface when the payload carried none', (tester) async {
      await tester.pumpWidget(_harness(ArtistPanelCard(artist: _panel(backgroundColor: null))));
      await tester.pump();

      final context = tester.element(find.byType(ArtistPanelCard));
      final container = tester.widget<Container>(
        find
            .descendant(of: find.byType(ArtistPanelCard), matching: find.byType(Container))
            .first,
      );
      expect(
        (container.decoration as BoxDecoration).color,
        Theme.of(context).colorScheme.surfaceContainerHigh,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a pale tint takes dark text, whatever the app theme says', (tester) async {
      // The case following `theme.brightness` would get wrong: a light artist
      // colour inside a dark-themed app, where white-on-white loses the name.
      await tester.pumpWidget(
        _harness(
          ArtistPanelCard(
            artist: _panel(
              backgroundColor: const ThemedColor(light: 0xFFF5F5F5, dark: 0xFFF0FBFF),
            ),
          ),
        ),
      );
      await tester.pump();

      final name = tester.widget<Text>(find.text('Sanitised Channel 1'));
      expect(name.style!.color, const Color(0xFF0B0B0B));
    });
  });

  group('the panel', () {
    testWidgets('renders name, metadata and description', (tester) async {
      await tester.pumpWidget(_harness(ArtistPanelCard(artist: _panel())));
      await tester.pump();

      expect(find.text('Sanitised Channel 1'), findsOneWidget);
      expect(
        find.text('@sanitised_handle_1 • Sanitised Subscribers 1 • Sanitised Videos 1'),
        findsOneWidget,
      );
      expect(find.text('Sanitised Description 1'), findsOneWidget);
      expect(find.byType(SubscribeButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a null description renders no line rather than "null"', (tester) async {
      await tester.pumpWidget(_harness(ArtistPanelCard(artist: _panel(description: null))));
      await tester.pump();

      expect(find.textContaining('null'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Mix action appears only when the panel carried a mix id', (tester) async {
      await tester.pumpWidget(_harness(ArtistPanelCard(artist: _panel())));
      await tester.pump();
      expect(find.text('Mix'), findsNothing);

      await tester.pumpWidget(
        _harness(ArtistPanelCard(artist: _panel(mixPlaylistId: 'mix_001'))),
      );
      await tester.pump();
      expect(find.text('Mix'), findsOneWidget);
    });
  });

  group('the header columns', () {
    testWidgets('the two columns split the free space 2:3', (tester) async {
      // The regression this exists for: `Flexible` and `Expanded` both
      // default to `flex: 1`, so the identity and action columns divided the
      // row exactly in half no matter what either wanted — the pills wrapped
      // onto a second row while hundreds of pixels sat idle under the much
      // narrower name.
      //
      // Asserted as a ratio, and derived from rendered edges rather than
      // text: `flutter test` renders in Ahem, whose glyphs are all a full em
      // square, so anything text-derived here is roughly double its shipped
      // width and no absolute figure measured in this environment means
      // anything. The split, being pure flex arithmetic, is exact in both.
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _harness(ArtistPanelCard(artist: _panel(mixPlaylistId: 'mix_001'))),
      );
      await tester.pump();

      final card = tester.getRect(
        find
            .descendant(of: find.byType(ArtistPanelCard), matching: find.byType(Container))
            .first,
      );
      // Both blocks are left-aligned in their column, so the pills' left edge
      // is the boundary between the two.
      final pills = tester.getRect(
        find.ancestor(of: find.byType(SubscribeButton), matching: find.byType(Wrap)).first,
      );

      const cardPadding = 20.0;
      const avatarBlock = 88 + 20 + 32; // avatar, its gap, and the column gap

      final identityWidth = pills.left - 32 - (card.left + cardPadding + 88 + 20);
      final actionsWidth = card.right - cardPadding - pills.left;
      final free = card.width - cardPadding * 2 - avatarBlock;

      const total = kArtistIdentityFlex + kArtistActionsFlex;
      expect(identityWidth, closeTo(free * kArtistIdentityFlex / total, 1));
      expect(actionsWidth, closeTo(free * kArtistActionsFlex / total, 1));
      // The property the weights exist for, independent of their values: an
      // even split is the bug, and it is what a stray `flex: 1` pair reverts
      // to. Asserted separately so tuning the dial cannot quietly retire it.
      expect(actionsWidth, greaterThan(identityWidth));
    });

    testWidgets('a pill lays out at its asked-for height, not a touch target', (tester) async {
      await tester.pumpWidget(_harness(ArtistPanelCard(artist: _panel())));
      await tester.pump();

      final button = find.ancestor(
        of: find.text('View Channel'),
        matching: find.byType(OutlinedButton),
      );
      expect(tester.getSize(button.first).height, kArtistActionHeight);
    });
  });

  group('the backdrop', () {
    testWidgets('draws the panel backdrop, which is not the avatar', (tester) async {
      // The two are different pictures — a wide banner versus a square
      // portrait — and the panel rendered nothing at all while it had only
      // the avatar to work with.
      await tester.pumpWidget(
        _harness(
          ArtistPanelCard(artist: _panel(backdropUrl: 'https://fake.url/backdrop1.jpg')),
        ),
      );
      await tester.pump();

      final images = tester
          .widgetList<Image>(find.byType(Image))
          .map((image) => image.image)
          .whereType<NetworkImage>()
          .map((image) => image.url)
          .toList();
      expect(images, contains('https://fake.url/backdrop1.jpg'));
    });

    testWidgets('the backdrop is clipped inside its own box, not outside it', (tester) async {
      // The bar down the artwork's left edge. A blurred layer paints past its
      // own bounds and a `ShaderMask` masks only within its rect, so anything
      // the blur pushes outside is composited unmasked — and `TileMode.clamp`
      // pushes out a solid band of the artwork's edge pixel. A `ClipRect`
      // *outside* the fractional box clips to the whole card and contains
      // none of it; inside, nothing escapes. Structural rather than
      // pixel-based on purpose: the artefact is a compositing consequence of
      // this exact nesting, so the nesting is the thing worth pinning.
      await tester.pumpWidget(
        _harness(
          ArtistPanelCard(artist: _panel(backdropUrl: 'https://fake.url/backdrop1.jpg')),
        ),
      );
      await tester.pump();

      final box = find.byType(FractionallySizedBox);
      expect(box, findsOneWidget);
      expect(
        find.descendant(of: box, matching: find.byType(ClipRect)),
        findsOneWidget,
        reason: 'the clip has to be inside the box it is meant to contain',
      );
    });

    testWidgets('no backdrop in the payload draws no image and does not throw', (tester) async {
      await tester.pumpWidget(_harness(ArtistPanelCard(artist: _panel())));
      await tester.pump();

      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the shelf', () {
    testWidgets('renders its items as ordinary tiles', (tester) async {
      await tester.pumpWidget(
        _harness(ArtistPanelCard(artist: _panel(shelfItems: const [_shelfVideo]))),
      );
      await tester.pump();

      expect(find.byType(MediaTile), findsOneWidget);
      expect(find.text('Sanitised Title 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a shelf video with an avatar draws no placeholder glyph', (tester) async {
      // The sidecar backfills `channelAvatarUrl` from the panel because the
      // shelf's own lockups carry none; without it every tile fell back to
      // MediaTile's person glyph, which is what the strip actually showed.
      await tester.pumpWidget(
        _harness(ArtistPanelCard(artist: _panel(shelfItems: const [_shelfVideo]))),
      );
      await tester.pump();

      expect(
        find.descendant(of: find.byType(MediaTile), matching: find.byIcon(Icons.person)),
        findsNothing,
      );
    });

    testWidgets('the strip leaves room for a hovered tile to grow into', (tester) async {
      // A hovered MediaTile expands past its own bounds (10 px up, 4 px
      // down) and a ListView clips to its viewport — so the spacing has to be
      // the list's own padding, not an outer Padding. Asserted as the gap
      // between the strip box and the tile inside it, which is what an outer
      // Padding would leave at zero.
      await tester.pumpWidget(
        _harness(ArtistPanelCard(artist: _panel(shelfItems: const [_shelfVideo]))),
      );
      await tester.pump();

      final strip = tester.getRect(find.byType(SilkyListView));
      final tile = tester.getRect(find.byType(MediaTile));
      expect(tile.top - strip.top, greaterThan(10.0));
      expect(strip.bottom - tile.bottom, greaterThan(4.0));
    });

    testWidgets('an empty shelf renders no strip, and does not throw', (tester) async {
      // The panel is optional two ways: a search may carry no panel, and a
      // panel may carry no shelf. Only the second reaches this widget.
      await tester.pumpWidget(_harness(ArtistPanelCard(artist: _panel())));
      await tester.pump();

      expect(find.byType(MediaTile), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
