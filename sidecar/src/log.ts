/**
 * Logging — stderr only.
 *
 * Hard invariant 3: stdout is protocol. Everything here writes to stderr through
 * `process.stderr.write`, never `console.log`. The eslint config bans the
 * alternatives so this cannot regress quietly.
 *
 * Also home to the unknown-renderer registry. When YouTube ships a renderer we
 * do not recognise, the parser skips the node and records the type here — once
 * per type per run, with a running count. That log is the early-warning system
 * for "YouTube changed something and items are silently disappearing".
 */

import { redact } from './redact.ts';

const LEVELS = ['debug', 'info', 'warn', 'error'] as const;
export type LogLevel = (typeof LEVELS)[number];

const envLevel = (process.env.SIDECAR_LOG_LEVEL ?? 'info').toLowerCase();
const threshold = LEVELS.indexOf(envLevel as LogLevel);
const minLevel = threshold === -1 ? LEVELS.indexOf('info') : threshold;

/**
 * One write, one redaction pass.
 *
 * Task 22 §5. Every log line in the sidecar goes through here, so this is the
 * cheapest place to make "no cookie ever reaches stderr" a property of the
 * transport rather than a rule each call site has to remember. The sidecar's
 * own code never interpolates a cookie; what this catches is a *third party*
 * doing it — youtubei.js quoting a failed request, a fetch rejection carrying
 * headers — which is unreachable by reading this repo and silent when it
 * happens. See `redact.ts`.
 */
function emit(level: LogLevel, scope: string, message: string): void {
  if (LEVELS.indexOf(level) < minLevel) return;
  const stamp = new Date().toISOString();
  process.stderr.write(`${stamp} ${level.toUpperCase().padEnd(5)} [${scope}] ${redact(message)}\n`);
}

export interface Logger {
  debug(message: string): void;
  info(message: string): void;
  warn(message: string): void;
  error(message: string): void;
}

export function logger(scope: string): Logger {
  return {
    debug: (m) => emit('debug', scope, m),
    info: (m) => emit('info', scope, m),
    warn: (m) => emit('warn', scope, m),
    error: (m) => emit('error', scope, m),
  };
}

// ---------------------------------------------------------------------------
// Unknown-renderer registry
// ---------------------------------------------------------------------------

const unknownRenderers = new Map<string, number>();
const announced = new Set<string>();
const log = logger('parser');

/**
 * Record a renderer type the parser does not handle.
 *
 * The first sighting logs immediately (so a live capture shows it in context);
 * later sightings only bump the counter, which `unknownRendererSummary()` prints
 * at the end of a run. Never throws — hard invariant 4.
 */
export function noteUnknownRenderer(type: string, context = 'feed'): void {
  const key = `${context}:${type}`;
  unknownRenderers.set(key, (unknownRenderers.get(key) ?? 0) + 1);
  if (!announced.has(key)) {
    announced.add(key);
    log.warn(`unknown renderer '${type}' in ${context} — item skipped`);
  }
}

/** Snapshot of every unknown renderer seen this run, highest count first. */
export function unknownRendererCounts(): Array<{ type: string; count: number }> {
  return [...unknownRenderers.entries()]
    .map(([type, count]) => ({ type, count }))
    .sort((a, b) => b.count - a.count);
}

/** Write the accumulated unknown-renderer table to stderr. Safe to call repeatedly. */
export function logUnknownRendererSummary(): void {
  const counts = unknownRendererCounts();
  if (counts.length === 0) {
    log.info('unknown renderers: none — full vocabulary coverage on this run');
    return;
  }
  const total = counts.reduce((sum, c) => sum + c.count, 0);
  log.warn(`unknown renderers: ${counts.length} type(s), ${total} node(s) skipped`);
  for (const { type, count } of counts) {
    log.warn(`  ${String(count).padStart(5)}  ${type}`);
  }
}

/** Test seam — resets the per-run registry. */
export function resetUnknownRenderers(): void {
  unknownRenderers.clear();
  announced.clear();
}
