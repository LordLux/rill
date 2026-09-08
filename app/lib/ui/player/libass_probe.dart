/// **Throwaway instrumentation for the Task 19 phase 5 measurement.**
///
/// A static sink so `LibassLayer` can report what its render loop actually did
/// without the probe having to reach into private state. `enabled` is false in
/// every ordinary run and nothing reads these lists but `probe_task19.dart`.
///
/// **`libass_layer.dart` is NOT instrumented right now** — the four hunks below
/// were added, measured on 2026-08-25, and reverted, so the shipping file is
/// byte-identical to what it was. Re-apply them to take another reading:
///
/// 1. beside the other imports:
///        import 'libass_probe.dart';
/// 2. at the top of `_scheduleRender`, after the `_disposed` guard:
///        if (LibassProbe.enabled) {
///          LibassProbe.scheduled++;
///          if (_renderJob != null) LibassProbe.coalesced++;
///        }
/// 3. around the `_runRenderIsolate` await in `_renderLoop`:
///        final probeIter = Stopwatch()..start();
///        final rawImages = await _runRenderIsolate(...);
///        final probeIsolateUs = probeIter.elapsedMicroseconds;
/// 4. at the end of the loop body, after the image-dispose post-frame callback:
///        if (LibassProbe.enabled) {
///          LibassProbe.rendered++;
///          LibassProbe.isolateUs.add(probeIsolateUs);
///          LibassProbe.decodeUs.add(probeIter.elapsedMicroseconds - probeIsolateUs);
///          LibassProbe.totalUs.add(probeIter.elapsedMicroseconds);
///          LibassProbe.nowMs.add(nowMs);
///        }
library;

class LibassProbe {
  static bool enabled = false;

  /// `_scheduleRender` calls — one per `positionStream` event (plus resizes).
  static int scheduled = 0;

  /// Completed `_renderLoop` iterations.
  static int rendered = 0;

  /// `_scheduleRender` calls that landed while a render was already in flight.
  /// Their timestamp overwrites `_targetTimeSeconds`, so the *earlier* one is
  /// never drawn — this is the counter that says whether a step can be skipped.
  static int coalesced = 0;

  static final List<int> isolateUs = [];
  static final List<int> decodeUs = [];
  static final List<int> totalUs = [];

  /// The media time each completed iteration actually rendered.
  static final List<int> nowMs = [];

  static void reset() {
    scheduled = 0;
    rendered = 0;
    coalesced = 0;
    isolateUs.clear();
    decodeUs.clear();
    totalUs.clear();
    nowMs.clear();
  }
}
