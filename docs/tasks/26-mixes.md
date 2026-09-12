# Task 26 — Mixes

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.3 and §5,
`docs/architecture.md` §2.2, and the Task 14 and Task 21 reports.

A day-one requirement, currently half-built. Clicking a mix plays its first
video and nothing else — the mix itself never reaches the queue.

Task 14 deferred this explicitly: *"when the queue empties, stop — pulling from
related or a mix is a later task."* This is that task.

---

## 1. What exists, and what is a workaround

- **The parser handles mixes.** `MixItem` with an `RD*` id, `CollectionThumbnailView`
  plus a `"Mix"` badge, tested against the corpus.
- **The Mixes chip** is a feed chip like any other and should already work.
  **Confirm it does** — it was a named day-one requirement and nothing has
  checked it since the spike.
- **`mix.start` is specified** in §3.3 as `{videoId}` → `{playlistId, items[],
  continuation?}`. Verify it exists and does what the spec says. Several
  specified methods have turned out not to.
- **`mixSeedVideoId` is a workaround.** Task 21 hit a stop condition —
  `MixItem` carries the `RD*` id but no video id — and derived the seed rather
  than widening the contract. If `mix.start` takes the playlist id directly,
  **that derivation is dead and should go.**

## 2. Measure before designing

Mixes are dynamic and personalised; they are not playlists that happen to be
long. Establish:

- **What `mix.start` returns**: how many items, and whether the set is stable
  across two calls with the same id
- **What the continuation actually does** — appends more of the same radio, or
  paginates a fixed list. These need different handling
- **Whether `RD` sub-types behave the same.** `RDMM`, `RDAMVM`, `RDCLAK` and
  others exist; if they differ, say how
- **Whether mixes need auth.** An anonymous mix may exist and differ from a
  personalised one. Report both
- **Whether the watch-page response already carries the mix** when you open a
  video that belongs to one — if `/next` returns the playlist panel, `mix.start`
  may be redundant for that entry path

Report all five before building.

## 3. Queue integration — three decisions

**Starting a mix replaces the queue.** That is what youtube.com does, and a mix
appended to an existing queue is neither the queue the user built nor the mix
they asked for.

But say what happens to a queue the user assembled by hand. Silently discarding
it is the worst option; a confirmation is the safest; replacing and offering an
undo is probably right. Pick one and say why.

**The queue must know it is a mix.** The panel should show the mix title, and
the end-of-queue behaviour differs: a hand-built queue stops (Task 14, verified),
a mix extends.

**Autoplay advance is the existing path.** `QueueEntry` identity, the `version`
that only increments when the playhead logically moves, and the completion
advance are all built and tested. Do not rebuild them — extend them.

## 4. Auto-extension

Fetch the continuation as the user nears the end, so the mix never visibly runs
out.

- Pick a threshold and say why — how many items remaining triggers a fetch
- One fetch in flight at a time; a second advance must not fire a duplicate
- A failed extension is not fatal. The queue plays what it has and retries or
  stops cleanly, with the user told if it stopped
- **Do not cache mix contents.** They are personalised and change; a cached mix
  is a stale mix

## 5. Entry points

At minimum:

- A mix tile in the feed or search
- The mix offered on a watch page for a video that belongs to one

Both should land in the same state: playing, with the queue filled and
extensible. If the two paths produce different results, say how.

## 6. Reporting

`playback.report` is load-bearing (F6, re-verified 2026-09-12). YouTube tracks
watching *within* a mix, and a mix is one of the strongest recommendation
signals there is.

Establish whether reporting inside a mix needs the playlist context, and whether
the current call carries it. If it does not and that matters, say so — do not
build it silently.

---

## Tests

- `mix.start` returns items for a real `RD*` id, parsed into the same DTOs
- Starting a mix fills the queue and begins playback
- Nearing the end triggers exactly one extension fetch, not several
- A failed extension leaves the queue playable and the user informed
- A hand-built queue still stops at its end — the Task 14 behaviour must not
  regress
- The queue panel shows a mix as a mix
- `mixSeedVideoId` is gone, or a comment says why it is still needed

**Mutation-check the extension threshold and the single-flight guard.** A test
that advances to the end and asserts more items arrived passes if the fetch
fires on every advance. Assert the count.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- Click a mix; it plays and the queue fills
- Let it run past its initial length and it keeps going
- The Mixes feed chip works
- A hand-built queue still stops at its end
- Starting a mix over an existing queue does whatever §3 decided, visibly

**Run the app and say what you saw** — including letting a mix run long enough
to extend at least once, with the item counts before and after.

## Out of scope

Comments. The custom title bar. Autoplay from related videos when a hand-built
queue ends — that is a separate decision. Saving a mix as a playlist.

## Stop conditions

- **`mix.start` does not exist or does not return what §3.3 says.** Report the
  real shape before building against it.
- **`RD` sub-types diverge enough to need separate handling.** Report which and
  how before adding branches.
- **Mixes require a client other than `WEB`.** Report before building; the
  two-client model is load-bearing.
- **Extending needs per-cue or per-item state the DTOs cannot carry.** Report;
  do not widen the shared contract unilaterally.
