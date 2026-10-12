/// The playlist page's own behaviour — Task 35 §3 and §4: paging on scroll,
/// playing from a row, the loading and failure states, the stub buttons, and
/// re-reading under a new identity.
///
/// No sidecar: `playlist.get` is a scripted fake that records what it was asked
/// for, which is what most of these assert on.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/data/rpc/client.dart';
import 'package:rill/domain/feed_item.dart';
import 'package:rill/ui/auth_controller.dart';
import 'package:rill/ui/open_video.dart';
import 'package:rill/ui/pages/playlist.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player_shell.dart' show rootNavigatorKey;
import 'package:rill/ui/playlist_controller.dart';
import 'package:rill/ui/queue_controller.dart';
import 'package:rill/ui/widgets/media_tile.dart';
import 'package:rill/ui/widgets/shortcut_tooltip.dart';

VideoItem _video(int n) => VideoItem(
      kind: 'video',
      id: 'v$n',
      title: 'Video $n',
      channelName: 'Channel',
      thumbnailUrl: 'https://i.ytimg.com/vi/v$n/hq.jpg',
      isLive: false,
      canWatchLater: true,
      canAddToQueue: true,
    );

/// A playlist of [pages] pages of [perPage], behind `page-N` tokens.
class _Playlists implements MixService {
  _Playlists({this.pages = 3, this.owned = false});

  static const int perPage = 20;

  final int pages;
  final bool owned;

  /// The continuation of every request, in order; null is the first page.
  final List<String?> asked = [];

  /// How many of the next continuation requests fail.
  int failNext = 0;

  /// Thrown for the first page for as long as it is set.
  Object? firstPageError;

  Duration delay = Duration.zero;

  /// How long a continuation takes, when it should outlast a first page.
  Duration continuationDelay = Duration.zero;

  /// Added to every video number in thousands, so a test can tell which
  /// answers a list was built from.
  int era = 0;

  @override
  Future<PlaylistResult> getPlaylist(String playlistId, {String? continuation}) async {
    asked.add(continuation);
    // As asked, not as answered: a request that outlives a change still
    // returns what it was asked for.
    final era = this.era;
    final wait = continuation == null ? delay : (continuationDelay > Duration.zero ? continuationDelay : delay);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    if (continuation == null) {
      final error = firstPageError;
      if (error != null) throw error;
    } else if (failNext > 0) {
      failNext--;
      throw StateError('network down');
    }
    final page = continuation == null ? 0 : int.parse(continuation.substring('page-'.length));
    return PlaylistResult(
      header: continuation != null
          ? null
          : PlaylistHeader(
              thumbnailUrl: null,
              ownerName: 'Owner',
              ownerChannelId: null,
              ownerAvatarUrl: null,
              viewCountText: null,
              description: null,
              visibility: 'public',
              backgroundColor: null,
              isOwnedByViewer: owned,
            ),
      title: 'My Playlist',
      videoCount: pages * perPage,
      items: [for (var i = 0; i < perPage; i++) _video(era * 1000 + page * perPage + i)],
      continuation: page + 1 < pages ? 'page-${page + 1}' : null,
    );
  }

  @override
  Future<MixStart> start(String playlistId, {String? videoId, String? params}) async => throw UnimplementedError();

  @override
  Future<MixExtension> extend(String playlistId, String afterVideoId) async => throw UnimplementedError();
}

/// Playback that plays nothing: the real one resolves streams when the queue moves.
class _SilentPlayback extends PlaybackController {
  @override
  PlaybackState build() => const PlaybackState();
}

class _Auth extends AuthController {
  _Auth(this.initial);

  final AuthState initial;

  @override
  AuthState build() => initial;

  void become(AuthState next) => state = next;
}

const AuthState _signedIn = AuthState(status: AuthStatus.authenticated, accountHandle: '@tester');
const AuthState _signedOut = AuthState(status: AuthStatus.anonymous);

late ProviderContainer _container;

Future<void> _open(
  WidgetTester tester,
  _Playlists playlists, {
  AuthState auth = _signedOut,
  Size size = const Size(1200, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  _container = ProviderContainer(
    overrides: [
      mixServiceProvider.overrideWithValue(playlists),
      playbackProvider.overrideWith(_SilentPlayback.new),
      authProvider.overrideWith(() => _Auth(auth)),
    ],
  );
  addTearDown(_container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: _container,
    child: const MaterialApp(home: PlaylistPage(playlistId: 'PL123')),
  ));
  await _settle(tester);
}

/// Frames, not `pumpAndSettle`: a spinner or a skeleton never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

PlaylistState _page() => _container.read(playlistProvider('PL123')).value!;

/// The list's own scroll position: the one its rows are in.
ScrollPosition _list(WidgetTester tester) =>
    tester.state<ScrollableState>(find.ancestor(of: find.text('Video 0', skipOffstage: false), matching: find.byType(Scrollable)).first).position;

void main() {
  group('paging', () {
    testWidgets('the header and the first page show, and the next is asked for only near the end', (tester) async {
      final playlists = _Playlists();
      await _open(tester, playlists);

      expect(find.text('My Playlist'), findsOneWidget);
      expect(find.text('Video 0'), findsOneWidget);
      expect(playlists.asked, [null], reason: 'one page on open, not the whole playlist');

      final list = _list(tester);
      list.jumpTo(200);
      await _settle(tester);
      expect(playlists.asked, [null], reason: 'nowhere near the end yet');

      list.jumpTo(list.maxScrollExtent);
      await _settle(tester);
      expect(playlists.asked, [null, 'page-1']);
      expect(_page().items, hasLength(40));
    });

    testWidgets('a null continuation ends it', (tester) async {
      final playlists = _Playlists(pages: 1);
      await _open(tester, playlists);

      final list = _list(tester);
      list.jumpTo(list.maxScrollExtent);
      await _settle(tester);
      list.jumpTo(list.maxScrollExtent);
      await _settle(tester);

      expect(playlists.asked, [null]);
      expect(_page().continuation, isNull);
    });

    testWidgets('a page that fails keeps the list and offers a retry at its foot', (tester) async {
      final playlists = _Playlists()..failNext = 1;
      await _open(tester, playlists);

      final list = _list(tester);
      list.jumpTo(list.maxScrollExtent);
      await _settle(tester);
      expect(_page().items, hasLength(20), reason: 'what was loaded is still there');
      expect(_page().error, isNotNull);

      // More scrolling does not ask again by itself: the retry is the user's.
      list.jumpTo(list.maxScrollExtent - 50);
      await _settle(tester);
      list.jumpTo(list.maxScrollExtent);
      await _settle(tester);
      expect(playlists.asked, [null, 'page-1'], reason: 'one request per scroll event while the network is down');

      await tester.tap(find.text('Retry'));
      await _settle(tester);

      expect(_page().error, isNull);
      expect(_page().items, hasLength(40));
      expect(playlists.asked, [null, 'page-1', 'page-1']);
    });
  });

  group('playing from a row', () {
    testWidgets('a row on a later page starts the playlist there, with what the page had loaded', (tester) async {
      final playlists = _Playlists();
      await _open(tester, playlists);
      // Something to replace, so there is an undo to offer.
      _container.read(queueProvider.notifier).debugSetStateForTest(QueueState(items: [_video(900)], currentIndex: 0));

      final list = _list(tester);
      list.jumpTo(list.maxScrollExtent);
      await _settle(tester);
      expect(_page().items, hasLength(40));

      // Rows are built lazily: bring the one on the second page into the list.
      await tester.scrollUntilVisible(
        find.text('Video 25'),
        300,
        scrollable: find.ancestor(of: find.text('Video 19', skipOffstage: false), matching: find.byType(Scrollable)).first,
      );
      await _settle(tester);
      await tester.tap(find.text('Video 25'));
      await _settle(tester);

      final queue = _container.read(queueProvider);
      expect(queue.mix?.isPlaylist, isTrue);
      expect(queue.current?.id, 'v25', reason: 'the playlist from that video, not the video alone');
      expect(queue.entries.length, greaterThan(1));
      expect(playlists.asked.where((token) => token == null), hasLength(1), reason: 'page one is not fetched again');

      // The tile's path, not a bare queue call: it is the one that offers the undo.
      expect(find.text('Queue replaced by My Playlist'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
    });
  });

  group('before and instead of the page', () {
    testWidgets('a skeleton stands in while the first page is out', (tester) async {
      final playlists = _Playlists()..delay = const Duration(milliseconds: 900);
      await _open(tester, playlists);

      final skeleton = find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == 'Loading playlist');
      expect(skeleton, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await _settle(tester);
      expect(skeleton, findsNothing);
      expect(find.text('Video 0'), findsOneWidget);
    });

    // Nothing in it scrolls, so it is cut off at the bottom: laid out in a
    // plain column, a window shorter than the header card overflowed.
    for (final size in const [Size(700, 300), Size(1200, 300)]) {
      testWidgets('the skeleton fits a ${size.width.toInt()} x ${size.height.toInt()} window', (tester) async {
        final playlists = _Playlists()..delay = const Duration(milliseconds: 900);
        await _open(tester, playlists, size: size);

        expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == 'Loading playlist'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _settle(tester);
      });
    }

    testWidgets('a first page that fails says what was said, and asking again works', (tester) async {
      final playlists = _Playlists()..firstPageError = RpcException('UPSTREAM_ERROR', 'The playlist does not exist.', RpcRetryMode.auto);
      await _open(tester, playlists);

      expect(find.text('The playlist does not exist.'), findsOneWidget);
      expect(find.text('Video 0'), findsNothing);

      playlists.firstPageError = null;
      await tester.tap(find.text('Try again'));
      await _settle(tester);

      expect(find.text('The playlist does not exist.'), findsNothing);
      expect(find.text('Video 0'), findsOneWidget);
      expect(playlists.asked, [null, null]);
    });
  });

  group('the header\'s buttons', () {
    IconButton buttonOf(WidgetTester tester, IconData icon) =>
        tester.widget<IconButton>(find.ancestor(of: find.byIcon(icon), matching: find.byType(IconButton)));

    void expectStub(WidgetTester tester, IconData icon, String name, String says) {
      expect(buttonOf(tester, icon).onPressed, isNull, reason: '$name is not built: it must not look pressable');
      expect(tester.widget<Icon>(find.byIcon(icon)).semanticLabel, name);
      final tip = tester.widget<ShortcutTooltip>(find.ancestor(of: find.byIcon(icon), matching: find.byType(ShortcutTooltip)));
      expect(tip.label, says);
      expect(tip.silent, isTrue, reason: 'in the tree, not an overlay (CLAUDE.md, Accessibility)');
    }

    testWidgets('Save and Shuffle are there, disabled, named, and say why; Play all and Share are live', (tester) async {
      await _open(tester, _Playlists());

      expectStub(tester, Icons.bookmark_border, 'Save playlist', 'Save is not available yet');
      expectStub(tester, Icons.shuffle, 'Shuffle', 'Shuffle is not available yet');
      expect(buttonOf(tester, Icons.reply).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(find.ancestor(of: find.text('Play all'), matching: find.bySubtype<FilledButton>())).onPressed, isNotNull);
      expect(find.byIcon(Icons.add), findsNothing, reason: 'not the viewer\'s playlist');
    });

    testWidgets('the owner\'s two are stubs too, and only for the owner while signed in', (tester) async {
      await _open(tester, _Playlists(owned: true), auth: _signedIn);
      expectStub(tester, Icons.add, 'Add videos', 'Add videos is not available yet');
      expectStub(tester, Icons.edit_outlined, 'Edit playlist', 'Edit is not available yet');

      // Signed out, the page still says "owned" until its re-read lands: the
      // buttons go at once.
      (_container.read(authProvider.notifier) as _Auth).become(_signedOut);
      await tester.pump();
      expect(find.byIcon(Icons.add), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      await _settle(tester);
    });
  });

  // Decision 1 of the task: the thumbnail plays, the rest of the tile opens the
  // page. Two targets, so two names and two Tab stops.
  group('a playlist tile', () {
    const item = PlaylistItem(
      kind: 'playlist',
      id: 'PL123',
      title: 'A playlist',
      thumbnailUrl: 'https://i.ytimg.com/vi/ccccccccccc/hq.jpg',
      videoCount: 60,
      channelName: 'Owner',
    );

    Future<_Playlists> pumpTile(WidgetTester tester, {bool navigator = false}) async {
      final playlists = _Playlists();
      _container = ProviderContainer(
        overrides: [
          mixServiceProvider.overrideWithValue(playlists),
          playbackProvider.overrideWith(_SilentPlayback.new),
          authProvider.overrideWith(() => _Auth(_signedOut)),
        ],
      );
      addTearDown(_container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: _container,
        child: MaterialApp(
          // Only where the test wants the page pushed: playing also pushes the
          // watch page through this key, which is not what is under test.
          navigatorKey: navigator ? rootNavigatorKey : null,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => SizedBox(
                width: 400,
                child: MediaTile(
                  spec: specFor(item)!,
                  onTap: tapHandlerFor(context, ref, item),
                  onThumbnailTap: thumbnailTapHandlerFor(context, ref, item),
                ),
              ),
            ),
          ),
        ),
      ));
      await _settle(tester);
      return playlists;
    }

    testWidgets('has two names: one to play it, one to open it', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpTile(tester);
      expect(find.bySemanticsLabel('Play A playlist'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Open playlist A playlist')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the thumbnail plays it, by pointer and by keyboard, and opens no page', (tester) async {
      final semantics = tester.ensureSemantics();
      final playlists = await pumpTile(tester);

      await tester.tap(find.bySemanticsLabel('Play A playlist'));
      await _settle(tester);
      expect(_container.read(queueProvider).mix?.playlistId, 'PL123');
      // Once for the start; the queue then pages ahead by itself.
      expect(playlists.asked.where((token) => token == null), hasLength(1));
      expect(find.byType(PlaylistPage), findsNothing);

      // Tab reaches the tile, then its thumbnail; Enter there starts it again.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(
        playlists.asked.where((token) => token == null),
        hasLength(2),
        reason: 'the thumbnail is a Tab stop of its own, and Enter presses it',
      );
      expect(find.byType(PlaylistPage), findsNothing);
      // Let the two "Queue replaced" snack bars run out.
      await tester.pump(const Duration(seconds: 12));
      await _settle(tester);
      semantics.dispose();
    });

    testWidgets('the rest of it opens the page and plays nothing', (tester) async {
      await pumpTile(tester, navigator: true);

      await tester.tap(find.text('A playlist'));
      await _settle(tester);

      expect(find.byType(PlaylistPage), findsOneWidget);
      expect(_container.read(queueProvider).isEmpty, isTrue);
    });
  });

  // A page asked for under one identity must not land under the next: the
  // re-read is the whole of what the new viewer may see.
  testWidgets('a page still on the wire when the identity changes is dropped', (tester) async {
    final playlists = _Playlists();
    await _open(tester, playlists, auth: _signedIn);

    playlists.continuationDelay = const Duration(milliseconds: 900);
    final list = _list(tester);
    list.jumpTo(list.maxScrollExtent);
    await tester.pump(const Duration(milliseconds: 100));
    expect(playlists.asked, [null, 'page-1'], reason: 'the second page is out');

    playlists.era = 1;
    (_container.read(authProvider.notifier) as _Auth).become(_signedOut);
    // The re-read answers first, then the old viewer's page, then whatever the
    // new page went on to ask for.
    // Looked at every 50 ms and not only at the end: the new page's own next
    // request would paper over a stale one a moment later.
    var reRead = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final items = _container.read(playlistProvider('PL123')).value?.items ?? const <VideoItem>[];
      reRead = reRead || (items.isNotEmpty && items.first.id == 'v1000');
      if (!reRead) continue;
      expect(
        items.where((item) => !item.id.startsWith('v1')),
        isEmpty,
        reason: 'at ${i * 50} ms: nothing the old viewer asked for is in the list the new one sees',
      );
    }

    expect(reRead, isTrue);
    expect(playlists.asked.take(3), [null, 'page-1', null]);
  });

  testWidgets('signing in reads the page again, and keeps the anonymous one on screen meanwhile', (tester) async {
    final playlists = _Playlists();
    await _open(tester, playlists);
    expect(playlists.asked, [null]);

    playlists.delay = const Duration(milliseconds: 400);
    (_container.read(authProvider.notifier) as _Auth).become(_signedIn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(playlists.asked, [null, null], reason: 'whose playlist it is, and whether they may see it, is the viewer\'s');
    expect(find.text('Video 0'), findsOneWidget, reason: 'not blanked to a skeleton for the re-read');

    await _settle(tester);
    expect(find.text('Video 0'), findsOneWidget);
  });

  // The other direction is not symmetric: what is on screen may be a private
  // playlist, and it must not outlive the account by the length of a request.
  testWidgets('signing out takes the page off the screen at once, not when the re-read lands', (tester) async {
    final playlists = _Playlists(owned: true);
    await _open(tester, playlists, auth: _signedIn);
    expect(find.text('My Playlist'), findsOneWidget);

    playlists.delay = const Duration(milliseconds: 400);
    (_container.read(authProvider.notifier) as _Auth).become(_signedOut);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('My Playlist'), findsNothing);
    expect(find.text('Video 0'), findsNothing);
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == 'Loading playlist'), findsOneWidget);

    await _settle(tester);
    expect(find.text('Video 0'), findsOneWidget);
  });

  group('a queue that is already this playlist', () {
    Future<void> playThenReturn(WidgetTester tester, _Playlists playlists) async {
      await _open(tester, playlists);
      await tester.tap(find.text('Video 1'));
      await _settle(tester);
      // The "Queue replaced" snack bar of that first start, if any, runs out.
      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
      expect(_container.read(queueProvider).current?.id, 'v1');
    }

    testWidgets('is moved within by another row: same entries, no undo, no fetch', (tester) async {
      final playlists = _Playlists();
      await playThenReturn(tester, playlists);
      final before = _container.read(queueProvider).entries;
      final askedBefore = playlists.asked.length;

      await tester.tap(find.text('Video 3'));
      await _settle(tester);

      final queue = _container.read(queueProvider);
      expect(queue.current?.id, 'v3');
      expect(identical(queue.entries[3], before[3]), isTrue, reason: 'the queue was kept, not rebuilt');
      expect(find.textContaining('Queue replaced'), findsNothing);
      expect(playlists.asked.where((token) => token == null), hasLength(1));
      expect(playlists.asked.length, askedBefore);
    });

    testWidgets('is restarted from its first video by Play all, without replacing it', (tester) async {
      final playlists = _Playlists();
      await playThenReturn(tester, playlists);
      final before = _container.read(queueProvider).entries;

      await tester.tap(find.text('Play all'));
      await _settle(tester);

      final queue = _container.read(queueProvider);
      expect(queue.current?.id, 'v0');
      expect(identical(queue.entries.first, before.first), isTrue);
      expect(find.textContaining('Queue replaced'), findsNothing);
    });
  });

  testWidgets('Play all starts from what the page has loaded, without asking for page one again', (tester) async {
    final playlists = _Playlists();
    await _open(tester, playlists);

    await tester.tap(find.text('Play all'));
    await _settle(tester);

    expect(_container.read(queueProvider).current?.id, 'v0');
    expect(playlists.asked.where((token) => token == null), hasLength(1));
  });

  // The header card stacks its artwork over its text below a width of 664,
  // its own margins included.
  testWidgets('the header puts its artwork beside its text from 664 wide, and over it below', (tester) async {
    await _open(tester, _Playlists());

    Future<void> resize(double width) async {
      tester.view.physicalSize = Size(width, 800);
      await tester.pump();
      await tester.pump();
    }

    final card = find.byType(TooltipBounds).first;
    double headerWidth() => tester.getSize(card).width + 24;
    bool sideBySide() {
      final art = tester.getRect(find.descendant(of: card, matching: find.byType(AspectRatio)).first);
      return tester.getTopLeft(find.text('My Playlist')).dy < art.bottom;
    }

    // Narrow enough for the stacked page layout, where the header is as wide
    // as the page; what the rail takes is measured, not assumed.
    await resize(900);
    final rail = 900 - headerWidth();

    await resize(rail + 664);
    expect(headerWidth(), 664);
    expect(sideBySide(), isTrue);

    await resize(rail + 663);
    expect(headerWidth(), 663);
    expect(sideBySide(), isFalse);
  });
}
