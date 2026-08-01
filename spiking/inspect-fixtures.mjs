#!/usr/bin/env node
/**
 * Offline fixture inspector.
 *
 * No network. Reads whatever the spike already dumped into ./fixtures/ and answers
 * the questions the spike could only guess at:
 *
 *   - What renderer types does YouTube ACTUALLY serve this account right now?
 *   - Where do chip-like nodes live, and do any of them say "Mixes"?
 *   - Are there Shorts nodes the filter would need to strip?
 *   - Is there any hover-preview media (mp4/webm) anywhere in the tree?
 *
 * Run:  node inspect-fixtures.mjs
 */

import { readdir, readFile } from 'node:fs/promises';

const FIXTURE_DIR = new URL('./fixtures/', import.meta.url);
const C = { g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };

/** Walk every node, invoking fn(node, path). */
function walk(node, fn, path = '$', depth = 0, seen = new Set()) {
  if (!node || typeof node !== 'object' || depth > 40 || seen.has(node)) return;
  seen.add(node);
  fn(node, path);
  if (Array.isArray(node)) {
    node.forEach((v, i) => walk(v, fn, `${path}[${i}]`, depth + 1, seen));
  } else {
    for (const [k, v] of Object.entries(node)) {
      walk(v, fn, `${path}.${k}`, depth + 1, seen);
    }
  }
}

/** Pull any human-readable label off a node, whatever shape it takes. */
function labelOf(node) {
  const candidates = [
    node?.text?.text, node?.text, node?.label, node?.title?.text, node?.title,
    node?.content, node?.accessibility_text, node?.chipText, node?.simpleText,
  ];
  for (const c of candidates) {
    if (typeof c === 'string' && c.trim()) return c.trim();
  }
  return null;
}

async function main() {
  let files;
  try {
    files = (await readdir(FIXTURE_DIR)).filter((f) => f.endsWith('.json') && f !== '_results.json');
  } catch {
    console.error('No ./fixtures/ directory. Run spike.mjs first.');
    process.exit(1);
  }

  const typeCounts = new Map();
  const chipHits = [];
  const shortsHits = [];
  const mediaHits = [];
  const mixMentions = [];

  for (const file of files) {
    let data;
    try {
      data = JSON.parse(await readFile(new URL(file, FIXTURE_DIR), 'utf8'));
    } catch (e) {
      console.error(`  skip ${file}: ${e.message}`);
      continue;
    }

    walk(data, (node, path) => {
      const t = node?.type;
      if (typeof t === 'string') {
        typeCounts.set(t, (typeCounts.get(t) ?? 0) + 1);

        if (/chip/i.test(t)) {
          chipHits.push({ file, path, type: t, label: labelOf(node) });
        }
        if (/short|reel/i.test(t)) {
          shortsHits.push({ file, path, type: t, label: labelOf(node) });
        }
      }

      // Any playable media URL — moving thumbnails, storyboards, previews.
      for (const [k, v] of Object.entries(node)) {
        if (typeof v === 'string' && /\.(mp4|webm)(\?|$)/i.test(v)) {
          mediaHits.push({ file, path: `${path}.${k}`, url: v.slice(0, 110) });
        }
        if (typeof v === 'string' && /\bmix(es)?\b/i.test(v) && v.length < 60) {
          mixMentions.push({ file, path: `${path}.${k}`, value: v });
        }
      }
    });
  }

  const line = (s) => console.log(s);

  line(`\n${C.b}RENDERER TYPE HISTOGRAM${C.x} ${C.d}(${typeCounts.size} distinct across ${files.length} fixtures)${C.x}\n`);
  [...typeCounts.entries()]
    .sort((a, b) => b[1] - a[1])
    .forEach(([t, n]) => line(`  ${String(n).padStart(4)}  ${t}`));

  line(`\n${C.b}CHIP-LIKE NODES${C.x} ${C.d}(${chipHits.length})${C.x}\n`);
  if (!chipHits.length) {
    line(`  ${C.y}none — the filter bar is genuinely absent from these fixtures${C.x}`);
  } else {
    for (const h of chipHits.slice(0, 60)) {
      line(`  ${h.type.padEnd(28)} ${h.label ? `"${h.label}"` : C.d + '(no label)' + C.x}`);
      line(`  ${C.d}${h.file} ${h.path}${C.x}`);
    }
  }

  line(`\n${C.b}"MIX" STRING MENTIONS${C.x} ${C.d}(${mixMentions.length})${C.x}\n`);
  if (!mixMentions.length) {
    line(`  ${C.y}none — no Mixes chip or shelf in this feed sample${C.x}`);
  } else {
    for (const m of mixMentions.slice(0, 25)) {
      line(`  "${m.value}"  ${C.d}${m.file} ${m.path}${C.x}`);
    }
  }

  line(`\n${C.b}SHORTS / REEL NODES${C.x} ${C.d}(${shortsHits.length})${C.x}\n`);
  if (!shortsHits.length) {
    line(`  ${C.y}none found — verify against youtube.com before trusting this${C.x}`);
  } else {
    const byType = new Map();
    for (const h of shortsHits) byType.set(h.type, (byType.get(h.type) ?? 0) + 1);
    for (const [t, n] of byType) line(`  ${String(n).padStart(4)}  ${t}`);
  }

  line(`\n${C.b}PLAYABLE MEDIA URLS (hover-preview candidates)${C.x} ${C.d}(${mediaHits.length})${C.x}\n`);
  if (!mediaHits.length) {
    line(`  ${C.y}none — feed carries no moving thumbnails.${C.x}`);
    line(`  ${C.d}Fallback: player-response storyboards (sprite sheets) animated on hover.${C.x}`);
  } else {
    for (const m of mediaHits.slice(0, 15)) {
      line(`  ${C.d}${m.path}${C.x}`);
      line(`    ${m.url}`);
    }
  }

  line('');
}

main().catch((e) => { console.error(e); process.exit(1); });
