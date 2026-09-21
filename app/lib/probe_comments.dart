/// **Measurement entrypoint for the comment lists (Task 27 §6).** Never wired
/// into the app; build and run it explicitly:
///
///   fvm flutter build windows --release -t lib/probe_comments.dart
///   .\build\windows\x64\runner\Release\rill.exe
///
/// **This overwrites `build/windows/x64/runner/Release/`** with the probe app;
/// `rill build` puts the real one back.
///
/// It answers the question the spec asked and the first delivery did not:
/// *what does a long comment list cost in frame times* — the top-level list
/// and a thread's replies, both at the same counts, N = 20 (one page), 100, 500,
/// 1000. Both are rows of one virtualised `SliverList.builder` now; until the
/// lazy-reply rewrite a thread's replies were a plain `Column` inside their
/// thread (eager: every loaded reply built on every rebuild), and the numbers
/// in `architecture.md` F34 for that shape were taken with this same probe.
///
/// `RILL_PROBE_PHASES` (default `ABC`) picks phases, e.g. `C` for the click-cost
/// sweep alone; a warm-up always runs first.
///
/// It mounts the **real** [CommentsSection] — real threads, real reply
/// controls, real rich-text measuring — over a synthetic [CommentsSource], so no
/// sidecar and no network are involved, and serves the avatars from a loopback
/// HTTP server so they are real `NetworkImage` decodes of real-sized (88 px,
/// what `comments.json` carries) images, unique per comment as they are on
/// YouTube. Comment lengths follow a live page's (median 62 chars, p90 117, max
/// 340). Real `FrameTiming` is recorded in a release/AOT process — a
/// `flutter test` run is JIT and has no raster thread, so it cannot answer this.
///
/// The report goes to stdout *and* to `RILL_PROBE_OUT` (default
/// `%TEMP%\rill-probe-comments.txt`), because a release `rill.exe` is a
/// launcher whose child's stdout is not the console (`CLAUDE.md`).
library;

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/comments_source.dart';
import 'domain/comment.dart';
import 'ui/widgets/comments_section.dart';

const _counts = [20, 100, 500, 1000];

/// Scripted scroll: a flick's worth of speed, for long enough to be a sample.
const _scrollSeconds = 8;
const _scrollPxPerSecond = 4000.0;

/// Frames forced one after another in the rebuild phase.
const _rebuildFrames = 60;

late final IOSink? _out;
void _say(String line) {
  print(line);
  _out?.writeln(line);
}

// ---------------------------------------------------------------------------
// Synthetic data
// ---------------------------------------------------------------------------

/// A live page's comment lengths, in characters (median 62, p90 117, max 340).
const _lengths = [32, 45, 62, 62, 62, 80, 117, 117, 200, 340];
const _words = ['never', 'gonna', 'give', 'you', 'up', 'this', 'song', 'is', 'from', 'the', 'year', 'nineteen', 'eighty', 'seven'];

Comment _comment(String id, int seed, int port, {int replyCount = 0, String? repliesContinuation}) {
  final random = math.Random(seed);
  final length = _lengths[random.nextInt(_lengths.length)];
  final buffer = StringBuffer();
  while (buffer.length < length) {
    buffer.write('${_words[random.nextInt(_words.length)]} ');
  }
  final content = buffer.toString().substring(0, length).trimRight();

  // About one comment in seven carries a timestamp or a link, as real ones do.
  final kind = random.nextInt(14);
  final commandRuns = switch (kind) {
    0 => [CommentCommandRun(startIndex: 0, length: math.min(4, content.length), startTimeSeconds: 42)],
    1 => [CommentCommandRun(startIndex: 0, length: math.min(6, content.length), url: 'https://example.com')],
    _ => null,
  };

  return Comment(
    id: id,
    authorName: '@author_$seed',
    authorAvatarUrl: 'http://127.0.0.1:$port/avatar/$id.png',
    text: CommentText(content: content, commandRuns: commandRuns),
    likeCount: '${random.nextInt(900)}',
    publishedText: '${1 + random.nextInt(11)} months ago',
    replyCount: replyCount,
    isVerified: random.nextInt(10) == 0,
    creatorHearted: random.nextInt(20) == 0,
    // A spread of all three, so a measurement run draws both filled glyphs as
    // a real page would rather than only the outlined pair.
    myRating: switch (random.nextInt(8)) { 0 => 'like', 1 => 'dislike', _ => 'none' },
    repliesContinuation: repliesContinuation,
  );
}

/// Answers instantly, from memory. `top` is the thread list; `replies` is one
/// thread's whole reply list in a single page (the real one pages ten at a
/// time, which only means more, smaller rebuilds of the same list).
class _SyntheticSource implements CommentsSource {
  _SyntheticSource({required this.port});

  final int port;
  int threads = 20;
  int replies = 0;

  /// `true`: thread 0's replies come [pageSize] at a time behind a `rp:<offset>`
  /// token, as YouTube's do (measured live: 10, then 10-14 per page). `false`:
  /// all of them in one page.
  bool paged = false;
  int pageSize = 12;
  int _next = 1;

  @override
  CommentsPageRequest page(String continuation) {
    final id = _next++;
    if (continuation.startsWith('rp:')) {
      final start = int.parse(continuation.substring(3));
      final end = math.min(replies, start + pageSize);
      return (
        id: id,
        response: Future.value(
          CommentsResult(
            items: [for (var i = start; i < end; i++) _comment('reply-$i', 100000 + i, port)],
            continuation: end < replies ? 'rp:$end' : null,
          ),
        ),
      );
    }
    final replyCountAsked = switch (continuation) {
      'replies' => replies,
      'replies-small' => 3,
      _ => 0,
    };
    final items = continuation.startsWith('replies')
        ? [for (var i = 0; i < replyCountAsked; i++) _comment('reply-$i', 100000 + i, port)]
        : [
            for (var i = 0; i < threads; i++)
              _comment(
                'thread-$i',
                i,
                port,
                // Thread 0 is the one whose replies are measured; a third of the
                // others carry a (collapsed) reply control, as real threads do.
                replyCount: i == 0 && replies > 0 ? replies : (i % 3 == 0 ? 3 : 0),
                repliesContinuation: i == 0 && replies > 0 ? (paged ? 'rp:0' : 'replies') : (i % 3 == 0 ? 'replies-small' : null),
              ),
          ];
    return (id: id, response: Future.value(CommentsResult(items: items)));
  }

  @override
  void cancel(int id) {}

  // The probe measures build and frame cost, never the network, so the writes
  // answer instantly and change nothing. They exist because `CommentsSource`
  // grew them (`todo.md` 39.5) — a synthetic source has to satisfy the same
  // interface the real widgets talk to, or the thing being measured is not the
  // real widget.
  @override
  Future<Comment?> post(String createParams, String text) async => null;

  @override
  Future<void> reply(String replyParams, String text) async {}

  @override
  Future<void> delete(String deleteParams) async {}

  @override
  Future<void> rate(String params) async {}
}

Future<Uint8List> _avatarPng() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 88, 88),
    Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(88, 88), [Colors.teal, Colors.indigo]),
  );
  final image = await recorder.endRecording().toImage(88, 88);
  return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

// ---------------------------------------------------------------------------
// Measuring
// ---------------------------------------------------------------------------

final _frames = <FrameTiming>[];

String _stats(String label, List<int> micros) {
  if (micros.isEmpty) return '$label  <no samples>';
  final s = [...micros]..sort();
  String at(double p) => (s[((s.length - 1) * p).round()] / 1000).toStringAsFixed(2).padLeft(6);
  return '$label p50=${at(0.5)} p90=${at(0.9)} p99=${at(0.99)} max=${(s.last / 1000).toStringAsFixed(2).padLeft(6)}';
}

/// Frames recorded since [_frames] was last cleared. `FrameTiming`s reach the
/// callback in batches up to a second late, so this waits them out.
Future<List<FrameTiming>> _drain() async {
  await Future<void>.delayed(const Duration(milliseconds: 2500));
  final frames = List.of(_frames);
  _frames.clear();
  return frames;
}

void _report(String label, List<FrameTiming> frames) {
  _say('  $label   frames=${frames.length}');
  _say('    ${_stats('build ', [for (final f in frames) f.buildDuration.inMicroseconds])}   (ms, UI thread: build + layout + paint)');
  _say('    ${_stats('raster', [for (final f in frames) f.rasterDuration.inMicroseconds])}   (ms, raster thread)');
  _say('    ${_stats('total ', [for (final f in frames) f.totalSpan.inMicroseconds])}   (ms, vsync to raster done)');
  int over(double ms) => frames.where((f) => f.totalSpan.inMicroseconds > ms * 1000).length;
  _say('    frames over 8.33 ms=${over(8.33)}  16.67 ms=${over(16.67)}  33.3 ms=${over(33.3)}');
}

// ---------------------------------------------------------------------------
// Driving the real UI
// ---------------------------------------------------------------------------

Element? _findText(String data) {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is Text && w.data == data) {
      found = e;
      return;
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement!.visitChildren(visit);
  return found;
}

/// Scrolls until the widget showing [data] exists, then to the middle of the viewport, and
/// lets it settle. A "Show more replies" button sits below every reply already loaded, and
/// a lazy list builds only what is near the viewport — so it cannot simply be looked up,
/// and the first version of this, which could, stopped working when the list became lazy.
Future<void> _reveal(String data, ScrollController controller) async {
  controller.jumpTo(0);
  await SchedulerBinding.instance.endOfFrame;
  for (var i = 0; i < 600 && _findText(data) == null; i++) {
    final position = controller.position;
    if (position.pixels >= position.maxScrollExtent) break;
    controller.jumpTo(math.min(position.maxScrollExtent, position.pixels + 400));
    await SchedulerBinding.instance.endOfFrame;
  }
  final element = _findText(data);
  if (element == null) throw StateError('no Text("$data") found after scrolling the whole list');
  await Scrollable.ensureVisible(element, alignment: 0.5, duration: Duration.zero);
  await SchedulerBinding.instance.endOfFrame;
}

/// [_reveal], then tap — retrying, because a lazy list re-estimates its extents in the
/// frame after a jump and can drop the very widget that was just scrolled to before
/// anything taps it. The look-up and the tap share one synchronous stretch, so once the
/// widget is found nothing can remove it before the tap lands.
Future<void> _revealAndTap(String data, ScrollController controller) async {
  for (var attempt = 0; attempt < 8; attempt++) {
    try {
      await _reveal(data, controller);
    } on StateError {
      continue;
    }
    if (_findText(data) != null) {
      await _tapText(data);
      return;
    }
  }
  throw StateError('could not bring Text("$data") on screen to tap it, in 8 tries');
}

/// A real tap, through the real gesture arena, on the widget showing [data].
Future<void> _tapText(String data) async {
  final element = _findText(data);
  if (element == null) throw StateError('no Text("$data") on screen');
  final box = element.renderObject! as RenderBox;
  final at = box.localToGlobal(box.size.center(Offset.zero));
  GestureBinding.instance.handlePointerEvent(PointerDownEvent(position: at, pointer: 7, kind: PointerDeviceKind.touch));
  GestureBinding.instance.handlePointerEvent(PointerUpEvent(position: at, pointer: 7, kind: PointerDeviceKind.touch));
}

Future<void> _pingPong(ScrollController c) async {
  final clock = Stopwatch()..start();
  var down = true;
  while (clock.elapsed.inSeconds < _scrollSeconds) {
    final p = c.position;
    final target = down ? math.min(p.maxScrollExtent, p.pixels + 12000) : math.max(p.minScrollExtent, p.pixels - 12000);
    final distance = (target - p.pixels).abs();
    if (distance < 1) {
      down = !down;
      await Future<void>.delayed(const Duration(milliseconds: 16));
      continue;
    }
    await c.animateTo(
      target,
      duration: Duration(milliseconds: (distance / _scrollPxPerSecond * 1000).round().clamp(50, 4000)),
      curve: Curves.linear,
    );
    down = !down;
  }
}

class _Rig {
  _Rig(this.source);

  final _SyntheticSource source;
  final _tree = ValueNotifier<int>(0);
  ScrollController controller = ScrollController();
  Key key = UniqueKey();

  Widget build() {
    return ValueListenableBuilder<int>(
      valueListenable: _tree,
      builder: (context, _, _) => CustomScrollView(
        key: key,
        controller: controller,
        // Deliberately not `const`: a new widget per build is the whole point of
        // the rebuild phase.
        slivers: [CommentsSection(videoId: 'probe', initialContinuation: 'top')],
      ),
    );
  }

  /// Mount a fresh section (new state, fresh sidecar-less fetch).
  Future<void> remount() async {
    controller = ScrollController();
    key = UniqueKey();
    _tree.value++;
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  /// One new `CommentsSection` widget per frame: what a `setState` in the
  /// section costs, threads and any expanded replies included.
  Future<void> rebuildBurst() async {
    for (var i = 0; i < _rebuildFrames; i++) {
      _tree.value++;
      await SchedulerBinding.instance.endOfFrame;
    }
  }
}

/// Waits until the image cache stops growing: an expand asks for every avatar in
/// the list at once, and those decodes must not land in the next phase's frames.
Future<void> _settleImages(ImageCache cache) async {
  for (var i = 0; i < 25; i++) {
    final before = cache.currentSize;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (cache.currentSize == before) break;
  }
  await _drain();
}

/// Scrolls the whole list once, end to end, fast: the avatar cache after it says
/// how many decoded images a long list ends up holding.
Future<void> _sweep(ScrollController c) async {
  var lastMax = -1.0;
  while (true) {
    final p = c.position;
    final distance = p.maxScrollExtent - p.pixels;
    if (distance < 1 && p.maxScrollExtent == lastMax) break;
    lastMax = p.maxScrollExtent;
    if (distance < 1) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      continue;
    }
    await c.animateTo(
      p.maxScrollExtent,
      duration: Duration(milliseconds: (distance / 20000 * 1000).round().clamp(50, 8000)),
      curve: Curves.linear,
    );
  }
}

double _worstBuildMs(List<FrameTiming> frames) =>
    frames.isEmpty ? 0 : frames.map((f) => f.buildDuration.inMicroseconds).reduce(math.max) / 1000;

void _cacheLine(ImageCache cache) =>
    _say('    image cache: ${cache.currentSize} decoded avatars, ${(cache.currentSizeBytes / 1048576).toStringAsFixed(1)} MB');

Future<void> _phaseA(_Rig rig, ImageCache cache, int n) async {
  rig.source
    ..threads = n
    ..replies = 0
    ..paged = false;
  cache.clear();
  _frames.clear();
  await rig.remount();
  await _drain(); // mounting N threads is not the measurement

  await _pingPong(rig.controller);
  _report('N=$n  scrolling', await _drain());
  _cacheLine(cache);

  await rig.rebuildBurst();
  _report('N=$n  rebuild (new CommentsSection per frame)', await _drain());
  _say('');
}

Future<void> _phaseSweep(_Rig rig, ImageCache cache, int n) async {
  rig.source
    ..threads = n
    ..replies = 0
    ..paged = false;
  cache.clear();
  _frames.clear();
  await rig.remount();
  await _drain();
  await _sweep(rig.controller);
  _report('N=$n  one full sweep at 20000 px/s', await _drain());
  _cacheLine(cache);
  _say('');
}

/// [report] false makes it a warm-up: the first expand in a process pays for
/// shaders and first-use paths that no later one does, and would be billed to
/// whichever M happened to run first.
Future<void> _phaseB(_Rig rig, ImageCache cache, int m, {bool report = true}) async {
  rig.source
    ..threads = 20
    ..replies = m
    ..paged = false;
  cache.clear();
  _frames.clear();
  await rig.remount();
  await _drain();

  // The expand: a real tap on "Show M replies". Builds the whole reply list.
  await _tapText('Show $m replies');
  final expand = await _drain();
  await _settleImages(cache);
  if (!report) return;
  _report('M=$m  expand (tap -> all $m replies built in one page)', expand);
  _say('    worst single build frame = ${_worstBuildMs(expand).toStringAsFixed(2)} ms');

  // Any setState above the thread while it is on screen. Jumped to the top and
  // *checked*: the first pass of this probe did not, and for M<=100 the thread
  // had scrolled out of the viewport (and out of the tree), so it measured nothing.
  rig.controller.jumpTo(0);
  await SchedulerBinding.instance.endOfFrame;
  _say('    thread expanded and in the tree for the rebuild: ${_findText('Hide replies') != null}');
  await rig.rebuildBurst();
  _report('M=$m  rebuild (thread expanded, on screen)', await _drain());

  // Collapse and expand again: the loaded replies are kept, the widgets are not.
  // Before the scroll below, while the thread is provably in the tree.
  await _tapText('Hide replies');
  await _drain();
  await _tapText('Show $m replies');
  final again = await _drain();
  _say('  M=$m  re-expand (collapse, then expand): worst single build frame = ${_worstBuildMs(again).toStringAsFixed(2)} ms');

  await _pingPong(rig.controller);
  _report('M=$m  scrolling through them', await _drain());
  _cacheLine(cache);

  // A `SliverList` disposes a child that leaves the viewport, and a thread's
  // expansion and loaded replies live in its `State`.
  rig.controller.jumpTo(0);
  await SchedulerBinding.instance.endOfFrame;
  _say('  M=$m  after scrolling away and back, the thread is still expanded: ${_findText('Hide replies') != null}');
  _say('');
}

/// What the app really does: a page of ~12 replies per click, so a click's cost
/// is the rebuild of every reply already loaded plus the first build of ~12.
Future<void> _phasePaged(_Rig rig, ImageCache cache, int m, List<int> marks) async {
  rig.source
    ..threads = 20
    ..replies = m
    ..paged = true
    ..pageSize = 12;
  cache.clear();
  _frames.clear();
  await rig.remount();
  await _drain();

  _say('  M=$m advertised, ${rig.source.pageSize} replies per click; cost of the click made with N already loaded:');
  await _tapText('Show $m replies'); // page 1: nothing existing to rebuild
  await Future<void>.delayed(const Duration(milliseconds: 1600));
  _say('    N=  0 loaded -> +${rig.source.pageSize}: worst build frame ${_worstBuildMs(List.of(_frames)).toStringAsFixed(2)} ms');
  _frames.clear();

  var loaded = rig.source.pageSize;
  while (loaded < m) {
    final measured = marks.contains(loaded);
    if (measured) {
      // Bring it on screen and let the frames from doing so pass, so they are not
      // billed to the click; then clear and tap, with nothing awaited in between.
      for (var attempt = 0; attempt < 8; attempt++) {
        await _reveal('Show more replies', rig.controller);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (_findText('Show more replies') != null) break;
      }
      _frames.clear();
      await _tapText('Show more replies');
    } else {
      await _revealAndTap('Show more replies', rig.controller);
    }
    await Future<void>.delayed(Duration(milliseconds: measured ? 1600 : 200));
    if (measured) {
      final f = List.of(_frames);
      _frames.clear();
      _say('    N=${loaded.toString().padLeft(3)} loaded -> +${rig.source.pageSize}: worst build frame ${_worstBuildMs(f).toStringAsFixed(2)} ms   (frames over 16.67 ms: ${f.where((x) => x.totalSpan.inMicroseconds > 16670).length} of ${f.length})');
    }
    loaded += rig.source.pageSize;
  }
  _say('');
}

Future<void> _run(_Rig rig, int port) async {
  final cache = PaintingBinding.instance.imageCache;

  _say('');
  _say('===== COMMENT LISTS PROBE =====');
  _say('mode: ${const bool.fromEnvironment('dart.vm.product') ? 'release/AOT' : 'debug/JIT  <-- NOT a valid measurement'}');
  final view = ui.PlatformDispatcher.instance.views.first;
  _say('window: ${(view.physicalSize.width / view.devicePixelRatio).round()} x ${(view.physicalSize.height / view.devicePixelRatio).round()} logical px @ ${view.devicePixelRatio}x');
  _say('scroll: ${_scrollSeconds}s ping-pong at $_scrollPxPerSecond px/s;  rebuild burst: $_rebuildFrames frames, one new CommentsSection each');
  _say('');
  await Future<void>.delayed(const Duration(seconds: 2)); // the first frames are the window opening

  await _phaseB(rig, cache, 20, report: false); // warm-up, discarded

  final phases = Platform.environment['RILL_PROBE_PHASES'] ?? 'ABC';
  _say('phases: $phases');

  if (phases.contains('A')) {
    _say('--- A. THE TOP-LEVEL LIST: N threads, none expanded (SliverList.builder) ---');
    for (final n in _counts) {
      await _phaseA(rig, cache, n);
    }
    _say('--- A2. THE WHOLE LIST SCROLLED THROUGH ONCE (what does it leave decoded?) ---');
    await _phaseSweep(rig, cache, 1000);
  }

  if (phases.contains('B')) {
    _say("--- B. ONE THREAD'S REPLIES: M replies loaded at once, 20 threads around it ---");
    for (final m in _counts) {
      await _phaseB(rig, cache, m);
    }
  }

  if (phases.contains('C')) {
    _say('--- C. THE SAME THREAD, LOADED THE WAY THE APP LOADS IT: ~12 replies per click ---');
    await _phasePaged(rig, cache, 500, const [12, 60, 120, 240, 480]);
  }

  _say('===== DONE =====');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final outPath = Platform.environment['RILL_PROBE_OUT'] ?? '${Directory.systemTemp.path}\\rill-probe-comments.txt';
  _out = File(outPath).openWrite();
  _say('report file: $outPath');

  // Avatars come from here, as real (88 px) decodes, one distinct URL each.
  final png = await _avatarPng();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    request.response
      ..headers.contentType = ContentType('image', 'png')
      ..add(png);
    request.response.close();
  });

  WidgetsBinding.instance.addTimingsCallback((timings) => _frames.addAll(timings));

  final source = _SyntheticSource(port: server.port);
  final rig = _Rig(source);
  runApp(
    ProviderScope(
      overrides: [commentsSourceProvider.overrideWithValue(source)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Builder(builder: (context) => rig.build())),
      ),
    ),
  );

  try {
    await _run(rig, server.port);
  } catch (e, st) {
    _say('PROBE FAILED: $e\n$st');
  }
  await _out?.flush();
  await _out?.close();
  exit(0);
}
