# Task 12 — `feed.home` end to end

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.2 and §7,
`docs/architecture.md` §2.2 and the DTO contract in `CLAUDE.md`.

The first feed method over the wire, and the first time the sidecar's DTOs reach
Dart. That contract is the point of this task — the grid is the smallest thing
that proves it.

**Deliberately plain.** No hover previews, no storyboards, no action buttons, no
quality stepper, no navigation. Those are Task 13. A task that builds the tile
and the contract at once debugs both through each other.

---

## 1. Sidecar — `feed.home`

`protocol.md` §3.2: `{chipToken?, continuation?}` →
`{chips[], items[], continuation?}`.

The parser already produces these DTOs and is tested against the fixture corpus.
This exposes it over RPC — it should be close to wiring, not new logic. If it
turns out not to be, that is worth reporting.

- Authenticated `WEB` session, per §2.3
- `chipToken` selects a chip; `continuation` fetches the next page. Both are
  parameters on the same method — no separate `*.more`
- `chips[]` carries both generations, `scope: 'feed' | 'shelf'`
- Shorts stripped
- Unknown renderers skipped and logged, never fatal (hard invariant 4)

**Session creation stays lazy.** `event.ready` must remain under 500 ms — the
first `feed.home` pays for the session, not startup. The existing assertion
should still pass untouched.

## 2. Dart — `freezed` models mirroring the DTOs

`app/lib/domain/`. Mirror `CLAUDE.md`'s DTO contract exactly:
`VideoItem`, `MixItem`, `PlaylistItem`, `ChannelItem`, `Chip`.

- `kind` is the discriminator — a sealed union, so the UI switches exhaustively
- Every field a value or `null`, never absent. A missing view count is not a
  reason to drop an item
- An **unknown `kind` must not throw**. The sidecar's tolerance is worthless if
  the Dart side is strict — parse it into an `UnknownItem` the grid skips, and
  log it

## 3. Contract tests — the point of §7

Both sides test against the **same fixtures**, which is what makes this a
contract rather than two hopeful implementations.

Export a representative slice of `sidecar/fixtures/` as parsed DTO JSON into a
location both suites read. The Dart tests parse that JSON into `freezed` models
and assert nothing is lost.

Required:
- Every DTO kind round-trips sidecar → JSON → `freezed` with no field lost
- A payload with an unknown `kind` parses; the unknown item is skipped, the
  siblings survive
- A `null` in every nullable field parses rather than throwing
- The sidecar's parser tests still pass against the same corpus

Fixtures are gitignored (personal data). The exported DTO slice must be
**sanitised** — fake video IDs, channel names and thumbnail URLs — so it can be
committed. That sanitised set is the contract corpus from here on.

## 4. The grid

`app/lib/ui/`. Replace the Task 07 harness as the default view; keep the player
reachable behind a debug route so playback stays testable.

- Chips as a horizontal strip. Tapping one refetches with its token
- Responsive grid: thumbnail, title, channel name, duration, view count
- Infinite scroll: fetch the continuation as the user nears the bottom
- Loading, empty and error states. `AUTH_DEGRADED` shows a re-auth prompt, not
  an empty grid (§3.1)

**Riverpod for state.** A `FeedController` owning items, chips, selected chip,
continuation token and loading state.

Visual polish is not the point. A working grid that is plainly styled is the
target; a beautiful one that hides a contract bug is not.

## 5. Two constraints that will bite

**Hard invariant 9.** Nothing in the UI polls `NativePlayer.getProperty`. Not
relevant to the grid directly, but the debug player route still uses it.

**JSON decoding off the UI isolate.** A feed page is the large payload Task 10's
isolate work anticipated. Verify it holds under a real `feed.home` response, not
just the synthetic test — a stutter on every scroll-triggered fetch is the
failure mode.

Cancellation matters here for the first time: scrolling fast issues
continuations the user has scrolled past. Wire `$cancel` to superseded requests.

---

## Definition of done

- `flutter run -d windows` shows the real personalised home feed with working
  chips and infinite scroll
- `bunx tsc --noEmit` clean, `bun test` green, `flutter test` green
- The contract corpus is committed and both suites read it
- `event.ready` still under 500 ms
- Scrolling does not stutter on fetch

**Run the app and say what you saw** — item count, whether chips changed the
feed, whether scroll stayed smooth. A screenshot description is fine. This is
the part no test covers.

## Report

State whether exposing the parser was wiring or turned out to need new logic. If
any DTO needed a field the contract does not have, say which and stop — the
contract is shared, and widening it on one side breaks the other.

## Out of scope

Hover previews, storyboards, tile action buttons, the quality stepper, watch
navigation, search, subscriptions, playback reporting, Task 04 item 1.

## Stop conditions

- **A DTO cannot represent something the feed contains** without adding a field.
  Report it; do not widen `CLAUDE.md`'s contract unilaterally.
- **`event.ready` regresses past 500 ms.** Something moved back into startup.
- **The sanitised corpus cannot be produced** without hand-editing every file —
  say so rather than committing real personal data.
