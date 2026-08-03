# Task 10 — RPC transport, completed

**Prerequisite:** `CLAUDE.md` (hard invariants 3 and 9), `docs/protocol.md`
§1, §2, §6, and `docs/tasks/08-rpc-transport.md`.

Task 08 built the transport and left it incomplete. This finishes it. Read
Task 08's brief as well — its requirements still stand and several were not met.

---

## 1. `event.ready` must be near-instant

**This is the root cause of Task 08's failures, and it is a design bug, not a
test-timeout problem. Do not raise any timeout to make a test pass.**

Evidence: `event.ready` passes at 3972 ms and previously failed at 5016 ms; the
other RPC tests take 4.0–4.4 s each. The sidecar is doing network work — session
creation, visitor-id mint, `retrieve_player` — before announcing itself.

Three consequences, all real beyond the tests: the app would wait four seconds
before its first call, an offline start would hang or fail rather than reporting
`anonymous`, and the handshake sits on the edge of every timeout.

Required:

- `event.ready` is emitted from **local state only**. `capabilities` is a disk
  check (`resolveYtDlp` already is); that stays.
- Session creation, visitor minting and player retrieval become **lazy** — done
  on the first call that needs them, not at startup.
- Test: measure from process spawn to `event.ready` and assert **under 500 ms**.
  Not "faster than before" — a number, so a regression is visible.
- Test: the sidecar starts and emits `event.ready` **with no network**.

Once this lands, the chunk-boundary test should pass without modification. If it
still fails, that is a second bug and worth reporting as one.

## 2. The tests Task 08 required and did not deliver

Task 08's brief listed these. Present: five. Add the rest.

**Sidecar, offline:**
- Two concurrent requests return to the correct `id`s, **out of order**
- An internal signal escaping to dispatch becomes `UPSTREAM_ERROR`, not a crash
  (`toEnvelope()` throws by design; the dispatch boundary must catch it)

**Dart client, offline** — against a fake sidecar, a script emitting canned
NDJSON. None of this exists yet:
- `id` correlation, including out-of-order responses
- `$cancel`
- `protocolVersion` mismatch fails fast
- envelope errors decode to a Dart exception carrying `code`, `message`, and
  `retry` as an enum

**Integration** — the real sidecar:
- `auth.verify` and `playback.open` end to end
- Killing the Flutter process leaves no orphaned sidecar

Run `flutter test` as part of verification. Task 08 ran `flutter analyze`, which
does not execute anything.

## 3. The Dart client is on the UI isolate

Task 08's report claimed the client reads "off the UI isolate". Dart stream
callbacks run on whichever isolate registered them, so an `RpcClient`
constructed on the main isolate decodes there.

Harmless for `auth.verify`; not harmless for a feed page, which is the next task
after this one. Per hard invariant 9's reasoning, move JSON decoding off the UI
isolate — an `Isolate.run` for parsing, or a receive port fed by a worker.
`Process.start` and line-splitting can stay where they are; it is the parse of a
large payload that must not land on the frame loop.

Add a test that decoding a large payload does not block the main isolate.

## 4. Dangling processes

`bun test` reports `killed 1 dangling process`. Something is leaving a child
alive. Find it and fix it — this is the same class as the orphan problem, and a
sidecar surviving its parent holds cookies and a live session.

## 5. Wire the harness to `variants[]`

Task 09 landed `variants[]`. `app/lib/main.dart` currently reads top-level
`videoUrl`/`audioUrl`, which no longer exist.

Point it at `variants[0]` and log the full list so the shape is visible. **Do
not build the quality stepper** — that is a later task.

## 6. Small items

- `flutter analyze` reports `prefer_final_fields` on
  `lib/data/rpc/client.dart:34`. Fix it.
- Task 09 emits `itag: 0` for the yt-dlp tier, meaning "unknown". `0` is a
  valid-looking itag that will flow into logs and any future itag-keyed logic.
  If `protocol.md` §3.5 can carry `itag: number | null`, prefer null and amend
  the doc. If that is a protocol change you would rather not make here, say so
  and leave it.

---

## Definition of done

- `bun test` fully green — no failures, no dangling processes
- `flutter test` green
- `flutter run -d windows` plays a video resolved over RPC from `variants[0]`,
  no hardcoded URLs. **Run it and say so** — this was claimed but unverified in
  Task 08.
- Spawn-to-`event.ready` under 500 ms, asserted
- Sidecar starts with no network
- Killing the Flutter process leaves no orphan

## Report

State the measured spawn-to-ready time. If any required test is absent, say
which and why — an omission stated is fine, an omission implied by silence is
what this task exists to correct.

## Out of scope

Any method beyond `auth.verify` and `playback.open`. Feed UI, tiles, navigation.
The quality stepper. Riverpod or freezed models. Task 04 item 1.

## Stop conditions

- **`event.ready` cannot be made fast** because something in the startup path
  genuinely requires network. Report what and why rather than raising a timeout.
- **stdout cannot be kept clean** — some dependency writes to it.
- **The parent-death test cannot be made reliable on Windows.** Report rather
  than shipping a leak.
