#!/usr/bin/env node
/**
 * Node extractor — pulls the full JSON of specific renderer types out of the
 * fixtures so you can write the domain model against real shapes instead of
 * guessing at field names.
 *
 * Run:  node dump-nodes.mjs
 *       node dump-nodes.mjs LockupView ChipView        (specific types only)
 *
 * Writes one file per type to ./nodes/<Type>.json containing every instance found.
 */

import { readdir, readFile, writeFile, mkdir } from 'node:fs/promises';

const FIXTURE_DIR = new URL('./fixtures/', import.meta.url);
const OUT_DIR = new URL('./nodes/', import.meta.url);

// The types that actually matter for the domain model, based on the histogram.
const DEFAULT_TARGETS = [
  'LockupView',                            // the video tile
  'LockupMetadataView',                    // title / channel / metadata
  'CollectionThumbnailView',               // Mix + playlist tiles
  'ThumbnailHoverOverlayToggleActionsView',// Watch Later / queue buttons
  'ThumbnailHoverOverlayView',             // possible hover-preview container
  'ChipView',                              // dynamic topic chips
  'ChipsShelfView',                        // chip strip container
  'ContinuationItem',                      // infinite scroll token
  'ThumbnailBadgeView',                    // duration / LIVE / MIX badges
];

const targets = process.argv.slice(2).length ? process.argv.slice(2) : DEFAULT_TARGETS;

function walk(node, fn, path = '$', depth = 0, seen = new Set()) {
  if (!node || typeof node !== 'object' || depth > 40 || seen.has(node)) return;
  seen.add(node);
  fn(node, path);
  const entries = Array.isArray(node)
    ? node.map((v, i) => [`[${i}]`, v])
    : Object.entries(node).map(([k, v]) => [`.${k}`, v]);
  for (const [seg, v] of entries) walk(v, fn, path + seg, depth + 1, seen);
}

/** Trim deep noise so the output stays readable. */
function prune(node, depth = 0) {
  if (node === null || typeof node !== 'object') return node;
  if (depth > 6) return '…truncated…';
  if (Array.isArray(node)) return node.slice(0, 6).map((v) => prune(v, depth + 1));
  const out = {};
  for (const [k, v] of Object.entries(node)) {
    // tracking_params and logging blobs are pure noise for modelling purposes
    if (/tracking_params|logging_directives|loggingDirectives|clickTracking/i.test(k)) continue;
    out[k] = prune(v, depth + 1);
  }
  return out;
}

async function main() {
  const files = (await readdir(FIXTURE_DIR)).filter((f) => f.endsWith('.json'));
  await mkdir(OUT_DIR, { recursive: true });

  const collected = new Map(targets.map((t) => [t, []]));

  for (const file of files) {
    let data;
    try { data = JSON.parse(await readFile(new URL(file, FIXTURE_DIR), 'utf8')); }
    catch { continue; }

    walk(data, (node, path) => {
      if (typeof node?.type === 'string' && collected.has(node.type)) {
        collected.get(node.type).push({ _file: file, _path: path, ...prune(node) });
      }
    });
  }

  console.log('');
  for (const [type, instances] of collected) {
    if (!instances.length) {
      console.log(`  \x1b[33m—\x1b[0m ${type.padEnd(42)} not present in fixtures`);
      continue;
    }
    // Keep the first 3 — enough to see optional fields without drowning.
    await writeFile(
      new URL(`${type}.json`, OUT_DIR),
      JSON.stringify(instances.slice(0, 3), null, 2)
    );
    console.log(`  \x1b[32m✓\x1b[0m ${type.padEnd(42)} ${String(instances.length).padStart(3)} found -> nodes/${type}.json`);
  }

  // Field frequency across all LockupView instances — shows which fields are
  // always present vs optional, which is what the Dart model needs to know.
  const lockups = collected.get('LockupView') ?? [];
  if (lockups.length) {
    const freq = new Map();
    for (const l of lockups) {
      for (const k of Object.keys(l)) {
        if (k.startsWith('_')) continue;
        freq.set(k, (freq.get(k) ?? 0) + 1);
      }
    }
    console.log(`\n  \x1b[36mLockupView field frequency\x1b[0m (${lockups.length} instances)\n`);
    [...freq.entries()].sort((a, b) => b[1] - a[1]).forEach(([k, n]) => {
      const flag = n === lockups.length ? '\x1b[32mrequired\x1b[0m' : '\x1b[33moptional\x1b[0m';
      console.log(`    ${String(n).padStart(3)}/${lockups.length}  ${flag}  ${k}`);
    });
  }
  console.log('');
}

main().catch((e) => { console.error(e); process.exit(1); });
