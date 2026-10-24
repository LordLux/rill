// Whether there is anything to release since the latest release. Run by the plan job:
//
//   bun release/release-needed.ts --since v0.12.0   # prints true or false
//
// A commit that changes only files the shipped app and installer do not contain (docs, the
// todo reader, scratch notes, the shell wrappers) is not worth an installer. This used to be
// `paths-ignore` on the push trigger, which a scheduled run ignores, so a docs-only commit was
// still released overnight. Here it is one rule that every trigger goes through, and the one
// list of what does not count.
//
// `workflow_dispatch` does not ask: a person starting a run wants it built.

import { parseArgs } from 'node:util';

/** What a release does not ship. Anything else changed since the last release is worth one. */
export const NOT_SHIPPED: readonly string[] = [
  'docs/**',
  '**/*.md',
  'scratch/**',
  'sidecar/scratch/**',
  'spiking/**',
  'tools/**',
  '.mcp.json',
  'setup.bat',
  'rill.ps1',
  'rill.bat',
];

const globs = NOT_SHIPPED.map((pattern) => new Bun.Glob(pattern));

export function isNotShipped(file: string): boolean {
  const normal = file.replaceAll('\\', '/');
  return globs.some((glob) => glob.match(normal));
}

/** True when `files` leaves something worth releasing. An empty change is nothing to release. */
export function releaseNeeded(files: readonly string[]): boolean {
  return files.some((file) => !isNotShipped(file));
}

function git(args: string[], cwd?: string): string {
  const result = Bun.spawnSync(['git', ...args], { cwd, stdout: 'pipe', stderr: 'pipe' });
  if (!result.success) throw new Error(`git ${args[0] ?? ''} failed: ${result.stderr.toString().trim()}`);
  return result.stdout.toString();
}

/** Files that differ between `since` and HEAD, by their final names (a rename counts both ends). */
export function changedSince(since: string, cwd?: string): string[] {
  return git(['diff', '--name-only', '--no-renames', `${since}..HEAD`], cwd)
    .split('\n')
    .filter((line) => line !== '');
}

function main(): void {
  const { values } = parseArgs({ options: { since: { type: 'string' } } });
  if (!values.since) {
    // No release yet: everything is new.
    process.stderr.write('release-needed: no previous release, so there is one to make\n');
    process.stdout.write('true\n');
    return;
  }
  let files: string[];
  try {
    files = changedSince(values.since);
  } catch (error) {
    // Unknown: build rather than guess that nothing shipped.
    process.stderr.write(`release-needed: ${error instanceof Error ? error.message : error}; releasing to be safe\n`);
    process.stdout.write('true\n');
    return;
  }
  const shipped = files.filter((file) => !isNotShipped(file));
  process.stderr.write(
    `release-needed: ${files.length} file(s) changed since ${values.since}, ${shipped.length} of them shipped` +
      (shipped.length > 0 ? ` (${shipped.slice(0, 5).join(', ')}${shipped.length > 5 ? ', …' : ''})` : '') +
      '\n',
  );
  process.stdout.write(`${shipped.length > 0}\n`);
}

if (import.meta.main) main();
