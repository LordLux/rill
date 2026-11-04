/**
 * `release/release-labelled.ts`: a merged pull request is released only when it carries the label.
 *
 * Tested like `next-version.ts` and `release-needed.ts`: the rule as a table, the history it reads
 * against a real repository, and the script's two safe exits (no previous release, and anything it
 * cannot find out) without a network. What `gh` answers is injected; the one call that asks it is
 * three lines and runs only in the workflow.
 */

import { afterAll, describe, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decide, hasLabel, pullRequestNumber, subjectsSince } from '../../release/release-labelled.ts';

const ROOT = join(import.meta.dir, '..', '..');
const SCRIPT = join(ROOT, 'release', 'release-labelled.ts');
const roots: string[] = [];
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

class Repo {
  readonly dir: string;
  private n = 0;
  constructor() {
    this.dir = mkdtempSync(join(tmpdir(), 'rill-labelled-'));
    roots.push(this.dir);
    this.git('init', '-q', '-b', 'main');
    this.git('config', 'user.email', 'test@example.invalid');
    this.git('config', 'user.name', 'test');
    this.git('config', 'commit.gpgsign', 'false');
  }
  git(...args: string[]): string {
    const result = Bun.spawnSync(['git', ...args], { cwd: this.dir, stdout: 'pipe', stderr: 'pipe' });
    if (!result.success) throw new Error(`git ${args.join(' ')}: ${result.stderr.toString()}`);
    return result.stdout.toString();
  }
  commit(message: string): void {
    writeFileSync(join(this.dir, 'file.txt'), `${message} ${(this.n += 1)}\n`);
    this.git('add', '.');
    this.git('commit', '-q', '-m', message);
  }
}

function run(args: string[], env: Record<string, string | undefined> = {}, cwd = ROOT): { out: string; err: string } {
  const result = Bun.spawnSync(['bun', SCRIPT, ...args], { cwd, env: { ...process.env, GITHUB_REPOSITORY: undefined, ...env }, stdout: 'pipe', stderr: 'pipe' });
  return { out: result.stdout.toString().trim(), err: result.stderr.toString() };
}

describe('pullRequestNumber', () => {
  test.each([
    ['Merge pull request #29 from LordLux/feat/quality-video-add', 29],
    ['feat(player): a quality switch is made in a second player (#32)', 32],
    ['feat(player): a quality switch is made in a second player (#32)  ', 32],
    ['docs: a plain commit', null],
    ['fix: mentions #7 in the middle', null],
    ['Revert "feat: a thing (#7)"', null],
  ])('%s', (subject, expected) => {
    expect(pullRequestNumber(subject)).toBe(expected);
  });
});

describe('decide', () => {
  const labelledOnly = (...numbers: number[]) => (n: number) => numbers.includes(n);

  test('an unlabelled pull request does not release', () => {
    const decision = decide(['Merge pull request #5 from a/b'], labelledOnly());
    expect(decision.wanted).toBe(false);
    expect(decision.pullRequests).toEqual([5]);
  });

  test('a labelled one does, whichever way it was merged', () => {
    expect(decide(['Merge pull request #5 from a/b'], labelledOnly(5)).wanted).toBe(true);
    expect(decide(['something (#6)'], labelledOnly(6)).wanted).toBe(true);
  });

  test('a commit pushed to main still releases: the label is about pull requests', () => {
    const decision = decide(['Merge pull request #5 from a/b', 'fix: pushed straight to main'], labelledOnly());
    expect(decision.wanted).toBe(true);
    expect(decision.ordinary).toBe(1);
  });

  test('one labelled pull request among unlabelled ones releases them all', () => {
    const decision = decide(['one (#1)', 'two (#2)', 'three (#3)'], labelledOnly(2));
    expect(decision.wanted).toBe(true);
    expect(decision.labelled).toEqual([2]);
  });

  test('nothing since the release is nothing wanted', () => {
    expect(decide([], labelledOnly(1)).wanted).toBe(false);
  });

  test('the label is asked only about pull requests', () => {
    const asked: number[] = [];
    decide(['plain', 'one (#1)', 'Merge pull request #2 from a/b'], (n) => {
      asked.push(n);
      return false;
    });
    expect(asked).toEqual([1, 2]);
  });
});

describe('subjectsSince, against a real history', () => {
  test('is oldest first, first-parent only, and after the tag', () => {
    const repo = new Repo();
    repo.commit('initial');
    repo.git('tag', 'v0.1.0');
    repo.git('checkout', '-q', '-b', 'topic');
    repo.commit('work on the topic');
    repo.git('checkout', '-q', 'main');
    repo.git('merge', '--no-ff', '-q', '-m', 'Merge pull request #4 from a/topic', 'topic');
    repo.commit('docs: after the merge');
    expect(subjectsSince('v0.1.0', repo.dir)).toEqual(['Merge pull request #4 from a/topic', 'docs: after the merge']);
  });

  test('an unknown tag is an error, which the script turns into releasing', () => {
    const repo = new Repo();
    repo.commit('initial');
    expect(() => subjectsSince('v9.9.9', repo.dir)).toThrow();
  });
});

describe('hasLabel, against a gh that is not GitHub', () => {
  // The workflow's `gh` is the real one; this one is a Bun script that answers from a file, so the
  // arguments it is asked with, and how its JSON is read, are checked without a network.
  const dir = mkdtempSync(join(tmpdir(), 'rill-fake-gh-'));
  roots.push(dir);
  const log = join(dir, 'args.txt');
  // Their behaviour is in the file, not in the environment: Bun does not hand a child the
  // environment changes made after it started.
  const answers = join(dir, 'answers.ts');
  writeFileSync(
    answers,
    [
      "import { writeFileSync } from 'node:fs';",
      `writeFileSync(${JSON.stringify(log)}, process.argv.slice(2).join(' '));`,
      "process.stdout.write(JSON.stringify({ labels: [{ name: 'bug' }, { name: 'release' }] }));",
    ].join('\n'),
  );
  const fails = join(dir, 'fails.ts');
  writeFileSync(fails, "process.stderr.write('boom');\nprocess.exit(1);\n");

  test('finds the label among the others, and asks gh for exactly that pull request', () => {
    expect(hasLabel('o/r', 7, 'release', ['bun', answers])).toBe(true);
    expect(hasLabel('o/r', 7, 'nope', ['bun', answers])).toBe(false);
    expect(readFileSync(log, 'utf8').trim()).toBe('pr view 7 --repo o/r --json labels');
  });

  test('a gh that fails throws, so the script releases instead of guessing', () => {
    expect(() => hasLabel('o/r', 7, 'release', ['bun', fails])).toThrow(/gh pr view #7 failed: boom/);
  });
});

describe('the script', () => {
  test('with no previous release, the first one is made', () => {
    const { out, err } = run([]);
    expect(out).toBe('true');
    expect(err).toContain('no previous release');
  });

  test('what it cannot find out releases rather than guessing that nobody wanted one', () => {
    const repo = new Repo();
    repo.commit('initial');
    // No --repo and no GITHUB_REPOSITORY, so it stops before it would ask gh anything.
    const { out, err } = run(['--since', 'v0.1.0'], {}, repo.dir);
    expect(out).toBe('true');
    expect(err).toContain('releasing to be safe');
  });
});

describe('the workflow', () => {
  // A rule nobody runs is no rule: the plan job has to ask, and a person's dispatch has to skip it.
  const workflow = readFileSync(join(ROOT, '.github', 'workflows', 'release.yml'), 'utf8');

  test('the plan job asks the script, and not for a dispatch', () => {
    const asked = workflow.indexOf('bun release/release-labelled.ts');
    expect(asked).toBeGreaterThan(-1);
    const before = workflow.slice(Math.max(0, asked - 300), asked);
    expect(before).toContain('"$EVENT" != workflow_dispatch');
  });
});
