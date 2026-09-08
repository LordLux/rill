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
 * This is deliberately **one file with two assertions**, not a documentation
 * framework. Each one compares a doc against the code that is the actual
 * authority, and neither needs a list anyone has to maintain.
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
// 1. CLAUDE.md's DTO contract block vs. the real types
// ---------------------------------------------------------------------------

/**
 * Field names per interface, from a TypeScript-ish source.
 *
 * A regex, not a parser. It must be insensitive to layout, because the two
 * sides are laid out differently on purpose: `types.ts` puts one field per
 * line with a doc comment above it, and CLAUDE.md packs the small DTOs onto
 * two lines to keep the contract readable at a glance. An earlier, line-
 * anchored version of this read only the first field on each line and reported
 * three interfaces as mismatched when every one of them agreed.
 */
function interfaceFields(source: string): Map<string, Set<string>> {
  // Comments go first, and not for tidiness: `types.ts` documents
  // `VideoItem.isVerified` with a `{@link isArtistChannel}`, whose closing
  // brace ends the interface body as far as the match below is concerned. The
  // effect was that the last five fields of the largest DTO in the app simply
  // did not exist to this check.
  const stripped = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

  const out = new Map<string, Set<string>>();
  const blocks = stripped.matchAll(/interface\s+(\w+)\s*\{([^}]*)\}/g);
  for (const [, name, body] of blocks) {
    const fields = new Set<string>();
    for (const [, field] of (body ?? '').matchAll(/(?:^|[{;\n])\s*(\w+)\s*\??\s*:/g)) {
      fields.add(field!);
    }
    out.set(name!, fields);
  }
  return out;
}

describe('CLAUDE.md documents the DTOs the code actually ships', () => {
  const documented = interfaceFields(doc('CLAUDE.md'));
  const actual = interfaceFields(readFileSync(join(SRC, 'types.ts'), 'utf8'));

  test('the contract block was found at all', () => {
    // Guards against the check silently passing because the block moved,
    // was renamed, or stopped being a fenced `ts` block.
    expect([...documented.keys()]).toContain('VideoItem');
    expect(documented.size).toBeGreaterThanOrEqual(4);
  });

  for (const [name, fields] of documented) {
    test(`${name}`, () => {
      const real = actual.get(name);
      expect(real, `CLAUDE.md documents \`${name}\`, which types.ts does not define`).toBeDefined();
      expect([...fields].sort(), `\`${name}\` in CLAUDE.md and in types.ts`).toEqual(
        [...real!].sort(),
      );
    });
  }
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
