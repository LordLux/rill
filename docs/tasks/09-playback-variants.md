# Task 09 — `variants[]` in `PlaybackSource`

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.5, `docs/architecture.md`
F16.

Small and self-contained. `protocol.md` §3.5 was amended so `PlaybackSource`
carries a ranked `variants[]`; `sidecar/src/playback/resolve.ts` predates the
amendment and still returns one `videoUrl`/`audioUrl` pair at the top level.
Task 08 hit that gap and correctly reported it rather than reshaping one side to
fit the other.

This closes it. **No RPC work** — that is Task 10.

---

## Why the shape changed

F16 measured 2160p60 dropping 16–29% of frames on an Intel iGPU while 1080p60
dropped none. So "tallest available" is not "best", and a cap chosen in the
sidecar would be wrong differently on every machine. The sidecar ranks; the
client picks and may step down on sustained frame drops.

## What to build

`openPlayback` returns `PlaybackSource` with `variants[]` exactly as §3.5
specifies. Each entry:

```ts
{ videoUrl, audioUrl, itag, height, fps, videoCodec, audioCodec }
```

Rules:

- **One `/player` response, many variants.** Do not make a round trip per
  variant. `spiking/07-resolve.ts` already does this — it signs itags
  401/315/399/303 from a single cached response. Reuse that approach.
- **Ranked best-first**, by height, then fps, then codec preference. The client
  reads the order as the sidecar's recommendation.
- **Every variant is playable.** A variant that cannot be signed is omitted, not
  emitted with a null URL.
- **Every `videoUrl` and `audioUrl` is a `SignedUrl`** (hard invariant 2). The
  branded type applies to every entry, not just the first.
- **Audio may be shared.** If one audio track serves several video variants,
  reuse the same signed URL rather than signing it repeatedly.
- **`height` and `fps` come from the format**, not from the itag. An itag→height
  lookup table will be wrong the first time YouTube reuses a number.

## Tiers that cannot offer a choice

Tiers 3, 4 and 5 may legitimately return a single variant — the progressive
floor is one format by definition, and a yt-dlp dump is whatever it resolved.
That is fine: `variants` is an array with one entry, not a special case.

`qualityDegraded` keeps its current meaning and is unaffected.

## Fields that leave the top level

`videoUrl`, `audioUrl`, `videoCodec`, `audioCodec` and `height` move into each
variant. `sessionId`, `durationMs`, `storyboardTemplate`, `qualityDegraded` and
`transport` stay where they are.

Grep for every consumer before changing the type — `spiking/`, the existing
tests, and Task 08's Dart harness if it is on this branch. A consumer left
reading the old top-level fields is the failure this task exists to prevent.

---

## Tests

- Tier 1 returns more than one variant from one `/player` response, and makes
  exactly one network call doing it
- Variants are ordered best-first; the order is asserted, not assumed
- Every variant's URLs are branded `SignedUrl`s
- A format that fails to sign is absent from the array, not present with a null
- Tiers 4 and 5 return exactly one variant and remain valid
- `PlaybackSource` still survives JSON round-tripping with no field lost, and
  the branded URLs are plain strings on the wire
- `height` and `fps` match the format's own fields, not a lookup table
- The existing 114 stay green

Add a fixture-backed variant test to the offline suite so this does not depend
on the network.

## Definition of done

- `bun test` green, including the existing suite
- Typecheck and lint clean
- No consumer anywhere still reads a top-level `videoUrl`

## Out of scope

The RPC transport. The quality stepper — the client-side logic that watches
frame drops and steps down is a later task; this only makes the choice
available. Any `app/` work beyond fixing a consumer that no longer compiles.

## Stop conditions

- **A tier cannot produce more than one signable variant** where you expected
  several. Report the tier and why, rather than emitting a one-entry array and
  calling it done.
- **`protocol.md` §3.5 and this brief disagree** on any field. The protocol
  wins; say so in the report.
