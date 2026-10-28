/**
 * `rill check` and the release gate: no tracked text file may hold a control character.
 *
 * What it catches is an edit that went wrong in the shell and nobody saw. The Bash tool eats
 * one level of backslashes, so `\an1` in a heredoc or a `sed` replacement reaches the file as a
 * BEL byte (`\a`); the file still opens, every tool still reads it, and the override it was
 * meant to carry silently does nothing. That is why editing with `sed` used to be forbidden
 * outright. With this check run before anything is committed, a `sed` edit whose diff has been
 * read is fine.
 *
 * Fails on, in any tracked file that is text:
 *  - a C0 control other than tab, line feed and carriage return (so BEL, ESC, form feed ...)
 *    or DEL;
 *  - a carriage return that is not part of a CRLF pair, anywhere;
 *  - carriage returns in what git would commit: an index entry with CR, or a working-tree file
 *    that mixes CRLF and LF lines. `.bat` and `.cmd` are exempt (their CRLF is the point).
 *    A working-tree file that is CRLF throughout is not a failure: `* text=auto eol=lf` turns it
 *    into LF when it is added, and a few files from before that rule still sit that way.
 *
 * It also refuses a raw YouTube response in the repository (2026-10-27): any tracked file
 * outside `corpus/` that holds the response-context key, or a stream URL's `ip=` with a public
 * address. This is a public repository, and a captured response carries the capturing machine's
 * address, a visitor id, and for a signed-in capture the account's subscriptions and avatar. Two
 * such files sat in `main` for months, and 55 untracked captures were pushed by a `git add -f`
 * before anyone looked. `corpus/` is the sanitised copy and is exempt; so is one test that builds
 * a response by hand. The problem line names the file, the line and the kind, never the value.
 * The pre-commit hook (`tools/hooks/pre-commit`) runs this on what is staged, so it stops at the
 * commit, before a push makes anything public.
 *
 * "Text" is decided by what is declared and by content, not by git's own guess: a file whose
 * attributes say `-text` or `binary` is skipped, as is one with a NUL in its first 8000 bytes or
 * a known binary extension. A lone CR makes git itself call a file binary, so git's guess is
 * exactly what would let this class of damage through.
 *
 *   bun tools/check-text-files.ts [path ...]   (no paths: every tracked file)
 *   bun tools/check-text-files.ts --staged     (what is staged, from the index; the pre-commit hook)
 */
import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';

const BINARY_EXTENSIONS = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.bmp', '.dll', '.exe', '.lockb', '.sig',
  '.zip', '.gz', '.7z', '.ttf', '.otf', '.woff', '.woff2', '.pdf', '.mp4', '.webm', '.opus',
]);

const CRLF_EXEMPT = new Set(['.bat', '.cmd']);

/**
 * Control characters that are the content of a file, by path. The GNU licences in
 * `THIRD_PARTY_LICENSES` are paginated with form feeds. An entry here is one byte value in one
 * file, so a stray `\f` anywhere else still fails.
 */
const KNOWN: Record<string, number[]> = {
  THIRD_PARTY_LICENSES: [0x0c],
};

export interface Problem {
  path: string;
  line: number;
  column: number;
  what: string;
}

/**
 * The key every raw InnerTube response opens with. Written in two pieces so that this file does
 * not hold it and trip its own check.
 */
const RESPONSE_CONTEXT = 'response' + 'Context';

/** The sanitised copy of the captures; a raw response belongs nowhere else. */
const RAW_RESPONSES_ALLOWED_UNDER = 'corpus/';

/**
 * Files that hold the key on purpose, by path, with the reason. One test builds a response by
 * hand with a made-up visitor id; it is not a capture.
 */
const RESPONSE_CONTEXT_ALLOWED: Record<string, string> = {
  'sidecar/test/parser.test.ts': 'a response built inline in a test, with an invented visitor id',
};

/** Whether an `ip=` value is an address that could be someone's: not private, loopback, unspecified or reserved for documentation. */
export function isPublicAddress(value: string): boolean {
  if (value.includes(':')) {
    const v6 = value.toLowerCase();
    return !(v6 === '::' || v6 === '::1' || /^f[cd]/.test(v6) || v6.startsWith('fe80') || v6.startsWith('2001:db8'));
  }
  const parts = value.split('.').map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b, c] = parts as [number, number, number, number];
  if (a === 0 || a === 10 || a === 127) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 100 && b >= 64 && b <= 127) return false; // shared address space
  if ((a === 192 && b === 0 && c === 2) || (a === 198 && b === 51 && c === 100) || (a === 203 && b === 0 && c === 113)) return false;
  return true;
}

/**
 * A raw YouTube response in a file that should not hold one. Reports where and what kind, never
 * the value found.
 */
export function scanSensitive(file: string, bytes: Uint8Array): Problem[] {
  if (file.startsWith(RAW_RESPONSES_ALLOWED_UNDER)) return [];
  const text = Buffer.from(bytes).toString('latin1');
  const problems: Problem[] = [];
  const lineOf = (index: number) => text.slice(0, index).split('\n').length;

  if (!(file in RESPONSE_CONTEXT_ALLOWED)) {
    const at = text.indexOf(RESPONSE_CONTEXT);
    if (at >= 0) {
      problems.push({
        path: file,
        line: lineOf(at),
        column: 1,
        what: 'a raw YouTube response (it has the response-context key): captures stay out of the repository, sanitised copies go in corpus/',
      });
    }
  }

  const ip = /(?:[?&]|\\u0026|&amp;)ip(?:=|%3D)((?:\d{1,3}\.){3}\d{1,3}|[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7})/g;
  let first = -1;
  let count = 0;
  for (const match of text.matchAll(ip)) {
    if (!isPublicAddress(match[1]!)) continue;
    if (first < 0) first = match.index!;
    count++;
  }
  if (count > 0) {
    problems.push({
      path: file,
      line: lineOf(first),
      column: 1,
      what: `a stream URL with a public ip= address (${count} of them): it is the address of whoever captured it`,
    });
  }
  return problems;
}

const NAMES: Record<number, string> = {
  0x00: 'NUL', 0x01: 'SOH', 0x02: 'STX', 0x03: 'ETX', 0x04: 'EOT', 0x05: 'ENQ', 0x06: 'ACK',
  0x07: 'BEL (what "\\a" becomes)', 0x08: 'BS (what "\\b" becomes)', 0x0b: 'VT (what "\\v" becomes)',
  0x0c: 'FF (what "\\f" becomes)', 0x0e: 'SO', 0x0f: 'SI', 0x10: 'DLE', 0x11: 'DC1', 0x12: 'DC2',
  0x13: 'DC3', 0x14: 'DC4', 0x15: 'NAK', 0x16: 'SYN', 0x17: 'ETB', 0x18: 'CAN', 0x19: 'EM',
  0x1a: 'SUB', 0x1b: 'ESC', 0x1c: 'FS', 0x1d: 'GS', 0x1e: 'RS', 0x1f: 'US', 0x7f: 'DEL',
};

/**
 * Whether the bytes of one file are clean. [crlfAllowed] is true for the files whose
 * line endings are CRLF on purpose; a lone CR is wrong everywhere.
 */
export function scan(file: string, bytes: Uint8Array, crlfAllowed = false): Problem[] {
  const problems: Problem[] = [];
  const known = KNOWN[file] ?? [];
  let line = 1;
  let column = 1;
  for (let i = 0; i < bytes.length; i++) {
    const byte = bytes[i]!;
    if (byte === 0x0a) {
      line++;
      column = 1;
      continue;
    }
    if (byte === 0x0d) {
      const pair = bytes[i + 1] === 0x0a;
      if (!pair) problems.push({ path: file, line, column, what: 'carriage return not followed by a line feed' });
      else if (!crlfAllowed) {
        // Only the first CRLF is worth a line: a file full of them is one problem, not three hundred.
        if (!problems.some((p) => p.what.startsWith('CRLF'))) {
          problems.push({ path: file, line, column, what: 'CRLF line ending (only .bat and .cmd keep them)' });
        }
      }
      column++;
      continue;
    }
    if (byte !== 0x09 && (byte < 0x20 || byte === 0x7f) && !known.includes(byte)) {
      problems.push({ path: file, line, column, what: `control character 0x${byte.toString(16).padStart(2, '0')} ${NAMES[byte] ?? ''}`.trim() });
    }
    column++;
  }
  return problems;
}

/** One line of `git ls-files --eol`: `i/lf    w/lf    attr/text=auto eol=lf \tpath`. */
interface Entry {
  path: string;
  index: string;
  tree: string;
  attr: string;
}

function parseEol(output: string): Entry[] {
  const entries: Entry[] = [];
  for (const record of output.split('\0')) {
    const tab = record.indexOf('\t');
    if (tab < 0) continue;
    const [index = '', tree = '', ...attr] = record.slice(0, tab).trim().split(/\s+/);
    entries.push({ path: record.slice(tab + 1), index: index.replace(/^i\//, ''), tree: tree.replace(/^w\//, ''), attr: attr.join(' ').replace(/^attr\//, '') });
  }
  return entries;
}

function isDeclaredBinary(attr: string): boolean {
  return /(^|\s)-text(\s|$)/.test(attr) || /(^|\s)binary(\s|$)/.test(attr) || /(^|\s)-diff(\s|$)/.test(attr);
}

/** Every problem in the tracked files, or in [only] when given. */
export function checkTracked(root: string, only: string[] = []): { problems: Problem[]; checked: number } {
  const listed = spawnSync('git', ['ls-files', '--eol', '-z'], { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (listed.status !== 0) throw new Error(`git ls-files failed: ${listed.stderr}`);
  const wanted = only.length ? new Set(only.map((p) => p.replace(/\\/g, '/'))) : null;
  const problems: Problem[] = [];
  let checked = 0;
  for (const entry of parseEol(listed.stdout)) {
    if (wanted && !wanted.has(entry.path)) continue;
    if (isDeclaredBinary(entry.attr)) continue;
    const extension = path.extname(entry.path).toLowerCase();
    if (BINARY_EXTENSIONS.has(extension)) continue;
    let bytes: Buffer;
    try {
      bytes = fs.readFileSync(path.join(root, entry.path));
    } catch {
      continue; // tracked but deleted in the working tree: the commit will say so
    }
    if (bytes.subarray(0, 8000).includes(0)) continue;
    checked++;
    const exempt = CRLF_EXEMPT.has(extension);
    // CRLF in the working tree is git's to normalise unless the file mixes the two endings, or the
    // index entry itself holds CR.
    const crlfIsGitsBusiness = !exempt && entry.tree === 'crlf' && entry.index === 'lf';
    const found = scan(entry.path, bytes, exempt || crlfIsGitsBusiness);
    if (!exempt && (entry.index === 'crlf' || entry.index === 'mixed') && !found.some((p) => p.what.startsWith('CRLF'))) {
      found.push({ path: entry.path, line: 1, column: 1, what: `the index holds CR line endings (i/${entry.index})` });
    }
    if (!exempt && entry.tree === 'mixed' && !found.some((p) => p.what.startsWith('CRLF'))) {
      found.push({ path: entry.path, line: 1, column: 1, what: 'mixed CRLF and LF line endings' });
    }
    found.push(...scanSensitive(entry.path, bytes));
    problems.push(...found);
  }
  return { problems, checked };
}

/** The same checks on what is staged, read from the index and not the working tree. */
export function checkStaged(root: string): { problems: Problem[]; checked: number } {
  const listed = spawnSync('git', ['diff', '--cached', '--name-only', '-z', '--diff-filter=ACMR'], { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (listed.status !== 0) throw new Error(`git diff --cached failed: ${listed.stderr}`);
  const problems: Problem[] = [];
  let checked = 0;
  for (const name of listed.stdout.split('\0').filter(Boolean)) {
    const extension = path.extname(name).toLowerCase();
    if (BINARY_EXTENSIONS.has(extension)) continue;
    const blob = spawnSync('git', ['show', `:${name}`], { cwd: root, maxBuffer: 256 * 1024 * 1024 });
    if (blob.status !== 0) continue;
    const bytes = blob.stdout as Buffer;
    if (bytes.subarray(0, 8000).includes(0)) continue;
    checked++;
    problems.push(...scan(name, bytes, CRLF_EXEMPT.has(extension)), ...scanSensitive(name, bytes));
  }
  return { problems, checked };
}

function main(args: string[]): number {
  const staged = args.includes('--staged');
  let root = path.resolve(import.meta.dir, '..');
  if (staged) {
    // The repository being committed to, which is not always the one this file sits in.
    const top = spawnSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' });
    if (top.status !== 0) throw new Error(`git rev-parse failed: ${top.stderr}`);
    root = top.stdout.trim();
  }
  const { problems, checked } = staged ? checkStaged(root) : checkTracked(root, args);
  if (problems.length === 0) {
    console.log(`text files: ${checked} ${staged ? 'staged ' : ''}checked, no control characters or raw responses.`);
    return 0;
  }
  for (const problem of problems.slice(0, 60)) {
    console.error(`${problem.path}:${problem.line}:${problem.column}  ${problem.what}`);
  }
  if (problems.length > 60) console.error(`... and ${problems.length - 60} more`);
  console.error(
    `text files: ${problems.length} problem(s) in ${new Set(problems.map((p) => p.path)).size} file(s). ` +
      'A BEL is a "\\a" that a shell turned into a byte: read the diff of whatever edited the file. A raw response is a capture that must not be committed: unstage it (git rm --cached), and keep captures in an ignored folder such as sidecar/scratch/.',
  );
  return 1;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
