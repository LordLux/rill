/**
 * What this installation can actually do — probed once, said out loud.
 *
 * There is exactly one optional piece today: `yt-dlp`, ladder tier 4. It is a
 * fallback rather than a dependency, so its absence must not stop the sidecar
 * starting — but it must not be silent either. Without it the ladder is four
 * rungs instead of five, and the rung that disappears is the one that exists for
 * age-restricted and Vevo videos. Those then resolve to "Unavailable" with
 * nothing anywhere saying that a missing binary is the reason, which reads to a
 * user as a broken app and to us as a broken extractor.
 *
 * So: warn at startup, and report it in the `event.ready` handshake
 * (`protocol.md` §2) so the app knows too rather than inferring it from a video
 * that will not play.
 *
 * The probe is a lookup, not an execution — spawning `yt-dlp --version` to find
 * out whether it exists costs a process on every start to learn what a PATH
 * lookup already says.
 */

import { existsSync } from 'node:fs';

import { logger } from './log.ts';
import type { Capabilities } from './types.ts';

const log = logger('capabilities');

/**
 * The binary tier 4 will spawn: whatever was configured, or the conventional
 * name. Says nothing about whether it exists — `tierYtDlp` names it in its
 * decline either way, and a wrong `YT_DLP_PATH` should appear in that message
 * rather than being quietly replaced with something else.
 */
export function ytDlpBinary(override?: string): string {
  return override ?? process.env['YT_DLP_PATH'] ?? 'yt-dlp';
}

/**
 * The same binary, resolved to something that is actually there — or `null`.
 *
 * A configured path is checked on disk; a bare name goes through PATH. Both
 * forms are in use: `YT_DLP_PATH` is usually a full path on Windows, and a
 * developer machine usually just has it on PATH.
 */
export function resolveYtDlp(override?: string): string | null {
  const binary = ytDlpBinary(override);
  if (binary.includes('/') || binary.includes('\\')) {
    return existsSync(binary) ? binary : null;
  }
  return Bun.which(binary);
}

/** What this machine can do, as the handshake reports it. */
export function probeCapabilities(ytDlpPath?: string): Capabilities {
  return { ytDlp: resolveYtDlp(ytDlpPath) !== null };
}

/**
 * Probe and log. Call once at startup, before serving anything.
 *
 * Separate from `probeCapabilities` so the probe stays free of side effects and
 * can be called again — by the handshake, or by a test — without a second round
 * of warnings in the log.
 */
export function announceCapabilities(ytDlpPath?: string): Capabilities {
  const capabilities = probeCapabilities(ytDlpPath);
  const resolved = resolveYtDlp(ytDlpPath);

  if (capabilities.ytDlp) {
    log.info(`yt-dlp: ${resolved}`);
  } else {
    log.warn(
      `yt-dlp not found (looked for '${ytDlpBinary(ytDlpPath)}'). Ladder tier 4 is ` +
        'unavailable, so age-restricted and Vevo videos will fail with ' +
        'STREAM_UNAVAILABLE. Install it or set YT_DLP_PATH.',
    );
  }

  return capabilities;
}
