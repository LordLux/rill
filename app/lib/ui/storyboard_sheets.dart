/// Storyboard sprite sheets — **wired to nothing.** This is the scrubber's input, kept ahead of
/// the task that needs it; hover previews play real video instead (`architecture.md` §2.6,
/// `protocol.md` §3.7).
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../data/rpc/client.dart';
import '../domain/storyboard_spec.dart';

/// Raw bytes for a sheet URL. Injected so the cache is testable without a socket.
typedef SheetFetcher = Future<Uint8List> Function(String url);

/// A video's storyboard spec, or null when YouTube ships none for it.
typedef StoryboardResolver = Future<StoryboardSpec?> Function(String videoId);

/// Bytes → a decoded image. Injected for the same reason as [SheetFetcher].
typedef SheetDecoder = Future<ui.Image> Function(Uint8List bytes);

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

Future<StoryboardSpec?> _resolveOverRpc(String videoId) async {
  final result = await RpcClient.instance.call('video.storyboard', {'videoId': videoId});
  final map = result as Map<String, dynamic>?;
  final storyboard = map?['storyboard'] as Map<String, dynamic>?;
  // `null` is an ordinary answer (§3.7) — YouTube builds no sheets for some
  // videos at all. The tile keeps its static thumbnail.
  if (storyboard == null) return null;
  return StoryboardSpec.fromJson(storyboard);
}

/// One client for every sheet, so connections to `i.ytimg.com` are pooled — a client per
/// request and a `close(force: true)` after it defeats keep-alive entirely.
HttpClient? _sharedClient;

Future<Uint8List> _fetchOverHttp(String url) async {
  final client = _sharedClient ??= HttpClient();
  final uri = Uri.parse(url);
  final request = await client.getUrl(uri);
  final response = await request.close();
  if (response.statusCode != 200) {
    // 403 is the interesting one: it is what a URL missing `sqp` or `sigh` answers, so it means
    // the substitution broke rather than the network.
    await response.drain<void>();
    throw HttpException('HTTP ${response.statusCode}', uri: uri);
  }
  return consolidateHttpClientResponseBytes(response);
}

/// Decode off the frame loop — hard invariant 9's reasoning applies to CPU work in a build
/// method as much as to a blocking property read.
Future<ui.Image> _decodeAsync(Uint8List bytes) async {
  // By content, never by extension: the path ends `.jpg` and the bytes may be WebP (§3.7).
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecWithSize(buffer);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}

// ---------------------------------------------------------------------------
// The decoded-sheet cache
// ---------------------------------------------------------------------------

/// One decoded sheet and the grid that addresses it.
@immutable
class StoryboardSheet {
  const StoryboardSheet(this.spec, this.image);

  final StoryboardSpec spec;
  final ui.Image image;

  /// Bytes this sheet occupies decoded — four per pixel, premultiplied RGBA.
  int get decodedBytes => image.width * image.height * 4;

  /// The source rectangle of one frame, row-major from the top left.
  Rect frameRect(int index) {
    final wrapped = index % spec.frameCount;
    final column = wrapped % spec.columns;
    final row = wrapped ~/ spec.columns;
    return Rect.fromLTWH(
      (column * spec.frameWidth).toDouble(),
      (row * spec.frameHeight).toDouble(),
      spec.frameWidth.toDouble(),
      spec.frameHeight.toDouble(),
    );
  }
}

class _Entry {
  _Entry(this.sheet);

  final StoryboardSheet sheet;

  /// Holders painting this right now. Without it, eviction can dispose an image a
  /// `CustomPainter` is about to draw, which throws from inside the paint phase.
  int refs = 0;

  /// Evicted while pinned: disposed as soon as the last holder lets go.
  bool condemned = false;
}

/// Decoded sheets, bounded, with the pinned one exempt from eviction.
///
/// **The bound is 16 MiB of decoded pixels** — a byte budget rather than a sheet count, because
/// sheets differ: the usual one is 480×270 (~518 KB) and a higher level can be 800×450 (~1.4 MB),
/// so a fixed count would stand for wildly different memory. 16 MiB holds ~32 typical sheets,
/// comfortably more than a feed page's ~22 tiles.
class StoryboardSheetCache {
  StoryboardSheetCache({
    StoryboardResolver? resolve,
    SheetFetcher? fetch,
    SheetDecoder? decode,
    this.maxDecodedBytes = defaultMaxDecodedBytes,
  })  : _resolve = resolve ?? _resolveOverRpc,
        _fetch = fetch ?? _fetchOverHttp,
        _decode = decode ?? _decodeAsync;

  static const int defaultMaxDecodedBytes = 16 * 1024 * 1024;

  final StoryboardResolver _resolve;
  final SheetFetcher _fetch;
  final SheetDecoder _decode;
  final int maxDecodedBytes;

  /// Insertion-ordered, and re-inserted on hit — so iteration order is LRU-first.
  final Map<String, _Entry> _entries = <String, _Entry>{};
  final Map<String, Future<StoryboardSheet?>> _inFlight = <String, Future<StoryboardSheet?>>{};

  /// Bumped by [clear]. A load still in flight across a clear must not repopulate the cache it
  /// was emptied out of — and its decoded image has to be disposed rather than dropped.
  int _epoch = 0;

  @visibleForTesting
  int get sheetCount => _entries.length;

  @visibleForTesting
  int get decodedBytes => _entries.values.fold(0, (sum, e) => sum + e.sheet.decodedBytes);

  @visibleForTesting
  bool holds(String videoId) => _entries.containsKey(videoId);

  /// The sheet for [videoId], **pinned** — every non-null result must be [release]d. Null for a
  /// video with no storyboard and for any failure; a missing sheet is not an error state.
  Future<StoryboardSheet?> acquire(String videoId) async {
    final existing = _entries[videoId];
    if (existing != null) {
      // Re-insert to make this the most recently used.
      _entries.remove(videoId);
      _entries[videoId] = existing;
      existing.refs++;
      return existing.sheet;
    }

    // A pointer swept off a tile and back on must not start a second resolution.
    final pending = _inFlight[videoId];
    if (pending != null) {
      final sheet = await pending;
      if (sheet == null) return null;
      final entry = _entries[videoId];
      if (entry == null) return null; // evicted between the await and here
      entry.refs++;
      _evict();
      return sheet;
    }

    late final Future<StoryboardSheet?> request;
    request = _load(videoId).whenComplete(() {
      // Only if it is still ours — an older request settling must not clear a newer one's slot.
      if (identical(_inFlight[videoId], request)) _inFlight.remove(videoId);
    });
    _inFlight[videoId] = request;

    final sheet = await request;
    if (sheet == null) return null;
    final entry = _entries[videoId];
    if (entry == null) return null;
    // Pinned *before* the budget is enforced: evicting inside `_load` can throw away the very
    // sheet that was just requested, and `acquire` then answers null for a preview that loaded
    // perfectly well.
    entry.refs++;
    _evict();
    return sheet;
  }

  Future<StoryboardSheet?> _load(String videoId) async {
    final epoch = _epoch;
    try {
      final spec = await _resolve(videoId);
      if (spec == null || !spec.isUsable) return null;

      final image = await _decode(await _fetch(spec.url));

      // Must be the grid the spec described, or every frame lands at the wrong offset — which
      // renders as a smear rather than a failure, and would never be reported.
      if (image.width < spec.sheetWidth || image.height < spec.sheetHeight) {
        image.dispose();
        debugPrint(
          'storyboard $videoId: sheet is ${image.width}x${image.height}, '
          'spec says ${spec.sheetWidth}x${spec.sheetHeight} — ignoring it',
        );
        return null;
      }

      if (epoch != _epoch) {
        // Cleared while this was in flight. Nothing may enter the map, and the image is ours to
        // dispose — dropping it leaks a decoded bitmap nothing will ever free.
        image.dispose();
        return null;
      }

      final sheet = StoryboardSheet(spec, image);
      _entries[videoId] = _Entry(sheet);
      return sheet;
    } on Object catch (error) {
      // Silent to the user, loud in the log: every failure ends the same way, with the static
      // thumbnail that was already on screen.
      debugPrint('storyboard $videoId: no preview ($error)');
      return null;
    }
  }

  /// Let go of a sheet [acquire] handed out. One condemned by [clear] while still painted is
  /// disposed here by the last holder, never underneath one.
  void release(String videoId) {
    final entry = _entries[videoId];
    if (entry == null) return;
    entry.refs--;
    if (entry.condemned && entry.refs <= 0) {
      _entries.remove(videoId);
      entry.sheet.image.dispose();
    }
  }

  void _evict() {
    var total = decodedBytes;
    while (total > maxDecodedBytes && _entries.length > 1) {
      // Oldest first, skipping anything being painted.
      String? victim;
      for (final entry in _entries.entries) {
        if (entry.value.refs <= 0) {
          victim = entry.key;
          break;
        }
      }
      if (victim == null) return;
      final evicted = _entries.remove(victim)!;
      total -= evicted.sheet.decodedBytes;
      evicted.sheet.image.dispose();
    }
  }

  /// Drop everything. Test seam, and what a memory-pressure signal would call.
  void clear() {
    // Loads already on the wire are disowned rather than awaited: `_load` checks the epoch and
    // disposes its image instead of repopulating a cache that was just emptied.
    _epoch++;
    _inFlight.clear();
    for (final entry in _entries.values) {
      if (entry.refs > 0) {
        entry.condemned = true;
        continue;
      }
      entry.sheet.image.dispose();
    }
    _entries.removeWhere((_, entry) => !entry.condemned);
  }
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

/// One frame of a sheet: the decoded image, and the rectangle to take from it.
@immutable
class StoryboardFrame {
  const StoryboardFrame(this.image, this.src);

  final ui.Image image;
  final Rect src;
}

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

/// One frame of a sheet, scaled to fill its box with `BoxFit.cover` semantics. The sheet is
/// decoded once; this only moves a source rectangle across it.
class StoryboardFramePainter extends CustomPainter {
  StoryboardFramePainter(this.frame);

  final StoryboardFrame frame;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final scale = (size.width / frame.src.width) > (size.height / frame.src.height)
        ? size.width / frame.src.width
        : size.height / frame.src.height;
    final width = frame.src.width * scale;
    final height = frame.src.height * scale;
    final dst = Rect.fromLTWH((size.width - width) / 2, (size.height - height) / 2, width, height);

    canvas.drawImageRect(
      frame.image,
      frame.src,
      dst,
      // 48×27 upscaled ~9×: nearest neighbour would be visible blocks.
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(StoryboardFramePainter oldDelegate) =>
      oldDelegate.frame.src != frame.src || !identical(oldDelegate.frame.image, frame.image);
}

/// A sheet frame drawn into whatever box it is given, or nothing until there is one.
class StoryboardPreviewLayer extends StatelessWidget {
  const StoryboardPreviewLayer({super.key, required this.frames});

  final ValueListenable<StoryboardFrame?> frames;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<StoryboardFrame?>(
      valueListenable: frames,
      builder: (context, frame, _) {
        if (frame == null) return const SizedBox.shrink();
        return TweenAnimationBuilder<double>(
          // Runs once, on insertion — later rebuilds are already at `end`. Hides the cut from a
          // sharp thumbnail to a soft upscaled frame.
          tween: Tween<double>(begin: 0, end: 1),
          duration: const Duration(milliseconds: 150),
          builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
          child: RepaintBoundary(
            child: CustomPaint(painter: StoryboardFramePainter(frame), size: Size.infinite),
          ),
        );
      },
    );
  }
}
