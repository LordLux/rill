# Task 06 — Ladder reordering + playback hedges

**Prerequisite:** `CLAUDE.md`, `docs/architecture.md` (F5, F10–F13), the spike 03
and spike 05 reports (`task-03-report.html`, `task-05-report.html`), and `docs/tasks/04-player-revision-safety.md` (item 2 only!!).

Four changes, all in the playback path, all mechanical. Item 1 of Task 04 is
**not** in scope — it is scoped separately after this lands, because ANDROID_VR
carries no `n` and that changes what the fix has to cover.

---

## 1. `ANDROID_VR` becomes tier 1

Spike 03 established it satisfies every constraint at once: plain URLs, no `n`
to decipher, open-ended ranges accepted, bare GETs accepted, throughput above
the bar, hardware decode, and — per spike 05 — seeks on the shipped libmpv with
no options.

New ordering:

1. `ANDROID_VR` plain adaptive, anonymous, **server-issued visitor id**
2. `MWEB` plain adaptive — retains the decipher path
3. SABR → DASH — still seam only, still throws `STREAM_REQUIRES_SABR`
4. `yt-dlp` subprocess
5. itag 18 progressive, `qualityDegraded: true`

`MWEB` stays as a tier rather than being deleted: it is the only client with a
proven decipher path, and F10 constrains how it can be *consumed*, not whether
it resolves.

### The visitor id

`createSession` currently passes `generate_session_locally: !cookie`, so the
anonymous sessions used for stream resolution get a fabricated id. Set it
`false` for the resolution session so youtubei.js fetches a server-issued one.

**Measure the lifetime before deciding where to cache it.** Spike 03 left this
open, and it decides whether this is a session-scoped fetch or a per-open round
trip. Mint once, reuse across N resolutions, record where it stops working.
Report the number; do not guess at a TTL.

### `LOGIN_REQUIRED` is retryable

A fabricated id passes ~7% of the time (2/28), not 0% — so this is a
probabilistic bot score, not a hard rule, and a server-issued id raises a
probability rather than satisfying a requirement. Treat `LOGIN_REQUIRED` as
retryable: mint a fresh visitor id and retry once before declining the tier.

## 2. Set `request_size` unconditionally

Pass `stream-lavf-o=request_size=1048576` wherever playback options are
constructed.

On the shipped libmpv (FFmpeg n6.0) it is accepted and ignored — still 4/4 on
seeks. On modern FFmpeg it is the difference between 0/4 and 4/4. One option
string covers both, and makes a future pin move a non-event.

> The shipped build **accepts** the option, returns 0, and echoes it back on
> read, while ignoring it entirely. Never probe for support at runtime — the
> answer is a false positive. Only scanning the binary is evidence.

## 3. Pin `media_kit_libs_windows_video` exactly

Constrain to the resolved version rather than a range. The risk has inverted:
it is no longer that the pin is too old, but that a bump lands a modern FFmpeg
and reintroduces the seek freeze. Item 2 defuses it; the exact pin means it
cannot happen unnoticed.

The package has not published since March 2025, so nothing is being forgone.
Add a comment naming the reason, or the next person removes it as stale.

## 4. Task 04 item 2 — the `tierYtDlp` stderr deadlock

Drain both pipes concurrently:

```ts
const [stdoutText, stderrText] = await Promise.all([
  new Response(child.stdout).text(),
  new Response(child.stderr).text(),
]);
const exitCode = await child.exited;
```

**Test:** a stub binary that writes well over 64 KB to stderr and then valid
JSON to stdout must resolve normally and promptly. Asserting only that stderr
appears in the error message does not exercise the deadlock — the buffer has to
be overflowed for the test to mean anything.

---

## Tests

- Ladder resolves via `ANDROID_VR` by default, with no `n` on the primary path
- A tier that throws is a decline, not a failure — existing behaviour, keep it
- `LOGIN_REQUIRED` triggers exactly one retry with a fresh visitor id, then
  declines
- Network: sustained throughput > 1.5 MB/s via tier 1
- The stderr overflow test above
- Existing suite still green

## Doc changes

- `docs/architecture.md` §2.4 — the undecided paragraph closes. State the
  resolution: `ANDROID_VR` tier 1, no proxy, media_kit's default DLL retained,
  `request_size` set unconditionally as a hedge. Cite F11, F12, F13.
- `docs/architecture.md` §4 — amend the F10 failure-mode row, which currently
  reads "undecided".
- `docs/architecture.md` §1 — add to F4 that 4.0 MB/s is per-format pacing on
  itag 315, not a property of `MWEB`.
- `CLAUDE.md` — add hard invariant 8: option acceptance is not evidence of
  option support; scan the binary.
- `CLAUDE.md` — replace the trailing findings line with:
  "Findings in `architecture.md` are dated where they were measured. They are
  dated observations, not permanent properties." No enumeration, so it stops
  going stale.

## Out of scope

Task 04 item 1. Any `app/` or media_kit work. Building a proxy. Vendoring
libmpv. Deleting the `MWEB` tier.
