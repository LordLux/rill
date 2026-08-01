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
 */
export function get(root: Json, ...path: string[]): unknown {
  let cursor: unknown = root;
  for (const segment of path) {
    if (!isObject(cursor)) return null;
    cursor = cursor[segment];
  }
  return cursor ?? null;
}

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
