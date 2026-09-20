/**
 * No fixture is destroyed by a tool that does not own it — asserted, not
 * reasoned about.
 *
 * `todo.md` 41: `comments.json`, `comments-replies.json` and
 * `comments-viewer-state.json` sat in `sidecar/fixtures/` with no stage of
 * `capture.ts` writing them, and `promoteStaging` replaces that directory
 * wholesale. One routine `bun run capture` would have deleted all three, and
 * every test guarded by `hasFixture('comments…')` would then have **skipped
 * silently**. It was found by reading the code, because running the thing would
 * have been the accident.
 *
 * Two halves, and each covers the other's gap:
 *
 *   - The declaration in `src/fixtures.ts` is checked against `capture.ts`'s
 *     actual stages, statically. A stage added without a declaration, or a
 *     declaration with no stage, fails here rather than a whole capture run
 *     later.
 *   - `prepareStaging` and `promoteStaging` are driven against **real temporary
 *     directories**, including the refusals. The question is what survives on
 *     disk, so the assertions read the disk.
 *
 * `promoteStaging` answers a boolean instead of calling `process.exit` for
 * exactly this reason — see its comment.
 */

import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import { mkdtemp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { CAPTURE_FILES, CARRIED, lostFixtures, unownedEntries } from '../src/fixtures.ts';
import { prepareStaging, promoteStaging } from '../src/capture.ts';

const SIDECAR = join(dirname(fileURLToPath(import.meta.url)), '..');

// ---------------------------------------------------------------------------
// The declaration against the script
// ---------------------------------------------------------------------------

describe('the fixture ownership declaration', () => {
  /**
   * Every `capture('<name>', …)` in the script. A source scan rather than a run:
   * running it is a live capture, which is the act this whole file exists to
   * make safe.
   */
  const stageNames = (() => {
    const source = readFileSync(join(SIDECAR, 'src', 'capture.ts'), 'utf8');
    const names = new Set<string>();
    for (const match of source.matchAll(/\bcapture\(\s*'([a-z0-9-]+)'/g)) names.add(match[1]!);
    return names;
  })();

  test('the scan found the stages at all', () => {
    // A regex that silently matches nothing would make every assertion below
    // vacuously true — the same shape of failure as a test file that does not
    // load. `home` is the one stage the run aborts without.
    expect(stageNames.size).toBeGreaterThan(10);
    expect(stageNames.has('home')).toBe(true);
  });

  test('every stage capture.ts writes is declared', () => {
    const declared = new Set(CAPTURE_FILES.map((file) => file.name));
    const undeclared = [...stageNames].filter((name) => !declared.has(`${name}.json`));
    expect(undeclared).toEqual([]);
  });

  test('every declared capture file is written by a stage', () => {
    // A declaration with no stage behind it is worse than harmless: if it is
    // `required`, `lostFixtures` reports it missing on every run and the promote
    // refuses forever.
    const orphaned = CAPTURE_FILES.map((file) => file.name)
      .filter((name) => name !== 'manifest.json')
      .filter((name) => !stageNames.has(name.replace(/\.json$/, '')));
    expect(orphaned).toEqual([]);
  });

  test('manifest.json is declared, though no stage writes it', () => {
    // Written directly at the end of the run. Undeclared, it would be reported
    // as unowned by the next run and refuse the promote.
    expect(CAPTURE_FILES.some((file) => file.name === 'manifest.json')).toBe(true);
  });

  test('nothing is both captured and carried', () => {
    // The promote copies each carried entry into staging. An overlap would
    // silently clobber the file this run just captured, with the older one.
    const captured = new Set(CAPTURE_FILES.map((file) => file.name));
    expect(CARRIED.filter((entry) => captured.has(entry))).toEqual([]);
  });

  test("todo.md 41's three fixtures are each accounted for", () => {
    // The regression, named. Two became stages; the third cannot be, and is
    // carried — `src/fixtures.ts` says why.
    expect(unownedEntries(['comments.json', 'comments-replies.json', 'comments-viewer-state.json'])).toEqual([]);
    const captured = CAPTURE_FILES.map((file) => file.name);
    expect(captured).toContain('comments.json');
    expect(captured).toContain('comments-replies.json');
    expect(CARRIED).toContain('comments-viewer-state.json');
    expect(CARRIED).toContain('viewer-state');
  });
});

describe('unownedEntries', () => {
  test('flags an entry belonging to neither side, and names it', () => {
    expect(unownedEntries(['home.json', 'comments-by-hand.json', 'viewer-state'])).toEqual([
      'comments-by-hand.json',
    ]);
  });

  test('an empty or fully-owned directory is clean', () => {
    expect(unownedEntries([])).toEqual([]);
    expect(unownedEntries([...CAPTURE_FILES.map((file) => file.name), ...CARRIED])).toEqual([]);
  });
});

describe('lostFixtures', () => {
  test('a required file present live and absent from this run is a loss', () => {
    expect(lostFixtures(['home.json', 'history.json'], ['home.json'])).toEqual(['history.json']);
  });

  test('an optional stage that did not run this time is not a loss', () => {
    // `mix` and `playlist` chain off whatever the live feeds contained. They
    // legitimately vanish between runs, and refusing on one would make the
    // promote a coin toss.
    const optional = CAPTURE_FILES.filter((file) => !file.required).map((file) => file.name);
    expect(optional.length).toBeGreaterThan(0);
    expect(lostFixtures(optional, [])).toEqual([]);
  });

  test('a carried entry is never reported as lost', () => {
    // It is not this run's to produce. Reporting it would refuse every promote
    // on a machine that has run `capture:viewer-state`.
    expect(lostFixtures([...CARRIED], [])).toEqual([]);
  });

  test('a first run, with nothing live, loses nothing', () => {
    expect(lostFixtures([], [])).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// The destructive path, on real directories
// ---------------------------------------------------------------------------

describe('promoteStaging', () => {
  let root: string;
  let fixtures: string;
  let staging: string;

  /** Everything a promote needs to succeed: every required file, in staging. */
  async function stageAComplete(): Promise<void> {
    for (const file of CAPTURE_FILES.filter((entry) => entry.required)) {
      await writeFile(join(staging, file.name), `{"from":"staging","file":"${file.name}"}`, 'utf8');
    }
  }

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'rill-fixtures-'));
    fixtures = join(root, 'fixtures');
    staging = join(root, 'fixtures.partial');
    await mkdir(fixtures, { recursive: true });
    await mkdir(staging, { recursive: true });
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  test('replaces the captured files and carries the rest across', async () => {
    await writeFile(join(fixtures, 'home.json'), '{"from":"the previous run"}', 'utf8');
    await writeFile(join(fixtures, 'comments-viewer-state.json'), '{"liked":4}', 'utf8');
    await mkdir(join(fixtures, 'viewer-state'), { recursive: true });
    await writeFile(join(fixtures, 'viewer-state', 'watch-after.json'), '{"state":"after"}', 'utf8');
    await stageAComplete();

    expect(await promoteStaging(fixtures, staging)).toBe(true);

    // Replaced.
    expect(JSON.parse(await readFile(join(fixtures, 'home.json'), 'utf8'))).toEqual({
      from: 'staging',
      file: 'home.json',
    });
    // Carried, byte for byte, including the subdirectory's contents.
    expect(await readFile(join(fixtures, 'comments-viewer-state.json'), 'utf8')).toBe('{"liked":4}');
    expect(await readFile(join(fixtures, 'viewer-state', 'watch-after.json'), 'utf8')).toBe('{"state":"after"}');
    expect(existsSync(staging)).toBe(false);
  });

  test('refuses on an entry owned by nothing, and deletes nothing', async () => {
    // `todo.md` 41 as it actually was: an ad-hoc capture at the top level, with
    // no stage behind it. Before this guard, this promote deleted it.
    await writeFile(join(fixtures, 'home.json'), '{"from":"the previous run"}', 'utf8');
    await writeFile(join(fixtures, 'captured-by-hand.json'), '{"irreplaceable":true}', 'utf8');
    await stageAComplete();

    expect(await promoteStaging(fixtures, staging)).toBe(false);

    expect(await readFile(join(fixtures, 'captured-by-hand.json'), 'utf8')).toBe('{"irreplaceable":true}');
    expect(await readFile(join(fixtures, 'home.json'), 'utf8')).toBe('{"from":"the previous run"}');
    // The run is not thrown away either — it is still in staging to retry from.
    expect((await readdir(staging)).length).toBeGreaterThan(0);
  });

  test('refuses when a required stage failed, rather than replacing a good copy with nothing', async () => {
    await stageAComplete();
    await rm(join(staging, 'history.json'));
    for (const file of CAPTURE_FILES.filter((entry) => entry.required)) {
      await writeFile(join(fixtures, file.name), `{"from":"the previous run"}`, 'utf8');
    }

    expect(await promoteStaging(fixtures, staging)).toBe(false);

    expect(await readFile(join(fixtures, 'history.json'), 'utf8')).toBe('{"from":"the previous run"}');
  });

  test('an optional stage that did not run does not refuse the promote', async () => {
    await stageAComplete();
    await writeFile(join(fixtures, 'mix.json'), '{"from":"the previous run"}', 'utf8');

    expect(await promoteStaging(fixtures, staging)).toBe(true);
    expect(existsSync(join(fixtures, 'mix.json'))).toBe(false);
  });

  test('a first run, with no fixtures/ at all, promotes', async () => {
    await rm(fixtures, { recursive: true, force: true });
    await stageAComplete();

    expect(await promoteStaging(fixtures, staging)).toBe(true);
    expect(existsSync(join(fixtures, 'home.json'))).toBe(true);
  });
});

describe('prepareStaging', () => {
  let root: string;
  let staging: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'rill-fixtures-'));
    staging = join(root, 'fixtures.partial');
    await mkdir(staging, { recursive: true });
  });

  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });

  test('clears an ordinary leftover staging directory', async () => {
    await writeFile(join(staging, 'home.json'), '{"half a run"}', 'utf8');

    expect(await prepareStaging(staging)).toBe(true);
    expect(await readdir(staging)).toEqual([]);
  });

  test('refuses to clear a staging directory holding carried fixtures', async () => {
    // The crash window: `promoteStaging` copies the carried entries in, then
    // swaps. A run that dies between those two leaves this copy as the only one,
    // and clearing staging on the next run would finish what the crash started.
    await mkdir(join(staging, 'viewer-state'), { recursive: true });
    await writeFile(join(staging, 'viewer-state', 'watch-after.json'), '{"state":"after"}', 'utf8');

    expect(await prepareStaging(staging)).toBe(false);
    expect(await readFile(join(staging, 'viewer-state', 'watch-after.json'), 'utf8')).toBe('{"state":"after"}');
  });

  test('creates the staging directory when it is absent', async () => {
    await rm(staging, { recursive: true, force: true });

    expect(await prepareStaging(staging)).toBe(true);
    expect(await readdir(staging)).toEqual([]);
  });
});
