# Task 18 — Caption styling (YTT)

**Prerequisite:** `CLAUDE.md`, the Task 17 report, `docs/architecture.md` §2.9,
`docs/protocol.md` §3.8.

Task 17 built the caption pipeline and deliberately left styling unbuilt. This
finishes it. Captions currently render unstyled, and — as the duplication
investigation established — visibly wrong on styled tracks.

**Small by design.** Task 17 asserted the work is one function inside
`json3.ts`, at the line reading `style: null`. §3 below is the part most likely
to prove that wrong; if it does, say so early.

Use `YT_DUMP_ASS` throughout. Caption output cannot be asserted visually, and
reading the generated ASS is the only way to see what libass is actually handed.

---

## 1. What already exists

From Task 17, measured:

- **There is no separate YTT document.** `fmt=ytt` returns 404. The styling model
  is the `pens`, `wsWinStyles` and `wpWinPositions` arrays already at the head of
  every `json3` document — empty for a plain track, populated for a styled one.
- **The cue model carries every field**, optional and unset: alignment,
  `positionX`, `positionY`, `textColor`, `backgroundColor`, `edgeColor`,
  `edgeStyle`, font, size, bold/italic/underline.
- **The ASS renderer already emits** `\an`, `\pos`, `\fn`, `\fs`, `\c`, `\3c`,
  `\4c`, `\bord`, `\shad`, `\b`, `\i`, `\u`, each with a test.
- **Per-word `offsetMs` survives** parsing, grouping and merging, rebased on
  merge and tested.

## 2. Resolving the style

Read the three arrays from the document head, and resolve each event's
`pPenId`, `wsWinStyleId` and `wpWinPosId` into a `CueStyle`.

Known field names from the Task 17 sample — **verify against real payloads
rather than trusting this list**:

| Source | Fields seen |
|---|---|
| `wpWinPositions` | `apPoint`, `ahHorPos`, `avVerPos`, `rcRows`, `ccCols` |
| `wsWinStyles` | `mhModeHint`, `juJustifCode`, `sdScrollDir` |
| `pens` | `etEdgeType` seen; enumerate colour, size and font fields as you find them |

### Three mappings that will not be obvious

**Anchor points.** `apPoint` and ASS's `\an` are both 3×3 grids and are
**numbered differently**. Do not assume a mapping — determine it empirically,
render a frame, and check the caption lands where the source asked. Getting this
silently wrong puts captions in the wrong corner with no error anywhere.

**Coordinates.** `ahHorPos` and `avVerPos` are percentages; ASS `\pos` is pixels
against `PlayResX`/`PlayResY`. Establish what the renderer currently declares. If
it declares neither, that is a decision to make now.

**Colours.** ASS wants `&HAABBGGRR` — byte-reversed, alpha inverted. The renderer
already owns this per §2.9. Feed it the model's colour fields; do not
reimplement the conversion.

## 3. The duplication case — resolve this first

This is what produced the visible symptom, and it is the sub-problem most likely
to make the task bigger than one function.

The investigation found that YouTube **emits the same text twice, at the same
time, with different `pPenId`s** — one mapping to `etEdgeType: 4` (drop shadow),
one to `etEdgeType: 3` (outline). With `style: null` both collapse to the same
unpositioned default, and libass separates them vertically. Hence two identical
lines on screen.

**The fix proposed alongside that finding does not address it.** A test asserting
that two cues with *different `positionX`* emit distinct `\pos` covers a
different scenario — these two cues are at the *same* position with *different
edge effects*. Keep that test; it is not the one that matters here.

Three candidate behaviours, and the right one is a measurement, not a preference:

1. **Merge.** ASS expresses outline and shadow on one line — `\bord` and `\shad`
   together. If YouTube is compositing two renders of one caption, one merged
   line is the faithful output and avoids double-drawing the same glyphs.
2. **Emit both, positioned.** If `\pos` is present, libass is believed to skip
   collision avoidance, so both would land exactly on top of each other and
   composite as the source intends. **Verify that belief** — it is the
   load-bearing assumption and it is unmeasured.
3. **Pick one.** Only if the pens genuinely conflict in a way ASS cannot express
   on a single line — different fill colours, say.

**Settle it by looking at what youtube.com renders.** Open `L-BgxLtMxh0` on the
site with captions on and describe the "Bold text." cue: does it carry both a
shadow and an outline, or only one? That answers which behaviour is faithful.

Then handle the general case: two events with identical text and timing merge
where ASS allows it, and fall back to (2) where it does not. Say what rule you
landed on.

## 4. The ASR consequence — a product decision

Task 17 measured the ASR tracks carrying a real window: `apPoint: 6`,
`ahHorPos: 20`, `avVerPos: 100`, `rcRows: 2`, `ccCols: 40` — a two-row rolling
window at 20%/100%.

**Honouring that will move auto-generated captions.** That is probably right,
since fidelity to the site is the product's premise — but it changes the common
case, not a styled-track edge case.

Do it, and **show a before/after** of an ASR track's on-screen position. If it
lands somewhere that reads badly, say so rather than shipping it.

## 5. Karaoke and fonts

**`\k` is out of scope** unless it falls out for free. Per-word timing is already
carried, so the decision is only whether to emit. Say what it would take; do not
build it.

**Fonts:** YouTube specifies families that may not exist locally and libass will
substitute silently. Establish what the bundled libass does when a font is
missing and report it — a caption in the wrong face is fine, a surprise is not.

---

## Tests

- `pens`, `wsWinStyles` and `wpWinPositions` parse from a real styled document
- **The duplication case**: a document with two events sharing text and timing
  but differing in pen produces whatever §3 decided, asserted explicitly — not
  "two cues exist"
- A track with **empty** style arrays produces `style: null` and ASS
  **byte-identical to today's output**
- Each mapping produces the expected override: anchor, position, colour, edge,
  font, size, bold/italic/underline
- An unknown or out-of-range id degrades to the default rather than throwing
  (hard invariant 4's reasoning)
- An ASR track's window resolves to the position the document declares

**Mutation-check the anchor mapping, the duplication rule and the empty-arrays
case.** The first is where a silent off-by-one lives, the second is the visible
bug, the third protects every existing video from a styling regression.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- `L-BgxLtMxh0` and `1S7uIQmkRzk` render styled, **without duplicated lines**
- A plain track renders exactly as today — byte-identical ASS on an unstyled
  document
- An ASR track sits where its window declares

**Run the app and say what you saw** — both styled videos, an ASR track before
and after, and a plain manual track confirming nothing moved. Describe the
rendered frames, and attach the `YT_DUMP_ASS` output for the styled cases.

## Out of scope

Karaoke (`\k`). Translations (`&tlang=`). User-adjustable caption styling.
Caption search or transcripts.

## Stop conditions

- **The anchor or coordinate mapping cannot be determined empirically** — report
  what you tried rather than shipping a guess.
- **`\pos` does not suppress libass collision avoidance** and behaviour (2) is
  therefore unavailable — report it; it changes which §3 option is reachable.
- **Honouring the ASR window makes auto-generated captions worse.** Report the
  before/after and stop; that is a product decision.
- **The work is not one function in `json3.ts`.** Task 17 asserted it was. If the
  cue model or the renderer needs changing too, say what and why before doing it.
