/**
 * The pull request workflow runs the release gate's checks, copied (`.github/workflows/`), and
 * nothing else makes the two stay the same. This does: the steps of `gate` in release.yml and of
 * `gate` in pull-request.yml are the same text, and so are the pinned versions.
 */
import { describe, expect, test } from 'bun:test';
import * as fs from 'node:fs';
import * as path from 'node:path';

const root = path.resolve(import.meta.dir, '..');
const read = (name: string) => fs.readFileSync(path.join(root, '.github', 'workflows', name), 'utf8').replace(/\r\n/g, '\n');

/** The `gate` job's `steps:` block: from that line to the next job at the same indent, or the end. */
export function gateSteps(workflow: string): string {
  const start = workflow.search(/^ {2}gate:\n/m);
  if (start < 0) throw new Error('no gate job');
  const body = workflow.slice(start);
  const steps = body.search(/^ {4}steps:\n/m);
  if (steps < 0) throw new Error('the gate job has no steps');
  const rest = body.slice(steps);
  const next = rest.slice(1).search(/^ {2}[A-Za-z0-9_-]+:\n/m);
  return (next < 0 ? rest : rest.slice(0, next + 1)).trimEnd();
}

const pin = (workflow: string, name: string) => new RegExp(`^ {2}${name}: '([^']+)'`, 'm').exec(workflow)?.[1];

describe('the pull request gate', () => {
  const release = read('release.yml');
  const pullRequest = read('pull-request.yml');

  test('has the release gate\'s steps, word for word', () => {
    expect(gateSteps(pullRequest)).toBe(gateSteps(release));
  });

  test('pins the same Bun and the same fvm', () => {
    expect(pin(pullRequest, 'BUN_VERSION')).toBeDefined();
    expect(pin(pullRequest, 'BUN_VERSION')).toBe(pin(release, 'BUN_VERSION'));
    expect(pin(pullRequest, 'FVM_VERSION')).toBe(pin(release, 'FVM_VERSION'));
  });

  test('runs on the same runner, with the same limit', () => {
    for (const workflow of [release, pullRequest]) {
      const gate = workflow.slice(workflow.search(/^ {2}gate:\n/m));
      expect(gate).toMatch(/runs-on: windows-latest/);
      expect(gate).toMatch(/timeout-minutes: 60/);
    }
  });

  test('is triggered by pull requests to main and cancels what it supersedes', () => {
    expect(pullRequest).toMatch(/on:\n {2}pull_request:\n {4}branches: \[main\]/);
    expect(pullRequest).toMatch(/cancel-in-progress: true/);
  });

  test('the extraction itself finds a step, so a rename cannot make the comparison vacuous', () => {
    const steps = gateSteps(release);
    expect(steps).toContain('bun run check');
    expect(steps).toContain('test_suite_guard.dart');
    expect(steps.split('\n').length).toBeGreaterThan(20);
  });
});
