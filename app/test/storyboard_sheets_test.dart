/// Storyboard sheet cache. Wired to nothing — kept for the scrubber, and tested anyway, because
/// an untested cache waiting a task or two for its first caller is one that will not work when
/// it arrives (`architecture.md` §2.6).
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/domain/storyboard_spec.dart';
import 'package:rill/ui/storyboard_sheets.dart';

const StoryboardSpec kSpec = StoryboardSpec(
  url: 'https://i.ytimg.com/sb/vid/storyboard3_L0/default.jpg?sqp=Q&sigh=rs%24A',
  columns: 4,
  rows: 2,
  frameCount: 8,
  frameWidth: 10,
  frameHeight: 10,
  intervalMs: 5000,
);

/// A real decoded image, because the cache measures and checks one.
Future<ui.Image> solidImage(int width, int height) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint(),
  );
  return recorder.endRecording().toImage(width, height);
}

void main() {
  group('the decoded-sheet cache', () {
    /// A cache whose budget holds exactly two of these sheets.
    ({StoryboardSheetCache cache, List<String> resolved}) boundedCache(int sheets) {
      final resolved = <String>[];
      const spec = StoryboardSpec(
        url: 'https://i.ytimg.com/sb/x/storyboard3_L0/default.jpg?sqp=Q&sigh=rs%24A',
        columns: 4,
        rows: 2,
        frameCount: 8,
        frameWidth: 10,
        frameHeight: 10,
        intervalMs: 5000,
      );
      // 40 × 20 × 4 bytes = 3200 per sheet.
      const bytesPerSheet = 40 * 20 * 4;

      return (
        cache: StoryboardSheetCache(
          maxDecodedBytes: bytesPerSheet * sheets,
          resolve: (videoId) async {
            resolved.add(videoId);
            return spec.copyWith(url: 'https://i.ytimg.com/sb/$videoId/L0/default.jpg');
          },
          fetch: (url) async => Uint8List(0),
          decode: (bytes) => solidImage(spec.sheetWidth, spec.sheetHeight),
        ),
        resolved: resolved,
      );
    }

    testWidgets('evicts at its bound', (tester) async {
      final (:cache, :resolved) = boundedCache(2);

      for (final id in <String>['a', 'b', 'c']) {
        final sheet = await cache.acquire(id);
        expect(sheet, isNotNull);
        cache.release(id);
      }

      expect(cache.sheetCount, 2, reason: 'the bound is two sheets');
      expect(cache.decodedBytes, lessThanOrEqualTo(3200 * 2));
      // Oldest first: `a` went, `b` and `c` stayed.
      expect(cache.holds('a'), isFalse);
      expect(cache.holds('b'), isTrue);
      expect(cache.holds('c'), isTrue);

      // And evicting really did drop it — re-acquiring `a` resolves again.
      await cache.acquire('a');
      cache.release('a');
      expect(resolved, <String>['a', 'b', 'c', 'a']);
    });

    testWidgets('a hit does not re-resolve, and is promoted', (tester) async {
      final (:cache, :resolved) = boundedCache(2);

      await cache.acquire('a');
      cache.release('a');
      await cache.acquire('b');
      cache.release('b');
      // Touch `a` again — it becomes the most recently used, so `b` is now the
      // eviction candidate rather than `a`.
      await cache.acquire('a');
      cache.release('a');
      expect(resolved, <String>['a', 'b'], reason: 'the second acquire of a was a hit');

      await cache.acquire('c');
      cache.release('c');
      expect(cache.holds('b'), isFalse);
      expect(cache.holds('a'), isTrue);
    });

    testWidgets('never evicts the sheet being painted', (tester) async {
      final (:cache, resolved: _) = boundedCache(1);

      // `a` stays held — this is the running preview.
      final held = await cache.acquire('a');
      expect(held, isNotNull);

      await cache.acquire('b');
      cache.release('b');

      // Over budget, and the only candidate is pinned. Eviction declines rather
      // than disposing an image a `CustomPainter` is about to draw — which
      // throws from inside the paint phase, not from anywhere useful.
      expect(cache.holds('a'), isTrue);
      expect(() => held!.image.width, returnsNormally);

      cache.release('a');
    });

    testWidgets('a freshly loaded sheet survives a full cache', (tester) async {
      // Evicting inside the load can throw away the very sheet that was just requested, and
      // `acquire` then answers null for one that fetched and decoded perfectly well.
      final (:cache, resolved: _) = boundedCache(1);

      final held = await cache.acquire('a');
      expect(held, isNotNull);

      final second = await cache.acquire('b');
      expect(second, isNotNull, reason: 'the new sheet was evicted before it was handed over');
      expect(cache.holds('b'), isTrue);

      cache.release('a');
      cache.release('b');
    });

    testWidgets('a load landing after clear() does not repopulate the cache', (tester) async {
      final (:cache, resolved: _) = boundedCache(4);

      final pending = cache.acquire('a');
      cache.clear();
      expect(await pending, isNull);
      expect(cache.holds('a'), isFalse);
      expect(cache.sheetCount, 0);
    });

    testWidgets('a sheet that is not the size the spec promised is refused', (tester) async {
      // Every frame after the first would land at the wrong offset, which reads
      // as a smeared thumbnail rather than as an error — so nobody would ever
      // report it.
      final cache = StoryboardSheetCache(
        resolve: (videoId) async => kSpec,
        fetch: (url) async => Uint8List(0),
        decode: (bytes) => solidImage(kSpec.sheetWidth ~/ 2, kSpec.sheetHeight),
      );

      expect(await cache.acquire('a'), isNull);
      expect(cache.holds('a'), isFalse);
    });

    testWidgets('two hovers of the same tile share one resolution', (tester) async {
      final (:cache, :resolved) = boundedCache(4);

      // A pointer swept off a tile and back on before the first load landed.
      final first = cache.acquire('a');
      final second = cache.acquire('a');
      await Future.wait(<Future<StoryboardSheet?>>[first, second]);

      expect(resolved, <String>['a']);
      cache.release('a');
      cache.release('a');
    });
  });
}
