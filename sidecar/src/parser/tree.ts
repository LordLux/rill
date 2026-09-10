/**
 * Raw-tree primitives.
 *
 * Everything here is total: given any input, it returns a value. Nothing throws
 * on a shape it does not recognise (hard invariant 4). Depth and cycle guards
 * exist because InnerTube responses are large and occasionally self-referential
 * once youtubei.js has touched them.
 */

export type Json = unknown;
export type JsonObject = Record<string, unknown>;

const MAX_DEPTH = 60;

export function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * First value in the tree satisfying `predicate`, depth-first.
 * Returns `null` rather than `undefined` so callers can stay on the DTO contract.
 */
export function deepFind(
  root: Json,
  predicate: (node: JsonObject) => boolean,
): JsonObject | null {
  let hit: JsonObject | null = null;
  walk(root, (node) => {
    if (hit === null && predicate(node)) hit = node;
    return hit === null;
  });
  return hit;
}

/** Every value in the tree satisfying `predicate`. */
export function deepCollect(
  root: Json,
  predicate: (node: JsonObject) => boolean,
): JsonObject[] {
  const out: JsonObject[] = [];
  walk(root, (node) => {
    if (predicate(node)) out.push(node);
    return true;
  });
  return out;
}

/**
 * Depth-first walk over every object in the tree.
 * `visit` returns false to prune the subtree below the current node.
 */
export function walk(root: Json, visit: (node: JsonObject) => boolean): void {
  const seen = new WeakSet<object>();

  const step = (value: Json, depth: number): void => {
    if (depth > MAX_DEPTH || value === null || typeof value !== 'object') return;
    if (seen.has(value)) return;
    seen.add(value);

    if (Array.isArray(value)) {
      for (const entry of value) step(entry, depth + 1);
      return;
    }

    const node = value as JsonObject;
    if (!visit(node)) return;
    for (const entry of Object.values(node)) step(entry, depth + 1);
  };

  step(root, 0);
}

/**
 * Read a nested path, tolerating anything missing along the way.
 * `get(node, 'metadata', 'lockupMetadataViewModel', 'title', 'content')`
 *
 * **A numeric segment indexes an array** — `get(node, 'messages', '0')`. That
 * looks obvious and was not true until 2026-09-09: every hop was guarded by
 * `isObject`, which excludes arrays *by design*, so the moment a path stepped
 * onto a list every remaining segment answered `null`. The one caller that
 * relied on it (`parser/player.ts`'s `playabilityStatus.messages[0]` fallback
 * for a refusal reason) had therefore been dead since the initial commit —
 * written, documented, believed in, and never once firing. Nothing threw and
 * nothing logged; the field was simply always absent.
 *
 * Audited when it was found: that was the only such caller in `src/`, so this
 * is a latent trap rather than a fleet of silent bugs. It is fixed here rather
 * than in `isObject` because `isObject` is right — its `value is JsonObject`
 * predicate would become a lie, and ~30 call sites that gate on "is this a
 * renderer payload" would start accepting lists. Only `get`, which walks a
 * *path*, ever needed to step through one.
 *
 * A **non**-numeric segment against an array is still `null`, deliberately:
 * `get(node, 'runs', 'length')` reading `3` off the JS array would be a path
 * silently answering with a property of the container rather than with data.
 */
export function get(root: Json, ...path: string[]): unknown {
  let cursor: unknown = root;
  for (const segment of path) {
    if (Array.isArray(cursor)) {
      if (!ARRAY_INDEX.test(segment)) return null;
      cursor = cursor[Number(segment)];
      continue;
    }
    if (!isObject(cursor)) return null;
    cursor = cursor[segment];
  }
  return cursor ?? null;
}

/** A path segment that addresses an array position. Non-negative, digits only. */
const ARRAY_INDEX = /^\d+$/;

/** A string value, or null. Empty and whitespace-only strings count as absent. */
export function str(value: unknown): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/** A finite number, or null. Accepts numeric strings, which InnerTube uses freely. */
export function num(value: unknown): number | null {
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string' && value.trim() !== '') {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

/** Coerce to an array — InnerTube alternates between a bare object and a list. */
export function asArray(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (value === null || value === undefined) return [];
  return [value];
}

/**
 * The subtrees that can contain feed content.
 *
 * A first-page response puts everything under `contents`; a continuation puts it
 * under `onResponseReceivedActions` or `continuationContents`. Branches like
 * `topbar`, `header` and `frameworkUpdates` carry notification and entity payloads
 * that look enough like tiles to pollute a naive whole-response walk.
 *
 * If none of the known roots is present we return the whole response — being
 * tolerant matters more than being tidy.
 */
const CONTENT_ROOTS = [
  'contents',
  'continuationContents',
  'onResponseReceivedActions',
  'onResponseReceivedEndpoints',
  'onResponseReceivedCommands',
  'actions',
];

export function contentRoots(raw: Json): Json[] {
  if (!isObject(raw)) return [raw];

  // youtubei.js hands back { data: … } from actions.execute; unwrap it.
  const body = isObject(raw['data']) ? (raw['data'] as JsonObject) : raw;

  const roots = CONTENT_ROOTS.filter((k) => body[k] !== undefined).map((k) => body[k]);
  return roots.length > 0 ? roots : [body];
}
