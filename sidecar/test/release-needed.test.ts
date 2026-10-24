/**
 * `release/release-needed.ts`: a release only when something the app ships has changed.
 *
 * The rule replaces `paths-ignore` on the push trigger, which a scheduled run never
 * honoured: `ef86a4a`, a todo edit, became v0.12.1 overnight. So it is tested the way
 * `next-version.ts` is, against real histories, plus the glob list as a table.
 */

import { afterAll, describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { changedSince, isNotShipped, releaseNeeded } from '../../release/release-needed.ts';

const SCRIPT = join(import.meta.dir, '..', '..', 'release', 'release-needed.ts');
const roots: string[] = [];
afterAll(() => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

class Repo {
  readonly dir: string;
  constructor() {
    this.dir = mkdtempSync(join(tmpdir(), 'rill-needed-'));
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
  commit(message: string, ...files: string[]): void {
    for (const file of files) {
      const path = join(this.dir, file);
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, `${message} ${Math.random()}\n`);
    }
    this.git('add', '-A');
    this.git('commit', '-q', '-m', message);
  }
  async cli(...args: string[]) {
    const proc = Bun.spawn(['bun', SCRIPT, ...args], { cwd: this.dir, stdout: 'pipe', stderr: 'pipe' });
    const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
    return { exitCode: await proc.exited, stdout, stderr };
  }
}

describe('what a release does not ship', () => {
  const notShipped = [
    'docs/todo.md',
    'docs/tasks/36-one-watch-page.md',
    'README.md',
    'CLAUDE.md',
    'app/test/README.md',
    'scratch/probe.ts',
    'sidecar/scratch/measure-audio-hold.ts',
    'spiking/idea/main.dart',
    'tools/todo/parse.ts',
    '.mcp.json',
    'setup.bat',
    'rill.ps1',
    'rill.bat',
  ];
  const shipped = [
    'app/lib/main.dart',
    'app/pubspec.yaml',
    'app/windows/runner/main.cpp',
    'sidecar/src/main.ts',
    'sidecar/package.json',
    'release/rill.iss',
    'release/version',
    '.github/workflows/release.yml',
    // Near misses: the list is exact, not a prefix.
    'rill.exe',
    'toolsmith/x.ts',
    'doc/x.txt',
    'docs',
  ];

  for (const file of notShipped) test(`${file} is not shipped`, () => expect(isNotShipped(file)).toBe(true));
  for (const file of shipped) test(`${file} is shipped`, () => expect(isNotShipped(file)).toBe(false));

  test('a Windows path is read the same', () => expect(isNotShipped('docs\\todo.md')).toBe(true));
});

describe('releaseNeeded', () => {
  test('nothing changed is nothing to release', () => expect(releaseNeeded([])).toBe(false));
  test('only unshipped files is nothing to release', () => {
    expect(releaseNeeded(['docs/todo.md', 'tools/todo/cli.ts', 'CLAUDE.md'])).toBe(false);
  });
  test('one shipped file among them is a release', () => {
    expect(releaseNeeded(['docs/todo.md', 'app/lib/main.dart', 'tools/todo/cli.ts'])).toBe(true);
  });
});

describe('against a history', () => {
  const build = () => {
    const repo = new Repo();
    repo.commit('App', 'app/lib/main.dart', 'docs/todo.md');
    repo.git('tag', 'v0.1.0');
    return repo;
  };

  test('docs commits since the release are nothing to release', async () => {
    const repo = build();
    repo.commit('Todo edit', 'docs/todo.md');
    repo.commit('Notes', 'CLAUDE.md', 'tools/todo/parse.ts');
    expect(changedSince('v0.1.0', repo.dir).sort()).toEqual(['CLAUDE.md', 'docs/todo.md', 'tools/todo/parse.ts']);
    const result = await repo.cli('--since', 'v0.1.0');
    expect(result.stdout).toBe('false\n');
    expect(result.stderr).toContain('0 of them shipped');
  });

  test('a code commit after a docs commit is a release, and the docs ride along', async () => {
    const repo = build();
    repo.commit('Todo edit', 'docs/todo.md');
    repo.commit('Fix', 'sidecar/src/main.ts');
    const result = await repo.cli('--since', 'v0.1.0');
    expect(result.stdout).toBe('true\n');
    expect(result.stderr).toContain('sidecar/src/main.ts');
  });

  test('a shipped file edited and put back is not a release', async () => {
    const repo = build();
    const before = repo.git('rev-parse', 'HEAD').trim();
    repo.commit('Change', 'app/lib/main.dart');
    repo.git('revert', '--no-edit', 'HEAD');
    expect(repo.git('rev-parse', 'HEAD').trim()).not.toBe(before);
    expect((await repo.cli('--since', 'v0.1.0')).stdout).toBe('false\n');
  });

  test('no release to compare with is a release', async () => {
    const repo = build();
    const result = await repo.cli();
    expect(result.stdout).toBe('true\n');
    expect(result.stderr).toContain('no previous release');
  });

  test('a tag that cannot be found is a release, not a guess that nothing shipped', async () => {
    const repo = build();
    const result = await repo.cli('--since', 'v9.9.9');
    expect(result.stdout).toBe('true\n');
    expect(result.stderr).toContain('releasing to be safe');
  });
});
