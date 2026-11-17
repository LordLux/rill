/**
 * `parseFeed` — the tolerant renderer walker.
 *
 * Walks a raw (`parse: false`) InnerTube response and emits flat DTOs. It never
 * throws on an unrecognised node: the item is skipped, the type is logged once
 * per run with a count, and its siblings are unaffected. That property is the
 * whole point of the component — YouTube A/B-tests renderers continuously, and a
 * strict parser turns a new tile type into a silently empty screen.
 *
 * Traversal rules, in priority order per object key:
 *
 *   item        → map to a DTO, do not descend (a tile's own menu must not be
 *                 re-read as a sibling tile)
 *   strip       → drop the whole subtree (Shorts, ads — an in-feed ad nests a
 *                 real lockupViewModel inside adSlotRenderer)
 *   chip        → collect, do not descend (chip tokens are not continuations)
 *   continuation→ collect the token, do not descend
 *   container   → descend
 *   ignore      → skip (menus, dialogs, topbar furniture)
 *   unknown     → log once, skip the node, keep walking its siblings
 */

import { logger, noteUnknownRenderer } from '../log.ts';
import type { ArtistPanel, Chip, FeedItem, FeedResult, Shelf, ShelfItem } from '../types.ts';
import { mapArtistPanel, mapChip, mapItem } from './items.ts';
import { buildShelf, mapPost, mapShortsLockup, SHELF_RENDERERS, shelfTitle } from './shelves.ts';
import { asArray, contentRoots, get, isObject, str, type Json, type JsonObject } from './tree.ts';
import { isRendererKey, normaliseRendererName, roleOf, type RendererRole } from './vocabulary.ts';

const log = logger('parser');

/** Exported for tests only, alongside `traverse` — see its doc comment. */
export interface Collector {
  items: FeedItem[];
  /** Finished shelves, in page order. Only filled when `collectShelves` is on. */
  shelves: Shelf[];
  /**
   * Shelves asked for (`feed.home`). Off, a shelf container is an ordinary container,
   * its tiles join `items`, and a Shorts or posts shelf stays dropped — exactly the
   * behaviour every other surface has always had.
   */
  collectShelves: boolean;
  /** The shelves currently being walked, innermost last. Tiles go to the innermost. */
  frames: ShelfFrame[];
  chips: Chip[];
  continuation: string | null;
  seenChips: Set<string>;
  stripped: { shorts: number; ads: number };
  artistPanel: ArtistPanel | null;
  /** `entityKey → subscribed`, resolved once from `frameworkUpdates.entityBatchUpdate` — see `mapArtistPanel`. */
  subscriptionEntities: ReadonlyMap<string, boolean>;
  /** Measurement only (`parser/feed-shape.ts`, Task 37): watches the walk, never changes it. */
  observer?: TraversalObserver;
}

/** A shelf under construction: where it sits and what has been collected so far. */
interface ShelfFrame {
  title: string | null;
  index: number;
  items: ShelfItem[];
}

/**
 * A read-only view of the walk, for the names-only shape dump. `renderer` fires
 * once per classified renderer key, before the walker descends into it; `enter`
 * and `leave` bracket a descent. An observer must not throw — it is measurement,
 * and a failure in it must never cost a request (invariant 4).
 */
export interface TraversalObserver {
  renderer(event: {
    key: string;
    name: string;
    role: RendererRole | null;
    payload: Json;
    /** What `mapItem` returned; null for every role but `item`, and for an item it declined. */
    item: ShelfItem | null;
  }): void;
  enter(): void;
  leave(): void;
}

/**
 * The response-level entity store `officialCardViewModel`'s subscribe button
 * reads from — its own subtree carries no current-state boolean, only what
 * each button variant would produce. Resolved once per response rather than
 * per panel, though today's vocabulary only ever produces one.
 */
function subscriptionEntitiesFrom(raw: Json): Map<string, boolean> {
  const map = new Map<string, boolean>();
  const mutations = asArray(get(raw, 'frameworkUpdates', 'entityBatchUpdate', 'mutations'));
  for (const mutation of mutations) {
    const key = str(get(mutation, 'entityKey'));
    const subscribed = get(mutation, 'payload', 'subscriptionStateEntity', 'subscribed');
    if (key && typeof subscribed === 'boolean') map.set(key, subscribed);
  }
  return map;
}

const SHORTS = /^(shortslockup|reelitem|reelshelf|richshelfshorts)$/;

/**
 * Continuation token from a continuation marker.
 *
 * Both generations bury it one level differently, and a continuation response
 * re-wraps it again, so we probe the known paths in order rather than sweeping
 * for any `token` — chips carry `continuationCommand.token` too, and picking one
 * up as the feed continuation makes infinite scroll silently reload the filter.
 */
function continuationToken(node: JsonObject): string | null {
  const paths: string[][] = [
    ['continuationEndpoint', 'continuationCommand', 'token'],
    ['continuationEndpoint', 'commandExecutorCommand', 'commands'],
    ['endpoint', 'continuationCommand', 'token'],
    ['button', 'buttonRenderer', 'command', 'continuationCommand', 'token'],
    ['continuationCommand', 'token'],
    // A playlist page's `continuationItemViewModel` (F54).
    ['continuationCommand', 'innertubeCommand', 'continuationCommand', 'token'],
    ['token'],
  ];

  for (const path of paths) {
    const value = get(node, ...path);
    if (typeof value === 'string') {
      const token = str(value);
      if (token && token.length > 20) return token;
    }
    // commandExecutorCommand wraps a list; scan it for the first real token.
    if (Array.isArray(value)) {
      for (const entry of value) {
        const nested = get(entry, 'continuationCommand', 'token');
        const token = str(nested);
        if (token && token.length > 20) return token;
      }
    }
  }
  return null;
}

/**
 * No de-duplication by id, deliberately.
 *
 * The traversal never descends into a tile it has already mapped, so a tile
 * cannot be emitted twice by accident — and repeats are real content: watch
 * history lists the same video once per viewing. De-duplicating cost 42 of 183
 * entries on the history fixture.
 */
function pushItem(collector: Collector, item: FeedItem | null): void {
  if (!item) return;
  const frame = collector.frames[collector.frames.length - 1];
  if (frame) frame.items.push(item);
  else collector.items.push(item);
}

function pushChip(collector: Collector, chip: Chip | null): void {
  if (!chip) return;
  const key = `${chip.scope}:${chip.label}:${chip.token}`;
  if (collector.seenChips.has(key)) return;
  collector.seenChips.add(key);
  collector.chips.push(chip);
}

/** A shelf tile that carried too little to be one: skipped and logged, never an error (invariant 4). */
function noteUnmappedShelfTile(name: string, context: string): void {
  log.debug(`${context}: a ${name} tile in a shelf carried no id or no text and was skipped`);
}

/**
 * Open a shelf frame when a container that is a shelf is about to be walked.
 * Returns the frame to close afterwards, or null when no shelf is being collected.
 */
function openShelf(collector: Collector, rendererKey: string, payload: Json): ShelfFrame | null {
  if (!collector.collectShelves || !SHELF_RENDERERS.has(normaliseRendererName(rendererKey))) return null;
  const frame: ShelfFrame = { title: shelfTitle(payload), index: collector.items.length, items: [] };
  collector.frames.push(frame);
  return frame;
}

function closeShelf(collector: Collector, frame: ShelfFrame | null): void {
  if (!frame) return;
  collector.frames.pop();
  const shelf = buildShelf(frame.title, frame.index, frame.items);
  if (shelf) collector.shelves.push(shelf);
}

/**
 * Classify and handle one renderer node.
 * Returns true when the caller should descend into `payload`.
 */
function handleRenderer(
  collector: Collector,
  rendererKey: string,
  payload: Json,
  context: string,
): boolean {
  const name = normaliseRendererName(rendererKey);
  const role = roleOf(rendererKey);
  let item: ShelfItem | null = null;
  let descend = false;

  switch (role) {
    case 'item': {
      const mapped = mapItem(name, payload);
      item = mapped;
      pushItem(collector, mapped);
      break;
    }

    case 'strip': {
      // A Short tile inside a shelf is the shelf's content (`todo.md` 111); anywhere
      // else — search, subscriptions, a shelf nobody asked for — it is dropped as ever.
      const frame = collector.frames[collector.frames.length - 1];
      if (frame && name === 'shortslockup') {
        const short = mapShortsLockup(payload);
        item = short;
        if (short) frame.items.push(short);
        else noteUnmappedShelfTile(name, context);
      } else if (SHORTS.test(name)) collector.stripped.shorts += 1;
      else collector.stripped.ads += 1;
      break;
    }

    case 'chip-feed':
      if (isObject(payload)) pushChip(collector, mapChip(payload, 'feed'));
      break;

    case 'chip-shelf':
      if (isObject(payload)) pushChip(collector, mapChip(payload, 'shelf'));
      break;

    case 'continuation':
      if (isObject(payload)) collector.continuation ??= continuationToken(payload);
      break;

    case 'artist-panel':
      // First one wins, and never descended into — `mapArtistPanel` lifts the
      // embedded shelf out itself (Task 23), so descending here would put the
      // artist's top videos in the search results as well. Today's vocabulary
      // never produces more than one panel per response anyway.
      if (isObject(payload)) {
        collector.artistPanel ??= mapArtistPanel(payload, collector.subscriptionEntities);
      }
      break;

    case 'ignore': {
      // Likewise a post: ignored everywhere except inside a shelf, where it is a tile.
      const frame = collector.frames[collector.frames.length - 1];
      if (frame && name === 'post') {
        const post = mapPost(payload);
        item = post;
        if (post) frame.items.push(post);
        else noteUnmappedShelfTile(name, context);
      }
      break;
    }

    case 'container':
      descend = true;
      break;

    default:
      noteUnknownRenderer(rendererKey, context);
      break;
  }

  collector.observer?.renderer({ key: rendererKey, name, role, payload, item });
  return descend;
}

/**
 * Depth-first traversal. Hand-rolled rather than reusing `walk` from tree.ts
 * because the pruning decision here depends on the *key* a value arrived under,
 * which a value-only visitor cannot see.
 *
 * Exported for tests only — specifically `tree.test.ts`'s check that this
 * function's own `value === null || typeof value !== 'object'` /
 * `Array.isArray` split still agrees with `isObject` (tree.ts) and the inline
 * branch inside `walk` (tree.ts). Everything in production reaches this
 * through `parseFeed`.
 */
export function traverse(collector: Collector, value: Json, context: string, depth: number): void {
  if (depth > 60 || value === null || typeof value !== 'object') return;

  if (Array.isArray(value)) {
    for (const entry of value) traverse(collector, entry, context, depth + 1);
    return;
  }

  const node = value as JsonObject;

  // Parsed-shape fallback: youtubei.js trees carry the renderer name on `type`
  // rather than as the wrapping key. We only ever consume parse:false responses,
  // but degrading gracefully costs one branch.
  //
  // The PascalCase guard matters: raw responses are full of lowercase `type`
  // fields ("grid", "video") whose values collide with vocabulary names. Acting
  // on one would prune a subtree that still had real tiles in it — precisely the
  // silent-loss failure this parser exists to avoid.
  const typeName = str(node['type']);
  if (typeName && /^[A-Z]/.test(typeName)) {
    const role = roleOf(typeName);
    if (role !== null && role !== 'container' && !handleRenderer(collector, typeName, node, context)) {
      return;
    }
  }

  for (const [key, child] of Object.entries(node)) {
    if (isRendererKey(key)) {
      if (handleRenderer(collector, key, child, context)) {
        const frame = openShelf(collector, key, child);
        collector.observer?.enter();
        traverse(collector, child, context, depth + 1);
        collector.observer?.leave();
        closeShelf(collector, frame);
      }
      continue;
    }
    traverse(collector, child, context, depth + 1);
  }
}

/**
 * Parse any list-shaped response — home, subscriptions, history, search,
 * playlist, related — into chips, items and a continuation token.
 *
 * `context` only labels the unknown-renderer log, so a surprise in search is
 * distinguishable from the same surprise in the home feed.
 */
export function parseFeed(
  raw: Json,
  context = 'feed',
  observer?: TraversalObserver,
  options: { shelves?: boolean } = {},
): FeedResult {
  const collector: Collector = {
    items: [],
    shelves: [],
    collectShelves: options.shelves === true,
    frames: [],
    chips: [],
    continuation: null,
    seenChips: new Set(),
    stripped: { shorts: 0, ads: 0 },
    artistPanel: null,
    subscriptionEntities: subscriptionEntitiesFrom(raw),
    ...(observer ? { observer } : {}),
  };

  for (const root of contentRoots(raw)) {
    traverse(collector, root, context, 0);
  }

  const { shorts, ads } = collector.stripped;
  if (shorts > 0 || ads > 0) {
    log.debug(`${context}: stripped ${shorts} Shorts node(s), ${ads} ad node(s)`);
  }

  return {
    chips: collector.chips,
    items: collector.items,
    shelves: collector.shelves,
    continuation: collector.continuation,
    artistPanel: collector.artistPanel,
  };
}
