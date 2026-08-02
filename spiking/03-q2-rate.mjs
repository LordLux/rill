#!/usr/bin/env node
/**
 * Spike 03 / Q2 addendum — is open-ended delivery paced?
 *
 * Check 3 measured 2.11 MB/s on itag 401 over an open-ended range, against Task
 * 02's 10.9-23.3 MB/s on the same client over bounded ranges. Both are above the
 * 1.5 MB/s bar, so the check passes either way — but a 5x gap that shows up only
 * on the request shape mpv actually uses is worth pinning down before someone
 * later reads it as a regression.
 *
 * Same URL, same moment, bounded vs open-ended, two sample sizes.
 *
 *   node 03-q2-rate.mjs
 */

import { readFile } from 'node:fs/promises';

const OUT = new URL('./03-out/', import.meta.url);
const C = { r: '\x1b[31m', g: '\x1b[32m', y: '\x1b[33m', b: '\x1b[36m', d: '\x1b[2m', x: '\x1b[0m' };

async function measure(url, { bounded, bytes }) {
  const ctl = new AbortController();
  const timeout = setTimeout(() => ctl.abort(), 120_000);
  const started = Date.now();
  let received = 0;
  let firstByteMs = null;
  try {
    const res = await fetch(url, {
      headers: { Range: bounded ? `bytes=0-${bytes - 1}` : 'bytes=0-' },
      signal: ctl.signal,
    });
    if (res.status !== 206 && res.status !== 200) return { status: res.status };
    for await (const chunk of res.body) {
      if (firstByteMs === null) firstByteMs = Date.now() - started;
      received += chunk.length;
      if (received >= bytes) break;
    }
    const seconds = (Date.now() - started) / 1000;
    return { status: res.status, mbps: received / 1024 / 1024 / seconds, received, seconds, firstByteMs };
  } catch (e) {
    return { status: 'ERR', error: e.message };
  } finally {
    clearTimeout(timeout);
    ctl.abort();
  }
}

const urls = JSON.parse(await readFile(new URL('q2-urls.json', OUT), 'utf8'));

console.log(`${C.b}Spike 03 / Q2 addendum — bounded vs open-ended delivery rate${C.x}`);
console.log(`${C.d}urls captured ${urls.capturedAt}${C.x}\n`);

for (const key of ['av1', 'vp9', 'audio']) {
  const f = urls[key];
  if (!f?.url) continue;
  console.log(`${C.b}${key} — itag ${f.itag}  ${f.mimeType}${C.x}`);
  for (const bytes of [12 * 1024 * 1024, 40 * 1024 * 1024]) {
    for (const bounded of [true, false]) {
      const r = await measure(f.url, { bounded, bytes });
      const mb = (bytes / 1024 / 1024).toFixed(0);
      if (r.mbps === undefined) {
        console.log(`  ${(bounded ? 'bounded ' : 'open-end').padEnd(9)} ${mb.padStart(2)} MB  ${C.r}HTTP ${r.status}${C.x} ${r.error ?? ''}`);
        continue;
      }
      const tone = r.mbps > 8 ? C.g : r.mbps > 1.5 ? C.y : C.r;
      console.log(
        `  ${(bounded ? 'bounded ' : 'open-end').padEnd(9)} ${mb.padStart(2)} MB  ` +
          `${tone}${r.mbps.toFixed(2)} MB/s${C.x}  ${C.d}${r.seconds.toFixed(1)}s, ttfb ${r.firstByteMs}ms${C.x}`,
      );
    }
  }
  console.log('');
}
