# Task 19 — draggable captions and a caption style menu

**Status: built 2026-08-20.** All four decisions implemented; §9 records what was built,
what the measurements said, and the one thing this brief got wrong. Written to be read
without the conversation that produced it.

Two corrections were folded in on 2026-08-20, both recorded rather than quietly swapped,
because in each case the original reasoning is the thing someone would otherwise repeat:

> **Decision 1's premise was inverted.** It was taken on the understanding that a split
> renderer "would serve a minority of tracks". Sampling ordinary videos shows the split is
> **~100% plain / 0% styled** — the other way round. The decision does not change; the
> reason does, and the measured reason is stronger. See §5, Decision 1.

> **Decision 3 claimed a geometry that does not exist.** An earlier draft had Flutter
> clamping against "the bitmap's real size". Under Decision 1 there is no such bitmap —
> libass composites into the video texture and publishes no geometry. The drag is a
> Flutter-drawn ghost, and the clamp is an estimate. See §4.3 and §5, Decision 3.

---

## 1. Context

Rill is a native Windows YouTube client: Flutter UI, libmpv playback via `media_kit`,
backed by a headless Node/Bun sidecar that talks to YouTube's private InnerTube API.

Captions are built and working. The pipeline is
`fetch json3 → parse → cues → group (ASR only) → ASS → sub-add`, entirely in the
sidecar; **libass draws them into the video texture, and Flutter draws none**
(`docs/architecture.md` §2.9, a decision that explicitly rejected a Flutter overlay).

Task 18 finished the styling half of that: position, colour, font, size, weight,
underline, background boxes and karaoke highlighting all survive to the screen.

Two bugs closed on the way, both worth knowing because they shape the risk appetite here:

- **Stacked duplicate lines.** YouTube composites a styled caption from more than one
  event — an invisible-glyph pen contributing a drop shadow over a visible pen
  contributing the outline, which is 240 of one test document's 257 cue groups. The
  parser now merges them into one line carrying both edges.
- **media_kit ships with libass off.** `PlayerConfiguration.libass` defaults to `false`,
  which becomes `sub-ass=no` *and* `sub-visibility=no` on the mpv side — mpv strips every
  tag and then draws nothing — while the `Video` widget mounts a Flutter `SubtitleView`
  that paints the stripped plain text itself. So **Flutter was drawing every caption from
  tag-stripped text for two entire tasks**, invisibly, because a plain caption looks
  correct either way. Both settings now live together in `engine.dart` as
  `kLibassEnabled` and `kNoFlutterSubtitles`.

That second bug is the reason the decisions below treat "two things can draw a caption"
as a serious risk rather than a detail.

---

## 2. What is being asked for

A caption the user can drag anywhere in the player, plus a YouTube-style caption style
menu. Stated requirements, all confirmed:

- Free **two-dimensional** drag anywhere in the player.
- A **background** behind each caption line, with slightly rounded corners. Always drawn.
  It is the grab handle.
- A **window** — a separate, larger rectangle wrapping every caption on screen at once.
  YouTube always draws this too, at 0% opacity by default, so the style menu can turn it
  up. Background and window are two different boxes; the distinction matters throughout.
- The cursor becomes a **grab cursor** over the text and its background — or over the
  window, once that has opacity.
- A **style menu**: font family, font colour, font size, background colour, background
  opacity, window colour, window opacity, character edge style, font opacity. Plus a
  **reset** control, which lives in this menu.
- **Position persists per video and per track.** It survives turning captions off and back
  on. It resets when the track changes.
- **A caption never leaves the frame, not even partly.** Drag one into the bottom-right
  corner, and a longer line that follows must come back in to fit.

---

## 3. Measurements that bound the design

All measured against the *bundled* libmpv (mpv v0.36.0-403 / FFmpeg n6.0) — the exact
DLL the app loads — by rendering ASS documents to frames through it via Bun FFI. Not
from documentation. The harness is `sidecar/scratch/render-ass.ts`.

| Question | Answer |
|---|---|
| `\pos` vs libass collision avoidance | Positioned events superimpose exactly; unpositioned ones stack vertically |
| Inline `\c` with alpha | Six digits only; alpha needs a separate `\1a`. Eight digits render opaque and the wrong hue, silently |
| Caption background | `BorderStyle: 3`, filled from `\3c` — not `\4c`, which the name suggests |
| Both boxes | **`BorderStyle: 4` draws a per-text box from `\3c` *and* a whole-block rectangle from `\4c`** — YouTube's background and window both exist in ASS |
| Rounded corners | Not expressible. Both boxes are rectangles |
| A positioned line wider than the frame | **Runs straight off the edge. No clamp, no wrap** |
| `sub-pos` | Does **not** move a positioned cue — rules it out as the drag mechanism |
| `sub-ass-override=force` | Overrides the ASS `Style`, **not** inline override tags |
| Missing font | Silent fallback to the default sans face |
| Colour emoji | Glyph outline filled with the text colour; colour layers never used |
| `sub-add` cost | 12–36 ms, and it does **not** rebuild the video texture |

Live mpv properties that exist and accept writes: `sub-font`, `sub-color`, `sub-scale`,
`sub-font-size`, `sub-back-color`, `sub-border-color`, `sub-border-size`,
`sub-shadow-offset`, `sub-margin-x`, `sub-margin-y`, `sub-align-x`, `sub-align-y`,
`sub-ass-override`, `sub-ass-force-style`.

---

## 4. The design that follows

### 4.1 Position is a delta, not a coordinate

Store the *difference* between where a caption would have been and where it was dragged
to, as a fraction of the video rect. Add it to whatever position the source gives, when
the sidecar writes `\pos`:

| Cue | Base position | With a delta |
|---|---|---|
| Plain manual | none emitted | `\pos(960+dx, 1020+dy)` |
| Auto-generated rolling window | `\pos(420, 1020)` | `\pos(420+dx, 1020+dy)` |
| Styled / positioned | `\pos(942, 694)` | `\pos(942+dx, 694+dy)` |

One rule for every kind of track, so nothing has to ask what kind of caption it is
holding. A zero delta emits nothing new, so a plain track still produces byte-identical
ASS to what it produces today. A fraction rather than pixels means it survives resize,
fullscreen and the mini-player.

This keeps the existing `styled` classification **cosmetic** (it drives a picker badge)
rather than load-bearing. That matters: two of the three predicates tried for it during
Task 18 were wrong, and a misclassification that only costs a wrong badge is very
different from one that picks a renderer.

### 4.2 The no-overflow rule needs a width nobody has

libass will not help — a positioned line too wide for the frame runs straight off the
edge, measured. So the clamp is ours, and it needs the rendered width of the text.

**Neither side has that width.** The sidecar holds every cue's text but has no font
engine. Flutter has the font engine but, under Decision 1, holds no cue text — libass
paints inside the video texture and publishes no geometry.

The resolution is in §4.3: **Flutter is the only measuring instrument, so it measures, and
the number it produces is used in both places.** It applies directly for the cue on screen
and by calibration for the cues that follow. Nothing is estimated twice by two different
methods, which was the flaw in an earlier draft of this section.

### 4.3 One estimate, three uses

Under Decision 1 nothing publishes the caption's rectangle. The hit rect, the hover
cursor, the drag ghost and the clamp therefore all run on **one estimate**, produced in
one place, rather than three approximations that can disagree.

**How it is produced.** `TextPainter`, at the font family and size the ASS document was
generated with. That is far closer than a character-count heuristic, because it is real
shaping of the real string — it differs from libass only in the shaper (HarfBuzz +
fontconfig vs Flutter's) and in font fallback.

**Bias it large, always.** The estimate is inflated before use. An over-estimate makes the
hit rect slightly too big and stops the drag a few pixels short of the corner; an
under-estimate lets text clip off the edge of the player. Only one of those is a bug, and
it is not the first. Every rounding in this path rounds outward.

**The cue on screen, and the cues after it, are different problems.** Flutter can measure
only what it can see the text of, which is the current cue. Later cues are positioned when
the sidecar writes `\pos`, long before they appear.

- **Current cue** — hit rect, cursor, ghost, and the clamp during a drag. Flutter measures
  it directly with `TextPainter`.
- **Later cues** — the nudge from Decision 2. Flutter sends the sidecar **one calibration
  number**: pixels per character for this track's font at this size, obtained by measuring
  a reference string with the same `TextPainter`. The sidecar multiplies by each cue's
  character count and inflates. Same instrument, same bias, applied where the position is
  actually written.

The alternative is shipping the whole cue list — text, times and resolved style — so
Flutter can measure every cue itself. **Not proposed:** it duplicates the ASS document in
a second structured form on the wire, and it re-creates the "two representations of one
caption" shape that this project has already been bitten by once. One calibrated number
buys most of the accuracy for none of that.

**What it needs, and what that costs the protocol.** Three things, none of them a cue list:

1. **The current caption's text.** Free. Measured 2026-08-20: `sub-text` is populated
   while libass is drawing — plain text, tags stripped, alongside `sub-start`/`sub-end` —
   and media_kit already observes it and exposes `player.stream.subtitle`. No protocol
   change at all.
2. **The layout the ASS was generated with.** Not free, but small: font family, font size,
   `PlayResX`/`PlayResY`, the margin box, outline width, box padding, and the default
   anchor. That is **~8 values per track, not per cue** — added to `captions.get`'s result
   as a layout descriptor.
3. **The calibration, going the other way.** One number on the request that commits a
   drag, beside the delta. Nothing persistent.

The descriptor is sent rather than duplicated as constants on both sides deliberately:
`ass.ts` picks those numbers, and a second copy in Flutter is two things that have to
agree and will eventually not.

**Styled tracks are the gap, and it is a small one.** A styled cue's base position varies
per cue, so an exact hit rect there would need per-cue geometry — a compact
`(startMs, endMs, x, y, an)` list, roughly 10 KB for 265 cues. **Not proposed for this
task**: §5 Decision 1 measured 0% of ordinary tracks as styled, so this buys precision on
content almost nobody has. Ship the descriptor; on a styled track the handle falls back to
the default anchor, which is approximate but still grabbable. Revisit if it ever matters.

### 4.4 The style menu applies during ASS generation, not through mpv properties

**The property route cannot work, and it fails silently on exactly the tracks it would be
aimed at.** `sub-ass-override=force` overrides the ASS `Style`; Task 18 emits a styled
track's colour, font and size as *inline override tags*, and force does not touch those —
measured in §3. So a user setting a font colour would see it apply to plain tracks and do
nothing at all on styled ones, with no error and no explanation.

So the sidecar applies user overrides **when it generates the ASS**, suppressing the
inline tags the user has overridden. Uniform across every track type, because there is
only one mechanism.

**Cost, measured 2026-08-20.** Parse and re-render of a real document:

| Document | Cues | Size | Parse + render |
|---|---|---|---|
| `1S7uIQmkRzk` | 99 | 70 KB | **2.8 ms** |
| `L-BgxLtMxh0` | 265 | 127 KB | **4.4 ms** |
| `8Oos6D4_Bjo` | 230 | 3.1 MB | 104.7 ms |

Plus `sub-add` at 12–36 ms with no texture rebuild, plus one RPC round trip. So a style
change costs **roughly 15–40 ms** on ordinary content, and ~140 ms on the pathological
3 MB outlier. Caching parsed cues (§6) removes the parse from repeats, leaving render plus
`sub-add`.

**Slider input is debounced** — trailing, ~120 ms — so dragging an opacity slider commits a
handful of times rather than once per frame. Discrete controls (font family, edge style)
commit immediately.

**Two things fall out of this that are worth having.** `sub-ass-override` can stay at its
default and never be touched, which removes a mode flip that would otherwise have to be
right per track. And the style overrides travel the same path as the drag delta — one
regeneration, one cache, one commit point — instead of the delta regenerating while style
went through properties.

**The hybrid, costed, and why not.** Live properties for plain tracks and regeneration for
styled ones would make plain tracks respond in well under a millisecond, against 15–40 ms.
That difference is invisible on a discrete control and marginal on a debounced slider. It
buys that by keeping two update mechanisms for one menu, flipping `sub-ass-override` per
track, and making the same control feel different depending on which track is selected —
including the case where a user switches tracks with the menu open. Given §5's measurement
that 100% of ordinary tracks are plain, the hybrid would also mean the regeneration path
is the one that almost never runs, so the rarely-exercised path is the one handling the
harder case. **Not recommended.**

### 4.5 What the menu can honestly offer

Because §4.4 applies overrides at generation, **every control works on every track**. That
was the point of moving off properties, and it settles Decision 4 by construction: there
is no track type on which a control silently does nothing, so nothing has to be hidden or
disabled per track.

Two entries in YouTube's menu cannot be honoured as distinct settings, and should not be
offered as if they were:

- **Raised and Depressed edge styles.** ASS has `\bord` and `\shad` and no bevel, so both
  render as a drop shadow. Offering both means offering two entries with one result. Offer
  None / Drop shadow / Outline, and leave the other two out.
- **Rounded corners on the background.** Not expressible — see §8.

Everything else maps cleanly: font family, font colour and opacity, font size, background
colour and opacity, window colour and opacity, and the reset.

**One override deserves a guard.** Setting a font colour on a *karaoke* track would flatten
the sung/unsung distinction into one colour, because both runs are inline colours the
override would replace. Either exclude per-segment colours from the override, or accept it
— the user is asking for one colour and would be getting it. Worth deciding during
implementation rather than discovering.

---

## 5. Decisions

### Decision 1 — who draws plain captions — **SETTLED: Option A**

**libass draws every caption; Flutter draws none.** Flutter measures the same string only
to place an *invisible* hit rectangle. Recorded in `docs/architecture.md` §2.9 under
"Who draws a caption".

The reason is measured. Sampled across 34 ordinary videos off live search — 20 had
captions, 23 tracks read:

| | tracks | share |
|---|---|---|
| `plain` | 23 | **100%** |
| `styled` | 0 | 0% |

Every styled track in the corpus is a caption-art demo. Ordinary videos are plain, and
every auto-generated track is plain by construction — ASR carries a rolling window and no
pens.

- **B — Flutter draws plain, libass keeps styled. Rejected.** The split is ~100/0, so
  Flutter would draw effectively every caption a user sees while libass served demo
  videos. The styling pipeline would become the path that almost never runs, and the
  two-renderer risk would apply to the common case rather than an edge one. That risk is
  not hypothetical — see §1.
- **C — Flutter draws everything, libass removed. Rejected for now, not rejected.** It
  would give exact geometry, a rounded box and a real hit target. Its cost is rebuilding
  what `ass.ts` and libass already do between them: custom line metrics, multi-pass
  painting, collision tracking, scaling — a bespoke subtitle rendering engine. Kept on
  record because someone will propose Flutter rendering again; the objection is the
  engine, not the idea.

**Accepted limitation: no rounded corners.** ASS has both boxes — `BorderStyle: 3` fits
one per line (the background), `BorderStyle: 4` adds a rectangle round the whole block
(the window) — but both are rectangles. This sits with vertical text and colour emoji in
§8 as knowingly dropped, not quietly missed.

### Decision 2 — clamp the drag, or nudge each cue — **SETTLED: nudge each cue**

- **Clamp the drag** by the track's widest line: the caption never moves on its own.
- **Nudge each cue** as it appears: a freer drag, but the caption shifts sideways whenever
  a line changes length.

**Recommendation: nudge each cue.** Three reasons, and the first is what changed my mind.

1. **Clamping the drag needs a number that is worse than the one nudging needs.** "The
   track's widest line" is itself an estimated width, so it is an estimate *of an
   estimate*. On a track with one long line among a hundred short ones, that single
   outlier shrinks the draggable area for the whole track — and the user finds the caption
   refusing to reach a corner it is nowhere near filling, for a reason nothing on screen
   explains.
2. **The drag itself is clamped precisely anyway**, against the cue actually on screen,
   measured directly by Flutter (§4.3). Nudging governs only the cues that arrive
   *afterwards*, where a calibrated estimate is all either side has.
3. **It is what was asked for** — "pushed to the left to make it not overflow" — and it is
   what YouTube does. The jitter objection is real but narrow: it fires only on cues that
   would otherwise leave the frame, i.e. a caption dragged near an edge, and the
   alternative there is text off-screen.

Mitigation for the jitter, if it proves objectionable: nudge inward only, and hold the
nudged position until a cue appears that does not need it. That turns per-line jitter into
one move at the edge.

**The estimate is §4.3's**, not a separate crude one — Flutter measures, the sidecar
applies the calibration to the cue texts it already holds, and every rounding rounds
outward.

### Decision 3 — what happens during the drag — **SETTLED**

**Drag the static libass bitmap on the Flutter side; commit to `sub-add` only on drag
end.** The bitmap already on screen *is* the ghost — nothing is re-rendered mid-gesture,
and no re-render cycle needs measuring.

**One correction to how this was first written.** "Drag the libass bitmap" is not
available: libass composites the caption *into the video texture*, and media_kit exposes
no separate subtitle surface — that is Decision 1's premise, and an earlier draft of this
section contradicted it by claiming Flutter would know "the bitmap's real size". It does
not. What is actually dragged is a **Flutter-drawn ghost**, built from the current
caption's text and the layout descriptor in §4.3, while the real caption stays put until
release. On release: commit the delta, regenerate, `sub-add`, ghost disappears.

That is a small amount of text drawn in Flutter, transiently, during a gesture. It is
worth naming plainly so nobody mistakes it for Option C arriving by the back door: it
renders one line of already-known text at a known size, and it is never on screen at the
same time as a caption it is meant to match.

Three of the four justifications hold exactly as stated:

- **Smoothness is guaranteed** because libass and the FFI boundary are out of the loop for
  the whole gesture. 60/120 fps is a property of the approach, not a target to hit.
- **The text cannot reflow while dragging.** The real caption does not move at all until
  release, and the ghost is a fixed box. Re-rendering mid-drag would re-wrap lines as the
  available width changed, so the caption would change shape under the cursor.
- **The hover cursor falls out** — a `MouseRegion` over the hit rect is the whole
  implementation.

The fourth changes: **clamping is not exact.** It runs on the same estimate as the hit
rect — see §4.3. The behaviour is unchanged (the caption stops at the border and still
slides tangentially along it); only its precision is, and it errs on the safe side.

### Decision 4 — how the style menu applies — **SETTLED**

**Overrides are applied by the sidecar during ASS generation, suppressing the inline tags
the user has overridden.** Uniform across every track type; no control is hidden or
disabled per track. The property route was rejected because it silently does nothing on
styled tracks — §4.4 has the mechanism, the measured cost, and the costed hybrid.

The original question — whether background and window should reach a styled track — is
answered by construction: **everything reaches every track.** The reasoning that motivated
it still holds and is worth keeping, because it is why "reach everything" is right rather
than merely convenient:

- **Background and window are legibility controls, not style controls.** Turning up a
  window is how someone makes captions readable over a bright scene. That need does not go
  away because the track's author chose a font, and a caption-art track is exactly the kind
  most likely to be hard to read.
- **They compose rather than fight.** A window sits *behind* the text and takes nothing
  away, so the author's styling still renders as authored.

Two entries cannot be honoured and are dropped rather than faked: **Raised** and
**Depressed** edge styles (ASS has no bevel — both are a drop shadow), and rounded
corners. See §4.5 and §8.

The reset control resets everything the menu owns, including the delta.

---

## 6. Implementation notes

The sidecar currently caches **rendered ASS** per video and track. Re-rendering at a new
delta would make every drag refetch and re-parse the caption document, so it should cache
**parsed cues** instead.

---

## 6a. Where each measurement runs

Two clamps, and they are not redundant — they cover different moments:

| When | Who measures | Against what |
|---|---|---|
| Hit rect, cursor, ghost, live clamp | Flutter, `TextPainter` | The cue on screen, whose text comes from mpv's `sub-text` |
| Nudging cues that appear later | Sidecar, in `ass.ts` | Flutter's calibration × character count |

Same instrument, same outward bias, applied in the two places a position is decided.

---

## 7. Not in question

- The delta model (§4.1) — it composes across every track type and keeps `styled` cosmetic.
- The clamp living in the sidecar on an upper-bound estimate (§4.2).
- Persistence rules: per video and per track, surviving off/on, resetting on track change.
- The background is always drawn; the window is always drawn at 0% opacity by default.
- A reset control exists, in the style menu.
- Styled tracks keep libass in every option. Only plain tracks are in question.

## 8. Known limits, already accepted

Not bugs, not worth approximating, and not part of this task:

- **Colour emoji render in one colour** — libass fills the glyph outline with the text
  colour. YouTube gives the emoji run its own pen, so `✨` arrives gold and renders gold;
  what is lost is the two-tone gradient, not the hue. Fixing it needs a newer libass, and
  the `media_kit_libs_windows_video` pin is load-bearing for a seek-freeze regression.
- **Vertical text** (`pdPrintDir: 2`) — libass has no writing mode.
- **Packed text** — downstream of vertical, not separate. The geometry is already
  faithful; the content is not.
- **Sub- and superscript** — no ASS tag, and YouTube's own web player does not render them
  either.
- **Rounded corners on the caption background** — both ASS boxes are rectangles.
  Knowingly dropped as part of Decision 1.
- **Raised and Depressed edge styles** — ASS has `\bord` and `\shad` and no bevel, so both
  render as a drop shadow. The style menu offers None / Drop shadow / Outline and leaves
  the other two out rather than shipping two entries with one result.

The last two are the only stated requirements of this task that will not be met. Both are
in `docs/architecture.md` §2.9 alongside vertical text and colour emoji.

---

## 9. Built — 2026-08-20

All four decisions implemented, plus the four points raised on approval. Every
claim below is re-checkable: `sidecar/scratch/probe-task19.ts` runs the whole
feature against real YouTube tracks and the bundled libass and reports each as
OK or FAIL.

### 9.1 The four points, answered

**1. Karaoke — per-segment colours excluded.** A user font colour replaces the
*line's base* colour and nothing else. A run whose colour differs from the base is
the highlight and is left exactly as authored. It generalises past karaoke without
detecting it: on a plain track every run is the base and everything changes; on a
track that colours one word for emphasis, the emphasis survives.

One thing this needed that was not obvious. An ASS override persists to the end of
its event, so a base run that emitted *nothing* would inherit the highlight's
colour — the very distinction the rule exists to keep. Base runs therefore restate
the user's colour explicitly. Measured on `L-BgxLtMxh0`: all 291 authored inline
colours survive both a drag and a colour override.

**2. The calibration is a table, not a scalar, and it cannot be missing when it
matters.**

*On the shape.* Measured through the bundled libass
(`scratch/measure-advances.ts`), advances at Arial 48 span **8.3 px to 40.5 px** —
a 4.9× range, which is the answer to "proportional fonts do not have a
monospace-ish relationship". Estimator error on real caption lines:

| Estimator | Error span |
|---|---|
| pixels-per-char from a representative sentence | **−52% … +384%** |
| pixels-per-char from the alphabet mean | −42% … +476% |
| **sum of per-character advances** | **−1% … +2%** |

A representative string does **not** beat a per-character average in general —
both fail, in opposite directions, and the reference-string calibration
under-estimates an all-capitals caption by 26% and a run of `M` by 46%.
Under-estimating is the direction that clips text off the player. So the wire
carries 74 numbers instead of one. That is the correction to §4.3's "one
calibration number".

*On it being missing.* Two answers that compose. The nudge only exists when the
delta is non-zero, so a track nobody drags never needs one. And the client learns
the font from `layout` on the **first** `captions.get` for a track — which by
definition carries no offset, because the offset resets when the track changes —
so by the time an offset exists, a table does too. What is left is an older client
or a restored offset that outlived its measurement, and `captions/style.ts`
carries a **measured** Arial-48 fallback table for those, scaled to the document's
font size, rather than failing the request.

*One measurement the brief did not anticipate.* ASS `Fontsize` is not an em size —
libass scales the face so ascent + descent equals `Fontsize`, so Arial advances at
`Fontsize: 48` are 0.895× an em-sized 48 px `TextPainter` (2048/2288 exactly).
Measuring at the nominal size would over-estimate every caption by ~11.7%: safe,
but enough to visibly stop a drag short of a corner. `caption_geometry.dart`
derives the equivalent size from the face's own vertical metrics.

**3. The 3 MB document is an outlier, not a category.** Sampled across six search
queries, 219 caption tracks: p50 **29 KB**, p90 60 KB, p99 405 KB, max 1240 KB,
**1 of 219** over 1 MB, and **1 of 219** carrying any per-segment styling.

And the cost driver is not size — it is *segments per cue*, because `renderAss`
emits a run per segment. The 3 MB document has **201** segments per cue; the two
ordinary ones have 4.2 and 1.2. The largest track in the real sample is a 1.2 MB
ASR document at 4.7 segments per cue: big, and it renders in the ordinary band.

The cue cache is the fast path and it is enough:

| Document | Segments | full `convert()` | cached (render only) |
|---|---|---|---|
| `1S7uIQmkRzk` | 417 | 3.4 ms | **1.3 ms** |
| `L-BgxLtMxh0` | 317 | 3.7 ms | **1.0 ms** |
| `8Oos6D4_Bjo` | 46 320 | 58.8 ms | **32.8 ms** |

**No further fast path is warranted.** If that ever changes, the number to watch
is segments per cue, not bytes.

**4. Suites re-run.** Counts and skips are in §9.4.

### 9.2 One thing the brief got wrong, found while building

**Turning the background on by default would have silently disabled every edge
style.** ASS makes the background a `BorderStyle`, and `BorderStyle: 3` *replaces*
the outline — `\bord` becomes the box's padding and no outline is drawn. So with
the background on (which §2 requires: YouTube draws one, and it is the drag
handle), the menu's *Character edge style* control and every edge a styled track
authored would have done nothing at all. Exactly the failure mode this brief keeps
naming, arriving through the requirement rather than through the design.

The fix is layering: **a caption is up to three events**, one per layer — a
`BorderStyle: 4` window, a `BorderStyle: 3` box with invisible glyphs, and the
text event keeping `BorderStyle: 1` and its outline. Verified by rendering, in
`scratch/probe-layers.ts`. A document that draws neither backdrop emits neither,
and no layer numbers, so the byte-identity property with Task 17 is kept — and is
still asserted, now with the background explicitly off.

### 9.3 The end-to-end run

`scratch/probe-task19.ts`, real tracks, rendered through the bundled libass:

```
plain (dQw4w9WgXcQ / .en)
  OK   a caption renders at all                             ink 102x60 at (909,966)
  OK   the layout descriptor rides along                    font Arial 48, anchor (960,1020)
  OK   a drag moves the caption on screen                   (909,966) -> (525,642), wanted (525,642)
  OK   the same request is byte-identical                   second fetch matched
  OK   a zero delta is the untouched document               byte-identical
  OK   dragged into the corner, nothing leaves the frame    right 1853, bottom 1079
  OK   a longer cue is pushed further in than a shorter one 21 distinct x across 122 cues
  OK   style change: font colour                            6120 px of ink
  OK   style change: background off                         2243 px of ink
  OK   style change: window on                              6002 px of ink

styled (L-BgxLtMxh0 / .en)
  OK   a caption renders at all                             ink 198x39 at (862,977)
  OK   the layout descriptor rides along                    font Arial 48, anchor (960,1020)
  OK   a drag moves the caption on screen                   (862,977) -> (479,653), wanted (478,653)
  OK   the same request is byte-identical                   second fetch matched
  OK   a zero delta is the untouched document               byte-identical
  OK   dragged into the corner, nothing leaves the frame    right 1899, bottom 1073
  OK   a longer cue is pushed further in than a shorter one 49 distinct x across 292 cues
  OK   style change: font colour                            5760 px of ink
  OK   style change: background off                         5561 px of ink
  OK   style change: window on                              11407 px of ink
  OK   dragging a styled track keeps every authored colour  291 inline colours before, 291 after
```

The drag landed on the predicted pixel on the plain track and within 1 px on the
styled one, which is the width estimate and the clamp agreeing across the two
sides that compute them.

**Two rules are the client's and are held in Flutter instead**, because they are
`CaptionsState`'s and never reach the sidecar: the offset **resets when the track
changes** and **survives captions being toggled off and on**
(`app/test/caption_style_test.dart`), and the gesture itself — grab cursor, ghost
during the drag, real caption untouched until release, clamped at the frame edge
(`app/test/caption_drag_test.dart`).

### 9.4 Suites

| | pass | skip | fail |
|---|---|---|---|
| `bun run check` (typecheck + lint + tests) | **283** | 31 | 0 |
| `flutter analyze` | clean | — | — |
| `flutter test` | **330** | 0 | 0 |

Up from 269 and 305 respectively. The 31 sidecar skips are the pre-existing
network-gated suites (`test:network`), unchanged by this task.

---

## 10. Post-build: LibassLayer FFI migration and the `positional` flag

*Written 2026-08-23. The sections above describe what §9 delivered into the
`sub-add → mpv → libass` pipeline. This section records two decisions made
after that work landed and not covered by the original brief.*

### 10.1 Decision D — replace the mpv subtitle pipeline with a direct libass FFI layer

**Why.** The `sub-add` pipeline composites captions into the video texture, giving
Flutter no separate surface, no per-group geometry, and no way to intercept
individual images. A Flutter-drawn background and window (which §2 requires, and
§9.2 solved by emitting a separate box event) must then be approximated by
hit-testing against an estimated bounding box. A direct libass binding returns one
`ASS_Image` per glyph/shadow/outline and their exact pixel positions — giving exact
group geometry, exact hit targets, and letting Flutter own the background and window
as plain widgets whose colour comes directly from `CaptionStyle`.

**What was rejected first.** The `dart_libass` pub package (libass 0.14):
- `BorderStyle: 4` geometry differs from 0.17 — the window box is wrong.
- Reliable segfault on two simultaneous events carrying `BorderStyle: 3` and 4 —
  the exact layering §9.2 requires.

**What was built.** `libass_spike/` is a standalone Flutter project that spiked
the approach against libass 0.17 (the MSYS2 MinGW build). It resolved every
problem the `dart_libass` package had and produced a working render loop. The spike
is the reference implementation for the production `LibassLayer`; it should not be
deleted until the port is complete.

The production layer is `app/lib/ui/player/libass_layer.dart`, ported from the
spike and staged in the current commit. Key engineering decisions carried over from
the spike and documented in `libass_spike/README.md`:

- **The crop fix.** libass clips rasterised output against the video rectangle
  (`PlayResX/Y`), not the frame, so a glyph near the edge is silently cropped —
  overflow simply disappears. The fix pads `PlayResX/Y` by `kPadX=960` and
  `kPadY=540` in every direction (moving all coordinates and margins into the new
  space), then subtracts the pad from each image's `dst_x`/`dst_y` after render.
  The output can go negative (caption dragged off the left edge is partially
  visible) without being cropped. `probe_pad_equiv.dart` asserts byte-identity on
  15 event types and strict widening on overflow cases.

- **Grouping.** `ASS_Image` carries no event id. libass appends each event's images
  as one contiguous block in `shadow → outline → character` order, so `type` is
  non-increasing within an event and a new event begins exactly where `type` goes
  back up. Spatial tie-breakers were measured and removed — the smallest gap
  *between* two events is 0 px (YouTube composites a shadow event exactly on top of
  its text event), so no threshold separates groups. `probe_groups.dart` asserts
  exact group boxes against ground-truth single-event renders.

- **Repositioning.** The authored script is edited; the padded copy is derived
  fresh each render so nothing accumulates across drags. Three cases: `\\move` →
  shift its first four args; `\\pos` → shift it plus `\\org` and `\\clip`; neither →
  convert to `\\an<N>\\pos(x,y)` anchored exactly where libass had it, then shift.

- **Clamping.** Per caption group, per axis. A group wider than the video is left
  alone (translation cannot rescue it). The clamp is folded into the next commit so
  a dragged caption does not jump when the user grabs again.

- **Isolate rendering.** `ass_render_frame` runs in a `dart:isolate`, returning
  `TransferableTypedData` per image. The main isolate decodes pixels to `ui.Image`
  and disposes the previous frame via `addPostFrameCallback`. Teardown chains
  `whenComplete` on the render future to free the C objects after any in-flight
  render completes.

**Both pipelines coexist.** A debug toggle in the settings menu switches between
`sub-add → mpv → libass` (old) and `LibassLayer` (new). The intent is for
`LibassLayer` to become the default; the old pipeline may be kept as a power-user
fallback if `LibassLayer` proves too slow on some hardware, or removed once it is
feature-complete.

**Current state of `LibassLayer` (2026-08-23):**

| Feature | Status |
|---|---|
| FFI binding, isolate rendering, `TransferableTypedData` | ✅ Shipped |
| Coordinate system — crop fix, all six tag cases | ✅ Shipped |
| Grouping — type-sequence heuristic | ✅ Shipped |
| Drag — `_onPanUpdate` / `_commitDrag` / `repositionScript` | ✅ Shipped |
| Per-group clamping / nudging with animation | ✅ Shipped |
| `positional` drag-lock (§10.2) | ✅ Unstaged, ready to stage |
| Background — Flutter `CustomPaint`, color from `CaptionStyle` | ⚠️ Hardcoded black — needs wiring |
| Window — Flutter `CustomPaint`, color/opacity from `CaptionStyle` | ⚠️ Hardcoded off — needs wiring |
| ASS box events suppressed when LibassLayer is active | ⚠️ `BorderStyle: 3→1` replaces the Style entry but not the separate invisible-glyph box events Task 18 emits — these are still rendered by libass and produce the double-draw visible in the screenshot |

**The double-draw.** `_BackgroundPainter` draws a black rounded rectangle behind
each caption line (Flutter-owned, always on). The ASS document still contains the
separate `BorderStyle: 3` invisible-glyph box events Task 18 emits; libass renders
those too, compositing a second background on top of Flutter's. When the style menu
sets the background to a non-black colour, the libass-rendered layer shows as a
coloured rectangle over the Flutter-drawn black one. The fix: suppress the box
events from the ASS document when `LibassLayer` is the active renderer (they are
redundant — Flutter owns the background), and wire `_BackgroundPainter`'s colour to
`CaptionStyle.background`. Same logic for the window layer.

### 10.2 Decision — drag-lock via `positional`, not `styled` (§2.10)

A global offset applied to a track that places captions at multiple authored screen
positions (e.g., a caption-art track with words pinned to different corners) would
destroy its layout. The original heuristic used the `styled` classification
(`styled` or `karaoke` → locked). That was wrong: ASR tracks theoretically carry
custom `wpWinPositions`, which would lock them.

The correct predicate is measured per-document: a track is **locked** when it has
more than one distinct authored anchor (non-default `wpWinPositions` entries or
overlapping events). This is the `positional` boolean returned alongside `styled`
by `classifyDocument` in `sidecar/src/captions/service.ts` (unstaged). Measured
across 143 tracks: 100% of ASR tracks have `positional: false`; authored art tracks
have `positional: true`. `architecture.md` §2.10 has the full table and the
implementation notes.

`LibassLayer` enforces it at `isDraggable = track == null || track.positional != true`.
A `null` (not-yet-classified) track defaults to draggable — the classification
arrives with the first `captions.get`, which is one round trip after the track is
selected, and an incorrect allow-drag is recoverable (the document re-applies at
the new position).

## 11. Post-build round 2: the style menu's force flags, and what only manual use has covered

*Written 2026-08-26.* §10 shipped `LibassLayer` and the drag. This section is the
force-style/style-menu correctness pass that followed, done entirely through a
human running the real app and reporting back — the agent building it has no
way to see the live window. Every item below was found that way, not by a
suite failing.

**Bugs found and fixed:**

- **The Force Style master switch was derived, not stored**, computed from
  whether every individual tile agreed — so toggling one tile off silently
  toggled the master off too, and there was no way to have "master on, one
  tile off." Made an independent `forceStyleEnabled` field.
- **Colour and opacity shared one nullable field**, so resetting the opacity
  slider back to "Default" also forgot a colour the user had picked, and vice
  versa. Split into independent `textColor`/`textOpacity`,
  `background`/`backgroundOpacity`, `window`/`windowOpacity` pairs, each
  resolved independently client- and sidecar-side.
- **`captionStyleParam` never parsed any `forceXxx` field off the request** —
  a genuine, previously-undiscovered wire-protocol bug, not something this
  round introduced. Every force toggle in the menu was a no-op from the
  server's point of view.
- **Force text colour ignored the force flag on any run that differed from
  the cue's base colour** — a "protect karaoke highlights" heuristic that
  fired unconditionally, so a track with more than one inline colour (karaoke
  or just several speakers marked by colour) could never be overridden by
  force at all. Now: unforced defers to authored, including highlights;
  forced overrides everything, the same rule every other property already
  follows.
- **Force font size hard-replaced the authored size** rather than scaling it,
  discarding whatever relative emphasis a track authored (a cue sized up for
  emphasis would flatten to one size under force). Changed to multiply: 100%
  is a no-op, 200% doubles both an authored baseline and whatever bigger or
  smaller text a cue carries.
- **A caption visually overlapped the settings/quality panel** — an earlier
  fix made it click-through while a menu was open, which was confirmed
  insufficient: the panel was still hidden underneath the text. `LibassLayer`
  now reserves space against the panel's own rendered geometry
  (`settingsMenuPanelKey`), the same mechanism already used to keep captions
  clear of the bottom control bar.
- **A positional (non-draggable) caption still absorbed clicks** meant for
  the video underneath — its `GestureDetector` used
  `HitTestBehavior.opaque` regardless of whether `onPanUpdate`/`onPanEnd`
  were actually wired up. Wrapped in `IgnorePointer` when not draggable.

**What only manual testing has covered, and has no suite behind it.** The next
person touching `LibassLayer` or the settings menu should know these are
unverified by anything that runs in CI:

- **The Force Style tile grid's enabled/disabled visual state** — dimmed
  labels and icons, `IgnorePointer` on individual tiles when the master is
  off, and the master switch's own on/off rendering. Nothing asserts the
  *rendered* disabled appearance, only that the underlying booleans are set
  correctly.
- **The settings-panel clearance** (§this section, above) — that a caption
  actually stops short of the panel's real edge rather than merely computing
  a number that happens to be right. `probe-task19.ts` and the sidecar suite
  can assert ASS/geometry math; neither drives an actual `PlayerSettingsMenu`
  open against a `LibassLayer` to check the two don't overlap on screen.
- **Click-through correctness** — that a click over an open menu, or over a
  positional caption, actually reaches what's underneath rather than being
  swallowed. `IgnorePointer` placement is asserted nowhere; it was verified by
  a human clicking the app.
- **Caption position relative to the control bar and the settings panel, at
  the moment either opens or closes** — the debounced reserve/release timing
  (`_onControlsVisibilityChanged`, `_onSettingsMenuChanged`) has no test
  checking a caption actually slides clear in time, or doesn't jump early.

None of this needs fixing now — recorded so it isn't mistaken for coverage
that exists.

## 12. Known limitation, not built: a styled track's authored background colour

*Written 2026-08-26.* Reported during round 2: a styled track's own background
colour (from `pens`/`boBackAlpha`, parsed onto `CueStyle.backgroundColor`) is
never painted. Investigated and recorded as a deliberate limitation rather than
built — see `docs/architecture.md` §2.9, "Known limits of the libass route",
for the full argument (the wire protocol carries no per-cue channel today, the
ASS-native alternative is the one phase 5 explicitly removed, and the corpus
measurement is 0 of 23 ordinary tracks styled at all — this surfaces only in
caption-art demo content). Not revisited unless that frequency changes.

## 13. Post-build round 3: three real bugs found through live use, one left open

*Written 2026-08-27.* All three were reported against the round-2 build, none
caught by any suite — the pattern §11 already flagged as this feature's gap.
Every fix below was verified working live before being recorded here; the
fourth item was investigated and explicitly not resolved.

### 13.1 Style changes going stale — `CaptionsState.documentVersion`

Every style change (slider, colour, edge style) applied correctly server-side
but the caption on screen lagged one change behind — set A, nothing happens;
set B, the caption shows A; set C, it shows B. The value sent was always
right, confirmed by adding prints at the point of send.

**Root cause: a value-equal state write does not notify.** `_fetch`'s last
line was `state.copyWith(tracks: newTracks, isLoadingTrack: false)`. On a
track whose classification doesn't change on a plain style edit — the
ordinary case — `newTracks` is null and `isLoadingTrack` was already false, so
that write reconstructs a `CaptionsState` equal to the one already there.
Riverpod does not notify `ref.watch`ers on `state = value` when `value ==`
the previous state, and `LibassLayer` only ever looks at `engine.subtitle`
inside a `build()` that watching this provider triggers — so the document
`engine.setSubtitle` had just received was never looked at again, until some
*later*, unrelated field change (the next style edit's own `style` write, in
practice) dragged a rebuild along and the layer finally caught up to the
*previous* change.

**Fix:** a `documentVersion` counter on `CaptionsState`, bumped on every
successful fetch and included in equality, so that specific write can never
again be a no-op. Verified by mutation: a test counting live notifications
(`container.listen`) across one `setStyle` call fails at 1 notification
without the counter and passes at 2 with it — the style-field write and the
document-landed write are supposed to be two separate notifications, and only
one was firing.

### 13.2 A build-time race in the "Keep caption style" toggle

Found while fixing a stale test for §13.1's investigation, not reported by the
user — a genuine second bug the first one's test surfaced.
`KeepCaptionStyleNotifier.build()` starts a fire-and-forget prefs read; an
explicit `toggle()` call made before that read resolves gets silently
overwritten the moment it does. Narrow in production (the read is normally
fast), real nonetheless. Fixed with a `_touched` flag set at the top of
`toggle()`, checked by the pending load before it writes.

The test itself needed updating separately: it asserted style survives a
video change unconditionally, which stopped being true once "Keep caption
style" became an opt-in toggle (default off) rather than the original
always-on behaviour — a stale expectation, not a regression.

### 13.3 A drag-commit overshoot in fullscreen, paused

Reported: releasing a drag in fullscreen instantly placed the caption at the
right spot, then visibly slid in from the drag's own direction by roughly the
drag's own distance before settling — proportional to, in fact equal to, how
far it was dragged.

**Root cause: the box jumps instantly; the nudge on top of it didn't.**
`_CaptionGroup`'s `Positioned` is `groupBox` (switches value on every
rebuild, no animation of its own) plus `off` from a `TweenAnimationBuilder`
(always animates toward a new target over 180 ms). The commit render's
`groupBox` is already the fully-shifted document (`_commitDrag`'s
`repositionScript` bakes the shift in), and that same render's nudge
correctly resolves to ~zero — but the tween had been sitting at the *live
drag's full offset* right up to release, and it does not know the box just
made the same trip a different way. For one frame: box at the final
position, nudge still animating down from the full drag offset — the sum
overshoots past the target by exactly that offset, then eases back.

Windowed/theater never showed it, for a reason that turned out to matter:
there, the server's independently-regenerated document differs enough
(different length, byte-for-byte) from the client's local reposition that
`_groupBoxes` gets cleared for a frame while it's replaced — which tears down
and remounts `_CaptionGroup`, so its `TweenAnimationBuilder` starts fresh at
the target with nothing to animate from. Fullscreen's server response
happened to match byte-for-byte, so no rebuild was forced, the same widget
persisted, and its tween was caught mid-flight.

**Fix:** the render immediately after a commit snaps its nudge with a
zero-duration tween instead of the usual 180 ms; every other nudge change
(control bar, settings panel) still animates as before. Confirmed fixed,
paused, in fullscreen.

### 13.4 A stale in-flight render during playback — partially fixed, left open

Reported after 13.3 was confirmed: paused, fullscreen was flawless, but
*playing*, in both fullscreen and windowed, a commit made the caption jump
back to its pre-drag position for one frame before landing on the new one.

**Root cause, confirmed and fixed in part: `_renderLoop`'s per-iteration
state is captured before its one FFI `await`.** During playback, position
ticks keep the loop continuously busy, so a commit lands *while an iteration
is already in flight* far more often than while paused (where the loop is
idle and a commit starts a fresh one with current data). That in-flight
iteration already captured the pre-commit document and timestamp; finishing
and painting them races the commit's own, correct render. A `_renderRequestId`
counter, bumped whenever the target document changes and checked by each
iteration after its await, lets a stale result be discarded instead of
painted — the next iteration, already queued, picks up the current target.

**Verified measurably better, not eliminated.** The user confirmed the flash
still happens, "less" than before. Re-traced the fix's own logic afterward —
capture timing, what a discarded iteration still mutates before being
discarded, whether the snap flag from §13.3 could be consumed on the wrong
build — without finding a further gap; Dart's single-threaded execution
means the bump should be visible to every in-flight iteration's post-await
check. **Left open at the user's call** rather than guessed at further
without a fresh log capture. Debug prints in `libass_layer.dart` now carry
millisecond timestamps (`_ts()`) for exactly this class of problem — ordering
two racing async chains — should this get picked up again.

## 14. Open items

*Written 2026-08-27.* Everything outstanding across this task, in one place —
these had been scattered across four separate status reports to the point of
getting lost. Each line is the whole of what's known; follow the pointer for
the reasoning behind it.

- **Stale in-flight render during playback.** Guard added (§13.4) reduced but
  did not eliminate an old-position flash on drag-commit while playing.
  `_ts()`-timestamped prints are in place in `libass_layer.dart` for the next
  attempt, which needs a fresh log capture, not more reasoning from a static
  read of the code already re-checked once.
- **Windowed/theater one-frame flicker on drag-commit.** The caption briefly
  renders nothing at all (not the old position — genuinely absent) while the
  server's independently-regenerated document replaces the client's local one
  (§13.3's third paragraph has the mechanism). Explicitly accepted by the
  user rather than fixed.
- **`probe-task19.ts` cannot guard the window-vs-video coordinate class of
  regression.** It exercises `ass.ts`'s document output through mpv, never
  `LibassLayer`'s Flutter-side coordinate math — and `flutter test` can't
  either, structurally: `LibassLayer.build()` returns `SizedBox.shrink()`
  immediately whenever libass isn't loadable, which is always true in the
  test sandbox, so the geometry code never runs at all under test. Closing
  this needs moving the geometry bookkeeping ahead of the `_assUnavailable`
  short-circuit — a real, scoped change, not attempted since it wasn't
  confirmed worth the risk to a heavily-tuned file.
- **A fullscreen document-oscillation on mount, unexplained.** Early logging
  during the round-3 investigation (before the real bugs in §13.3/§13.4 were
  found) showed `LibassLayer`'s render loop alternating between two different
  document lengths immediately after entering fullscreen, before any drag.
  Superseded by the drag-commit investigation and never independently
  chased down — may or may not be the same class of race as §13.4's.
- **`PlaybackEngine.subtitleTextStream` is dead code.** Flagged by the
  orchestrator, not yet investigated. Maps mpv's own `sub-text` stream —
  a vestige of the pre-phase-5 pipeline (§10.1) — and nothing currently
  subscribes to it.
- **No karaoke-classified track has been rendered end to end.** Also flagged
  by the orchestrator. The karaoke merge logic (§ "Task 18" section above,
  edge/segment handling) has unit coverage; nothing has run a real
  karaoke-classified document through the full pipeline and looked at the
  frame it produces.
- **A styled track's authored background colour is not painted.** Deliberate,
  not missing — full argument in §12 and `docs/architecture.md` §2.9. Revisit
  only if styled tracks stop being ~0% of ordinary content.
- **Behaviours covered only by having looked at them, with no suite behind
  them:** the Force Style tile grid's enabled/disabled rendering, the
  settings-panel clearance actually keeping a caption clear on screen (not
  just computing a number), click-through correctness over an open menu or a
  positional caption, and caption position relative to the control bar at the
  moment either opens or closes. Full list and reasoning in §11.
