/**
 * The docs and the code, checked against each other — offline, no network.
 *
 * `CLAUDE.md`, `docs/architecture.md`, `docs/protocol.md`, `parser.test.ts`'s
 * `SHAPES` table and `corpus.test.ts`'s auditor each independently restate part
 * of the same contract, and nothing checked they agreed. Twice that has cost
 * real time:
 *
 *   - `ChannelItem.descriptionSnippet` was added to the code and left out of
 *     CLAUDE.md's DTO block, so the file the project tells you to read first
 *     described a DTO that no longer existed.
 *   - `ANDROID_VR` was replaced by `VISIONOS` at ladder tier 1 (architecture.md
 *     F11, 2026-08-18). The code, the fixtures and F11 all moved; CLAUDE.md,
 *     seven places in architecture.md, five in protocol.md and one test
 *     assertion did not. CLAUDE.md is loaded into every session, so it went on
 *     teaching the wrong client for months.
 *
 * This is deliberately **one file with two checks**, not a documentation
 * framework. Each compares a doc against the code that is the actual
 * authority, and neither needs a list anyone has to maintain: the first reads
 * whatever shapes the docs declare, the second whatever clients they name.
 */

import { describe, expect, test } from 'bun:test';
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const SRC = join(ROOT, 'sidecar', 'src');

const DOCS = ['CLAUDE.md', 'docs/architecture.md', 'docs/protocol.md'] as const;

function doc(path: string): string {
  return readFileSync(join(ROOT, path), 'utf8');
}

function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? sourceFiles(join(dir, entry.name)) : [join(dir, entry.name)],
  );
}

/** Every line of sidecar source, as one string. The authority both checks compare against. */
const SOURCE = sourceFiles(SRC)
  .map((path) => readFileSync(path, 'utf8'))
  .join('\n');

// ---------------------------------------------------------------------------
// 1. The shapes the docs declare vs. the real types
// ---------------------------------------------------------------------------
//
// Every `interface` and `type` inside a fenced ```ts block of CLAUDE.md or
// protocol.md is compared, **field names, optionality and types**, against the
// one declaration of that name in `sidecar/src`. Names alone used to be all this
// compared, so `channelId: string` against `string | null` passed — and that is
// exactly the distinction the DTO rule ("a value or `null`, never omitted")
// exists for.
//
// A small scanner rather than a TypeScript parser, and deliberately so: it has
// to read two things written differently on purpose (`types.ts` puts one field
// per line under a doc comment; CLAUDE.md packs the small DTOs onto two lines),
// and it must never quietly read *less* than is there. Anything it cannot parse
// is reported as a field of its own rather than skipped.

/** The docs whose ```ts blocks are contract, not illustration. */
const SHAPE_DOCS = ['CLAUDE.md', 'docs/protocol.md'] as const;

function tsBlocks(markdown: string): string {
  return [...markdown.matchAll(/^```ts[^\n]*\n([\s\S]*?)^```/gm)].map((m) => m[1]).join('\n');
}

/**
 * Source with comments removed and string literals kept whole.
 *
 * Both halves were learned the hard way. A doc comment can hold braces —
 * `{@link isArtistChannel}` in `types.ts` once closed an interface body early and
 * hid its last five fields — and a naive `//` strip cuts `'https://…'` in half,
 * which unbalances every brace after it. So this walks the text.
 */
function stripComments(src: string): string {
  let out = '';
  let i = 0;
  while (i < src.length) {
    const c = src[i]!;
    const next = src[i + 1];
    if (c === '/' && next === '/') {
      while (i < src.length && src[i] !== '\n') i++;
    } else if (c === '/' && next === '*') {
      const end = src.indexOf('*/', i + 2);
      i = end === -1 ? src.length : end + 2;
      out += ' ';
    } else if (c === "'" || c === '"' || c === '`') {
      const start = i++;
      while (i < src.length && src[i] !== c) i += src[i] === '\\' ? 2 : 1;
      out += src.slice(start, ++i);
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

const OPEN = '({[';
const CLOSE = ')}]';

/** Split at `separator` wherever no bracket is open. `=>` is not a bracket. */
function splitTopLevel(text: string, separator: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (OPEN.includes(c)) depth++;
    else if (CLOSE.includes(c)) depth--;
    else if (c === separator && depth === 0) {
      parts.push(text.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(text.slice(start));
  return parts;
}

/**
 * A type, spelled one canonical way: no whitespace, one quote style, and the
 * members of a top-level union in sorted order — `null | string` and
 * `string | null` are the same type, `string` is not.
 */
function normaliseType(type: string): string {
  const flat = type.replace(/\s+/g, '').replace(/"/g, "'");
  return splitTopLevel(flat, '|')
    .filter((member) => member.length > 0)
    .sort()
    .join('|');
}

/** `name` or `name?` → canonical type. Unparseable members are kept, keyed as such. */
function members(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const raw of splitTopLevel(body, ';')) {
    const member = raw.trim();
    if (!member) continue;
    const m = /^(?:readonly\s+)?(\w+)(\?)?\s*:\s*([\s\S]+)$/.exec(member);
    if (m) out[`${m[1]}${m[2] ?? ''}`] = normaliseType(m[3]!);
    else out[`(unparsed) ${member.replace(/\s+/g, ' ')}`] = '';
  }
  return out;
}

interface Declarations {
  interfaces: Map<string, Record<string, string>>;
  aliases: Map<string, string>;
}

function declarations(src: string): Declarations {
  const text = stripComments(src);
  const interfaces = new Map<string, Record<string, string>>();
  // `extends` is matched so the declaration is found at all. Inherited fields
  // are not merged in; a documented shape that extends another would show up
  // here as missing fields, which is loud, not silent.
  const head = /\binterface\s+(\w+)\s*(?:<[^{]*?>)?\s*(?:extends\s+[^{]+)?\{/g;
  for (const m of text.matchAll(head)) {
    const open = m.index! + m[0].length - 1;
    let depth = 0;
    let close = open;
    for (; close < text.length; close++) {
      if (text[close] === '{') depth++;
      else if (text[close] === '}' && --depth === 0) break;
    }
    interfaces.set(m[1]!, members(text.slice(open + 1, close)));
  }
  const aliases = new Map<string, string>();
  for (const m of text.matchAll(/\btype\s+(\w+)\s*=\s*([^;]+);/g)) {
    aliases.set(m[1]!, normaliseType(m[2]!));
  }
  return { interfaces, aliases };
}

/**
 * The single `sidecar/src` declaration of `name`. More than one is an error in
 * its own right: the docs would be describing whichever one this happened to
 * read.
 */
type DeclOf<K extends keyof Declarations> = Declarations[K] extends Map<string, infer V> ? V : never;

function codeDeclaration<K extends keyof Declarations>(
  kind: K,
  name: string,
): Array<{ path: string; decl: DeclOf<K> }> {
  const token = new RegExp(`\\b${kind === 'interfaces' ? 'interface' : 'type'}\\s+${name}\\b`);
  return sourceFiles(SRC)
    .filter((path) => path.endsWith('.ts'))
    .map((path) => ({ path, text: readFileSync(path, 'utf8') }))
    .filter(({ text }) => token.test(text))
    .flatMap(({ path, text }) => {
      const decl = (declarations(text)[kind] as Map<string, DeclOf<K>>).get(name);
      return decl === undefined ? [] : [{ path, decl }];
    });
}

const DOCUMENTED = SHAPE_DOCS.map((path) => ({ path, ...declarations(tsBlocks(doc(path))) }));

describe('the shapes the docs declare are the shapes the code ships', () => {
  test('the shape blocks were found at all', () => {
    // Guards against every assertion below passing because a block moved, was
    // renamed, or stopped being a fenced `ts` block.
    const byDoc = Object.fromEntries(
      DOCUMENTED.map(({ path, interfaces, aliases }) => [
        path,
        [...interfaces.keys(), ...aliases.keys()].sort(),
      ]),
    );
    expect(byDoc['CLAUDE.md']).toEqual(
      expect.arrayContaining(['FeedItem', 'VideoItem', 'MixItem', 'PlaylistItem', 'ChannelItem', 'Chip']),
    );
    // `VideoDetail` is the whole of `video.info` and had no written shape
    // anywhere until 2026-09-16 — which is where live drift landed.
    expect(byDoc['docs/protocol.md']).toEqual(
      expect.arrayContaining(['VideoDetail', 'PlaylistMembership', 'PlaylistPrivacy', 'SearchFilters']),
    );
  });

  for (const { path, interfaces, aliases } of DOCUMENTED) {
    for (const [name, documented] of interfaces) {
      test(`${path}: interface ${name}`, () => {
        const found = codeDeclaration('interfaces', name);
        expect(
          found.map((f) => f.path),
          `\`${name}\` must be declared exactly once in sidecar/src`,
        ).toHaveLength(1);
        expect(documented, `\`${name}\` in ${path} and in ${found[0]!.path}`).toEqual(found[0]!.decl);
      });
    }
    for (const [name, documented] of aliases) {
      test(`${path}: type ${name}`, () => {
        const found = codeDeclaration('aliases', name);
        expect(
          found.map((f) => f.path),
          `\`${name}\` must be declared exactly once in sidecar/src`,
        ).toHaveLength(1);
        expect(documented, `\`${name}\` in ${path} and in ${found[0]!.path}`).toBe(found[0]!.decl);
      });
    }
  }
});

describe('the shape check can actually fail', () => {
  // An auditor that cannot fail converts an unchecked property into a
  // checked-looking one, which is worse than no auditor. One control per
  // property the check claims to see.
  const shape = (src: string, name = 'X') => declarations(src).interfaces.get(name);

  test('nullability is compared, not just names', () => {
    expect(shape('interface X { a: string | null; }')).not.toEqual(shape('interface X { a: string; }'));
  });

  test('an optional field is not a required one', () => {
    expect(shape('interface X { a?: string; }')).not.toEqual(shape('interface X { a: string; }'));
  });

  test('union order does not matter; union membership does', () => {
    expect(shape("interface X { a: 'x' | 'y'; }")).toEqual(shape("interface X { a: 'y' | 'x'; }"));
    expect(shape("interface X { a: 'x' | 'y'; }")).not.toEqual(shape("interface X { a: 'x' | 'z'; }"));
    expect(declarations('type U = A | B;').aliases.get('U')).not.toBe(
      declarations('type U = A | B | C;').aliases.get('U'),
    );
  });

  test('braces in comments and slashes in strings do not cut a body short', () => {
    const src = [
      'interface X {',
      '  /** see {@link b} */',
      "  a: 'https://example.com/{x}';",
      '  // a } in a line comment',
      '  b: { inner: number; };',
      '  c: boolean;',
      '}',
    ].join('\n');
    expect(Object.keys(shape(src)!)).toEqual(['a', 'b', 'c']);
  });

  test('a declaration with `extends` or type parameters is still found', () => {
    expect(shape('export interface X<T> extends Y<T> { a: T; }')).toEqual({ a: 'T' });
  });

  test('a member the scanner cannot read is reported, not dropped', () => {
    expect(Object.keys(shape('interface X { a: string; [key: string]: number; }')!)).toHaveLength(2);
  });
});

// ---------------------------------------------------------------------------
// 2. No normative doc line names an InnerTube client the code does not use
// ---------------------------------------------------------------------------

/**
 * Anything shaped like an InnerTube client id. Matched by shape rather than
 * against a list, so a client retired in future is caught without anyone
 * remembering to add it here.
 */
const CLIENT_TOKEN = /\b(?:ANDROID|IOS|MWEB|WEB|TV|VISIONOS)[A-Z0-9_]*\b/g;

/**
 * A claim about what happened on a date, rather than about what the code does.
 *
 * Both markers are the docs' own existing conventions: architecture.md's
 * findings carry `F<n>` ids, and anything amended carries the date it was
 * measured. A dated claim about a retired client is history and must survive —
 * deleting it is how the reasoning gets lost. An *undated* one is a claim
 * about the present, and if the code disagrees, the doc is wrong.
 */
const HISTORICAL = /\bF\d+\b|\b20\d\d-\d\d-\d\d\b/;

/**
 * The docs split into the units a claim actually occupies. Hard-wrapped prose
 * puts the client on one line and the `F11` that dates it on the next, so a
 * per-line check misreads history as a live claim; a per-file one exempts a
 * whole document because it mentions one finding somewhere.
 *
 * A unit is a table row, a list item, or a paragraph — which is as much
 * structure as this needs, and all of it is markdown's, not ours.
 */
function claims(markdown: string): Array<{ line: number; text: string }> {
  const lines = markdown.split(/\r?\n/);
  const units: Array<{ line: number; text: string }> = [];
  let current: { line: number; text: string } | null = null;

  lines.forEach((raw, index) => {
    const startsUnit = /^\s*$/.test(raw) || /^\s*[-*|]/.test(raw) || /^\s*\d+\.\s/.test(raw);
    if (startsUnit || current === null) {
      current = { line: index + 1, text: raw };
      units.push(current);
      return;
    }
    current.text += `\n${raw}`;
  });

  return units;
}

/**
 * The spans a `F<n>`/date marker is allowed to vouch for.
 *
 * A table row is a finding whole — architecture.md's findings table is one row
 * per measurement, carrying its own id — so the row vouches for itself. In
 * prose, the sentence is the unit: a paragraph is free to say what was true in
 * August *and* what is true now, and the dated half must not excuse the other.
 * Without this split, adding "tier 1 was X until <date>" to a bullet exempts
 * the very sentence that says what tier 1 is today.
 */
function vouchingSpans(unit: string): string[] {
  if (/^\s*\|/.test(unit)) return [unit];
  return unit.split(/(?<=[.:!?])\s+/);
}

test('no doc claims a client the sidecar does not use', () => {
  const stale: string[] = [];

  for (const path of DOCS) {
    for (const claim of claims(doc(path))) {
      for (const span of vouchingSpans(claim.text)) {
        if (HISTORICAL.test(span)) continue;
        for (const token of new Set(span.match(CLIENT_TOKEN) ?? [])) {
          if (SOURCE.includes(token)) continue;
          stale.push(
            `${path}:${claim.line} names \`${token}\`, which appears nowhere in sidecar/src`,
          );
        }
      }
    }
  }

  // Named rather than counted: the failure has to say which line to open.
  expect(stale).toEqual([]);
});

test('the client check can actually fail', () => {
  // An auditor that cannot fail converts an unchecked property into a
  // checked-looking one, which is worse than no auditor — `corpus.test.ts`
  // makes the same argument and keeps the same kind of control.
  const invented = 'ANDROID_HOLOLENS';
  expect(SOURCE.includes(invented)).toBe(false);
  expect(`resolve as \`${invented}\` at tier 1`.match(CLIENT_TOKEN)).toContain(invented);
  expect(HISTORICAL.test(`resolve as \`${invented}\` at tier 1`)).toBe(false);
});
