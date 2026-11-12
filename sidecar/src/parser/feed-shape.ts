/**
 * The names-only shape of a home page response — Task 37 §1, a measurement
 * instrument, off unless `SIDECAR_FEED_SHAPE=1`.
 *
 * It exists to answer "which renderer carried this tile, under which shelf, and
 * how does a members-only tile mark itself" for an account that cannot be
 * captured (the signed-in one in the app: the capture account has no
 * memberships). A raw response must never leave the machine, so what is written
 * is built from an allow-list and nothing else:
 *
 *   written    renderer names, the parser's verdict, shelf header text, badge
 *              style / icon / label, enum-shaped tokens, a per-launch channel
 *              ordinal ("ch3"), and whether a view count is present
 *   never      a video title, a video / channel / playlist id, a URL, a
 *              thumbnail, an avatar, an endpoint, a token, or anything from
 *              the response's context block (the walk starts at the content roots, so it
 *              cannot reach it)
 *
 * **It watches the real walk** (`TraversalObserver` in `feed.ts`) instead of
 * walking a second time, so the verdicts are the parser's own and a change to
 * the vocabulary cannot leave this reporting something the parser does not do.
 * The channel ordinal is the one place an identity is touched: it is assigned in
 * order of first appearance within the process and has no relation to the id, so
 * it can say "9 tiles are from one channel, 7 of them in one shelf" and nothing
 * more. It is reset by a restart, and the file says so.
 *
 * The file goes to the temp directory and its path to stderr (the release log),
 * never to stdout — stdout is protocol only (invariant 3).
 */

import { writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { logger } from '../log.ts';
import type { FeedItem, FeedResult } from '../types.ts';
import { parseFeed, type TraversalObserver } from './feed.ts';
import { text } from './text.ts';
import { asArray, get, isObject, str, type Json, type JsonObject } from './tree.ts';
import { isRendererKey, type RendererRole } from './vocabulary.ts';

const log = logger('feed-shape');

/** Names of the containers a tile can sit under that are a shelf rather than the grid. */
const SHELFISH =
  /^(richshelf|shelf|gridshelf|horizontallist|verticallist|brandvideoshelf|chipsshelfwithvideoshelf|richsection)$/;

/** Renderer keys whose body is a badge, a status overlay or a membership marker. */
const BADGE_KEY = /badge|timestatus|sponsor|member/i;

/** `BADGE_STYLE_TYPE_MEMBERS_ONLY`, `SPONSORSHIP_STAR`, `MUSIC` — an enum, never prose. */
const ENUM_VALUE = /^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*$/;
/** Keys whose value is an enum. Ids, urls, params and tokens never match this list. */
const ENUM_KEY = /(style|icon|imageName|type|state|variant|layout|kind|appearance)/i;
const ENUM_KEY_EXCLUDED = /(id|url|params?|token|tracking)$/i;

const MAX_ENUMS_PER_TILE = 40;

/** Process-wide: the same channel keeps its ordinal across the pages of one launch. */
const channelOrdinals = new Map<string, number>();
/** `ordinal → shelf label → tiles`, across every page this launch has dumped. */
const channelTotals = new Map<number, Map<string, number>>();
let sequence = 0;

function ordinalOf(channelId: string): number {
  let ordinal = channelOrdinals.get(channelId);
  if (ordinal === undefined) {
    ordinal = channelOrdinals.size + 1;
    channelOrdinals.set(channelId, ordinal);
  }
  return ordinal;
}

function clip(value: string, max: number): string {
  const flat = value.replace(/\s+/g, ' ').trim();
  return flat.length > max ? `${flat.slice(0, max)}…` : flat;
}

function quote(value: string, max: number): string {
  return JSON.stringify(clip(value, max));
}

// ---------------------------------------------------------------------------
// What a shelf calls itself
// ---------------------------------------------------------------------------

function firstTitle(value: Json, depth: number): string | null {
  if (depth > 5) return null;
  if (Array.isArray(value)) {
    for (const entry of value) {
      const found = firstTitle(entry, depth + 1);
      if (found) return found;
    }
    return null;
  }
  if (!isObject(value)) return null;
  for (const key of ['title', 'headline', 'titleText', 'text']) {
    const found = text(value[key]);
    if (found) return found;
  }
  for (const child of Object.values(value)) {
    const found = firstTitle(child, depth + 1);
    if (found) return found;
  }
  return null;
}

/** A container's own title, or the one inside a header it carries. */
function headerTitle(payload: Json): string | null {
  if (!isObject(payload)) return null;
  const direct = text(payload['title']) ?? text(payload['headline']);
  if (direct) return direct;
  for (const [key, value] of Object.entries(payload)) {
    if (!/header/i.test(key)) continue;
    const found = firstTitle(value, 0);
    if (found) return found;
  }
  return null;
}

// ---------------------------------------------------------------------------
// What a tile carries that could be a marker
// ---------------------------------------------------------------------------

interface BadgeLine {
  renderer: string;
  styles: string[];
  icons: string[];
  label: string | null;
}

function badgeLine(key: string, node: JsonObject): BadgeLine {
  const styles: string[] = [];
  const icons: string[] = [];
  for (const [field, value] of Object.entries(node)) {
    if (/style/i.test(field) && typeof value === 'string' && ENUM_VALUE.test(value)) styles.push(value);
  }
  const iconType = str(get(node, 'icon', 'iconType'));
  if (iconType) icons.push(iconType);
  const iconName = str(node['iconName']) ?? str(node['imageName']);
  if (iconName) icons.push(iconName);
  for (const source of asArray(get(node, 'icon', 'sources'))) {
    const image = str(get(source, 'clientResource', 'imageName'));
    if (image) icons.push(image);
  }
  return {
    renderer: key,
    styles: [...new Set(styles)],
    icons: [...new Set(icons)],
    label: text(node['text']) ?? text(node['label']),
  };
}

/** Every badge-ish renderer under a tile, in document order. */
function collectBadges(root: Json): BadgeLine[] {
  const out: BadgeLine[] = [];
  const seen = new WeakSet<object>();
  const step = (value: Json, depth: number): void => {
    if (depth > 40 || value === null || typeof value !== 'object' || seen.has(value)) return;
    seen.add(value);
    if (Array.isArray(value)) {
      for (const entry of value) step(entry, depth + 1);
      return;
    }
    for (const [key, child] of Object.entries(value as JsonObject)) {
      if (isRendererKey(key) && BADGE_KEY.test(key) && isObject(child)) out.push(badgeLine(key, child));
      step(child, depth + 1);
    }
  };
  step(root, 0);
  return out;
}

/** `key=VALUE` for every enum-shaped string under a tile, wherever it sits. */
function collectEnums(root: Json): string[] {
  const out = new Set<string>();
  const seen = new WeakSet<object>();
  const step = (value: Json, depth: number): void => {
    if (out.size >= MAX_ENUMS_PER_TILE || depth > 40 || value === null || typeof value !== 'object') return;
    if (seen.has(value)) return;
    seen.add(value);
    if (Array.isArray(value)) {
      for (const entry of value) step(entry, depth + 1);
      return;
    }
    for (const [key, child] of Object.entries(value as JsonObject)) {
      if (
        typeof child === 'string' &&
        child.length >= 3 &&
        child.length <= 60 &&
        ENUM_VALUE.test(child) &&
        ENUM_KEY.test(key) &&
        !ENUM_KEY_EXCLUDED.test(key)
      ) {
        out.add(`${key}=${child}`);
      }
      step(child, depth + 1);
    }
  };
  step(root, 0);
  return [...out];
}

// ---------------------------------------------------------------------------
// The recorder
// ---------------------------------------------------------------------------

interface Line {
  depth: number;
  text: string;
  /** Repeated identical lines collapse; a tile never does. */
  collapsible: boolean;
}

interface ContainerFrame {
  name: string;
  shelfId: number | null;
  shelfLabel: string | null;
}

interface TileRecord {
  shelf: string;
  verdict: string;
  hasViews: boolean | null;
  members: boolean;
}

export class FeedShapeRecorder implements TraversalObserver {
  private readonly lines: Line[] = [];
  private readonly stack: ContainerFrame[] = [];
  private pending: ContainerFrame | null = null;
  private shelves = 0;
  private tileCount = 0;
  private readonly tiles: TileRecord[] = [];
  private readonly shelfTiles = new Map<string, { tiles: number; noViews: number; members: number }>();
  private readonly roleCounts = new Map<string, number>();

  constructor(private readonly label: string) {}

  enter(): void {
    this.stack.push(this.pending ?? { name: '?', shelfId: null, shelfLabel: null });
    this.pending = null;
  }

  leave(): void {
    this.stack.pop();
  }

  renderer(event: {
    key: string;
    name: string;
    role: RendererRole | null;
    payload: Json;
    item: FeedItem | null;
  }): void {
    try {
      this.record(event);
    } catch {
      // Measurement must never cost a request (invariant 4). A broken line is lost; the parse is not.
    }
  }

  private depth(): number {
    return this.stack.length;
  }

  private nearestShelf(): ContainerFrame | null {
    for (let i = this.stack.length - 1; i >= 0; i -= 1) {
      const frame = this.stack[i];
      if (frame && frame.shelfId !== null) return frame;
    }
    return null;
  }

  private record(event: {
    key: string;
    name: string;
    role: RendererRole | null;
    payload: Json;
    item: FeedItem | null;
  }): void {
    const { key, name, role, payload, item } = event;
    const roleName = role ?? 'unknown';
    this.roleCounts.set(roleName, (this.roleCounts.get(roleName) ?? 0) + 1);

    if (role === 'container') {
      const title = headerTitle(payload);
      let shelfId: number | null = null;
      let shelfLabel: string | null = null;
      if (SHELFISH.test(name)) {
        this.shelves += 1;
        shelfId = this.shelves;
        shelfLabel = `${key}${title ? ` ${quote(title, 80)}` : ''}`;
      }
      this.pending = { name, shelfId, shelfLabel };
      const id = shelfId === null ? '' : `  S${shelfId}`;
      this.lines.push({
        depth: this.depth(),
        text: `${key}${id}${title ? `  title=${quote(title, 80)}` : ''}`,
        collapsible: shelfId === null && title === null,
      });
      return;
    }

    if (role !== 'item') {
      this.lines.push({ depth: this.depth(), text: `${key}  ${roleName}`, collapsible: true });
      return;
    }

    // --- a tile --------------------------------------------------------------
    this.tileCount += 1;
    const frame = this.nearestShelf();
    const where = frame ? `S${frame.shelfId}` : 'grid';
    const shelfKey = frame?.shelfLabel ?? 'grid';

    let verdict = 'dropped';
    let hasViews: boolean | null = null;
    let members = false;
    let channel = 'ch-';
    let age = '';
    const flags: string[] = [];
    if (item) {
      verdict = `mapped:${item.kind}`;
      if (item.kind === 'video') {
        hasViews = item.viewCountText !== null;
        members = item.isMembersOnly;
        if (item.channelId) {
          const ordinal = ordinalOf(item.channelId);
          channel = `ch${ordinal}`;
          const totals = channelTotals.get(ordinal) ?? new Map<string, number>();
          totals.set(shelfKey, (totals.get(shelfKey) ?? 0) + 1);
          channelTotals.set(ordinal, totals);
        }
        if (item.publishedText) age = `  age=${quote(item.publishedText, 30)}`;
        if (item.isLive) flags.push('live');
        if (item.isShort) flags.push('short');
        if (item.isMusic) flags.push('music');
        if (item.isMembersOnly) flags.push('members');
        // Facts about the id and the actions, never the id: a promo tile that is not a video
        // (a Premium upsell) is told by an id that is not 11 characters and by having no actions.
        if (!/^[A-Za-z0-9_-]{11}$/.test(item.id)) flags.push('idodd');
        if (!item.canAddToQueue) flags.push('noqueue');
        if (!item.canWatchLater) flags.push('nowatchlater');
      }
    }

    const views = hasViews === null ? '-' : hasViews ? 'yes' : 'no';
    this.lines.push({
      depth: this.depth(),
      text:
        `${key}  tile#${this.tileCount}  ${verdict}  views=${views}${age}` +
        `  ch=${channel}  in=${where}${flags.length ? `  flags=${flags.join(',')}` : ''}`,
      collapsible: false,
    });

    for (const badge of collectBadges(payload)) {
      const parts = [`badge  ${badge.renderer}`];
      if (badge.styles.length) parts.push(`style=${badge.styles.join('|')}`);
      if (badge.icons.length) parts.push(`icon=${badge.icons.join('|')}`);
      if (badge.label) parts.push(`label=${quote(badge.label, 60)}`);
      this.lines.push({ depth: this.depth() + 1, text: parts.join('  '), collapsible: false });
    }
    const enums = collectEnums(payload);
    if (enums.length) {
      this.lines.push({ depth: this.depth() + 1, text: `enums  ${enums.join('  ')}`, collapsible: false });
    }

    this.tiles.push({ shelf: shelfKey, verdict, hasViews, members });
    const entry = this.shelfTiles.get(shelfKey) ?? { tiles: 0, noViews: 0, members: 0 };
    entry.tiles += 1;
    if (hasViews === false) entry.noViews += 1;
    if (members) entry.members += 1;
    this.shelfTiles.set(shelfKey, entry);
  }

  /** The finished file: a header, the tree, then two tables. */
  render(result: Pick<FeedResult, 'items' | 'chips' | 'continuation'>): string {
    const out: string[] = [];
    out.push(`# feed shape  label=${this.label}  written=${new Date().toISOString()}`);
    out.push('# Names only: renderer names, the parser verdict, shelf header text, badge style/icon/label,');
    out.push('# enum tokens, and a per-launch channel ordinal (chN: first-seen order in this process, not an id).');
    out.push(
      `# items=${result.items.length}  chips=${result.chips.length}  continuation=${result.continuation ? 'yes' : 'no'}` +
        `  roles: ${[...this.roleCounts].map(([r, n]) => `${r}=${n}`).join(' ')}`,
    );
    out.push('');

    // Tree, identical neighbours collapsed.
    let last: Line | null = null;
    let run = 0;
    const flush = (): void => {
      if (last) out.push(`${'  '.repeat(last.depth)}${last.text}${run > 1 ? `  x${run}` : ''}`);
      last = null;
      run = 0;
    };
    for (const line of this.lines) {
      if (last && line.collapsible && last.collapsible && last.depth === line.depth && last.text === line.text) {
        run += 1;
        continue;
      }
      flush();
      last = line;
      run = 1;
    }
    flush();

    out.push('');
    out.push('== by shelf (this page) ==');
    for (const [shelf, entry] of this.shelfTiles) {
      out.push(`${shelf}  tiles=${entry.tiles}  noViews=${entry.noViews}  members=${entry.members}`);
    }

    out.push('');
    out.push('== by channel, cumulative over every page this launch has dumped ==');
    const rows = [...channelTotals].map(([ordinal, shelves]) => {
      const total = [...shelves.values()].reduce((a, b) => a + b, 0);
      return { ordinal, shelves, total };
    });
    rows.sort((a, b) => b.total - a.total);
    for (const { ordinal, shelves, total } of rows.slice(0, 25)) {
      const split = [...shelves].map(([shelf, n]) => `${n} in ${shelf}`).join('; ');
      out.push(`ch${ordinal}  total=${total}  ${split}`);
    }
    return `${out.join('\n')}\n`;
  }
}

/**
 * `parseFeed`, and with `SIDECAR_FEED_SHAPE=1` the names-only dump of the same walk, labelled
 * `label` — for the surfaces besides `feed.home` that the dump now covers (the watch page's
 * related list, where a Premium promo card turned up). Off, exactly `parseFeed(raw, context)`.
 */
export function parseFeedDumped(raw: Json, context: string, label: string): FeedResult {
  if (process.env['SIDECAR_FEED_SHAPE'] !== '1') return parseFeed(raw, context);
  const recorder = new FeedShapeRecorder(label);
  const result = parseFeed(raw, context, recorder);
  writeFeedShape(recorder, result, label);
  return result;
}

/** Write one page's dump to the temp directory and say where on stderr. Never throws. */
export function writeFeedShape(recorder: FeedShapeRecorder, result: FeedResult, label: string): void {
  try {
    sequence += 1;
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, '');
    const path = join(tmpdir(), `rill-feed-shape-${stamp}-${String(sequence).padStart(2, '0')}-${label}.txt`);
    writeFileSync(path, recorder.render(result), 'utf8');
    log.info(`feed shape written: ${path}`);
  } catch (error) {
    log.warn(`feed shape not written: ${error instanceof Error ? error.message : 'unknown error'}`);
  }
}
