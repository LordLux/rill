# Task 08 — RPC transport

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §1, §2, §4, §6, and
`docs/architecture.md` §2.1.

`protocol.md` specifies a transport nothing implements. The sidecar has no
entrypoint but `capture` and `probe`; the app has no way to reach it. This task
builds the wire and nothing that travels on it.

**`docs/protocol.md` is the specification.** Where this brief and the protocol
disagree, the protocol wins — and say so in the report rather than picking one
silently.

---

## Scope

Two methods only: `auth.verify` and `playback.open`. They are the smallest pair
that exercises both a cheap call and an expensive one, and both already exist in
the sidecar. **Do not implement any other method.** Feeds, search, actions and
`playback.report` are later tasks; adding them here means the transport gets
debugged through eight surfaces instead of two.

---

## 1. Sidecar — `sidecar/src/rpc/`

### Entrypoint

A new `sidecar/src/main.ts` that starts the RPC server. `capture` and `probe`
stay as they are.

On start, before accepting requests, emit `event.ready` exactly as §2 specifies:
`protocolVersion` and `capabilities`. `announceCapabilities()` already exists —
the comment in `probe-playback.ts` says this call moves here when the RPC
entrypoint lands. Move it.

### Transport

NDJSON over stdio, one object per line, UTF-8.

**stdout is protocol only** (hard invariant 3). Every log line goes to stderr.
This is the single most likely way to break the transport, and it breaks it in a
way that looks like a parse error on the Flutter side rather than a logging
mistake on this one. Add the lint rule `protocol.md` §1 asks for.

Read stdin incrementally and split on newlines. A JSON object may arrive split
across chunk boundaries; a partial line is buffered, not parsed. Test this
explicitly by feeding a message one byte at a time.

### Dispatch

- Requests carry `id`; responses echo it. Concurrent in-flight requests are
  normal — `id` correlation is mandatory, not a nicety.
- `$cancel` maps to an `AbortController` for the named `id`. Cancelling an
  unknown or already-finished `id` is a no-op, not an error.
- Unknown method → `UPSTREAM_ERROR` envelope, never a crash.
- Malformed JSON on a line → log to stderr, skip the line, keep serving. One bad
  line must not kill the process.

### Errors

Use the existing `errors.ts`. `toEnvelope()` already throws on an internal
signal; that throw must be caught at the dispatch boundary and turned into
`UPSTREAM_ERROR` rather than killing the process — the guard exists to be loud,
not fatal.

## 2. Dart client — `app/lib/data/rpc/`

Spawns the sidecar as a child process and speaks the same protocol.

- `Future<T> call(String method, Map params)` with `id` correlation, completing
  the right future for the right response
- `cancel(int id)` sending `$cancel`
- Waits for `event.ready` before allowing calls; surfaces `capabilities`
- Mismatched `protocolVersion` → fail fast with a clear message (§6)
- Exposes envelope errors as a Dart exception carrying `code`, `message`, and
  `retry` — `retry` typed as an enum, not a string

**Supervision** (§6): sidecar exits → restart with backoff; fail all in-flight
calls with `retry: "auto"`; re-run `auth.verify` after restart.

**Orphan prevention:** the sidecar watches the parent PID and self-exits. On
Windows a killed Flutter process does not reap its children, so without this a
crash leaves a sidecar holding cookies and a session. Test it by killing the
parent and confirming the child exits.

### Where the client runs

The RPC client does blocking-ish I/O and JSON parsing. Per hard invariant 9's
reasoning, keep it off the UI isolate's critical path — `Process.start` and
stream decoding are async and fine, but do not add synchronous parsing of large
payloads to a UI-thread callback. A feed page is a large payload.

## 3. Wire the harness

`app/lib/main.dart` is Task 07's harness. Replace its `07-out/stream.json` read
with a real `playback.open` call over RPC. Everything else about it stays —
same window, same seek buttons, same readout.

`PlaybackSource` now carries `variants[]` (§3.5). The harness picks
`variants[0]` and plays it. **Do not build the quality stepper** — that is a
later task. Log the full variant list so the shape is visible.

This is the definition of done: the app plays a video it learned about over the
protocol, with no hardcoded URLs anywhere.

---

## Tests

**Sidecar, offline:**
- A request split across chunk boundaries, fed one byte at a time, dispatches
  correctly
- Two concurrent requests return to the correct `id`s, out of order
- Malformed JSON on one line does not kill the process; the next line works
- Unknown method returns `UPSTREAM_ERROR`
- `$cancel` on an unknown `id` is a no-op
- An internal signal escaping to dispatch becomes `UPSTREAM_ERROR`, not a crash
- `event.ready` is emitted before any response and matches §2's shape

**Dart, offline:** the client against a fake sidecar (a script emitting canned
NDJSON) — correlation, cancellation, version mismatch, error decoding.

**Integration:** the real sidecar, `auth.verify` and `playback.open` end to end,
plus the parent-death test.

The existing 112 must stay green.

---

## Definition of done

- `flutter run -d windows` plays a video resolved over RPC, no hardcoded URLs
- Sidecar survives malformed input, unknown methods, and cancellation
- Killing the Flutter process leaves no orphaned sidecar
- stdout carries protocol and nothing else, enforced by lint

## Out of scope

Any method beyond `auth.verify` and `playback.open`. Feed UI, tiles, navigation.
The quality stepper. Riverpod or freezed models. Storyboard previews. Task 04
item 1. The Phase 2 media channel.

## Stop conditions

- **stdout cannot be kept clean** — some dependency writes to it and cannot be
  redirected. Report it; the transport choice may need revisiting.
- **The Dart side cannot reliably detect parent death**, or the sidecar cannot
  self-exit on Windows. Report rather than shipping a leak.
- **`PlaybackSource`'s shape as implemented does not match §3.5.** The sidecar
  predates the `variants[]` amendment. If `resolve.ts` still returns a single
  URL pair, that is a real gap — report it and say which you built against, do
  not quietly reshape one to fit the other.
