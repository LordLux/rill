#!/usr/bin/env bun
import { startRpcServer } from './rpc/server.ts';
import { logger } from './log.ts';

const log = logger('main');

/**
 * Parent PID watch — the non-cooperative half of orphan prevention (F17).
 *
 * Parsed and validated once, up front. `parseInt` on a malformed value yields
 * `NaN`, and `process.kill(NaN, 0)` throws — inside the `catch` whose whole
 * premise is "the throw means the parent is gone". A typo in the environment
 * would therefore have killed a perfectly healthy sidecar three seconds after
 * start, and the symptom would be a sidecar that dies for no visible reason.
 *
 * With no usable pid the watch simply does not run. That is a real loss of
 * capability, so it is logged rather than left to be inferred: the broken stdin
 * pipe still ends the sidecar on parent death (measured 2026-08-06, both
 * mechanisms work independently), but the belt-and-braces is gone.
 */
const parentPid = Number.parseInt(process.env.FLUTTER_PARENT_PID ?? '', 10);
if (Number.isInteger(parentPid) && parentPid > 0) {
  setInterval(() => {
    try {
      process.kill(parentPid, 0);
    } catch {
      // The parent is gone. Optional catch binding: the error carries nothing
      // this needs — its existence *is* the signal.
      process.exit(0);
    }
  }, 3000).unref();
} else if (process.env.FLUTTER_PARENT_PID !== undefined) {
  log.warn(
    `FLUTTER_PARENT_PID is not a pid (${JSON.stringify(process.env.FLUTTER_PARENT_PID)}); ` +
      'parent watch disabled, relying on stdin close alone',
  );
}

startRpcServer();
