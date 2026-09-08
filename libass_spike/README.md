# libass_spike — Option D

Flutter + libass 0.17.5 over FFI on Windows. libass rasterises; Dart maps each
`ASS_Image` in the returned linked list to a tightly-cropped `RawImage` placed
with `Positioned`. No fontconfig — leaving `FONTCONFIG_PATH` unset lets libass
fall back to DirectWrite (`[ass] Using font provider directwrite (with GDI)`).

## The clipping bug, and why the first three fixes could not have worked

**libass crops rasterised glyphs against the *video* rectangle, which is
`ass_set_frame_size` minus `ass_set_margins` — not against the frame.**

That is the whole thing. `ass_set_margins` moves the layout origin *out* by the
margin and shrinks the content box by the same amount, so the two cancel and the
crop rectangle never moves. Growing the frame to 3920×3080 and adding 1000px
margins produces exactly the crop you had at 1920×1080.

Measured with asymmetric margins (`probe_clip2.dart`), which separates the two
hypotheses — frame 3920 wide, `ml=1500`, `mr=500`, so the content box is
`[1500..3420]` and the frame is `[0..3920]`:

| case | content-rect crop predicts | frame-rect crop predicts | measured |
|---|---|---|---|
| right overflow | `x[1500..3420]` | `x[2589..3920]` | **`x[2592..3420]`** |
| left overflow | `x[1500..2311]` | `x[889..2311]` | **`x[1500..2314]`** |

`ass_set_use_margins` makes no difference — it only governs whether
*un-positioned* events may be laid out into the margin area.

`\clip` could not have helped either: it only ever *intersects* the visible
region. There is no override that widens it.

## The fix: pad the script, not the renderer

The video rectangle *is* the `PlayResX`/`PlayResY` box scaled to the frame. So
grow the play res instead — `lib/ass_padding.dart`:

- `PlayResX/Y` += 2× pad
- every style's `MarginL/R/V` += pad
- every event's non-zero `MarginL/R/V` += pad (`0` means "inherit the style",
  which is already padded)
- every `\pos`, `\org`, `\move`, `\clip`, `\iclip` — rectangular and vector
  forms, including the vector form's `2^(scale-1)` pre-division — shifted
- frame size = padded play res, margins zero, `ass_set_pixel_aspect(1.0)`

The scale factor `frame / PlayRes` is 1 before and after, so font size, border,
shadow, blur and wrap width are untouched. The renderer's output is then in the
padded space; subtract the pad and you have the original script's coordinates,
free to go negative or past `PlayResX`.

`probe_pad_equiv.dart` renders 15 events both ways and asserts the bounding
boxes are byte-identical (plain `an2`, `an7`/`an8`, event margins, `\pos`,
`\blur`, `\bord`+`\shad`, `BorderStyle: 3`, `\org`+`\frz`, `\move`, rect clip,
vector clip, scaled vector clip, wrapping, `\fad`) — and that the two overflow
cases get *wider*:

```
overflow right   plain [1397..1920]   padded [1397..2218]
overflow left    plain [   0.. 538]   padded [ -283.. 538]
```

`probe_file_equiv.dart` does the same across whole real files, image by image:
every image must be either pixel-identical or strictly *wider* than the
unpadded render — same count, same colour, same type, containing the old box.
Over `complex_test.ass`, `L-BgxLtMxh0`, `1S7uIQmkRzk`, `v2`, `Untitled` and
`m (7)`: **0 differing frames**.

It caught one real bug. Coordinates were re-emitted with `toStringAsFixed(2)`,
and `Untitled.ass` carries `\move(441.333,170,1400,720)` — rounding that to
`441.33` moved a rasterisation boundary far enough to change a shadow bitmap by
one pixel at 11.2 s. Six decimals with trailing zeros stripped; `toString()`
would be exact but can emit exponent form, which no ASS parser accepts.

## Repositioning

`lib/ass_reposition.dart` edits the **authored** script; the padded copy is
derived and never edited, so nothing accumulates across drags. (The previous
version prepended a fresh `\clip(-1000,-1000,3000,3000)` on every commit — one
dead tag per gesture.) Three cases, in libass' own resolution order:

- `\move` present → it wins over `\pos`; shift its first four arguments only.
- `\pos` present → shift it, plus `\org` and any `\clip`, which live in the same
  screen space.
- Neither → the event is laid out from alignment and margins and there is no
  coordinate to add to. Convert it to `\an<N>\pos(x,y)` anchored exactly where
  libass had it, then shift. Wrapping survives: libass still wraps a `\pos`ed
  line at the margin box.

`probe_reposition.dart` renders before and after and asserts the bounding box
moved by exactly the delta, for all three cases plus rotation, clips and legacy
`\a` alignments.

## Clamping overflowing captions

With the crop gone, the app finally sees the true bounding box and can slide an
over-long line back inside. The first version of this looked like it did nothing
— you had to grab a caption before it snapped into place, and only then because
the *drag* clamp fired. Two separate defects, both measured with
`probe_nudge.dart`, which drags a whole track by a synthetic delta and walks the
timeline counting groups left hanging outside the video.

**1. The "deliberately off-screen" test flagged our own work.** Events were
exempted from clamping if they carried `\move` *or a `\pos` outside the video*.
But a drag shifts every line in the file, so any incidental line pushed out of
frame flagged itself — and the exemption was frame-wide, so it silenced the
clamp for that line's whole time span. On `L-BgxLtMxh0.ass` with a (340, −60)
drag: **30 of 265 events self-flagged, and 10 of 19 overflowing frames were
suppressed.** Only `\move` counts now, and it exempts just the group sitting on
the moving event's interpolated anchor, not the frame.

**2. Clamping was computed over the union of the whole frame.** A track can put
several independently placed captions on screen at once — `L-BgxLtMxh0.ass`
shows six scattered words at 32 s — and their union box is far wider than any
one of them, so it either moved five captions for the sake of the sixth or (more
often) exceeded the video and was skipped as unrescuable. Clamping is per
caption group now, and the drag clamp intersects the allowed range over the
groups that fit rather than clamping the union.

After both: across `L-BgxLtMxh0`, `1S7uIQmkRzk`, `v2` and `Untitled`, dragged
±600 px horizontally and ±300 px vertically, **every overflowing group is
clamped back in and none is left hanging** — symmetrically in all four
directions.

Two rules that are not obvious and stayed:

- Only clamp an axis where the content actually *fits*. A line wider than the
  video cannot be rescued by translation; pushing it just swaps which edge is
  cut.
- The clamp is display-only, and is folded into the next commit so a caption
  does not jump back when the user drags again.
- The clamp is gated on the same flag as dragging. A styled track is locked, and
  locking it disables clamping entirely — in production that flag comes from
  the track's own metadata (styled: locked; unstyled and ASR: draggable), not
  from the spike's toggle.

### Recovering caption groups from a flat image list

`ASS_Image` carries no event id, so grouping is inferred: `ass_render_frame`
appends each event's images as one contiguous block, emitting them shadow →
outline → character, so `type` is non-increasing within an event and a new event
begins exactly where `type` goes back up.

`probe_groups.dart` checks this against ground truth — render the track at time
T, group it, then render each active event *alone* in its own track at the same
T and compare boxes. Exact across the demo and all three `\pos`-ed sample
tracks.

A spatial tie-breaker was tried and removed. `probe_gaps.dart` says why: across
the sample tracks the largest gap *inside* one event is 0 px and the smallest
gap *between* two events is also 0 px, because YouTube composites a caption as
an invisible shadow-carrying event sitting exactly on top of a visible one. No
threshold separates the two populations. It also broke karaoke — `\k` colour
runs sit 11 px apart inside a single event and were split into one group per
syllable.

The heuristic's one blind spot is two adjacent events that draw fill only — no
outline, no shadow — which produce an unbroken run of `type == 0` and merge into
one group, clamping together instead of independently. Every real caption style
carries an outline. `probe_groups.dart` pins this case explicitly so a libass
change surfaces there rather than as a mystery in the UI.

### Animation

Only the clamp is animated, per group, and a group that has just appeared starts
*at* its clamped position rather than sliding in from zero. Per-image
`AnimatedPositioned` was wrong: the image widgets are rebuilt wholesale every
frame with no identity across frames, so Flutter tweened between unrelated glyph
groups.

## Layout

- `lib/ass_binding.dart` — FFI surface
- `lib/ass_padding.dart` — the crop fix
- `lib/ass_reposition.dart` — drag commit + event scanning
- `lib/caption_layout.dart` — image grouping and clamping (pure, no dart:ui)
- `lib/main.dart` — render loop, drag, clamp, UI

## Probes

libass is a DLL and Dart has FFI, so all of this is checkable offline against
the exact artefact the app loads:

```bash
dart run probe_pad_equiv.dart && dart run probe_file_equiv.dart && dart run probe_reposition.dart && dart run probe_groups.dart
```

`probe_clip.dart` / `probe_clip2.dart` record the crop measurement,
`probe_nudge.dart` and `probe_gaps.dart` are diagnostics that print rather than
assert, and `probe_dump.dart` dumps one frame's image rects.

`lib/test_ffi.dart` and `test_dw_frame.dart` are pre-existing scratch files with
mangled string interpolation; `lib/test_ffi.dart` does not compile and trips
`flutter analyze`. Nothing imports either.

Requires `libass-9.dll` at `C:\msys64\msys64\mingw64\bin` (hard-coded in
`main.dart` and in every probe).
