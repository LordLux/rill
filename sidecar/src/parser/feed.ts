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
import type { ArtistPanel, Chip, FeedItem, FeedResult } from '../types.ts';
import { mapArtistPanel, mapChip, mapItem } from './items.ts';
import { asArray, contentRoots, get, isObject, str, type Json, type JsonObject } from './tree.ts';
import { isRendererKey, normaliseRendererName, roleOf } from './vocabulary.ts';

const log = logger('parser');

/** Exported for tests only, alongside `traverse` — see its doc comment. */
export interface Collector {
  items: FeedItem[];
  chips: Chip[];
  continuation: string | null;
  seenChips: Set<string>;
  stripped: { shorts: number; ads: number };
  artistPanel: ArtistPanel | null;
  /** `entityKey → subscribed`, resolved once from `frameworkUpdates.entityBatchUpdate` — see `mapArtistPanel`. */
  subscriptionEntities: ReadonlyMap<string, boolean>;
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
  collector.items.push(item);
}

function pushChip(collector: Collector, chip: Chip | null): void {
  if (!chip) return;
  const key = `${chip.scope}:${chip.label}:${chip.token}`;
  if (collector.seenChips.has(key)) return;
  collector.seenChips.add(key);
  collector.chips.push(chip);
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

  switch (role) {
    case 'item':
      pushItem(collector, mapItem(name, payload));
      return false;

    case 'strip':
      if (SHORTS.test(name)) collector.stripped.shorts += 1;
      else collector.stripped.ads += 1;
      return false;

    case 'chip-feed':
      if (isObject(payload)) pushChip(collector, mapChip(payload, 'feed'));
      return false;

    case 'chip-shelf':
      if (isObject(payload)) pushChip(collector, mapChip(payload, 'shelf'));
      return false;

    case 'continuation':
      if (isObject(payload)) collector.continuation ??= continuationToken(payload);
      return false;

    case 'artist-panel':
      // First one wins, and never descended into — `mapArtistPanel` lifts the
      // embedded shelf out itself (Task 23), so descending here would put the
      // artist's top videos in the search results as well. Today's vocabulary
      // never produces more than one panel per response anyway.
      if (isObject(payload)) {
        collector.artistPanel ??= mapArtistPanel(payload, collector.subscriptionEntities);
      }
      return false;

    case 'ignore':
      return false;

    case 'container':
      return true;

    default:
      noteUnknownRenderer(rendererKey, context);
      return false;
  }
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
        traverse(collector, child, context, depth + 1);
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
export function parseFeed(raw: Json, context = 'feed'): FeedResult {
  const collector: Collector = {
    items: [],
    chips: [],
    continuation: null,
    seenChips: new Set(),
    stripped: { shorts: 0, ads: 0 },
    artistPanel: null,
    subscriptionEntities: subscriptionEntitiesFrom(raw),
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
    continuation: collector.continuation,
    artistPanel: collector.artistPanel,
  };
}
