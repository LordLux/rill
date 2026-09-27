/**
 * A release's version is a function of git history, so it is tested against real histories.
 *
 * `release/next-version.ts` reads one line from `release/version` — the setting — and counts
 * from the commit that last changed it: a merged pull request adds 1 to the minor and resets
 * the patch, any other commit adds 1 to the patch. What can go wrong is quiet and expensive:
 * the app installs only a strictly higher version, so a wrong number is a release nobody is
 * offered, and a duplicate is two releases that disagree about what they are. So the rules are
 * pinned as pure functions first, then driven through repositories built the way a real one is
 * built — a merge commit for a pull request, an edit to the setting made on the pull
 * request's own branch, a squash commit, a hotfix straight to main.
 */

import { afterAll, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  compareVersions,
  formatVersion,
  isPullRequestMerge,
  parseVersion,
  resolveVersion,
  versionAfter,
} from '../../release/next-version.ts';

const SCRIPT = join(import.meta.dir, '..', '..', 'release', 'next-version.ts');
const v = (text: string) => parseVersion(text);

describe('parseVersion', () => {
  test('reads MAJOR.MINOR.PATCH, with or without the trailing newline', () => {
    expect(v('0.2.0')).toEqual({ major: 0, minor: 2, patch: 0 });
    expect(v('10.20.30\n')).toEqual({ major: 10, minor: 20, patch: 30 });
    expect(v('1.0.0\r\n')).toEqual({ major: 1, minor: 0, patch: 0 });
  });

  test('is strict, because this file is the setting and a typo must fail rather than be guessed at', () => {
    for (const bad of ['', '1.2', 'v1.2.3', '1.2.3.4', '01.2.3', '1.2.x', ' 1.2.3', '1.2.3 ', '1.2.3\n\n', '# comment\n1.2.3', '1,2,3']) {
      expect(() => parseVersion(bad)).toThrow('MAJOR.MINOR.PATCH');
    }
  });
});

describe('compareVersions', () => {
  test('compares numerically, field by field: 0.10.0 is above 0.9.0', () => {
    expect(compareVersions(v('0.10.0'), v('0.9.0'))).toBeGreaterThan(0);
    expect(compareVersions(v('1.0.0'), v('0.99.99'))).toBeGreaterThan(0);
    expect(compareVersions(v('0.2.1'), v('0.2.0'))).toBeGreaterThan(0);
    expect(compareVersions(v('0.2.0'), v('0.2.0'))).toBe(0);
    expect(compareVersions(v('0.1.214'), v('0.2.0'))).toBeLessThan(0);
  });
});

describe('isPullRequestMerge', () => {
  test('recognises a merge commit and a squash commit', () => {
    expect(isPullRequestMerge('Merge pull request #7 from LordLux/release-pipeline')).toBe(true);
    expect(isPullRequestMerge('Add chapters to the progress bar (#12)')).toBe(true);
    expect(isPullRequestMerge('Add chapters to the progress bar (#12)  ')).toBe(true);
  });

  test('does not mistake anything else for one', () => {
    expect(isPullRequestMerge("Merge branch 'main' into feature")).toBe(false);
    expect(isPullRequestMerge('Merge pull request from nowhere')).toBe(false);
    expect(isPullRequestMerge('Fix the (#12) reference in a subject that goes on')).toBe(false);
    expect(isPullRequestMerge('Revert "Add chapters to the progress bar (#12)"')).toBe(false);
    expect(isPullRequestMerge('Pin the runners')).toBe(false);
    expect(isPullRequestMerge('')).toBe(false);
  });
});

describe('versionAfter', () => {
  const at = v('0.2.0');
  const PR = 'Merge pull request #1 from a/b';
  const commit = 'a direct commit';

  test('no commits after the anchor is the anchor', () => {
    expect(formatVersion(versionAfter(at, []))).toBe('0.2.0');
  });

  test('a merged PR adds one to the minor and resets the patch', () => {
    expect(formatVersion(versionAfter(at, [PR]))).toBe('0.3.0');
    expect(formatVersion(versionAfter(v('0.2.7'), [PR]))).toBe('0.3.0');
  });

  test('any other commit adds one to the patch', () => {
    expect(formatVersion(versionAfter(at, [commit]))).toBe('0.2.1');
    expect(formatVersion(versionAfter(at, [commit, commit]))).toBe('0.2.2');
  });

  test('order matters: a PR after two hotfixes resets them, hotfixes after a PR count from zero', () => {
    expect(formatVersion(versionAfter(at, [commit, commit, PR]))).toBe('0.3.0');
    expect(formatVersion(versionAfter(at, [PR, commit, commit]))).toBe('0.3.2');
    expect(formatVersion(versionAfter(at, [PR, commit, 'Squashed thing (#2)', commit]))).toBe('0.4.1');
  });

  test('the major is never touched by counting; only editing the setting moves it', () => {
    expect(versionAfter(v('3.9.9'), [PR, PR, commit]).major).toBe(3);
  });
});

// ---------------------------------------------------------------------------
// Real histories
// ---------------------------------------------------------------------------

const work = mkdtempSync(join(tmpdir(), 'rill-version-'));
afterAll(() => rmSync(work, { recursive: true, force: true }));

class Repo {
  readonly dir: string;
  constructor(name: string) {
    this.dir = join(work, name);
    mkdirSync(this.dir, { recursive: true });
    this.git('init', '-q', '-b', 'main');
  }
  git(...args: string[]): string {
    const result = Bun.spawnSync(
      ['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false', ...args],
      { cwd: this.dir, stdout: 'pipe', stderr: 'pipe' },
    );
    if (!result.success) throw new Error(`git ${args.join(' ')}: ${result.stderr.toString()}`);
    return result.stdout.toString().trim();
  }
  write(path: string, content: string): void {
    const full = join(this.dir, path);
    mkdirSync(join(full, '..'), { recursive: true });
    writeFileSync(full, content);
  }
  commit(message: string, file = 'file.txt', content = `${Math.random()}\n`): string {
    this.write(file, content);
    this.git('add', '-A');
    this.git('commit', '-q', '-m', message);
    return this.git('rev-parse', 'HEAD');
  }
  /** A pull request the way GitHub merges one: commits on a branch, then a --no-ff merge. */
  mergePullRequest(number: number, branchCommits: [string, string?, string?][]): string {
    const branch = `pr-${number}`;
    this.git('checkout', '-q', '-b', branch);
    for (const [message, file, content] of branchCommits) this.commit(message, file, content);
    this.git('checkout', '-q', 'main');
    this.git('merge', '-q', '--no-ff', '-m', `Merge pull request #${number} from someone/${branch}`, branch);
    return this.git('rev-parse', 'HEAD');
  }
  version(rev = 'HEAD'): string {
    return formatVersion(resolveVersion(rev, this.dir).version);
  }
  async cli(...args: string[]): Promise<{ stdout: string; stderr: string; exitCode: number }> {
    const child = Bun.spawn([process.execPath, SCRIPT, ...args], { cwd: this.dir, stdout: 'pipe', stderr: 'pipe' });
    const [stdout, stderr, exitCode] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    return { stdout, stderr, exitCode };
  }
}

describe('resolveVersion on real histories', () => {
  test('counts merged PRs and direct commits after the commit that introduced the setting', () => {
    const repo = new Repo('counting');
    repo.commit('Initial commit');
    const anchor = repo.commit('Introduce the version', 'release/version', '0.2.0\n');
    expect(repo.version()).toBe('0.2.0');

    const pr1 = repo.mergePullRequest(1, [['work'], ['more work']]);
    expect(repo.version()).toBe('0.3.0');

    const hotfix = repo.commit('Hotfix straight to main');
    expect(repo.version()).toBe('0.3.1');

    repo.commit('Squashed feature (#2)');
    expect(repo.version()).toBe('0.4.0');

    repo.mergePullRequest(3, [['x']]);
    expect(repo.version()).toBe('0.5.0');

    // Any earlier commit still has the version it had: a version is a property of a commit.
    expect(repo.version(anchor)).toBe('0.2.0');
    expect(repo.version(pr1)).toBe('0.3.0');
    expect(repo.version(hotfix)).toBe('0.3.1');
  });

  test('a PR with many commits is one merged PR, not many: only the first-parent line is counted', () => {
    const repo = new Repo('many-commits');
    repo.commit('Introduce the version', 'release/version', '0.2.0\n');
    repo.mergePullRequest(1, [['a'], ['b'], ['c'], ['d'], ['e']]);
    expect(repo.version()).toBe('0.3.0');
    // The merge resets the patch, so the version alone cannot tell a counted branch from an
    // uncounted one; the counters can.
    const resolved = resolveVersion('HEAD', repo.dir);
    expect(resolved.pullRequests).toBe(1);
    expect(resolved.otherCommits).toBe(0);
  });

  test('an edit to the setting made on a PR\'s own branch takes effect at the merge that lands it', () => {
    const repo = new Repo('override');
    repo.commit('Introduce the version', 'release/version', '0.2.0\n');
    repo.mergePullRequest(1, [['feature']]);
    repo.commit('Hotfix');
    expect(repo.version()).toBe('0.3.1');

    // The major bump: the setting is edited inside the pull request, not on main.
    const landed = repo.mergePullRequest(2, [['the big change'], ['Set the next version to 1.0.0', 'release/version', '1.0.0\n']]);
    expect(repo.version()).toBe('1.0.0');
    expect(repo.version(landed)).toBe('1.0.0');

    // Counting restarts from the new setting.
    repo.mergePullRequest(3, [['next']]);
    expect(repo.version()).toBe('1.1.0');
    repo.commit('Hotfix again');
    expect(repo.version()).toBe('1.1.1');
  });

  test('the setting can also be lowered or set to any value, and the next release simply follows it', () => {
    const repo = new Repo('set-anything');
    repo.commit('Introduce the version', 'release/version', '0.2.0\n');
    repo.mergePullRequest(1, [['Set 0.9.4', 'release/version', '0.9.4\n']]);
    expect(repo.version()).toBe('0.9.4');
    repo.mergePullRequest(2, [['next']]);
    expect(repo.version()).toBe('0.10.0');
  });

  test('a merge of main back into a branch, or of a branch that is not a PR, is an ordinary commit', () => {
    const repo = new Repo('not-a-pr');
    repo.commit('Introduce the version', 'release/version', '0.2.0\n');
    repo.git('checkout', '-q', '-b', 'topic');
    repo.commit('topic work');
    repo.git('checkout', '-q', 'main');
    repo.git('merge', '-q', '--no-ff', '-m', "Merge branch 'topic'", 'topic');
    expect(repo.version()).toBe('0.2.1');
  });

  test('a rebase-merged PR leaves nothing to recognise, so its commits count as patches', () => {
    const repo = new Repo('rebase');
    repo.commit('Introduce the version', 'release/version', '0.2.0\n');
    repo.commit('first commit of a rebased PR');
    repo.commit('second commit of a rebased PR');
    expect(repo.version()).toBe('0.2.2');
  });

  test('refuses history where the setting was never committed, or has been deleted, or is malformed', () => {
    const none = new Repo('never');
    none.commit('Initial commit');
    expect(() => resolveVersion('HEAD', none.dir)).toThrow('never been committed');

    const deleted = new Repo('deleted');
    deleted.commit('Introduce the version', 'release/version', '0.2.0\n');
    deleted.git('rm', '-q', 'release/version');
    deleted.git('commit', '-q', '-m', 'Remove it');
    expect(() => resolveVersion('HEAD', deleted.dir)).toThrow('was deleted');

    const bad = new Repo('bad');
    bad.commit('Introduce the version', 'release/version', '0.2\n');
    expect(() => resolveVersion('HEAD', bad.dir)).toThrow('MAJOR.MINOR.PATCH');
  });
});

describe('next-version CLI', () => {
  const build = () => {
    const repo = new Repo(`cli-${Math.random().toString(36).slice(2)}`);
    repo.commit('Introduce the version', 'release/version', '0.2.0\n');
    repo.mergePullRequest(1, [['work']]);
    return repo; // 0.3.0
  };

  test('prints only the version on stdout, and the working on stderr', async () => {
    const result = await build().cli();
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toBe('0.3.0\n');
    expect(result.stderr).toContain('0.3.0 = 0.2.0');
    expect(result.stderr).toContain('1 merged PR(s)');
  });

  test('--rev asks about any commit', async () => {
    const repo = build();
    repo.commit('Hotfix');
    expect((await repo.cli('--rev', 'HEAD~1')).stdout).toBe('0.3.0\n');
    expect((await repo.cli()).stdout).toBe('0.3.1\n');
  });

  test('--latest refuses a version below the latest release, and accepts equal or higher', async () => {
    const repo = build(); // 0.3.0
    const below = await repo.cli('--latest', 'v0.4.0');
    expect(below.exitCode).toBe(1);
    expect(below.stdout).toBe('');
    expect(below.stderr).toContain('below the latest release 0.4.0');
    expect((await repo.cli('--latest', 'v0.3.0')).exitCode).toBe(0);
    expect((await repo.cli('--latest', 'v0.1.214')).exitCode).toBe(0);
  });

  test('--latest that is not a tag is an error, not a pass', async () => {
    const result = await build().cli('--latest', 'nightly');
    expect(result.exitCode).toBe(1);
    expect(result.stderr).toContain('not a vMAJOR.MINOR.PATCH tag');
  });

  test('a repo with no setting is an error and prints no version', async () => {
    const repo = new Repo('cli-empty');
    repo.commit('Initial commit');
    const result = await repo.cli();
    expect(result.exitCode).toBe(1);
    expect(result.stdout).toBe('');
  });
});

describe('the committed setting', () => {
  test('is a valid version, so the very first run on main cannot fail on it', async () => {
    const { readFileSync } = await import('node:fs');
    const text = readFileSync(join(import.meta.dir, '..', '..', 'release', 'version'), 'utf8');
    expect(() => parseVersion(text)).not.toThrow();
    // Above every release made under the old commit-count scheme, so the app's
    // "install only a strictly higher version" rule holds across the change.
    expect(compareVersions(parseVersion(text), v('0.1.214'))).toBeGreaterThan(0);
  });
});
