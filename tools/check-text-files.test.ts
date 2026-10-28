import { afterAll, describe, expect, test } from 'bun:test';
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { checkStaged, checkTracked, isPublicAddress, scan, scanSensitive } from './check-text-files';

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

// The key a raw response opens with, in two pieces: this file must not hold it either.
const CONTEXT = 'response' + 'Context';
const PUBLIC_IP = ['151', '64', '112', '93'].join('.'); // from an address that is someone's; any public one would do

describe('scanSensitive: a raw YouTube response does not belong in the repository', () => {
  test('the response-context key is found, with its line, and the problem names no value', () => {
    const problems = scanSensitive('docs/capture.json', bytes(`{\n  "${CONTEXT}": { "visitorData": "abc" }\n}\n`));
    expect(problems).toHaveLength(1);
    expect(problems[0]).toMatchObject({ path: 'docs/capture.json', line: 2 });
    expect(problems[0]!.what).not.toContain('abc');
  });

  test('corpus/ is the sanitised copy and may hold it', () => {
    expect(scanSensitive('corpus/feed.json', bytes(`{"${CONTEXT}":{}}`))).toEqual([]);
  });

  test('the one test that builds a response by hand is allowed the key, and nothing else about it', () => {
    expect(scanSensitive('sidecar/test/parser.test.ts', bytes(`const r = { ${CONTEXT}: { visitorData: 'abc' } };`))).toEqual([]);
    expect(scanSensitive('sidecar/test/parser.test.ts', bytes(`url?x=1&ip=${PUBLIC_IP}&y=2`))).toHaveLength(1);
  });

  test('a stream URL with a public ip= is found, in plain and in JSON-escaped form, and the address is not printed', () => {
    for (const text of [`https://rr1.example/videoplayback?a=b&ip=${PUBLIC_IP}&c=d`, `"url":"https://x/v?a=b\u0026ip=${PUBLIC_IP}\u0026c=d"`, `x?ip%3D${PUBLIC_IP}`]) {
      const problems = scanSensitive('notes.md', bytes(text));
      expect(problems).toHaveLength(1);
      expect(problems[0]!.what).not.toContain(PUBLIC_IP);
    }
  });

  test('addresses that are nobody\'s are left alone: unspecified, private, loopback, documentation', () => {
    for (const ip of ['0.0.0.0', '10.1.2.3', '127.0.0.1', '192.168.1.5', '172.20.0.9', '169.254.1.1', '192.0.2.7', '198.51.100.4', '203.0.113.9']) {
      expect(isPublicAddress(ip)).toBe(false);
      expect(scanSensitive('a.ts', bytes(`u?ip=${ip}&x`))).toEqual([]);
    }
    expect(isPublicAddress(PUBLIC_IP)).toBe(true);
    expect(isPublicAddress('8.8.8.8')).toBe(true);
    expect(isPublicAddress('172.32.0.1')).toBe(true); // just outside 172.16/12
    expect(isPublicAddress('2606:4700::1111')).toBe(true);
    expect(isPublicAddress('fe80::1')).toBe(false);
  });

  test('words that merely contain ip= are not addresses', () => {
    expect(scanSensitive('a.ts', bytes('const s = "equip=1.2.3.4";'))).toEqual([]);
    expect(scanSensitive('a.ts', bytes('flip=abc'))).toEqual([]);
  });
});

describe('the guard in a repository, and the pre-commit hook', () => {
  const dirs: string[] = [];
  afterAll(() => {
    for (const dir of dirs) fs.rmSync(dir, { recursive: true, force: true });
  });

  const hooks = path.resolve(import.meta.dir, 'hooks');

  function git(dir: string, ...args: string[]) {
    return spawnSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'core.autocrlf=false', ...args], { cwd: dir, encoding: 'utf8' });
  }

  function repo(files: Record<string, string>): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rill-sensitive-'));
    dirs.push(dir);
    git(dir, 'init', '-q');
    fs.writeFileSync(path.join(dir, '.gitattributes'), '* text=auto eol=lf\n');
    for (const [name, content] of Object.entries(files)) {
      fs.mkdirSync(path.dirname(path.join(dir, name)), { recursive: true });
      fs.writeFileSync(path.join(dir, name), content);
    }
    git(dir, 'add', '-A');
    git(dir, 'commit', '-q', '-m', 'x');
    return dir;
  }

  // MUTATION (spec): a tracked file with the key fails the check that `rill check` and both workflows run.
  test('a tracked file holding the response-context key fails checkTracked', () => {
    const dir = repo({ 'ok.ts': 'fine\n', 'sidecar/capture.json': `{"${CONTEXT}":{}}\n` });
    const { problems } = checkTracked(dir);
    expect(problems).toHaveLength(1);
    expect(problems[0]).toMatchObject({ path: 'sidecar/capture.json' });
  });

  test('the same file under corpus/ passes', () => {
    const dir = repo({ 'corpus/capture.json': `{"${CONTEXT}":{}}\n` });
    expect(checkTracked(dir).problems).toEqual([]);
  });

  test('checkStaged reads the index: a clean working file with a bad staged version fails, a fixed one passes', () => {
    const dir = repo({ 'a.json': '{}\n' });
    fs.writeFileSync(path.join(dir, 'a.json'), `{"${CONTEXT}":{}}\n`);
    git(dir, 'add', 'a.json');
    fs.writeFileSync(path.join(dir, 'a.json'), '{}\n'); // the working copy is clean again, the index is not
    expect(checkStaged(dir).problems).toHaveLength(1);
    git(dir, 'add', 'a.json');
    expect(checkStaged(dir).problems).toEqual([]);
  });

  // MUTATION (spec): a staged file containing the key fails the hook, before the commit exists.
  test('the pre-commit hook refuses a commit whose staged file holds the key, and the commit does not happen', () => {
    const dir = repo({ 'ok.ts': 'fine\n' });
    const before = git(dir, 'rev-parse', 'HEAD').stdout.trim();
    fs.writeFileSync(path.join(dir, 'scratch.json'), `{"${CONTEXT}":{}}\n`);
    git(dir, 'add', '-f', 'scratch.json');

    const refused = git(dir, '-c', `core.hooksPath=${hooks}`, 'commit', '-m', 'oops');
    expect(refused.status).not.toBe(0);
    expect(refused.stderr).toContain('scratch.json');
    expect(refused.stderr).not.toContain('"{}');
    expect(git(dir, 'rev-parse', 'HEAD').stdout.trim()).toBe(before);
  });

  test('and lets a clean commit through', () => {
    const dir = repo({ 'ok.ts': 'fine\n' });
    fs.writeFileSync(path.join(dir, 'more.ts'), 'const a = 1;\n');
    git(dir, 'add', 'more.ts');
    const done = git(dir, '-c', `core.hooksPath=${hooks}`, 'commit', '-m', 'fine');
    expect(done.status).toBe(0);
  });

  test('a BEL in a staged file stops the commit too: one hook for both checks', () => {
    const dir = repo({ 'ok.ts': 'fine\n' });
    fs.writeFileSync(path.join(dir, 'bad.ts'), 'a\u0007b\n');
    git(dir, 'add', 'bad.ts');
    expect(git(dir, '-c', `core.hooksPath=${hooks}`, 'commit', '-m', 'bel').status).not.toBe(0);
  });
});
