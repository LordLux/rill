# Spike 05 — libmpv `request_size` availability

**This is a spike, not a task.** The deliverable is a finding. Throwaway code
and scratch builds go in `spiking/`. **Do not modify `sidecar/src/`.** Do not
build a proxy, reorder the ladder, or touch `app/`.

**Prerequisite:** `CLAUDE.md`, `docs/architecture.md` (F10, F11, F12), and the
spike 03 report.

---

## Why

Spike 03 established that `ANDROID_VR` clears F10 end to end — but only seeks
with ffmpeg's `request_size` option, and F12 records that option as absent from
the libmpv `media_kit` ships. Without it, playback looks perfect until the user
touches the progress bar, then hangs with nothing logged.

Every spike 03 result was measured against a system mpv
(`v0.41.0-244-gaf9c81fa1`, libavformat 62.10.101). **Nothing has been tested
against the binary the app will actually load.**

The upstream picture makes this urgent rather than a formality:
`media-kit/libmpv-win32-video-build` is archived; the live repo is
`libmpv-win32-video-cmake`, last updated around 11–13 December 2025.
`request_size` merged in February 2026 (FFmpeg 8.1). So the newest build
media-kit publishes may itself predate the option — meaning "wait for the pin to
move" has no timeline.

This spike decides one thing: **can the app get a libmpv with `request_size`,
or does it need a chunking proxy?**

---

## Q1 — What does media_kit actually ship?

Verify the packaging before assuming anything about it. The description below is
secondhand and may be wrong; **if the layout differs, report that and stop
rather than improvising.**

- Which `media_kit_libs_windows_video` version does the project resolve, and
  what does it download or vendor?
- Where does the DLL land in a built Flutter Windows app, and what is it called?
- Confirm the shipped build's versions directly from the binary — mpv version,
  libavformat version, and whether the option string `request_size` is present.
  Do not infer from the pin; check the artefact.

Record the exact paths. Everything below depends on them.

## Q2 — Does a current libmpv drop in?

Obtain a current Windows libmpv build — shinchiro's `mpv-winbuild-cmake`
releases are the usual source, and media-kit's own repo is forked from it.
Confirm the candidate actually contains `request_size` before testing anything
else.

Then replace the shipped DLL in a built Flutter app and check, in order:

1. The app starts and `media_kit` initialises without an ABI or missing-symbol
   error
2. A local video file plays
3. `mpv_get_property` / `mpv_set_option` accepts `stream-lavf-o` with
   `request_size` — the option is reachable through media_kit's API surface,
   not merely present in the DLL

**Report the mpv API version of both DLLs.** A newer libmpv with a bumped
`MPV_CLIENT_API_VERSION` may load and then misbehave subtly rather than fail
cleanly, which is the outcome most likely to waste days later.

## Q3 — Does it fix the seek?

Only if Q2 passes. Reproduce spike 03's check 4 against the **swapped** build,
not a system mpv:

- Resolve an `ANDROID_VR` stream (reuse the spike 03 script)
- Play through `media_kit` in a minimal Flutter harness — not the mpv CLI
- Four seeks: 300 s → 60 s → 500 s → 120 s
- Assert **position advances past the target**, not that `time-pos` equals it.
  mpv sets `time-pos` the instant a seek is queued; spike 03's baseline froze
  while reporting exactly 300.
- Record decode path (hardware vs software) and CPU

A minimal `flutter run -d windows` harness in `spiking/` is fine. It does not
need to resemble the app.

---

## Deliverable

A report in the same shape as spike 03's. Specifically:

- Q1: the resolved version, the artefact's real versions, `request_size`
  present or absent, and the exact DLL path
- Q2: loads / does not load, with API versions for both binaries
- Q3: seeks pass or fail against the swapped build
- A recommendation: **vendor a newer libmpv, or build a chunking proxy** — with
  the maintenance cost of vendoring stated plainly, since it means owning a
  binary and its updates across every platform the app later targets

Amend `docs/architecture.md` only with measured observations — F12's status
against the real artefact, and whatever Q3 establishes. **Do not** edit §2.4's
undecided paragraph or the ladder.

## Out of scope

Building the chunking proxy. Reordering tiers. Task 04's two defects. Anything
in `sidecar/src/` or `app/`.

## Stop conditions

- **If Q1 shows the packaging differs from the description above**, report and
  stop. The rest of the brief assumes a layout that may not exist.
- **If Q2 fails**, stop. A proxy becomes the answer, and that decision is made
  outside this session.
- **If Q3 passes**, say so and stop. Vendoring a binary across platforms is a
  real cost, and choosing it over a proxy is not this session's call.
