# Task 24 — Live streams

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.5, `docs/architecture.md`
F9, F10, F11, and A6.

**Investigate before fixing.** The symptom has a plausible cause, and this
project has repeatedly found that plausible causes dissolve under measurement.
§1 is measurement; §2 is only reachable once §1 has an answer.

---

## The symptom

Reported 9 Sep 2026, on an Apple Event live broadcast:

1. Video freezes after a few seconds
2. Audio continues alone for a few more seconds
3. Both stop

Nothing else known. Nothing measured.

## 1. Measure first

**Video dying while audio survives is the shape of a per-stream problem.** The
ladder hands mpv a `videoUrl` and an `audioUrl` separately, so one URL expiring
or running past what it describes would look exactly like this. But that is a
hypothesis, not a diagnosis.

Establish, in this order:

**What the ladder returned.** Which tier served it, whether `qualityDegraded`
was set, what `transport` says, and how many variants came back. A live stream
may not resolve the way a finished video does.

**What the `/player` response actually contained.** Specifically: is
`hlsManifestUrl` or `dashManifestUrl` present and being ignored? A live stream is
not a file, and the resolution path currently returns the same static adaptive
URLs it returns for a VOD. If a manifest is there and unused, that is likely the
whole answer.

**What mpv saw.** `RILL_LAUNCH_PROBE=1` raises libmpv to verbose. That is the
difference between "it stopped" and knowing whether the demuxer hit EOF, a 403,
or a stall. Get the log for both streams — they may differ, and the difference is
the finding.

**Whether the URLs outlive the playback.** After it stops, request each URL again
with `Range: bytes=0-`. A 403 says the URL expired; a 200 with no more data says
the stream moved past what it describes. Different problems.

**Whether it is time-bound or byte-bound.** Does it stop after N seconds, or
after N bytes? Try a low quality variant: if it survives longer, the limit is
bytes; if it stops at the same wall-clock moment, it is time.

Report all five before proposing anything.

## 2. Then decide

Do not skip to this section.

Three shapes the answer might take, and they cost very differently:

**A manifest exists and is ignored.** Then the fix is using it — libmpv consumes
HLS and DASH natively, so it may be as small as handing mpv a manifest URL
instead of two adaptive URLs, with `isLive` selecting the path.

**Segments need re-fetching as the stream advances.** Heavier: the sidecar has to
refresh what it handed mpv, or hand it something self-refreshing.

**It needs SABR.** Then stop. A6 rejected the SABR → local DASH bridge and F3's
tripwire exists to force that decision deliberately. **Live streams are not a
bug that quietly justifies building it.** Report and stop; it is a decision for
outside this task.

## 3. Constraints

- The two-client model holds: browse is `WEB` with cookies, resolution stays
  anonymous `VISIONOS` (F11). Live may behave differently per client — measure
  rather than assume the resolution client is right for it.
- `isLive` already exists on `VideoItem` and `durationSeconds` is already `null`
  for live, so the parser distinguishes them. The resolution path does not.
- Whatever changes, **VOD playback must not regress.** Seeking, quality
  switching, captions, the queue.
- If a fix only works for some live streams, say which and why. A stream that is
  live now versus a finished broadcast still marked live are different cases.

---

## Tests

- A live `/player` response parses, with whatever manifest fields it carries
  surfaced rather than dropped
- `playback.open` on a live video returns whatever §2 decided, and a VOD returns
  exactly what it returns today
- A finished-but-still-flagged-live video does not take the live path if that
  path would break it
- Existing VOD playback tests unchanged and green

**Mutation-check whatever selects the live path.** A test asserting "a live video
gets a manifest URL" passes if everything gets one. Assert the VOD case too.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- **A real live stream plays for at least five continuous minutes** — the
  symptom is a few seconds, so anything shorter proves nothing
- Seeking behaves sensibly on a live stream, or is deliberately disabled and the
  report says so
- VOD playback, seeking, quality switching and captions all still work

**Run the app and say what you saw**, on a genuinely live broadcast, with a
wall-clock duration.

## Out of scope

The SABR → DASH bridge. DVR seeking on live streams. Live chat. Premieres beyond
what already works. Any UI beyond what the fix requires.

## Stop conditions

- **The answer is SABR.** Report and stop, per §2.
- **A manifest is present but libmpv cannot consume it** on the pinned build
  (F12 pins it for a seek-freeze regression). Report what it rejected.
- **Live requires a different resolution client**, which would mean a second
  client on the resolution path. Report before building — the two-client model
  is load-bearing.
- **The measurements contradict the per-stream hypothesis** entirely. Say so;
  that is the most useful outcome §1 can have.

## Outcome (added 2026-09-11, `architecture.md` F23)

The manifest branch shipped without the `isLive` gate §2 and §3 both call for
("A manifest exists and is ignored... with `isLive` selecting the path";
"the resolution path does not \[distinguish them\]"), and without the
mutation-checked VOD test the "Tests" section above requires. The result was
not the reported freeze-then-stop on a live broadcast — it was ordinary,
non-live videos silently routed through the same manifest path, since
`VISIONOS` carries an `hlsManifestUrl` on VOD responses too. See F23 for the
full finding and the fix. The original live-freeze symptom this task was
opened for was never independently re-measured once the ungated branch was
found; if it recurs on a broadcast confirmed live at the time, treat it as
open again rather than assumed-fixed by F23.
