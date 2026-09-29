/**
 * The `css-tree` patch survives — asserted directly against the installed
 * copy, offline.
 *
 * `po-token.ts` (F48) pulls in `jsdom`, which pulls in `css-tree`. Three of
 * its files read local JSON through `createRequire(import.meta.url).require(
 * '...json')` — an ordinary, working pattern under `bun run`, and one
 * `bun build --compile` does not statically trace: the compiled binary exits
 * 0 and then crashes the first time the code path actually runs, with
 * `Cannot find module '../data/patch.json'`. That is exactly the silent-
 * success shape this project keeps finding (F19, F42, the release-bundle
 * staleness notes in `CLAUDE.md`) — `bun run build` reports success, `rill
 * check` never touches a compiled binary, and the first sign of trouble would
 * be a user's sidecar dying the moment `po-token.ts` first runs.
 *
 * The fix is `patches/css-tree@3.2.1.patch` (`bun patch`, recorded in
 * `package.json`'s `patchedDependencies`), converting those three reads to
 * static `import ... with { type: 'json' }`. A patch is inert unless it
 * actually reapplies on every `bun install` — including a `bun update` that
 * bumps `css-tree` to a version this patch does not target, which `bun`
 * silently skips rather than fails. So this checks the *installed* copy
 * directly, not the patch file's existence: `bun install` ran as part of
 * getting this suite to execute at all, so a lost or skipped patch is caught
 * here, offline, well before anyone reaches for a compiled binary to find out.
 */

import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const CSS_TREE_LIB = join(ROOT, 'node_modules', 'css-tree', 'lib');

const PATCHED_FILES = ['data.js', 'data-patch.js', 'version.js'];

describe('the css-tree patch (architecture.md F48)', () => {
  test('package.json declares it', () => {
    const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8')) as {
      patchedDependencies?: Record<string, string>;
    };
    expect(pkg.patchedDependencies?.['css-tree@3.2.1']).toBe('patches/css-tree@3.2.1.patch');
  });

  test('the patch file exists', () => {
    const patch = readFileSync(join(ROOT, 'patches', 'css-tree@3.2.1.patch'), 'utf8');
    expect(patch).toContain('data.js');
    expect(patch).toContain('data-patch.js');
    expect(patch).toContain('version.js');
  });

  test('the installed copy actually has it applied', () => {
    for (const file of PATCHED_FILES) {
      const source = readFileSync(join(CSS_TREE_LIB, file), 'utf8');
      expect(
        source,
        `node_modules/css-tree/lib/${file} still reads a local JSON file through ` +
          "createRequire(import.meta.url) — the patch did not apply (a css-tree version " +
          'bump bun silently skipped it for, a --no-save install, a manual node_modules ' +
          'edit undone). This file will crash the moment it runs inside a compiled binary: ' +
          "\"Cannot find module '../data/patch.json'\". Re-run `bun patch css-tree`, reapply " +
          'the three static-import edits (F48), and `bun patch --commit node_modules/css-tree`.',
      ).not.toContain('createRequire');
    }
  });
});
