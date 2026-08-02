# Task 07 — media_kit integration

**Prerequisite:** `CLAUDE.md`, `docs/architecture.md` (F10–F14 and the
measurement-gap note under §1), and the spike 03 and spike 05 reports.

This is the first code under `app/`. It is deliberately not an app — it is the
smallest Flutter program that can answer whether `media_kit` behaves like the
libmpv it wraps.

**Toolchain present:** Flutter 3.44.8 stable, Dart 3.12.2, Visual Studio
Community 2026 18.8 with Windows 10 SDK 10.0.26100.0, Windows 11 25H2.
`flutter doctor` reports Android SDK and Chrome missing — both irrelevant.

---

## Why

Every playback finding in this project — F10 through F13 — was measured through
libmpv's **C API**. The app will drive libmpv through `media_kit`'s Dart FFI
binding and its ANGLE render path, and F13's own measurement-gap note says so:

> Seeking is decided in ffmpeg's stream/demuxer layer, not the video output, so
> `vo=gpu` here versus `vo=libmpv` there should not change it — but that is
> reasoning, not evidence.

That reasoning is probably right. It is also the largest untested surface in the
project, and if it is wrong, F10–F13 do not transfer to the app and the playback
architecture is unresolved.

---

## 1. Scaffold `app/`

A minimal Flutter Windows project. Windows only — do not generate other
platform folders.

**Pin the libmpv package exactly:**

```yaml
dependencies:
  media_kit: ^1.2.0
  media_kit_video: ^1.3.0
  # EXACT, not caret. A bump lands modern FFmpeg and reintroduces the F13
  # seek freeze — the shipped 2023 build (FFmpeg n6.0) seeks correctly with
  # no options; FFmpeg 8.1+ does not without request_size. See F12, F13.
  media_kit_libs_windows_video: 1.0.11
```

Verify the resolved package downloads `mpv-dev-x86_64-20230924-git-652a1dd.7z`
and that the built app's `libmpv-2.dll` reports **mpv v0.36.0-403-g652a1dd907,
`MPV_CLIENT_API_VERSION` 2.1**. If it does not match F12's artefact, **stop and
report** — every finding below is about that specific binary.

## 2. Stream source

No RPC in this task. A script in `spiking/` resolves one `ANDROID_VR` video via
the existing sidecar code and writes `{videoUrl, audioUrl, itag, codec}` to a
JSON file; the harness reads that file at startup.

Stream URLs are time-limited (~6 h) and IP-bound. Re-resolve before each test
session rather than debugging a stale-URL 403 as if it were a media_kit fault.

## 3. The harness

One window. No feed, no tiles, no state management, no theming.

- `media_kit` player with `media_kit_video`'s `Video` widget
- Loads the video URL, with the audio URL as a separate track — the
  `--audio-file` equivalent through media_kit's API. **Establishing how
  media_kit expresses a second audio track is part of this task**; if there is
  no supported way, report that, because it invalidates §2.4's playback design
  rather than being a harness detail.
- Buttons: seek to 300 s, 60 s, 500 s, 120 s; play/pause
- On-screen readout: position, duration, buffered, decoder in use, dropped
  frames

## 4. What to measure

**Q1 — Does F13's seek result reproduce through media_kit?**

Spike 05's check 4, unchanged: four seeks 300 → 60 → 500 → 120 s. Assert
**position advances past the target**, never that it equals it — mpv sets
`time-pos` the instant a seek is queued, and spike 05's failing baseline froze
while reporting exactly 300.0. Run five times.

Expected 4/4 with no options set. **Anything less is the finding.**

**Q2 — Is `stream-lavf-o` reachable through media_kit's API?**

Independent of Q1. The hedge in `sidecar/src/playback/mpv-options.ts` is
worthless if the option cannot be set from Dart.

Establish how media_kit exposes raw mpv properties, set
`stream-lavf-o=request_size=1048576,short_seek_size=1048576`, and confirm it is
accepted. Per F13, **acceptance is not evidence of support** on this build — it
returns success and ignores the value. Confirming reachability is the goal, not
confirming effect.

**Q3 — Hardware decode through the ANGLE path.**

F11 and F13 measured `d3d11va` on both AV1 and VP9 with `vo=gpu`. media_kit uses
`vo=libmpv` with ANGLE. Record the decoder actually in use, dropped frames, and
CPU across a 40 s run, on itag 401 (AV1) and 315 (VP9).

Software decode here would be a real finding — it would argue for preferring VP9
from the same client, which F11 concluded was unnecessary.

---

## Definition of done

- `flutter run -d windows` builds and plays an `ANDROID_VR` stream with audio in
  sync
- Q1: 4/4 seeks across 5 runs, or a documented failure
- Q2: reachable or not, with the API surface named
- Q3: decoder, dropped frames, CPU recorded for both codecs
- `pubspec.lock` committed, with the resolved libmpv verified against F12

## Report

Same shape as previous reports. Amend `docs/architecture.md` only with measured
observations — F13's measurement gap closes or widens, and Q2/Q3 become new
findings. Do not edit §2.4's decisions.

## Out of scope

The RPC transport. Any feed, tile, or navigation UI. Riverpod, freezed, or
domain models. Storyboard hover previews. Task 04 item 1. Anything in
`sidecar/src/` beyond reading it to resolve a stream.

## Stop conditions

- **The resolved `libmpv-2.dll` does not match F12's artefact** — stop, report.
- **Q1 fails where the C API passed** — stop and report before attempting a fix.
  That result changes the playback architecture, and choosing the response is
  not this session's call.
- **media_kit has no supported way to attach a separate audio track** — stop and
  report. §2.4's two-URL design depends on it.
