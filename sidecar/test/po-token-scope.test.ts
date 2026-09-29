/**
 * The anonymous ladder stays token-free — asserted over the source, offline.
 *
 * F49: wiring `botguardPoTokenProvider` into the main `openPlayback` call was
 * pulled back after a report of mpv failing to open an ordinary video
 * immediately after this exact line attached a token to it — suggestive, but
 * never independently confirmed as the actual cause (the same failure text
 * has occurred before, rarely, with no token involved). The pullback does
 * not rest on that one incident: `/player` tolerating a PO token (F48) was
 * never evidence that the *signed stream URL* — the thing mpv actually opens
 * — tolerates one too, and nothing had verified that before this shipped;
 * only the age-restricted retry's own throwaway `WEB_CREATOR` session is
 * verified end to end (a real byte fetch, not just an `OK` status). This is
 * hard invariant 8's shape again, one layer down: a response looking right
 * is not evidence the URL built from it works.
 *
 * There is no offline way to prove a token breaks streaming — that needs a
 * real `videoplayback` fetch, which is `network.test.ts`'s job. What *can*
 * be checked cheaply and every time is the shape of the regression itself:
 * `playback.open`'s handler must not pass a real `PoTokenProvider` to the
 * anonymous ladder.
 *
 * **A second, deeper coupling was found the same way — live, against a real
 * broken `css-tree` patch, 2026-09-30.** `resolve.ts` used to import
 * `nullPoTokenProvider` — a runtime value, not just the `PoTokenProvider`
 * type — from `po-token.ts`, purely as `(deps.poTokens ?? nullPoTokenProvider)`'s
 * fallback. Since `resolve.ts` is what every single `playback.open` call
 * loads to resolve the ladder, that runtime import meant a broken
 * `po-token.ts` (the exact shape a lost `css-tree` patch takes) could take
 * the *entire anonymous ladder* down with it — not just the age-restricted
 * retry the scope test above is about. Measured directly: with the patch
 * reverted and the sidecar compiled, `nullPoTokenProvider` resolved to
 * `undefined` rather than the import rejecting outright (Bun does not
 * re-throw on a second `import()` of an already-broken module; it silently
 * hands back a module whose exports are `undefined`), and `openPlayback`
 * crashed with `undefined is not an object (evaluating '(deps.poTokens ??
 * nullPoTokenProvider).mint')` on *every* video, ordinary ones included.
 * `resolve.ts` now imports only `type PoTokenProvider` — erased at compile
 * time, so nothing about `po-token.ts` succeeding or failing can reach it —
 * and inlines the fallback (`deps.poTokens ? await deps.poTokens.mint(...) :
 * null`) instead.
 */

import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SRC = join(dirname(fileURLToPath(import.meta.url)), '..', 'src');

/** Mirrors `resolve-anonymous.test.ts`'s helper — kept local rather than shared across two small files for one string. */
function handlerSource(server: string, method: string): string {
  const start = server.indexOf(`method === '${method}'`);
  if (start === -1) return '';
  const next = server.indexOf('} else if (method ===', start + 1);
  return server.slice(start, next === -1 ? undefined : next);
}

describe('the anonymous ladder never gets a real PoTokenProvider (F49)', () => {
  test('the openPlayback call inside playback.open passes no poTokens', () => {
    const server = readFileSync(join(SRC, 'rpc', 'server.ts'), 'utf8');
    const handler = handlerSource(server, 'playback.open');
    expect(handler.length).toBeGreaterThan(0);

    // The call that resolves the anonymous ladder — deliberately distinct
    // from the age-restricted retry's own `resolveAgeRestricted({ ...,
    // poTokens: botguardPoTokenProvider, ... })` a few lines below it, which
    // is expected to carry one and is not what this test is about.
    const ladderCall = handler.match(/openPlayback\(\s*\{[^}]*\}/);
    expect(ladderCall, 'could not find the openPlayback({...}, ...) call in playback.open').not.toBeNull();
    expect(
      ladderCall![0],
      'openPlayback in playback.open must not pass poTokens — F49: never ' +
        'verified against a real stream fetch, only a /player metadata response',
    ).not.toContain('poTokens');
  });

  test('resolve.ts imports nothing runtime from po-token.ts — type only', () => {
    const resolveSrc = readFileSync(join(SRC, 'playback', 'resolve.ts'), 'utf8');
    const imports = [...resolveSrc.matchAll(/^import\b.*from ['"]\.\/po-token\.ts['"];?$/gm)];
    expect(imports.length, 'expected exactly one import from po-token.ts in resolve.ts').toBe(1);
    expect(
      imports[0]![0],
      'a runtime import from po-token.ts in resolve.ts couples every playback.open call to ' +
        'po-token.ts (and jsdom/bgutils-js/css-tree) importing successfully — measured live: a ' +
        'broken css-tree patch took the whole anonymous ladder down with it, ordinary videos ' +
        'included, not just the age-restricted retry. Only `import type` is safe here.',
    ).toMatch(/^import type\b/);
  });

  test('the age-restricted retry checks its imported provider before using it', () => {
    // Measured live: a *second* `import('../playback/po-token.ts')` of an
    // already-broken module does not reject the way the first one (the
    // warm-up call) does — it resolves with `botguardPoTokenProvider:
    // undefined`, no thrown error at the import line at all. Without an
    // explicit check here, that `undefined` reaches `resolveAgeRestricted`
    // and fails one layer further away, past this file's own loud log line.
    const server = readFileSync(join(SRC, 'rpc', 'server.ts'), 'utf8');
    const handler = handlerSource(server, 'playback.open');
    expect(handler).toMatch(/if\s*\(\s*!botguardPoTokenProvider\s*\)/);
  });
});
