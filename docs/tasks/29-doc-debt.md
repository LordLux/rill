# Task 29 — Documentation debt, and two guards so it stops accumulating

**Prerequisite:** `CLAUDE.md`, `docs/todo.md` items 19–29, `docs/architecture.md`,
`docs/protocol.md`, and `sidecar/test/contract-docs.test.ts`.

Stale documentation is the most expensive recurring failure in this project.
Eleven sites taught `ANDROID_VR` as tier 1 for months. Three contradicting
build_runner notes sat in `CLAUDE.md`. `CLAUDE.md:428` currently says Flutter
draws no captions, which is false. These files are read before any code is
written, so every wrong line costs every future session.

Todo items 19–29 are that debt. This task clears it and adds two checks so the
two worst classes of drift fail a test instead of waiting to be found.

**Almost no product code changes.** The two guards are tests. If a doc edit
reveals a real bug, file it in `todo.md` and do not fix it here.

---

## 1. Verify every claim before editing

Each backlog item is a claim about the code, dated when it was written, and the
code has moved since. At least three are already wrong:

- **Item 25** says `video.comments` has no handler. Task 27 added one, and
  item 39.3 describes how it behaves. Check which is true at HEAD.
- **Item 29** ends with "There is no Task 27." Task 27 (comments) was briefed and
  reported. If `docs/tasks/27-comments.md` is missing from the repo, fix that
  instead of recording the claim.
- **Item 55** is a UI bug filed under "Documentation backlog". Move it to the
  section it belongs in.

For every item, confirm the claim at HEAD before editing. If the claim is
already false, correct the todo entry rather than the doc it points at.

**Report every stale claim you find in the backlog itself.** That list is part
of the deliverable, because it measures how quickly the backlog drifts.

## 2. The edits

Items 19, 20, 21, 23, 24, 25, 26, 27, 28 and 29. The todo entries hold the
detail, so do not restate them here. Four rules apply:

- **Rewrite rather than delete** wherever the todo says so: §2.6, and §2.9's
  option-B amendment. History has to survive. Remember the cost `CLAUDE.md`
  records: a sentence with a dated note is exempt from `contract-docs.test.ts`.
  Date history, and leave current claims undated so they stay checked.
- **Item 23 is a decision, not an inventory.** §2.4 rejected vendoring a newer
  libmpv, and the project now vendors twenty libass DLLs. Say why the earlier
  reasoning does not apply here, and point at `THIRD_PARTY_LICENSES`.
- **Item 24's environment variables come from a grep, not from memory.** Decide
  where the table lives. `CLAUDE.md` is loaded into every session, so a
  30-row table there costs context each time. `docs/configuration.md` with a
  one-line pointer from `CLAUDE.md` is probably better. Say which you chose and
  why.
- **`CLAUDE.md` must record the Bun re-import quirk from F50**: a second
  `import()` of a module whose first import threw returns undefined exports
  instead of re-throwing. The previous session may already have added this
  note. If it is there, check it against F50. If it is missing, add it under
  "Notes that will bite otherwise".

## 3. Guard 1 — renderer parity

Item 19 records that mpv and `LibassLayer` are both user-selectable. §2.9 has
already paid once for "two things can draw a caption":
`PlayerConfiguration.libass` defaulted to off, and Flutter drew tag-stripped
plain text for two whole tasks. Nobody saw it, because a plain caption looks
correct either way.

With two selectable renderers, **a regression in whichever one is not selected
will not be noticed.**

Render the same ASS document through both paths and assert that each produces
output. Then go one step further: assert something that tells *working* apart
from *degraded*, such as a styled cue's colour or position surviving. Checking
only for non-empty output would pass the exact bug §2.9 describes.

The mpv path draws into the video texture, so this probably needs the real DLLs.
If it cannot run under `flutter test`, make it a probe with the same standing as
`probe-task19.ts`, and state in the file that it needs a release build.

**Mutation-check it.** Disable each renderer's output in turn, and separately
strip the styling from one path. All three must fail.

## 4. Guard 2 — method existence

This is the most-repeated bug in the project:

- `mix.start`, `playlist.get` and `video.comments` were specified in
  `protocol.md` and had no handler.
- `action.subscribe` and `action.like` were called by the Flutter client for
  weeks and had no handler. Every call failed silently.

Extend `contract-docs.test.ts`, or add a sibling test, to check three
directions:

1. Every method in `protocol.md`'s method tables either has a handler in
   `rpc/server.ts` or is marked as specified-and-absent, in the same wording
   `playlist.get` already uses.
2. Every method name the Dart client passes to `RpcClient.call` or
   `callCancelable` has a handler.
3. Every handler in `server.ts` appears in `protocol.md`. An undocumented
   handler is also drift.

Two requirements:

- **Make the scan fail if it matches nothing.** A scan with a broken regex
  finds zero methods and passes. This project has seen that exact vacuous pass
  several times.
- If a call site builds its method name dynamically, **report it**. Do not
  weaken the scan to accommodate it.

**Mutation-check it.** Rename a handler, add a Dart call to a method that does
not exist, and add an undocumented handler. All three must fail.

## 5. Todo hygiene

- Delete each finished item. Numbers are permanent, so do not renumber.
- Leave "Next number" alone unless you add an item.
- If a doc edit uncovers a real bug, it becomes a new item with the next number.

---

## Definition of done

- `bun run check` green, `rill check` green, lint gate 0
- Both guards exist, pass at HEAD, and are mutation-checked
- Every item from 19 to 29 is either done or corrected with the reason written
  next to it
- `CLAUDE.md` records the F50 re-import quirk
- `CLAUDE.md` no longer contains a claim that the code contradicts

**Report** which backlog claims were already stale, what each guard found on its
first run, and anything filed as a new item.

## Out of scope

Product code beyond the two guards. Items 44 and 33, which are waiting on an
occurrence. Accessibility (37, 38). The settings page.

## Stop conditions

- **A claim turns out to be a real bug, not stale documentation.** File it and
  continue. Do not fix it here.
- **A guard finds more than a few real mismatches on its first run.** Report the
  list and stop. A batch of absent methods is its own task.
- **The parity test cannot tell working from degraded** with the tools available.
  Report what you tried. A guard that only checks for non-empty output repeats
  §2.9's mistake.
