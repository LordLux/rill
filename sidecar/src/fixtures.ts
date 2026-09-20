/**
 * Who owns what under `sidecar/fixtures/`.
 *
 * `capture.ts` replaces that directory **wholesale** — the rule is one run, one
 * corpus, because a stale file left behind from an earlier run once produced a
 * completely wrong reading of the live feed. Two other tools write there as
 * well, and a wholesale replace does not know that. `comments.json`,
 * `comments-replies.json` and `comments-viewer-state.json` sat at the top level
 * for weeks with no stage writing them (`todo.md` 41): one routine
 * `bun run capture` would have deleted all three, and every test guarded by
 * `hasFixture('comments…')` would then have **skipped silently** — the same trap
 * as a test file that does not load.
 *
 * So ownership is declared here, in one place, and `capture.ts` enforces it
 * rather than assuming it:
 *
 *   - Anything in `fixtures/` that is neither a file this run writes nor a
 *     carried entry **refuses the promote**. The run's captures stay in
 *     `fixtures.partial/`, `fixtures/` is untouched, and the offending entries
 *     are named. That is the load-bearing half: the next ad-hoc capture dropped
 *     at the top level stops a capture run instead of vanishing into one.
 *   - A **net loss** refuses too. A stage that failed leaves nothing in staging,
 *     and promoting over a good copy would delete a fixture this run did not
 *     replace. `required: false` marks the stages that legitimately do not run
 *     every time, because they chain off whatever the live feeds contained.
 *
 * Rejected: clearing only the names this run writes. It reads like the safe
 * option and it quietly repeals "one run, one corpus" — a file whose stage has
 * since been renamed or dropped would survive and be read as part of the next
 * run's corpus, which is the exact failure the wholesale replace exists to
 * prevent. Rejected too: a subdirectory per tool as the *only* mechanism. It is
 * tidier on paper, but a convention nothing checks is how these three files
 * reached the top level to begin with, and it would force
 * `comments-viewer-state.json` to pretend it belongs to a tool that cannot
 * produce it (see `CARRIED`).
 */

/** A top-level file `capture.ts` writes, and therefore may replace. */
export interface CaptureFile {
  name: string;
  /**
   * `false` for a stage that chains off whatever the live feeds contained and
   * legitimately does not run every time. Only those may vanish between runs.
   */
  required: boolean;
}

export const CAPTURE_FILES: readonly CaptureFile[] = [
  { name: 'home.json', required: true },
  // Present only when the home feed carried a continuation token.
  { name: 'home-continuation.json', required: false },
  { name: 'subscriptions.json', required: true },
  { name: 'channels.json', required: true },
  { name: 'history.json', required: true },
  { name: 'watch-later.json', required: true },
  { name: 'search.json', required: true },
  { name: 'search-artist.json', required: true },
  // Only runs when neither home nor search contained a playlist.
  { name: 'search-playlists.json', required: false },
  // Both chain off a playlist/mix found in live data, which may not be there.
  { name: 'playlist.json', required: false },
  { name: 'mix.json', required: false },
  { name: 'watch.json', required: true },
  { name: 'player-web.json', required: true },
  { name: 'player-mweb.json', required: true },
  { name: 'player-vr.json', required: true },
  { name: 'comments.json', required: true },
  { name: 'comments-replies.json', required: true },
  { name: 'manifest.json', required: true },
];

/**
 * Entries `capture.ts` must carry across untouched, because something else owns
 * them. Each one needs a reason here — a carried entry is a fixture no capture
 * run can rebuild, so this list is also the list of what a `rm -rf fixtures/`
 * would cost.
 *
 *   `viewer-state/`
 *     `capture-viewer-state.ts`'s output: a pair of captures taken with the
 *     account deliberately put in a known state, verified against the raw
 *     response before anything is written. Reproducing it means mutating the
 *     account (like, subscribe, Watch Later, heart) and undoing it again.
 *
 *   `comments-viewer-state.json`
 *     A signed-in comments page on **someone else's** video: 4 comments the
 *     viewer liked and 1 the creator hearted, read as a non-creator
 *     (`TOOLBAR_HEART_STATE_HEARTED`, the plain variant — `viewer-state/` holds
 *     only the `…_EDITABLE` one the creator sees, and the plain one anonymously).
 *     It is the fixture F33 was fixed against. **No tool owns it and none can:**
 *     `capture.ts`'s comments stage is anonymous by design, and
 *     `capture-viewer-state.ts` targets the account's own comment on its own
 *     video precisely so that setting the state touches nobody else. Rebuilding
 *     this one means liking and un-liking four strangers' comments. Declared as
 *     what it is rather than filed under a tool that would not produce it.
 */
export const CARRIED: readonly string[] = ['viewer-state', 'comments-viewer-state.json'];

const CAPTURE_NAMES: ReadonlySet<string> = new Set(CAPTURE_FILES.map((file) => file.name));
const CARRIED_NAMES: ReadonlySet<string> = new Set(CARRIED);

/** Entries in `fixtures/` that belong to neither side of the declaration. */
export function unownedEntries(entries: readonly string[]): string[] {
  return entries.filter((entry) => !CAPTURE_NAMES.has(entry) && !CARRIED_NAMES.has(entry)).sort();
}

/**
 * Required capture files that `fixtures/` holds and this run did not produce.
 * Promoting over them would delete a fixture nothing replaced — the same loss
 * as the unowned case, arriving through the owner rather than past it.
 */
export function lostFixtures(live: readonly string[], staged: readonly string[]): string[] {
  const present = new Set(staged);
  return live
    .filter((entry) => {
      const file = CAPTURE_FILES.find((candidate) => candidate.name === entry);
      return file?.required === true && !present.has(entry);
    })
    .sort();
}
