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
 * "Text" is decided by what is declared and by content, not by git's own guess: a file whose
 * attributes say `-text` or `binary` is skipped, as is one with a NUL in its first 8000 bytes or
 * a known binary extension. A lone CR makes git itself call a file binary, so git's guess is
 * exactly what would let this class of damage through.
 *
 *   bun tools/check-text-files.ts [path ...]   (no paths: every tracked file)
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
    problems.push(...found);
  }
  return { problems, checked };
}

function main(args: string[]): number {
  const root = path.resolve(import.meta.dir, '..');
  const { problems, checked } = checkTracked(root, args);
  if (problems.length === 0) {
    console.log(`text files: ${checked} checked, no control characters.`);
    return 0;
  }
  for (const problem of problems.slice(0, 60)) {
    console.error(`${problem.path}:${problem.line}:${problem.column}  ${problem.what}`);
  }
  if (problems.length > 60) console.error(`... and ${problems.length - 60} more`);
  console.error(
    `text files: ${problems.length} problem(s) in ${new Set(problems.map((p) => p.path)).size} file(s). ` +
      'A BEL here is a "\\a" that a shell turned into a byte; read the diff of whatever edited the file.',
  );
  return 1;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
