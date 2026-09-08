/**
 * `json3` → cues.
 *
 * Chosen over `srv3`, `ttml` and `vtt` after fetching all of them against real
 * tracks (2026-08-18; the measurements are in the task report). `json3` and
 * `srv3` carry identical data — `srv3` is the same document as XML — and `json3`
 * is the one that needs no XML parser. `vtt` arrives pre-grouped but with
 * YouTube's karaoke markup inlined as `<00:00:19.039><c> no</c>`, which would
 * have to be stripped and re-derived; `ttml` is the same content again, longer.
 *
 * **`fmt=ytt` answers HTTP 404.** YTT is not a fourth format to fetch: its
 * styling model *is* the `pens` / `wsWinStyles` / `wpWinPositions` arrays at the
 * top of this document, empty for a plain track and populated for a styled one.
 * So the styling parser lives here, resolving the per-event `pPenId` /
 * `wsWinStyleId` / `wpWinPosId` references into a `CueStyle`.
 *
 * ## The style vocabulary, and where each mapping was measured
 *
 * Everything below was read off `L-BgxLtMxh0` on 2026-08-19 — a caption-styling
 * demo whose cues *label their own styling*, which makes it ground truth rather
 * than a guess. The fields it does not exercise are marked as unmeasured.
 *
 * | YTT | Meaning | How it was established |
 * |---|---|---|
 * | `fcForeColor` | `0xRRGGBB` | the cue reading "Red font." carries `0xFF0000` |
 * | `foForeAlpha` | 0–255, 0 = invisible | a fade is transmitted as a run of pens stepping 42→85→127→170→212 |
 * | `szPenSize` | damped scale, see [fontSizePercentFrom] | "48px font size" is 300, "72px font size" is 600 |
 * | `apPoint` | 3×3 grid, **row-major from 0**, see [ANCHOR_TO_ASS] | 6 pairs with `ahHorPos: 0` + left justify at the bottom; 7 with `ahHorPos: 50` |
 * | `fsFontStyle` | CEA-708 font tag | the cue reading "Times New Roman." carries 2 |
 * | `ofOffset` | 0 sub, 1 normal, 2 super | the cues read "Subscript text." and "Superscript text." |
 * | `etEdgeType` | CEA-708 pen edge | 3 and 4 are the outline/shadow pair of every duplicate group |
 * | `juJustifCode` | 0 left, 1 right, 2 centre | 0 appears only on the one left-anchored window |
 * | `pdPrintDir` | 2 is vertical | the cue reading "Vertical text. This gets interesting." |
 *
 * **Three of those cannot be expressed in ASS and are dropped on purpose:**
 * `ofOffset` (no sub/superscript tag), `pdPrintDir: 2` (no vertical writing
 * mode) and `hgHorizGroup`. Each is counted and logged once per document rather
 * than silently ignored, so a track that leans on them can be recognised.
 *
 * ## The shape, for the two kinds of track
 *
 * A **manual** track is already cue-level. Every event is one line:
 *
 * ```json
 * { "tStartMs": 22640, "dDurationMs": 4320,
 *   "segs": [{ "utf8": "♪ You know the rules\nand so do I ♪" }] }
 * ```
 *
 * An **ASR** track is a two-row window that text scrolls through, and it uses
 * three kinds of event that all have to be told apart:
 *
 * ```json
 * { "tStartMs": 0, "dDurationMs": 211879, "id": 1,
 *   "wpWinPosId": 1, "wsWinStyleId": 1 }                     // window definition
 * { "tStartMs": 21790, "dDurationMs": 4170, "wWinId": 1,
 *   "aAppend": 1, "segs": [{ "utf8": "\n" }] }               // roll marker
 * { "tStartMs": 21800, "dDurationMs": 7319, "wWinId": 1,
 *   "segs": [{ "utf8": "love." },
 *            { "utf8": " You", "tOffsetMs": 1000 }, …] }     // the line
 * ```
 *
 * Only the third is a cue. The first two are structure, and emitting them is how
 * a caption track acquires blank flickering lines. The declared 7319 ms overlaps
 * the next event by design — see `groupAsrCues`, which is where that is resolved.
 *
 * **An ASR line does not name its own window.** Note that the third event above
 * carries `wWinId: 1` and no `wpWinPosId` — the position lives on the *window
 * definition*, matched by its `id`. A parser that only reads `wpWinPosId` finds
 * nothing on any ASR line and positions the whole track at the default, which
 * looks exactly like a track that declares no position. [windowsById] is the
 * hop that avoids it.
 *
 * **A `pPenId` can also sit on a `seg`, and this parser does not read those.**
 * That is how YouTube styles karaoke — one pen for the sung run, another for the
 * rest — and it is why `L-BgxLtMxh0`'s "Basic karaoke timing." cues arrive as
 * three events with no event-level pen at all. They resolve identically here and
 * collapse to one plain line, which is right as far as it goes. Reading them
 * would mean a style per `CueSegment` and an override run per segment in the
 * Dialogue text; that is the same change `\k` needs, and `docs/tasks/18` scopes
 * karaoke out. Recorded rather than done.
 */

import { logger } from '../log.ts';
import {
  DEFAULT_FONT_SIZE_PERCENT,
  type Cue,
  type CueAlignment,
  type CueEdgeStyle,
  type CueSegment,
  type CueStyle,
  type RgbaColor,
} from './cues.ts';
import { asArray, get, isObject, num, type Json, type JsonObject } from '../parser/tree.ts';

const log = logger('captions');

// ---------------------------------------------------------------------------
// The style vocabulary
// ---------------------------------------------------------------------------

/**
 * `apPoint` → ASS `\an`. **Both are 3×3 grids and they are numbered
 * differently**, which is the kind of mistake that puts every caption in the
 * wrong corner and reports nothing.
 *
 * YTT counts row-major from the top-left; ASS counts like a numeric keypad, from
 * the bottom-left. Measured rather than assumed: the one window in
 * `L-BgxLtMxh0` with `apPoint: 6` sits at `ahHorPos: 0` and is the only one
 * using the left-justified window style, and `apPoint: 7` is the default
 * bottom-centre window at `ahHorPos: 50`. Two adjacent points in the bottom row
 * fix the whole grid.
 *
 * ```
 *   YTT          ASS
 *   0 1 2        7 8 9
 *   3 4 5   ->   4 5 6
 *   6 7 8        1 2 3
 * ```
 */
const ANCHOR_TO_ASS: readonly CueAlignment[] = [7, 8, 9, 4, 5, 6, 1, 2, 3];

/**
 * `etEdgeType` — CEA-708's pen edge enum, which is where YTT gets it from.
 *
 * 3 and 4 are the measured pair: every duplicate group in `L-BgxLtMxh0` is an
 * `etEdgeType: 4` layer with invisible glyphs over an `etEdgeType: 3` layer with
 * visible ones, which is a drop shadow composited under an outline. 1, 2 and 5
 * follow CEA-708 and are unmeasured — no sample carries them.
 */
const EDGE_TYPES: Readonly<Record<number, CueEdgeStyle>> = {
  0: 'none',
  1: 'raised',
  2: 'depressed',
  3: 'outline',
  4: 'dropShadow',
  5: 'dropShadow', // right drop shadow; ASS has no shadow direction
};

/**
 * `fsFontStyle` — CEA-708's font tags, as YouTube's caption settings name them.
 *
 * Only 2 is measured (the cue reading "Times New Roman."). The rest are the
 * standard tag set with YouTube's own font choices. libass substitutes silently
 * when a family is missing — measured against the bundled libmpv, an unknown
 * name falls back to the default sans face with no warning and no tofu — so a
 * wrong guess here costs the wrong typeface, never an unreadable caption.
 */
const FONT_FAMILIES: Readonly<Record<number, string>> = {
  1: 'Courier New', // monospaced serif
  2: 'Times New Roman', // proportional serif
  3: 'Lucida Console', // monospaced sans-serif
  4: 'Roboto', // proportional sans-serif
  5: 'Comic Sans MS', // casual
  6: 'Monotype Corsiva', // cursive
  7: 'Arial', // small capitals — ASS has no small-caps tag
};

/**
 * `szPenSize` → a percentage of the default caption size.
 *
 * **The relationship is not the identity, and reading it as one makes a 600
 * six times too big.** YouTube damps it: the demo's cue labelled "48px font
 * size" carries `szPenSize: 300` and the one labelled "72px font size" carries
 * `600`, which fixes a line through both points at a quarter of the nominal
 * percentage — `1 + (sz - 100) / 400`. At `sz: 100` that is exactly 1, which is
 * the property that makes it credible: an unstyled pen is the default size.
 *
 * It also explains a remark the demo makes on screen, that the size "must be
 * more than double the style's size to take affect" — at a quarter weight, 200
 * is a 25% change.
 */
export function fontSizePercentFrom(penSize: number): number {
  return DEFAULT_FONT_SIZE_PERCENT * (1 + (penSize - DEFAULT_FONT_SIZE_PERCENT) / 400);
}

/** `0xRRGGBB` — measured: the cue reading "Red font." carries `0xFF0000`. */
function rgbFrom(value: number, alpha: number): RgbaColor {
  return {
    r: (value >> 16) & 0xff,
    g: (value >> 8) & 0xff,
    b: value & 0xff,
    a: alpha,
  };
}

/** 0–255 → straight alpha. Absent means opaque, which is what an unstyled pen is. */
function alphaFrom(value: number | null): number {
  if (value === null) return 1;
  return Math.max(0, Math.min(255, value)) / 255;
}


// ---------------------------------------------------------------------------
// Resolving an event's style
// ---------------------------------------------------------------------------

/** The three arrays at the head of the document, plus a place to count what we drop. */
interface StyleTables {
  pens: JsonObject[];
  winStyles: JsonObject[];
  winPositions: JsonObject[];
  /** YTT features ASS has no tag for. Counted so a track leaning on them is visible in the log. */
  unsupported: Map<string, number>;
}

function table(doc: Json, key: string): JsonObject[] {
  return asArray(get(doc, key)).map((entry) => (isObject(entry) ? entry : {}));
}

function readStyleTables(doc: Json): StyleTables {
  return {
    pens: table(doc, 'pens'),
    winStyles: table(doc, 'wsWinStyles'),
    winPositions: table(doc, 'wpWinPositions'),
    unsupported: new Map(),
  };
}

/**
 * An out-of-range id resolves to nothing rather than throwing (hard invariant 4).
 * A caption that loses its colour is worth more than a track that fails to load.
 */
function entry(rows: JsonObject[], id: number | null): JsonObject {
  if (id === null || !Number.isInteger(id) || id < 0 || id >= rows.length) return {};
  return rows[id] ?? {};
}

function note(tables: StyleTables, feature: string): void {
  tables.unsupported.set(feature, (tables.unsupported.get(feature) ?? 0) + 1);
}

/**
 * A blank style. Written out rather than spread from a constant so that adding a
 * field to `CueStyle` is a type error here, where it needs a mapping, instead of
 * silently staying `null` for every track.
 */
function emptyStyle(): CueStyle {
  return {
    alignment: null,
    positionX: null,
    positionY: null,
    textColor: null,
    backgroundColor: null,
    edgeColor: null,
    edgeStyles: null,
    fontFamily: null,
    fontSizePercent: null,
    bold: null,
    italic: null,
    underline: null,
  };
}

/** One event's resolved presentation, plus what the merge rule needs to decide with. */
interface ResolvedStyle {
  style: CueStyle | null;
  /** 0–1. Zero means the glyphs are invisible and the layer contributes only its edge. */
  textAlpha: number;
}

/**
 * Resolve one event's `pPenId` / `wpWinPosId` / `wsWinStyleId` into a `CueStyle`.
 *
 * Returns `style: null` when the three references contribute nothing — a plain
 * track, whose `pens` and `wsWinStyles` are `[{}]` and whose events name no ids.
 * That is the case the whole design protects: an unstyled document has to come
 * out the far end of this file exactly as it did before styling existed.
 */
function resolveStyle(
  tables: StyleTables,
  penId: number | null,
  posId: number | null,
  winStyleId: number | null,
): ResolvedStyle {
  const pen = entry(tables.pens, penId);
  const position = entry(tables.winPositions, posId);
  const winStyle = entry(tables.winStyles, winStyleId);

  const style = emptyStyle();
  let touched = false;
  const set = <K extends keyof CueStyle>(key: K, value: CueStyle[K]) => {
    style[key] = value;
    touched = true;
  };

  // -- pen: colour, edge, font, weight ------------------------------------
  const foreAlpha = alphaFrom(num(pen['foForeAlpha']));
  const foreColor = num(pen['fcForeColor']);
  if (foreColor !== null || pen['foForeAlpha'] !== undefined) {
    // White when only an alpha is given: that is the default caption colour, and
    // it is what the fade pens rely on.
    set('textColor', rgbFrom(foreColor ?? 0xffffff, foreAlpha));
  }

  const backColor = num(pen['bcBackColor']);
  if (backColor !== null || pen['boBackAlpha'] !== undefined) {
    set('backgroundColor', rgbFrom(backColor ?? 0x000000, alphaFrom(num(pen['boBackAlpha']))));
  }

  const edgeColor = num(pen['ecEdgeColor']);
  if (edgeColor !== null) set('edgeColor', rgbFrom(edgeColor, 1));

  const edgeType = num(pen['etEdgeType']);
  if (edgeType !== null) {
    const edge = EDGE_TYPES[edgeType];
    // An edge type outside the enum degrades to the default rather than to
    // `none`, which would strip the outline a caption needs to stay readable.
    if (edge !== undefined) set('edgeStyles', [edge]);
    else note(tables, `etEdgeType:${edgeType}`);
  }

  const penSize = num(pen['szPenSize']);
  if (penSize !== null && penSize !== DEFAULT_FONT_SIZE_PERCENT) {
    set('fontSizePercent', fontSizePercentFrom(penSize));
  }

  const fontStyle = num(pen['fsFontStyle']);
  if (fontStyle !== null) {
    const family = FONT_FAMILIES[fontStyle];
    if (family !== undefined) set('fontFamily', family);
    else note(tables, `fsFontStyle:${fontStyle}`);
  }

  if (num(pen['bAttr']) === 1) set('bold', true);
  if (num(pen['iAttr']) === 1) set('italic', true);
  if (num(pen['uAttr']) === 1) set('underline', true);

  // Sub- and superscript. ASS has no tag for either, so the text renders on the
  // baseline; counted rather than dropped in silence.
  if (pen['ofOffset'] !== undefined && num(pen['ofOffset']) !== 1) note(tables, 'ofOffset');
  if (pen['hgHorizGroup'] !== undefined) note(tables, 'hgHorizGroup');

  // -- window: where the caption goes --------------------------------------
  const anchor = num(position['apPoint']);
  if (anchor !== null) {
    const alignment = ANCHOR_TO_ASS[anchor];
    if (alignment !== undefined) set('alignment', alignment);
    else note(tables, `apPoint:${anchor}`);
  }

  const horizontal = num(position['ahHorPos']);
  const vertical = num(position['avVerPos']);
  // Both or neither: `\pos` takes a pair, and half a position is not a position.
  if (horizontal !== null && vertical !== null) {
    set('positionX', horizontal / 100);
    set('positionY', vertical / 100);
  }

  // With no anchor to hang it on, justification is the only thing saying which
  // way a multi-line caption grows. Bottom row, because that is where a caption
  // without a window sits anyway.
  if (style.alignment === null) {
    const justify = num(winStyle['juJustifCode']);
    if (justify === 0) set('alignment', 1);
    else if (justify === 1) set('alignment', 3);
    else if (justify === 2) set('alignment', 2);
  }

  // Vertical writing. libass has no writing-mode tag, so the text stays
  // horizontal; the alternative would be one `\N` per character, which is a
  // layout engine and not a conversion.
  if (num(winStyle['pdPrintDir']) === 2) note(tables, 'pdPrintDir:vertical');

  return { style: touched ? style : null, textAlpha: foreAlpha };
}

// ---------------------------------------------------------------------------
// The duplication rule
// ---------------------------------------------------------------------------

/** One event, parsed, before layers that describe the same caption are merged. */
interface Layer {
  startMs: number;
  endMs: number;
  segments: CueSegment[];
  style: CueStyle | null;
  textAlpha: number;
  /** Identifies the caption a layer belongs to: same text, same time, same window. */
  key: string;
}

/**
 * How visible a layer is, once its segments are allowed to disagree with it.
 *
 * The merge rule turns on "did this layer draw any glyphs", and with per-segment
 * pens that is no longer a property of the event. `L-BgxLtMxh0`'s karaoke cues
 * carry *no* event pen at all and three layers of segment pens, two of which are
 * fully transparent — read at the event level all three look opaque, the merge
 * sees three visible layers, calls them a conflict and emits the line three
 * times. The brightest run wins, because one visible run makes the layer visible.
 */
function layerAlpha(segments: CueSegment[], eventAlpha: number): number {
  const styled = segments.filter((segment) => segment.style?.textColor != null);
  if (styled.length === 0) return eventAlpha;
  return Math.max(...styled.map((segment) => segment.style!.textColor!.a));
}

/**
 * Identifies the caption a layer belongs to.
 *
 * Joined on a unit separator rather than a space, because caption text contains
 * spaces and a key that can be forged by one is a key that merges two different
 * captions into one.
 */
function layerKey(
  startMs: number,
  durationMs: number | null,
  posId: number | null,
  styleId: number | null,
  segments: CueSegment[],
): string {
  const text = segments.map((segment) => segment.text).join('');
  return [startMs, durationMs, posId, styleId, text].join(SEPARATOR);
}

/** ASCII unit separator, written as an escape so it survives a copy-paste. */
const SEPARATOR = '\u001f';

/**
 * Collapse the layers YouTube composites into the single caption it draws.
 *
 * **This is the fix for the stacked-duplicates bug**, and the reason it is a
 * merge rather than a de-duplication is that the two layers are not redundant:
 * measured on `L-BgxLtMxh0`, 240 of 257 cue groups are a pen with
 * `foForeAlpha: 0` and `etEdgeType: 4` over a pen with visible glyphs and
 * `etEdgeType: 3`. The first draws a drop shadow around invisible text; the
 * second draws the text with an outline. On screen that is *one* caption
 * carrying both effects, and dropping either layer loses a real effect.
 *
 * The rule:
 *
 *  1. Group by start, end, text and window. Anything that differs in one of
 *     those is a different caption and is never touched.
 *  2. **At most one visible layer** — the ordinary case — collapses to one cue.
 *     The visible layer supplies the glyphs; every layer in the group, visible
 *     or not, contributes its edge to the union. One line, `\bord` and `\shad`
 *     together.
 *  3. **Two or more visible layers** genuinely conflict: they are different
 *     renders of the same text, not layers of one, and ASS cannot put two fill
 *     colours on one line. `L-BgxLtMxh0`'s "Chromatic aberration." cue is the
 *     real example — red and green at half alpha, offset. Those pass through
 *     untouched and composite the way the source intends, which is sound
 *     because they are positioned: measured against the bundled libmpv,
 *     **`\pos` suppresses libass's collision avoidance** — two positioned events
 *     with identical text land exactly on top of each other, where two
 *     unpositioned ones stack vertically. That stacking is the bug as reported.
 *
 * Ordering is by first appearance, so `normalizeCues`'s sort has nothing to fix.
 */
export function mergeStyleLayers(layers: Layer[]): Cue[] {
  const groups = new Map<string, Layer[]>();
  for (const layer of layers) {
    const group = groups.get(layer.key);
    if (group === undefined) groups.set(layer.key, [layer]);
    else group.push(layer);
  }

  const out: Cue[] = [];
  for (const group of groups.values()) {
    const first = group[0]!;
    if (group.length === 1) {
      out.push(toCue(first));
      continue;
    }

    // Distinct, because "two visible layers" only conflicts when they actually
    // render differently. `L-BgxLtMxh0`'s karaoke cues arrive as three layers
    // that resolve identically — YouTube varies them *per segment*, which this
    // parser does not read (see the header) — and emitting three byte-identical
    // events draws the same glyphs three times for no gain.
    const visible = distinctByStyle(group.filter((layer) => layer.textAlpha > 0));
    if (visible.length > 1) {
      for (const layer of distinctByStyle(group)) out.push(toCue(layer));
      continue;
    }

    const base = visible[0] ?? first;
    const edges = unionEdges(group);
    out.push(
      toCue(
        edges.length === 0
          ? base
          : { ...base, style: { ...(base.style ?? emptyStyle()), edgeStyles: edges } },
      ),
    );
  }
  return out;
}

/**
 * Drop the edge from a run's style, leaving it to the line.
 *
 * A pen is absolute, so a segment pen restates the edge its layer already
 * declared. Emitted per run that would set `\bord`/`\shad` mid-line to the same
 * value repeatedly — harmless, but it also means the *unsung* run of a karaoke
 * line could quietly cancel the shadow the union just established.
 */
function withoutEdges(style: CueStyle | null): CueStyle | null {
  if (style === null || style.edgeStyles === null) return style;
  return { ...style, edgeStyles: null };
}

/**
 * One layer per resolved style. Serialised rather than compared field by field
 * so that a new `CueStyle` field is included without anyone remembering to.
 */
function distinctByStyle(layers: Layer[]): Layer[] {
  const seen = new Set<string>();
  return layers.filter((layer) => {
    const key = JSON.stringify(layer.style);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/**
 * Every edge any layer of a group asks for, deduplicated, in the order seen.
 *
 * Segment pens count. ASS *can* vary an outline per run, but YouTube's layering
 * does not mean that: the shadow layer of a karaoke line carries its edge on the
 * segment pens because that is where all its other styling lives, and the effect
 * it describes belongs to the whole line. Collecting them here is what lets
 * `\bord` and `\shad` be emitted once, and is why [CueSegment.style] never
 * carries an edge.
 */
function unionEdges(group: Layer[]): CueEdgeStyle[] {
  const edges: CueEdgeStyle[] = [];
  const styles = group.flatMap((layer) => [
    layer.style,
    ...layer.segments.map((segment) => segment.style),
  ]);
  for (const style of styles) {
    for (const edge of style?.edgeStyles ?? []) {
      // `none` only survives if it is the only thing anyone asked for — a layer
      // that wants no edge must not erase the shadow another layer draws.
      if (!edges.includes(edge)) edges.push(edge);
    }
  }
  return edges.length > 1 ? edges.filter((edge) => edge !== 'none') : edges;
}

function toCue(layer: Layer): Cue {
  return {
    startMs: layer.startMs,
    endMs: layer.endMs,
    segments: layer.segments.map((segment) => ({
      ...segment,
      style: withoutEdges(segment.style),
    })),
    style: layer.style,
  };
}

// ---------------------------------------------------------------------------
// The parser
// ---------------------------------------------------------------------------

/**
 * The window each ASR line refers to by `wWinId`.
 *
 * A window definition is an event with an `id` and no `segs`. Its
 * `wpWinPosId`/`wsWinStyleId` belong to every line that names it — see the
 * header for why missing this hop is invisible rather than loud.
 */
function windowsById(events: unknown[]): Map<number, { posId: number | null; styleId: number | null }> {
  const windows = new Map<number, { posId: number | null; styleId: number | null }>();
  for (const event of events) {
    if (!isObject(event)) continue;
    const id = num(event['id']);
    if (id === null || event['segs'] !== undefined) continue;
    windows.set(id, {
      posId: num(event['wpWinPosId']),
      styleId: num(event['wsWinStyleId']),
    });
  }
  return windows;
}

/**
 * Parse a `json3` document into raw, ungrouped cues.
 *
 * Tolerant in the same way the renderer parser is (hard invariant 4): an event
 * this does not understand is skipped and counted, never thrown over. A caption
 * track that loses one line is worth far more than one that fails to load.
 */
export function parseJson3(raw: unknown): Cue[] {
  const events = asArray(get(raw as Json, 'events'));
  if (events.length === 0) {
    log.debug('json3: no events');
    return [];
  }

  const tables = readStyleTables(raw as Json);
  const windows = windowsById(events);

  const layers: Layer[] = [];
  let skipped = 0;

  for (const event of events) {
    if (!isObject(event)) {
      skipped++;
      continue;
    }

    // A window definition carries no `segs` at all. It is the ASR track's
    // header, and it declares the duration of the *whole track* — 211879 ms on a
    // 3½ minute video — so mistaking it for a cue puts one caption on screen for
    // the entire runtime.
    const segs = get(event, 'segs');
    if (segs === undefined || segs === null) continue;

    // The roll marker: `aAppend: 1` with a lone newline. It advances the window
    // rather than saying anything, and it is why a naive parser produces a blank
    // cue between every real one.
    if (event['aAppend'] === 1) continue;

    const startMs = num(event['tStartMs']);
    if (startMs === null) {
      skipped++;
      continue;
    }

    // An ASR line names its window indirectly; a manual cue names it outright.
    const window = windows.get(num(event['wWinId']) ?? -1);
    const posId = num(event['wpWinPosId']) ?? window?.posId ?? null;
    const styleId = num(event['wsWinStyleId']) ?? window?.styleId ?? null;
    const eventPenId = num(event['pPenId']);
    const resolved = resolveStyle(tables, eventPenId, posId, styleId);

    const segments: CueSegment[] = [];
    for (const seg of asArray(segs)) {
      if (!isObject(seg)) continue;
      // **Read raw, not through `str()`.** The tree helper trims, which is right
      // for renderer text and wrong here: an ASR segment carries its own leading
      // space (`"We're"`, `" no"`, `" strangers"`), and that space is the only
      // word separator in the document. Trimming produces
      // "We'renostrangersto" — every word rendered, nothing missing, and
      // completely unreadable, which is the kind of bug that survives review.
      const text = seg['utf8'];
      if (typeof text !== 'string') continue;

      // A pen on the *segment* overrides the event's. This is the karaoke path —
      // see [CueSegment.style]. Resolved with no window, because position is a
      // property of the line and a run cannot move itself.
      const segPenId = num(seg['pPenId']);
      const segStyle =
        segPenId === null || segPenId === eventPenId
          ? null
          : resolveStyle(tables, segPenId, null, null);

      segments.push({ text, offsetMs: num(seg['tOffsetMs']), style: segStyle?.style ?? null });
    }
    if (segments.length === 0) continue;

    const { style } = resolved;
    const durationMs = num(event['dDurationMs']);
    layers.push({
      startMs,
      // `0` rather than a guess: `normalizeCues` owns the "no duration declared"
      // rule, so there is one copy of it rather than one per format parser.
      endMs: durationMs === null ? 0 : startMs + durationMs,
      segments,
      style,
      textAlpha: layerAlpha(segments, resolved.textAlpha),
      key: layerKey(startMs, durationMs, posId, styleId, segments),
    });
  }

  if (skipped > 0) log.warn(`json3: skipped ${skipped} unreadable event(s)`);
  if (tables.unsupported.size > 0) {
    const summary = [...tables.unsupported].map(([name, count]) => `${name}×${count}`).join(', ');
    log.debug(`json3: styling ASS cannot express, dropped: ${summary}`);
  }

  const cues = mergeStyleLayers(layers);
  if (cues.length < layers.length) {
    log.debug(`json3: merged ${layers.length} styled layer(s) into ${cues.length} cue(s)`);
  }
  return cues;
}
