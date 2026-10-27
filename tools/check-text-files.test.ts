import { afterAll, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { checkTracked, scan } from './check-text-files';

const bytes = (text: string) => new TextEncoder().encode(text);

describe('scan', () => {
  test('ordinary text, tabs and line feeds are clean', () => {
    expect(scan('a.ts', bytes('const a = 1;\n\tconst b = "é";\n'))).toEqual([]);
  });

  test('a BEL is found, with where it is — what "\\a" becomes when a shell eats a backslash', () => {
    const problems = scan('captions.ts', bytes('line one\nthe tag \u0007n1 here\n'));
    expect(problems).toHaveLength(1);
    expect(problems[0]).toMatchObject({ path: 'captions.ts', line: 2, column: 9 });
    expect(problems[0]!.what).toContain('BEL');
  });

  test('the other controls a shell can produce: backspace, form feed, vertical tab, ESC, DEL', () => {
    for (const code of [0x08, 0x0c, 0x0b, 0x1b, 0x7f, 0x01]) {
      expect(scan('x.ts', new Uint8Array([0x61, code, 0x62]))).toHaveLength(1);
    }
  });

  test('a lone carriage return fails everywhere, .bat included', () => {
    expect(scan('x.ts', bytes('a\rb\n'))).toHaveLength(1);
    expect(scan('x.bat', bytes('a\rb\n'), true)).toHaveLength(1);
  });

  test('CRLF fails unless the file is allowed it, and is reported once, not per line', () => {
    const text = 'a\r\nb\r\nc\r\n';
    expect(scan('x.ts', bytes(text))).toHaveLength(1);
    expect(scan('x.bat', bytes(text), true)).toEqual([]);
  });

  test('a form feed is the content of the licences file and nowhere else', () => {
    const page = bytes('end of page\n\u000c\nnext page\n');
    expect(scan('THIRD_PARTY_LICENSES', page)).toEqual([]);
    expect(scan('docs/other.md', page)).toHaveLength(1);
    expect(scan('THIRD_PARTY_LICENSES', bytes('a\u0007b'))).toHaveLength(1);
  });
});

describe('checkTracked, in a real repository', () => {
  const dirs: string[] = [];
  afterAll(() => {
    for (const dir of dirs) fs.rmSync(dir, { recursive: true, force: true });
  });

  function repo(files: Record<string, string | Uint8Array>, attributes = '* text=auto eol=lf\n*.bat text eol=crlf\n*.png binary\n'): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rill-text-files-'));
    dirs.push(dir);
    const git = (...args: string[]) => {
      const result = spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'core.autocrlf=false', ...args], { cwd: dir, encoding: 'utf8' });
      if (result.status !== 0) throw new Error(`git ${args.join(' ')}: ${result.stderr}`);
    };
    git('init', '-q');
    fs.writeFileSync(path.join(dir, '.gitattributes'), attributes);
    for (const [name, content] of Object.entries(files)) {
      fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
      fs.writeFileSync(path.join(dir, name), content);
    }
    git('add', '-A');
    git('commit', '-q', '-m', 'x');
    return dir;
  }

  test('a clean repository passes', () => {
    const dir = repo({ 'a.ts': 'const a = 1;\n', 'docs/b.md': '# b\n' });
    expect(checkTracked(dir)).toEqual({ problems: [], checked: 3 });
  });

  // MUTATION (spec): a file with a BEL in it fails the check.
  test('a committed file with a BEL in it fails, and names the file and the byte', () => {
    const dir = repo({ 'sidecar/src/captions/x.ts': 'const tag = "\\an1";\n'.replace('\\a', '\u0007') });
    const { problems } = checkTracked(dir);
    expect(problems).toHaveLength(1);
    expect(problems[0]).toMatchObject({ path: 'sidecar/src/captions/x.ts', line: 1 });
    expect(problems[0]!.what).toContain('BEL');
  });

  test('an edit that has not been committed, or even staged, fails too: that is when it matters', () => {
    const dir = repo({ 'a.ts': 'ok\n' });
    fs.writeFileSync(path.join(dir, 'a.ts'), 'ok\nbad \u0007 here\n');
    expect(checkTracked(dir).problems).toHaveLength(1);
  });

  test('an untracked file is not looked at', () => {
    const dir = repo({ 'a.ts': 'ok\n' });
    fs.writeFileSync(path.join(dir, 'scratch.ts'), 'bad \u0007\n');
    expect(checkTracked(dir)).toEqual({ problems: [], checked: 2 });
  });

  test('a .bat keeps its CRLF; the same bytes in a .ts fail', () => {
    const dir = repo({ 'run.bat': 'echo hi\r\n' });
    expect(checkTracked(dir).problems).toEqual([]);
    const other = repo({ 'run.ts': 'a\n' });
    fs.writeFileSync(path.join(other, 'run.ts'), 'a\nb\r\nc\n');
    const { problems } = checkTracked(other);
    expect(problems.length).toBeGreaterThan(0);
  });

  test('a file that is CRLF throughout in the working tree is git\'s to normalise, not a failure', () => {
    const dir = repo({ 'old.ts': 'a\nb\n' });
    fs.writeFileSync(path.join(dir, 'old.ts'), 'a\r\nb\r\n');
    expect(checkTracked(dir).problems).toEqual([]);
  });

  test('binary files are skipped, whatever bytes they hold', () => {
    const dir = repo({ 'logo.png': new Uint8Array([0x89, 0x50, 0x07, 0x00, 0x1b]), 'a.ts': 'ok\n' });
    expect(checkTracked(dir).problems).toEqual([]);
  });

  test('named paths narrow the check', () => {
    const dir = repo({ 'a.ts': 'ok\n', 'b.ts': 'bad\u0007\n' });
    expect(checkTracked(dir, ['a.ts']).problems).toEqual([]);
    expect(checkTracked(dir, ['b.ts']).problems).toHaveLength(1);
  });
});
