# Task 11 — Orphan prevention

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §6, and Task 10's orphan
finding in `docs/architecture.md`.

Small and self-contained. `app/test/rpc_client_test.dart:89` currently **fails**
by design — it documents a real defect rather than hiding it. This task makes it
pass.

---

## The finding, and why its conclusion was wrong

Task 10 established that killing the Flutter parent with `TerminateProcess` does
not propagate stdin EOF to the sidecar: neither `rl.on('close')` nor
`process.stdin.on('end')` fires, and the sidecar is left running. That diagnosis
is correct and reproducible — the reviewer reproduced it independently with a
different PID.

The conclusion drawn was that a bidirectional heartbeat is the only remedy. It
is not. `TerminateProcess` skips user-mode cleanup, so **no cooperative
mechanism can work** — but the kernel offers a non-cooperative one.

An orphaned sidecar holds cookies and a live session. This is a leak worth
closing properly.

## 1. Job Object — try this first

Windows Job Objects kill their members when the job handle closes, including
when the owning process is terminated abruptly. The kernel enforces it; neither
process has to cooperate.

- `CreateJobObjectW`
- `SetInformationJobObject` with `JobObjectExtendedLimitInformation`, setting
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` in `BasicLimitInformation.LimitFlags`
- `AssignProcessToJobObject` with the spawned sidecar's process handle

Via `dart:ffi` against `kernel32.dll`. Roughly 60 lines.

Two details that bite:

- **You need the process HANDLE, not the PID.** Dart's `Process` exposes `pid`.
  Get a handle with `OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, …)`.
- **Assign before the child does anything that matters.** A child that spawns
  its own children before assignment leaves those outside the job.

If this works, `rpc_client_test.dart:89` passes unchanged. **Do not modify the
test to accommodate the implementation.**

## 2. PID watch — only if the Job Object does not work

The sidecar polls its parent PID every 3 s and exits when it is gone. Crude, and
it leaves an orphan alive for up to three seconds, but it needs no FFI.

Take this only if §1 genuinely fails, and say in the report exactly what failed.
If you take it, the test needs a tolerance for the polling interval — that is a
legitimate change, unlike weakening the assertion.

## 3. Do not build

**No bidirectional heartbeat.** It is more protocol surface than this needs, it
cannot survive a sidecar-side hang, and §1 makes it unnecessary. If both §1 and
§2 fail, report that rather than reaching for it.

---

## Cross-platform note

Job Objects are Windows-only. The sidecar spawn path will eventually need
`prctl(PR_SET_PDEATHSIG)` on Linux and kqueue `NOTE_EXIT` on macOS. **Do not
build those now** — Windows is the only target. Structure the code so the
platform-specific piece is isolated behind one function rather than inlined into
the spawn call, and leave a comment naming the other two mechanisms.

## Tests

- `app/test/rpc_client_test.dart:89` passes — the sidecar exits when the parent
  is killed
- The sidecar still exits cleanly on a **graceful** parent shutdown; whatever
  mechanism handles that today must not regress
- Normal operation is unaffected: the existing 128 sidecar tests and the Dart
  suite stay green

## Definition of done

- `bunx tsc --noEmit` clean
- `bun test` green
- `flutter test` green, including the orphan test
- After a killed parent, no `bun` process remains — verify with
  `Get-Process bun -ErrorAction SilentlyContinue`

## Report

State which mechanism landed and why. If §1 failed, quote the error. Amend the
dated finding in `docs/architecture.md` with the outcome — it currently records
the defect and the wrong conclusion, and both need correcting.

## Out of scope

Any RPC method beyond what exists. Feed UI. The quality stepper. Linux or macOS
process supervision.

## Stop conditions

- **`dart:ffi` cannot reach `kernel32` cleanly** in a Flutter Windows build —
  report the error before falling back.
- **The Job Object kills the sidecar during normal operation**, not just on
  parent death. That means the handle is being closed early; report it rather
  than working around it with a delay.
