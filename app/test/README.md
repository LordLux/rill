# Task 19 measurement probes

Not `_test.dart` files, so `flutter test` (bare) does not run them, and they are
not part of `bun run check`'s app-side equivalent. Run each explicitly. They
exist because phase 5 (removing the `sub-add → mpv → libass` fallback pipeline
and making `LibassLayer` the only renderer) needed three things measured that
had never been measured, and `docs/architecture.md`'s "Dragging a caption, and
the style menu" section has the results and what they mean for that decision.

**The finding that matters before you reach for `flutter test`:** `flutter
test` has no video-output timing loop. `media_kit`'s `Player()` without a
`VideoController` does load `libmpv-2.dll` and does report a duration, but it
emits exactly one `positionStream` event — `0:00:00.000000` — over 20 s of
real time. There is no render context, so mpv never starts the timer that
drives ordinary position updates. **`positionStream` cadence, and anything
that depends on it (whether a render call lands inside a given cue's window),
cannot be measured from a `flutter test` process at all** — not slowly, not
approximately, not at all. That half of the measurement needs a real Flutter
Windows process: `lib/probe_task19.dart`, one level up from this directory.

## What's here

- **`probe_libass_cadence.dart`** — `flutter test test/probe_libass_cadence.dart`.
  Measures the wall-clock cost of one `LibassLayer._runRenderIsolate` round
  trip (a fresh `Isolate.run` calling `ass_render_frame`) plus the main-thread
  `decodeImageFromPixels` work that follows it, against the real bundled
  `libass-9.dll`, over a real karaoke document (M1) and a real ASR
  rolling-window document (M2). The isolate body is copied verbatim from
  `lib/ui/player/libass_layer.dart` — if that file's render path changes,
  this stops measuring the real thing and needs re-syncing by hand.
  Loads the DLL via `SetDllDirectoryW('windows/libass_bundle')` (`flutter
  test`'s cwd is the package root), same pattern as `libass_spike/probe_clip.dart`.

- **`probe_drag_lag.dart`** — `flutter test test/probe_drag_lag.dart --reporter expanded`.
  Mounts a real `LibassLayer` and drives a real, continuous drag gesture
  (`tester.startGesture` + `moveBy`, separated by real `tester.pump(Duration(...))`
  advances — not single frame pumps) to measure whether the on-screen caption
  visibly lags the cursor, and whether that lag is bounded or grows over a long
  drag. Four runs at different pointer speeds/cadences (M4–M4d), plus a
  post-release catch-up trace.

- **`probe_tile_height.dart`** — `flutter test test/probe_tile_height.dart --reporter expanded`.
  Answers the one question a `MediaTile` cannot be asked at layout time: how
  tall is its metadata block. Every horizontal strip in the app
  (`artist_panel_card.dart`'s artist shelf, `feed_view.dart`'s Shorts shelf)
  has to carry that number as a constant, because the tile puts a
  `LayoutBuilder` at the root of its own build and a `LayoutBuilder` cannot
  answer an intrinsic-height query — so the strip's `SizedBox` height is
  computed, and a constant that is 1.5 px short is a visible overflow stripe.
  Renders a real tile under an unbounded constraint across widths, title
  lengths and badge states. Measured 2026-09-01: **93.5** with no badges
  (two lines of title, the cap, at every width from 180 to 320) and **115.5**
  with them — a flat **+22.0** for the badge row. Re-run it after any change
  to `MediaTile`'s `bottomArea`.

- **`probe_blur_edges.dart`** — `flutter test test/probe_blur_edges.dart --reporter expanded`.
  Renders a blurred image to a bitmap and reads the pixels along its edge, to
  settle which blur strategy leaves the dark rim the artist panel's backdrop
  was showing. Measured 2026-09-01 at sigma 8: an unfiltered reference holds
  255 at the edge, `TileMode.decal` drops to 134 (the artefact, reproduced),
  `TileMode.clamp` holds 255 (no rim), and a `BackdropFilter` in a `Stack`
  drops to the same 134 — so the mode is the fix and the backdrop is not.
  Blurring a composited scene still blurs across the artwork's boundary.

  Two traps this probe walked into, both of which made every strategy look
  identical and neither of which announced itself: the ground and the image
  must differ in the channel being read (pure red and pure white share a full
  red channel), and `toImage` on the boundary returns the **whole view**, not
  the harness box — so the scan geometry has to be derived from the captured
  size rather than from the widget's own padding.

- **`probe_backdrop_edge.dart`** — `flutter test test/probe_backdrop_edge.dart --reporter expanded`.
  The same question as `probe_blur_edges.dart` but against the artist panel's
  **real** composition — fractional box, two nested gradient masks, blurred
  image, over the tint — because the bare-square probe and the widget disagree
  about what is safe, and the widget is what ships. Stands the artwork in as a
  ramp with a dark left edge, which is the case that bites.

  Measured 2026-09-01, as delta from the flat tint (0 = bare card):

  | | outside the left edge | top edge, y=0→12 |
  |---|---|---|
  | `decal`, clip outside the box | 2, 5, 14, 23 | 37→69 ramp |
  | `clamp`, clip outside the box | **66, 66, 66, 66** | 69 flat |
  | `decal`, clip inside the box | 0, 0, 0, 0 | 37→69 ramp |
  | `clamp`, clip inside the box | 0, 0, 0, 0 | 69 flat |

  Two independent defects, and the first is not a blur setting at all. **A
  blurred layer paints past its own bounds and a `ShaderMask` masks only
  within its rect, so whatever escapes is composited with no mask on it** — a
  clip outside the fractional box clips to the whole card and contains none of
  it. With `clamp` (which repeats the edge pixel outward) that escaped band is
  a solid hard-edged bar, the flat 66. The second is the tile mode itself: at
  the top edge, where the card's boundary cuts the artwork, `decal` lets the
  tint through over ~10 px — the original "shadow" — while `clamp` is opaque
  from the first row. So the shipping answer is `clamp` **and** a tight clip;
  either alone leaves one of the two artefacts.

- **`probe_artist_header.dart`** — `flutter test test/probe_artist_header.dart --reporter expanded`.
  Measures the artist panel's two header columns across window widths: what
  each action pill costs, what a single row of them would need, and where each
  column lands. Exists because that split is driven by two constants
  (`_avatarBlockWidth`, `_minIdentityWidth`) whose only justification is that
  the pills keep a single row wherever one fits.

  **Read its numbers with the font in mind.** `flutter test` renders in Ahem,
  where every glyph is a full em square, so text-derived widths come out
  roughly double the shipped ones — the probe prints `text=` and `chrome=`
  separately so the two are distinguishable. Measured 2026-09-01: four pills
  report 782 px here, of which ~490 is Ahem glyph width; the same row is
  ~516 px in Roboto, against roughly 500 on youtube.com. A pixel target read
  straight off this probe will be wrong by a factor of two, which is why the
  regression tests in `artist_panel_test.dart` assert proportions instead.

- **`probe_fixtures/karaoke-L-BgxLtMxh0.ass`**, **`probe_fixtures/asr-dQw4w9WgXcQ.ass`**
  — real captured documents, not hand-authored. The karaoke one carries
  `L-BgxLtMxh0`'s real ~200 ms color-split steps; the ASR one is a real
  rolling-window track fetched anonymously over `MWEB`. Both probes above read
  these rather than synthesizing a document, because a hand-written ASS file
  doesn't share YouTube's actual event-timing structure and would measure
  nothing real. Refetch the ASR one (or a different video's) with
  `cd sidecar && bun run scratch/probe-asr-fetch.ts <videoId>`, which writes
  `scratch/out/<videoId>-asr.{json,ass}` — copy the `.ass` into `probe_fixtures/`.

- **`../lib/probe_task19.dart`** — the real-process measurement. Build and run it
  directly, it is never wired into the app:

  ```bash
  cd app
  flutter build windows --release -t lib/probe_task19.dart
  .\build\windows\x64\runner\Release\rill.exe
  ```

  Opens a **local** video file (env `RILL_PROBE_MEDIA`, default a file under
  Downloads — set it to any local file you have) through the real
  `MediaKitEngine`, mounts a real `LibassLayer` with a real captured document
  (`RILL_PROBE_ASS`, defaults to the karaoke fixture above), and for
  `RILL_PROBE_SECONDS` (default 30) records real `positionStream` inter-arrival
  times, real `FrameTiming` (build/raster/total span, dropped-frame counts),
  and — coverage — whether every cue that was live during the window got at
  least one render. This is real because the clock being measured is mpv's own
  property-observation timer; it has nothing to do with where the video came
  from, which is why a local file is enough and no YouTube session is needed
  here.

  **This overwrites `app/build/windows/x64/runner/Release/`.** Run
  `flutter build windows --release` (default target) afterward to put the real
  app back before testing anything else there.

- **`../lib/ui/player/libass_probe.dart`** — a static counters/timings sink
  `probe_task19.dart` reads. On its own it measures nothing: `libass_layer.dart`
  is not instrumented (the shipping file is byte-identical to HEAD). The
  file's own header has the exact four small hunks to re-apply to
  `libass_layer.dart` to light up the `--- LibassLayer render loop ---` block
  (scheduled/rendered/coalesced counts, isolate/decode timings, per-cue
  render coverage) — revert them after the run. Without those hunks,
  `probe_task19.dart` still reports real `positionStream` and `FrameTiming`
  numbers; only the render-loop section reads zero.

## Why these exist instead of a permanent `_test.dart`

They're not regression tests — nothing here has a fixed pass/fail assertion,
and CI never runs them. They're re-runnable measurements, the same role
`sidecar/scratch/probe-task19.ts` plays for the sidecar side: something to
reach for again the next time this render path changes and the isolate design
needs re-justifying, rather than re-deriving a `flutter test`-can't-see-this
harness from scratch under time pressure.
