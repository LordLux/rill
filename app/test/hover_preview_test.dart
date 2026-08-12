/// Hover previews — the real video, muted, in the tile (`architecture.md` §2.6).
///
/// Five properties here would pass against deleted code if written the obvious way: the delay,
/// the cancel, the suppression, the 30 s watch threshold, and the end-of-video teardown. Each is
/// marked MUTATION CHECK where it lives, with what the naive version would miss.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/playback_source.dart';
import 'package:rill/ui/hover_preview.dart';
import 'package:rill/ui/widgets/media_tile.dart';

import 'fake_engine.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

PlaybackVariant variant(int height) => PlaybackVariant(
      videoUrl: 'https://r1.googlevideo.com/videoplayback?h=$height',
      audioUrl: 'https://r1.googlevideo.com/videoplayback?audio=1',
      itag: height,
      height: height,
      fps: 30,
      videoCodec: 'vp9',
      audioCodec: 'opus',
    );

/// A ladder shaped like a real one: ranked best-first, 2160 down to 360.
PlaybackSource ladder() => PlaybackSource(
      sessionId: 'preload-session',
      durationMs: 600000,
      variants: [variant(2160), variant(1080), variant(720), variant(360)],
    );

/// Everything the controller talks to, counted.
class FakeBackend {
  FakeBackend({this.source, this.resolveError});

  final PlaybackSource? source;
  final Object? resolveError;

  final List<String> resolved = [];
  final List<String> sessionsOpened = [];
  final List<(String, int, String)> reports = [];
  final List<String> closed = [];

  Future<PlaybackSource> resolve(String videoId) async {
    resolved.add(videoId);
    if (resolveError != null) throw resolveError!;
    return source ?? ladder();
  }

  /// Held open by a test that needs the pointer to leave mid-call.
  Future<String?>? openSessionGate;

  Future<String?> openSession(String videoId) async {
    sessionsOpened.add(videoId);
    final gate = openSessionGate;
    if (gate != null) return gate;
    return 'watch-session-${sessionsOpened.length}';
  }

  Future<void> report(String sessionId, int positionMs, String state) async {
    reports.add((sessionId, positionMs, state));
  }

  Future<void> close(String sessionId) async => closed.add(sessionId);
}

class Harness {
  Harness({PlaybackSource? source, Object? resolveError})
      : backend = FakeBackend(source: source, resolveError: resolveError) {
    preview = HoverPreview(
      shell: shell,
      engineFactory: () {
        engineBuilds++;
        return engine;
      },
      resolve: backend.resolve,
      openSession: backend.openSession,
      report: backend.report,
      closeSession: backend.close,
    );
  }

  final FakeEngine shell = FakeEngine();
  final FakeEngine engine = FakeEngine();
  final FakeBackend backend;
  late final HoverPreview preview;
  int engineBuilds = 0;

  /// mpv has a picture. Either signal will do; position is the honest one, so tests drive it.
  void firstFrame() => engine.emitPosition(const Duration(milliseconds: 200));

  void dispose() => unawaited(preview.dispose());
}

const TileSpec kTile = TileSpec(
  title: 'A video',
  thumbnailUrl: 'https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg',
  previewVideoId: 'aaaaaaaaaaa',
  isStackedCards: false,
  durationText: '4:20',
  durationTone: DurationBadgeTone.normal,
  badges: <String>[],
  canWatchLater: true,
  canAddToQueue: true,
  primaryLine: 'Channel',
);

TileSpec tileFor(String id) => TileSpec(
      title: 'Video $id',
      thumbnailUrl: 'https://i.ytimg.com/vi/$id/hq.jpg',
      previewVideoId: id,
      isStackedCards: false,
      durationTone: DurationBadgeTone.normal,
      badges: const <String>[],
      canWatchLater: false,
      canAddToQueue: false,
      primaryLine: 'Channel',
    );

/// The preview surface, wherever it is mounted.
Finder get previewSurface => find.byKey(FakeEngine.surfaceKey);

/// How visible the mounted preview surface is, or null when there is none. The surface is
/// mounted before the first frame and hidden, not unmounted, so "the thumbnail is still what you
/// see" is a question about opacity rather than absence.
double? previewOpacity(WidgetTester tester) {
  final opacity = find.ancestor(of: previewSurface, matching: find.byType(Opacity));
  if (opacity.evaluate().isEmpty) return null;
  return tester.widget<Opacity>(opacity.first).opacity;
}

/// Somewhere on screen no tile covers — see the padding in [pumpTiles].
const Offset kAwayFromTiles = Offset(5, 5);

Future<TestGesture> pumpTiles(
  WidgetTester tester,
  Harness harness, {
  List<TileSpec> tiles = const <TileSpec>[kTile],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HoverPreviewScope(
        preview: harness.preview,
        child: Scaffold(
          // Inset, so there is somewhere to park the pointer that is *not* over a tile —
          // otherwise `onExit` never fires and every cancellation assertion tests nothing.
          body: Padding(
            padding: const EdgeInsets.all(60),
            child: Row(
              children: [
                for (final tile in tiles)
                  Expanded(
                    child: MediaTile(
                      key: ValueKey<String>(tile.previewVideoId ?? ''),
                      spec: tile,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  return gesture;
}

/// Let the resolve → open chain finish and any rebuild land. Several frames rather than one, and
/// not padding: the chain is three awaits deep, and a notifier firing partway through a frame
/// marks its builder dirty for the *next* one — a single `pump()` here is order-dependent.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(Duration.zero);
  }
}

/// Rebuild the single-tile tree with a different spec under the **same key**, which is what a
/// `ListView` does when it recycles an element.
Future<void> recycleTile(WidgetTester tester, Harness harness, TileSpec spec) async {
  await tester.pumpWidget(
    MaterialApp(
      home: HoverPreviewScope(
        preview: harness.preview,
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(60),
            child: Row(
              children: [
                Expanded(child: MediaTile(key: const ValueKey<String>('slot'), spec: spec)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Hover a tile and get all the way to a playing, visible preview.
Future<TestGesture> startPreview(WidgetTester tester, Harness harness) async {
  final gesture = await pumpTiles(tester, harness);
  await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
  await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
  await settle(tester);
  harness.firstFrame();
  await settle(tester);
  return gesture;
}

void main() {
  // -------------------------------------------------------------------------

  group('the hover delay', () {
    testWidgets('nothing is resolved before it elapses', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));

      // MUTATION CHECK. One millisecond short: the obvious version hovers, waits a second and
      // asserts a preview started, which passes with no delay implemented at all.
      await tester.pump(HoverPreview.hoverDelay - const Duration(milliseconds: 1));
      await settle(tester);

      expect(h.backend.resolved, isEmpty, reason: 'a stream was resolved before the delay elapsed');
      expect(h.engineBuilds, 0, reason: 'a second mpv instance was built for a hover that had not committed');
      expect(previewSurface, findsNothing);
      expect(previewOpacity(tester), isNull);
    });

    testWidgets('a stream opens once it has, muted, at 720p or below', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);

      expect(h.backend.resolved, <String>['aaaaaaaaaaa']);
      expect(h.engine.opened.single.height, 720, reason: 'F16: 2160p60 is not a preview');
      // Muted before the media opens; after would be a race the user hears.
      expect(h.engine.volumes.first, 0);
      expect(h.preview.activeVideoId, 'aaaaaaaaaaa');
    });

    testWidgets('the thumbnail stays until there is a first frame', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);

      // Opened and playing, but nothing decoded yet: mounted so media_kit has somewhere to
      // render, transparent so what the user sees is still the thumbnail.
      expect(h.engine.opened, hasLength(1));
      expect(previewOpacity(tester), 0);
      expect(find.byType(Image), findsWidgets);

      h.firstFrame();
      await settle(tester);
      expect(previewOpacity(tester), 1);
    });

    testWidgets('buffering clearing is the other first-frame signal', (tester) async {
      // Either can arrive first, depending on how fast the stream starts.
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      expect(previewOpacity(tester), 0);

      h.engine.setBuffering(false);
      await settle(tester);
      expect(previewOpacity(tester), 1);
    });
  });

  // -------------------------------------------------------------------------

  group('cancelling', () {
    testWidgets('leaving inside the delay resolves nothing, ever', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.moveTo(kAwayFromTiles);

      // MUTATION CHECK. Deleting the cancel leaves the delay timer running, so the wait has to
      // outlast the timer the buggy version would still have pending.
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);

      expect(h.backend.resolved, isEmpty, reason: 'a cancelled hover still opened a stream');
      expect(previewSurface, findsNothing);
      expect(h.preview.activeVideoId, isNull);
      expect(h.preview.isWaiting, isFalse);
    });

    testWidgets('leaving mid-playback stops the engine and restores the thumbnail',
        (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await startPreview(tester, h);
      expect(previewSurface, findsOneWidget);

      await gesture.moveTo(kAwayFromTiles);
      await tester.pump();

      expect(h.preview.activeVideoId, isNull);
      expect(h.engine.stopCount, greaterThan(0), reason: 'the preview kept decoding after the pointer left');
      expect(previewSurface, findsNothing);
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('sweeping across a grid opens no streams at all', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final tiles = [for (var i = 0; i < 5; i++) tileFor('video$i')];
      final gesture = await pumpTiles(tester, h, tiles: tiles);

      // A pointer crossing a row spends far less than the delay over each tile.
      for (final tile in tiles) {
        await gesture.moveTo(tester.getCenter(find.byKey(ValueKey<String>(tile.previewVideoId!))));
        await tester.pump(const Duration(milliseconds: 120));
      }
      await gesture.moveTo(kAwayFromTiles);
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);

      expect(h.backend.resolved, isEmpty);
      expect(h.engineBuilds, 0);
    });

    testWidgets('only one tile previews at a time', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final tiles = [tileFor('video0'), tileFor('video1')];
      final gesture = await pumpTiles(tester, h, tiles: tiles);

      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey<String>('video0'))));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      h.firstFrame();
      await settle(tester);
      expect(h.preview.activeVideoId, 'video0');
      expect(previewSurface, findsOneWidget);

      // Straight onto the neighbour: the first must stop before the second's delay begins.
      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey<String>('video1'))));
      await tester.pump();
      expect(h.preview.activeVideoId, isNull);
      expect(previewSurface, findsNothing);

      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      h.firstFrame();
      await settle(tester);
      expect(h.preview.activeVideoId, 'video1');
      // Still one engine — the shared surface, moved, not a second one built.
      expect(h.engineBuilds, 1);
      expect(previewSurface, findsOneWidget);
    });
  });

  // -------------------------------------------------------------------------

  group('suppression', () {
    testWidgets('nothing previews while a video is playing', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      // MUTATION CHECK. A harness whose shell is idle never exercises suppression at all, so
      // the shell is set playing first and the assertion is that nothing happens at all.
      h.shell.setPlaying(true);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);

      expect(h.backend.resolved, isEmpty, reason: 'a preview competed with the video being watched');
      expect(previewSurface, findsNothing);
      expect(h.preview.isSuppressed, isTrue);
    });

    testWidgets('a paused video does not suppress', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);
      h.shell.setPlaying(true);
      h.shell.setPlaying(false);

      await startPreview(tester, h);

      expect(h.preview.isSuppressed, isFalse);
      expect(h.backend.resolved, <String>['aaaaaaaaaaa']);
      expect(previewSurface, findsOneWidget);
      // And the paused video was left entirely alone.
      expect(h.shell.opened, isEmpty);
      expect(h.shell.stopCount, 0);
    });

    testWidgets('playback starting takes a running preview down', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);
      expect(previewSurface, findsOneWidget);

      // The mini-player's play button, with the pointer still on a tile.
      h.shell.setPlaying(true);
      await tester.pump();

      expect(h.preview.activeVideoId, isNull);
      expect(previewSurface, findsNothing);
      expect(h.engine.stopCount, greaterThan(0));
    });
  });

  // -------------------------------------------------------------------------

  group('the hover controls', () {
    testWidgets('the mute toggle replaces Watch Later and Add to queue', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pumpAndSettle();

      // Before the preview: the two ordinary actions.
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.byIcon(Icons.playlist_play), findsOneWidget);
      expect(find.byIcon(Icons.volume_off), findsNothing);

      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      h.firstFrame();
      await settle(tester);
      await tester.pumpAndSettle();

      // During it: the mute toggle, and only the mute toggle.
      expect(find.byIcon(Icons.volume_off), findsOneWidget);
      expect(find.byIcon(Icons.schedule), findsNothing);
      expect(find.byIcon(Icons.playlist_play), findsNothing);

      // And they come back when it stops.
      await gesture.moveTo(kAwayFromTiles);
      await tester.pumpAndSettle();
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.byIcon(Icons.volume_off), findsNothing);
    });

    testWidgets('tapping it unmutes, and says so', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);
      await tester.pumpAndSettle();

      expect(h.preview.isMuted, isTrue);
      await tester.tap(find.byIcon(Icons.volume_off));
      await tester.pumpAndSettle();

      expect(h.preview.isMuted, isFalse);
      expect(h.engine.volumes.last, 100);
      expect(find.byIcon(Icons.volume_up), findsOneWidget);

      await tester.tap(find.byIcon(Icons.volume_up));
      await tester.pumpAndSettle();
      expect(h.engine.volumes.last, 0);
      expect(find.byIcon(Icons.volume_off), findsOneWidget);
    });

    testWidgets('the duration badge is hidden while the preview plays', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pumpAndSettle();
      expect(find.text('4:20'), findsOneWidget);

      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      // Still showing while the stream opens — the thumbnail is still what is on screen.
      expect(find.text('4:20'), findsOneWidget);

      h.firstFrame();
      await settle(tester);
      expect(find.text('4:20'), findsNothing);

      // And back when the preview stops.
      await gesture.moveTo(kAwayFromTiles);
      await tester.pumpAndSettle();
      expect(find.text('4:20'), findsOneWidget);
    });

    testWidgets('there is no CC button — a dead control is worse than none', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.closed_caption), findsNothing);
      expect(find.byIcon(Icons.closed_caption_off), findsNothing);
    });

    testWidgets('a preview always starts muted, even after unmuting the last one',
        (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await startPreview(tester, h);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.volume_off));
      await tester.pumpAndSettle();
      expect(h.preview.isMuted, isFalse);

      await gesture.moveTo(kAwayFromTiles);
      await tester.pumpAndSettle();
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      h.firstFrame();
      await settle(tester);
      await tester.pumpAndSettle();

      expect(h.preview.isMuted, isTrue);
      expect(h.engine.volumes.last, 0);
    });
  });

  // -------------------------------------------------------------------------

  group('a long preview becomes a watch', () {
    testWidgets('nothing is reported below the threshold', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);

      // MUTATION CHECK. One second short: a version that reports from the first frame passes
      // any test that only asks "did it report eventually", and puts unwatched videos in history.
      h.engine.emitPosition(HoverPreview.watchThreshold - const Duration(seconds: 1));
      await settle(tester);

      expect(h.backend.sessionsOpened, isEmpty);
      expect(h.backend.reports, isEmpty);
      expect(h.preview.reportingSessionId, isNull);
    });

    testWidgets('past it, a reportable session is opened and the view registers',
        (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);
      h.engine.emitPosition(HoverPreview.watchThreshold);
      await settle(tester);

      // A second, non-preload open — the preload's sessionId is not reportable by construction.
      expect(h.backend.sessionsOpened, <String>['aaaaaaaaaaa']);
      expect(h.preview.reportingSessionId, 'watch-session-1');

      // Immediately, not on the first tick — a 15 s wait would lose the view.
      expect(h.backend.reports.single.$1, 'watch-session-1');
      expect(h.backend.reports.single.$3, 'playing');
    });

    testWidgets('promotion happens once, not on every position tick', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);
      for (var i = 0; i < 10; i++) {
        h.engine.emitPosition(HoverPreview.watchThreshold + Duration(seconds: i));
        await settle(tester);
      }

      expect(h.backend.sessionsOpened, hasLength(1));
    });

    testWidgets('it keeps reporting on the cadence', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);
      HoverPreview.reportInterval = const Duration(milliseconds: 100);
      addTearDown(() => HoverPreview.reportInterval = const Duration(seconds: 15));

      await startPreview(tester, h);
      h.engine.emitPosition(HoverPreview.watchThreshold);
      await settle(tester);
      expect(h.backend.reports, hasLength(1));

      await tester.pump(const Duration(milliseconds: 101));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 101));
      await settle(tester);
      expect(h.backend.reports.length, greaterThanOrEqualTo(3));
    });

    testWidgets('leaving sends a final report at the position it reached, then closes',
        (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await startPreview(tester, h);
      h.engine.emitPosition(HoverPreview.watchThreshold);
      await settle(tester);
      h.engine.emitPosition(const Duration(minutes: 4));
      await settle(tester);

      await gesture.moveTo(kAwayFromTiles);
      await settle(tester);

      // Captured before the engine is stopped; read afterwards it is zero.
      final last = h.backend.reports.last;
      expect(last.$3, 'paused');
      expect(last.$2, const Duration(minutes: 4).inMilliseconds);
      expect(h.backend.closed, <String>['watch-session-1']);
      expect(h.preview.reportingSessionId, isNull);
    });

    testWidgets('a session opened after the preview was abandoned is closed again', (tester) async {
      // `_openSession` is a round trip; the pointer can leave during it. Nothing else knows the
      // sessionId, so leaving it open strands it against the §5 cap.
      final h = Harness();
      addTearDown(h.dispose);

      final gate = Completer<String?>();
      h.backend.openSessionGate = gate.future;

      final gesture = await startPreview(tester, h);
      h.engine.emitPosition(HoverPreview.watchThreshold);
      await settle(tester);
      expect(h.backend.sessionsOpened, <String>['aaaaaaaaaaa']);
      expect(h.backend.closed, isEmpty);

      await gesture.moveTo(kAwayFromTiles);
      await settle(tester);
      gate.complete('watch-session-late');
      await settle(tester);

      expect(h.backend.closed, contains('watch-session-late'));
      expect(h.preview.reportingSessionId, isNull);
    });

    testWidgets('a preview that never crossed the threshold closes nothing', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await startPreview(tester, h);
      h.engine.emitPosition(const Duration(seconds: 5));
      await settle(tester);
      await gesture.moveTo(kAwayFromTiles);
      await settle(tester);

      expect(h.backend.reports, isEmpty);
      expect(h.backend.closed, isEmpty);
    });
  });

  // -------------------------------------------------------------------------

  group('the video ending', () {
    testWidgets('puts the tile back exactly as leaving it would', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);
      await tester.pumpAndSettle();
      expect(previewOpacity(tester), 1);
      expect(find.byIcon(Icons.volume_off), findsOneWidget);

      // The pointer never moves — this is the video running out underneath it.
      h.engine.complete();
      await settle(tester);
      await tester.pumpAndSettle();

      expect(h.preview.activeVideoId, isNull);
      expect(previewSurface, findsNothing);
      expect(find.byType(Image), findsWidgets);
      // The mute toggle goes with it and the ordinary actions come back; a CC button would be
      // in the same branch, so it is covered by construction.
      expect(find.byIcon(Icons.volume_off), findsNothing);
      expect(find.byIcon(Icons.volume_up), findsNothing);
      expect(find.byIcon(Icons.schedule), findsOneWidget);
      expect(find.byIcon(Icons.playlist_play), findsOneWidget);
    });

    testWidgets('does not loop or restart while the pointer sits there', (tester) async {
      // MUTATION CHECK. Asserting only that the surface went away also passes against a version
      // that never handled completion — so this waits out several hover delays and asserts
      // nothing came back and nothing resolved twice.
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);
      h.engine.complete();
      await settle(tester);

      await tester.pump(HoverPreview.hoverDelay * 4);
      await settle(tester);

      expect(h.backend.resolved, hasLength(1), reason: 'the preview restarted itself');
      expect(h.engine.opened, hasLength(1));
      expect(previewSurface, findsNothing);
      expect(h.preview.activeVideoId, isNull);
      expect(h.preview.isWaiting, isFalse);
    });

    testWidgets('leaving and returning starts a fresh preview', (tester) async {
      // The teardown must not be a dead end: the tile is still a tile.
      final h = Harness();
      addTearDown(h.dispose);

      final gesture = await startPreview(tester, h);
      h.engine.complete();
      await settle(tester);
      expect(previewSurface, findsNothing);

      await gesture.moveTo(kAwayFromTiles);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      h.firstFrame();
      await settle(tester);

      expect(h.backend.resolved, hasLength(2));
      expect(previewOpacity(tester), 1);
      expect(h.preview.isMuted, isTrue, reason: 'a fresh preview is a muted one');
    });

    testWidgets('a promoted watch reports ended, not paused', (tester) async {
      // A video watched to the end is a much stronger signal than one someone walked away from.
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);
      h.engine.emitPosition(HoverPreview.watchThreshold);
      await settle(tester);
      h.engine.emitPosition(const Duration(minutes: 9));
      await settle(tester);

      h.engine.complete();
      await settle(tester);

      final last = h.backend.reports.last;
      expect(last.$3, 'ended');
      expect(last.$2, const Duration(minutes: 9).inMilliseconds);
      expect(h.backend.closed, <String>['watch-session-1']);
    });

    testWidgets('an unpromoted preview ending reports nothing', (tester) async {
      final h = Harness();
      addTearDown(h.dispose);

      await startPreview(tester, h);
      h.engine.emitPosition(const Duration(seconds: 8));
      await settle(tester);
      h.engine.complete();
      await settle(tester);

      expect(h.backend.reports, isEmpty);
      expect(h.backend.closed, isEmpty);
      expect(previewSurface, findsNothing);
    });
  });

  // -------------------------------------------------------------------------

  group('tile recycling', () {
    testWidgets('a recycled tile stops the video it was showing', (tester) async {
      // The bug this exists for: `didUpdateWidget` runs *after* `widget` is swapped, so stopping
      // by `widget.spec.previewVideoId` names the new video, `exit` bails, and the old one keeps
      // decoding forever behind a tile that is now something else.
      final h = Harness();
      addTearDown(h.dispose);

      await recycleTile(tester, h, tileFor('first'));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      h.firstFrame();
      await settle(tester);
      expect(h.preview.activeVideoId, 'first');

      // Recycled into a tile with nothing to preview — a playlist or channel. Nothing re-enters
      // afterwards, so this is the case where stopping by the wrong id leaves the old video
      // decoding with no path back to it.
      final stopsBefore = h.engine.stopCount;
      await recycleTile(tester, h, const TileSpec(
        title: 'A playlist',
        thumbnailUrl: 'https://i.ytimg.com/vi/zzz/hq.jpg',
        isStackedCards: true,
        durationTone: DurationBadgeTone.normal,
        badges: <String>[],
        canWatchLater: false,
        canAddToQueue: false,
        primaryLine: 'Channel',
      ));
      await settle(tester);

      expect(h.engine.stopCount, greaterThan(stopsBefore),
          reason: 'the recycled-away video kept decoding');
      expect(h.preview.activeVideoId, isNull);
      expect(previewSurface, findsNothing);
    });

    testWidgets('a recycled tile under a stationary pointer previews the new video',
        (tester) async {
      // No `onEnter` is coming — the pointer never moved — so without a re-enter the tile sits
      // inert until the user leaves and comes back.
      final h = Harness();
      addTearDown(h.dispose);

      await recycleTile(tester, h, tileFor('first'));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      h.firstFrame();
      await settle(tester);

      await recycleTile(tester, h, tileFor('second'));
      await settle(tester);
      // Still nothing until the delay elapses again — recycling is not a shortcut past it.
      expect(h.backend.resolved, <String>['first']);

      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      h.firstFrame();
      await settle(tester);

      expect(h.backend.resolved, <String>['first', 'second']);
      expect(h.preview.activeVideoId, 'second');
    });
  });

  // -------------------------------------------------------------------------

  group('a stale open landing late', () {
    testWidgets('does not stop the preview that replaced it', (tester) async {
      // `MediaKitEngine.open` waits up to 20 s for a duration, so a slow first hover can return
      // long after the pointer moved on. Stopping the shared engine there kills whatever is
      // playing *now*.
      final h = Harness();
      addTearDown(h.dispose);

      final gate = Completer<void>();
      h.engine.openGate = gate.future;

      final tiles = [tileFor('slow'), tileFor('quick')];
      final gesture = await pumpTiles(tester, h, tiles: tiles);

      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey<String>('slow'))));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);

      // Move on while the first open is still hanging, and let the second one finish.
      h.engine.openGate = null;
      await gesture.moveTo(tester.getCenter(find.byKey(const ValueKey<String>('quick'))));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);
      h.firstFrame();
      await settle(tester);
      expect(h.preview.activeVideoId, 'quick');
      final stopsBefore = h.engine.stopCount;

      // Now the first open finally returns.
      gate.complete();
      await settle(tester);

      expect(h.engine.stopCount, stopsBefore, reason: 'the stale open stopped the live preview');
      expect(h.preview.activeVideoId, 'quick');
    });
  });

  // -------------------------------------------------------------------------

  group('failure and absence', () {
    testWidgets('an unresolvable video leaves the thumbnail and no error UI', (tester) async {
      final h = Harness(resolveError: Exception('STREAM_UNAVAILABLE'));
      addTearDown(h.dispose);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);

      expect(h.backend.resolved, <String>['aaaaaaaaaaa']);
      expect(previewSurface, findsNothing);
      expect(find.byType(Image), findsWidgets);
      expect(tester.takeException(), isNull);
      // The ordinary hover actions are still the ones on offer.
      expect(find.byIcon(Icons.schedule), findsOneWidget);
    });

    testWidgets('an empty ladder is the same non-event', (tester) async {
      final h = Harness(source: const PlaybackSource(sessionId: 's'));
      addTearDown(h.dispose);

      final gesture = await pumpTiles(tester, h);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(HoverPreview.hoverDelay + const Duration(milliseconds: 1));
      await settle(tester);

      expect(previewSurface, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tile outside a scope previews nothing and asks for nothing',
        (tester) async {
      // Every other tile test builds a bare `MediaTile`; if absence of a scope did anything but
      // disable previews, those tests would be starting a sidecar and an mpv instance.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox(width: 400, child: MediaTile(spec: kTile)))),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(MediaTile)));
      await tester.pump(const Duration(seconds: 3));

      expect(previewSurface, findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------

  group('variant choice', () {
    test('takes the best at or under the cap', () {
      expect(pickPreviewVariant(ladder().variants)?.height, 720);
    });

    test('takes the smallest when every rung is above it', () {
      // Not `variants.first`: where nothing fits, the top is the worst possible answer.
      final tall = [variant(2160), variant(1440), variant(1080)];
      expect(pickPreviewVariant(tall)?.height, 1080);
    });

    test('an empty ladder has no answer', () {
      expect(pickPreviewVariant(const []), isNull);
    });
  });
}
