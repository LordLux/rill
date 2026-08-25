/// **Throwaway measurement harness for Task 19 phase 5, measurement 3.**
///
///   flutter test test/probe_drag_lag.dart --reporter expanded
///
/// Does the rendered caption lag the cursor during a continuous window-edge
/// drag, and is the lag bounded?
///
/// `LibassLayer._onPanUpdate` recomputes `_nudges` synchronously on every
/// pointer move (correct — nothing is re-rendered mid-gesture), but the offset
/// reaches the screen through a `TweenAnimationBuilder` with a fixed 180 ms
/// `easeOutCubic` that is **re-targeted on every one of those setStates**. Each
/// retarget restarts the curve from the current animated value, so the drawn
/// position chases the cursor rather than following it.
///
/// This drives a real gesture with real elapsed time between moves and compares
/// where the pointer is against where `_CaptionGroup` (keyed `ValueKey(0)`)
/// actually is, at the same instant.
library;

// ignore_for_file: avoid_print

import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rill/ui/playback_controller.dart';
import 'package:rill/ui/player/libass_layer.dart';

import 'fake_engine.dart';

void _addDllDirectory(String path) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final setDllDir = kernel32.lookupFunction<Int32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)>('SetDllDirectoryW');
  final p = path.toNativeUtf16();
  setDllDir(p);
  malloc.free(p);
}

/// 1920x1080 at 16:9, so widget pixels and the document's PlayRes are 1:1 —
/// the same choice `caption_drag_test.dart` makes and for the same reason.
const _surface = Size(1920, 1080);

late FakeEngine engine;
late ProviderContainer container;

/// Mount the layer with a real caption on screen at [atMs].
Future<void> _pump(WidgetTester tester, {required int atMs}) async {
  await tester.binding.setSurfaceSize(_surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final ass =
      File('test/probe_fixtures/karaoke-L-BgxLtMxh0.ass').readAsStringSync();

  engine = FakeEngine();
  container = ProviderContainer(
    overrides: [playbackEngineProvider.overrideWithValue(engine)],
  );
  addTearDown(container.dispose);

  engine.emitPosition(Duration(milliseconds: atMs));
  await engine.setSubtitle(ass);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1920,
            height: 1080,
            child: LibassLayer(aspectRatio: 16 / 9),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  // The render is a real isolate round trip, so it needs real time.
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() async {
      engine.emitPosition(Duration(milliseconds: atMs));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump();
    if (find.byKey(const ValueKey(0)).evaluate().isNotEmpty) return;
  }
}

/// One continuous drag at [stepMs] between pointer moves, [steps] long.
Future<void> _drag(WidgetTester tester,
    {required int stepMs, required int steps, required Offset per}) async {
  final start = tester.getCenter(find.byKey(const ValueKey(0)));
  final rect0 = tester.getRect(find.byKey(const ValueKey(0)));
  final gesture = await tester.startGesture(start);
  await tester.pump();

  var pointer = start;
  final lags = <double>[];
  final samples = <String>[];
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(per);
    pointer += per;
    await tester.pump(Duration(milliseconds: stepMs));

    final r = tester.getRect(find.byKey(const ValueKey(0)));
    // Where the caption *should* be if it tracked the pointer exactly.
    final wantDx = pointer.dx - start.dx;
    final wantDy = pointer.dy - start.dy;
    final gotDx = r.left - rect0.left;
    final gotDy = r.top - rect0.top;
    final lagPx = Offset(wantDx - gotDx, wantDy - gotDy).distance;
    lags.add(lagPx);
    if (i < 6 || i >= steps - 4) {
      samples.add('  step ${i.toString().padLeft(2)}  '
          'pointer=(${wantDx.toStringAsFixed(1)},${wantDy.toStringAsFixed(1)}) '
          'caption=(${gotDx.toStringAsFixed(1)},${gotDy.toStringAsFixed(1)}) '
          'lag=${lagPx.toStringAsFixed(2)}px');
    }
  }

  final speedPxPerMs = per.distance / stepMs;
  print('drag: step=${stepMs}ms steps=$steps per=$per '
      '(${(speedPxPerMs * 1000).toStringAsFixed(0)} px/s)');
  for (final s in samples) {
    print(s);
  }
  final tail = lags.sublist(lags.length ~/ 2);
  final tailMean = tail.reduce((a, b) => a + b) / tail.length;
  final maxLag = lags.reduce((a, b) => a > b ? a : b);
  print('  lag: first=${lags.first.toStringAsFixed(2)}px '
      'max=${maxLag.toStringAsFixed(2)}px '
      'steady(second half mean)=${tailMean.toStringAsFixed(2)}px '
      '= ${(tailMean / speedPxPerMs).toStringAsFixed(1)}ms behind the cursor');
  print('  growth: first-quarter mean='
      '${(lags.sublist(0, lags.length ~/ 4).reduce((a, b) => a + b) / (lags.length ~/ 4)).toStringAsFixed(2)}px '
      'last-quarter mean='
      '${(lags.sublist(lags.length - lags.length ~/ 4).reduce((a, b) => a + b) / (lags.length ~/ 4)).toStringAsFixed(2)}px');

  // Release, and see how long the caption takes to catch up. `_commitDrag`
  // talks to the sidecar, which is not booted here; the settle is what matters.
  await gesture.up();
  for (var t = 0; t <= 240; t += 20) {
    await tester.pump(const Duration(milliseconds: 20));
    final r = tester.getRect(find.byKey(const ValueKey(0)));
    final gotDx = r.left - rect0.left;
    final gotDy = r.top - rect0.top;
    final lagPx =
        Offset(pointer.dx - start.dx - gotDx, pointer.dy - start.dy - gotDy)
            .distance;
    if (t % 40 == 0) {
      print('  after release +${t + 20}ms  lag=${lagPx.toStringAsFixed(2)}px');
    }
  }
}

void main() {
  setUpAll(() =>
      _addDllDirectory(Directory('windows/libass_bundle').absolute.path));

  testWidgets('M4: caption-vs-cursor lag during a continuous drag',
      (tester) async {
    await _pump(tester, atMs: 5300);
    expect(find.byKey(const ValueKey(0)), findsOneWidget,
        reason: 'no caption on screen — the render loop never produced a group');
    print('M4: caption group at ${tester.getRect(find.byKey(const ValueKey(0)))}');

    // ~16 ms between moves: a 60 Hz mouse, 8 px per step = 500 px/s.
    await _drag(tester, stepMs: 16, steps: 40, per: const Offset(-4, -4));
  });

  testWidgets('M4b: same drag at a 30 ms pointer cadence', (tester) async {
    await _pump(tester, atMs: 5300);
    expect(find.byKey(const ValueKey(0)), findsOneWidget);
    await _drag(tester, stepMs: 30, steps: 24, per: const Offset(-7, -7));
  });

  testWidgets('M4c: a long continuous drag — does the lag grow?',
      (tester) async {
    await _pump(tester, atMs: 5300);
    expect(find.byKey(const ValueKey(0)), findsOneWidget);
    await _drag(tester, stepMs: 16, steps: 100, per: const Offset(-3, -1));
  });

  testWidgets('M4d: a fast flick — 8 ms between moves', (tester) async {
    await _pump(tester, atMs: 5300);
    expect(find.byKey(const ValueKey(0)), findsOneWidget);
    await _drag(tester, stepMs: 8, steps: 60, per: const Offset(-3, -2));
  });
}
