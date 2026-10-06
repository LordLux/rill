# Task 34: Play playlists (todo 58)

**Read first:** `CLAUDE.md` (hard invariants 1, 4 and 6; the DTO block),
`docs/protocol.md` §3.3, `architecture.md` F24 and F25, `docs/todo.md` items 58
and 59, and `sidecar/src/mix/service.ts`'s header comment. That comment explains
how mixes work, and playlists must **not** be made to work the same way.

**The bug.** Tapping a playlist tile does nothing. `tapHandlerFor`
(`app/lib/ui/open_video.dart`) handles `MixItem`, and every other kind goes
through `watchTargetFor`, which has no answer for a `PlaylistItem`, so the tap
handler is null. Mixes play through their own path (`mix.start` / `mix.extend`,
`startMixFromTile`, the queue's `MixQueue`). Playlists have no path at all.

`playlist.get` is in `protocol.md` §3.3, marked **not implemented**, with a
paragraph saying so. Guard 2 (`sidecar/test/contract-docs.test.ts`) keeps that
marking honest, so the handler and the removal of the marking land together.

**Playlists are not mixes.** A mix is a sliding window with no continuation,
extended by re-anchoring (F24). A playlist is a finite, ordered list that pages
with real continuations. Share the queue machinery where it is genuinely the
same: the "top up before it runs out" threshold, the undo, the panel naming the
list. Do not route a playlist through mix logic, or the other way round.

---

## 1. Measure first

Use raw responses only (`parse: false`, invariant 1). `capture.ts` already saves
`/browse {browseId: 'VL<id>'}` as `fixtures/playlist.json` when a capture finds a
playlist; start from that, and capture fresh ones as needed. Find out:

1. **Where the list lives:** in `/browse VL<id>`, and in `/next {playlistId}`
   (the watch page's playlist panel). Pick one source for `playlist.get` and say
   why. `/browse VL<id>` is the likely answer: it pages, and it is also what the
   detail page (item 59) will need.
2. **Paging:** the page size, where the continuation token sits, and what a
   continuation request returns. Test a playlist with **more than 200 videos**.
3. **Unavailable entries:** what a private or deleted video looks like in the
   list, so the parser can skip it.
4. **Auth:**
   - whether a public playlist answers anonymously;
   - what an unlisted one and a private one (the viewer's own, signed in) return;
   - what `WL` (Watch Later) and `LL` (Liked videos) return signed in.

   Only measure these. Building the Watch Later page is not this task.
5. **The header:** title, owner, count, visibility, description, thumbnail.
   Record which fields exist, in the item 59 notes in `todo.md`. Do not build
   the page.

**Report what you found before building.** Put the measurements in the report;
they also become the `architecture.md` finding (§6).

## 2. The sidecar: `playlist.get`

- **The shape stays `{playlistId, continuation?}` → `{items: VideoItem[],
  continuation: string | null}`.** If you add a field (a `title` for the first
  page, say), restate it everywhere the DTO lives:
  - `protocol.md`;
  - `CLAUDE.md`'s DTO block;
  - `types.ts`;
  - the Dart model;
  - the corpus sanitiser.

  `contract-docs.test.ts` checks the first three.
- **Tolerant parsing (invariant 4).** An unknown renderer drops one row, never
  the page. Unavailable entries are skipped, with one log line saying how many.
  Renderer trees stay in the sidecar (invariant 6).
- **Parameter validation before any I/O,** like every other handler: a missing
  or blank `playlistId` is `BAD_REQUEST`.
- **Remove the "not implemented" marking and its paragraph** from `protocol.md`,
  and write the real paging behaviour there instead.
- **Add a sanitised corpus entry** through `export-contract-corpus`, so the Dart
  contract test covers the new response.

## 3. The app: starting a playlist and keeping it going

1. **Tap.** `tapHandlerFor` gives a `PlaylistItem` a handler,
   `startPlaylistFromTile`, modelled on `startMixFromTile`:
   - open the watch page before the round trip, so the click is never dead;
   - start at the first playable video;
   - offer the same undo, because it replaces the queue;
   - on failure, put the old queue back and say why.
2. **The queue knows it is playing a playlist.** Generalise `MixQueue` into a
   list source with two kinds, mix and playlist. Or keep two types if that reads
   better; your call, but keep one field on `QueueState`, so every mutation
   either keeps the source or drops it deliberately.
   - A **mix** keeps today's behaviour exactly: re-anchor, and stop when
     `exhausted`.
   - A **playlist** tops up through `playlist.get` with its continuation, at the
     same threshold. It ends when the continuation is null.
   - At the end, a playlist stops the way a hand-built queue does (Task 14),
     with no autoplay into something else.
3. **The panel names the playlist,** as it names a mix. The tile's title is
   enough if `playlist.get` does not return one.
4. **Reporting.** `playback_controller.dart` passes `playlistId` to
   `playback.open` only for a mix today (`queueProvider.mix?.playlistId`). Pass
   the source's id for both kinds, so a watch inside a playlist is reported with
   `list=` (F25). **Verify it is:** check the watchtime URL's `list` parameter
   for a playlist watch, the way F25 was measured.
5. **Not this task:** shuffle, loop, starting at the Nth video, the detail page
   (item 59), and editing playlists.

## 4. Tests

**Sidecar:**
- the parser against the captured fixture (guarded by `hasFixture`, like the
  others), plus a small synthetic tree: an unavailable entry is skipped and the
  continuation is extracted;
- a blank `playlistId` is `BAD_REQUEST`;
- Guard 2 passes with the marking removed.

**App:**
- tapping a playlist tile starts a playlist;
- the queue tops up through the continuation at the threshold;
- a null continuation ends it, and nothing else is fetched;
- a mix still extends by re-anchoring;
- `playback.open` carries the playlist's id;
- the undo restores the previous queue.

**Mutations,** each must fail a test, and paste the output:
1. ignore the continuation;
2. send a playlist through the mix extension;
3. drop `playlistId` from `playback.open` for playlists;
4. keep fetching after a null continuation.

## 5. Hand-off to the user

1. Play a public playlist from search and from the home feed.
2. Play one with **more than 200 videos** and skip ahead, to check that paging
   works past the first page.
3. Play one that contains private or deleted videos. They are skipped, and
   playback never stops on them.
4. Check that the queue panel shows the playlist's name and that undo works.
5. Play a mix, to check it behaves as before.

## 6. Docs

- **`protocol.md`:** `playlist.get` documented with its real paging.
- **`architecture.md`:** a finding with §1's measurements. Use the next free F
  number. Read the table for it; do not count.
- **`todo.md`:** delete item 58; add §1's header findings to item 59.
- **`CLAUDE.md`'s DTO block,** if the shape changed.

**Todo numbering.** Two agents have recently given out a number that was already
taken. If you add an item, take its number from the **"Next number" line of the
file as it is on disk at that moment**, and bump that line in the same edit.
Never number from your own count or from a copy you read earlier.

---

## Definition of done

- §1's measurements in the report and in an `architecture.md` finding
- `playlist.get` implemented; the protocol marking removed; Guard 2 green
- A playlist plays from its tile, pages past 200 videos, skips unavailable
  entries, ends cleanly, and is reported with `list=`
- Mixes unchanged
- Tests and the four mutations above
- `.\rill check` and `cd sidecar; bun run check` green, raw output pasted
- The §5 hand-off given to the user

## Out of scope

- The playlist detail page (item 59); shuffle, loop and starting at an index.
- Watch Later and history pages, beyond §1's measurement.
- Editing playlists.

## Stop conditions

- **A public playlist needs auth,** or the list is not at `/browse VL<id>` or
  `/next` in any usable form. Report it.
- **Paging needs something unusual** (a token the client must build, or a
  hard cap). Report it before working around it.
- **Generalising the queue would change mix behaviour.** Report it; do not
  alter F24's semantics to make it fit.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Edit files with your editor tools only, never with scripts that rewrite source
  files. Delete any helper scripts before reporting.
- Say plainly what you ran and what you handed to the user.
