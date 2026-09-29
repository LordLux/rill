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
 * anonymous ladder. `resolve.ts`'s `PlaybackDeps.poTokens` defaults to
 * `nullPoTokenProvider`, so simply omitting the argument is correct —
 * checked by absence, not by asserting a specific default value the source
 * scan cannot see past a dynamic import anyway.
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
});
