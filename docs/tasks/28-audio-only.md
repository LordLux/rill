# Task 28 — Audio-only mode

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.5, `docs/architecture.md`
F13, F15, F16, F19, and the Task 14 and Task 19 reports.

For listening rather than watching. Most of it exists already: `variants[]`
ships the audio URL separately, the queue is built, and background playback is
nearly free once the video output is gone.

**Not YouTube Music.** No albums, no artist pages, no separate client. This is
the existing app not drawing video.

---

## 1. The measurement that decides the design

Two ways to not play video, and they cost differently:

**(a) Do not pass `videoUrl` at all.** Saves bandwidth *and* decode. Requires
reopening the media to switch modes — F19 measured a quality switch at
0.55–12 s with a texture rebuild, and this is the same operation.

**(b) Pass both and set mpv's `vid=no`.** Saves decode only; the video stream
may still be fetched. Might be a live property change with no reopen.

Measure both before choosing:

- Does `vid=no` stop the **video HTTP fetch**, or only the decode? Watch actual
  bytes, not CPU
- Can `vid=no` be set live without a reopen, and what does it cost?
- What does (a) cost to switch — the same 0.55–12 s as a quality switch, or less
  because there is no texture to rebuild?
- CPU and memory at rest in each, against video playback as the control

Report all four. **(a) is probably right** — bandwidth is the point of the
feature — but say so with numbers.

## 2. Mode, not a per-video toggle

A global mode the user turns on, persisted. Per-video would mean deciding twice
for every video and produce a queue that switches modes mid-play.

- Toggle where the user will find it — the player controls and/or the settings
  surface
- Persisted across restarts
- **Switching mid-playback preserves position and play state.** Report what the
  switch costs; if it is a visible stall, say so rather than hiding it behind a
  spinner

## 3. The player

The shell `Player` lives above the `Navigator` (Task 14 §1) and that does not
change. What changes is whether it has a video output.

- No `VideoController`, no texture, no ANGLE surface in audio mode
- **Do not destroy and recreate the shell player on a mode switch** unless
  measurement says there is no alternative. Task 15 measured what create/dispose
  churn costs and F13 pins libmpv for a seek-freeze regression
- Seeking, the queue, autoplay and `playback.report` all work exactly as they do
  now

## 4. What audio mode turns off

Each of these should be suppressed, not merely hidden:

- **Hover previews.** They play video, which defeats the point. Suppress the
  fetch, not just the render
- **Captions.** `LibassLayer` has nothing to draw over. Confirm it mounts
  nothing rather than mounting invisibly
- **The quality picker.** Replace with audio quality if `variants[]` carries
  distinguishable audio streams — it does, per Task 09's shared-audio finding.
  Say whether that is worth exposing
- **Theatre and fullscreen.** Nothing to make bigger

## 5. The now-playing surface

The watch page in audio mode shows art rather than a video rect.

- Large thumbnail as art, title, channel, scrubber, controls
- The queue is more prominent here than in video mode — it is the primary
  interaction
- The mini-player becomes the main surface for a user who navigates away, and it
  already exists
- Related videos and comments still render; audio mode is not a different app

**The `LayerLink` that tracks the video rect** is used by captions and took four
rounds to get right. Establish what it does when there is no video rect —
probably nothing, since captions are off, but confirm rather than assume.

## 6. System media controls

Windows SMTC was named in the original architecture as the thing that makes
media keys and the volume flyout work, and it has never been built. It matters
far more in audio mode, where the app is often not in front.

- Play, pause, previous, next from media keys
- Title, artist and art in the volume flyout
- The queue drives previous and next

If this turns out to be its own task, say so and scope it — but audio mode
without media keys is half a feature.

## 7. What must not regress

- Video playback, seeking, quality switching, captions and hover previews with
  audio mode **off**
- The queue and autoplay in both modes
- `playback.report` still lands — an audio listen is a watch to YouTube and F6
  is load-bearing

---

## Tests

- Audio mode persists across restart
- Switching modes mid-playback preserves position and play state
- Hover previews do not fetch in audio mode — assert the absence of the request,
  not the absence of the widget
- Captions mount nothing
- The queue advances on completion in audio mode
- `playback.report` fires on the same cadence in both modes
- Video mode is byte-for-byte unchanged in what it opens

**Mutation-check the hover-preview suppression and the mode persistence.** A test
asserting "no preview widget" passes if the widget is hidden while still
fetching.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- Audio mode plays a queue with no video decoded and, per §1, no video fetched
- Media keys control playback and the flyout shows the track
- Switching modes mid-playback keeps the position
- Video mode works exactly as before

**Run the app and say what you saw** — including bandwidth and CPU in both
modes over a few minutes, and media keys with the app minimised.

## Out of scope

YouTube Music, albums, artist pages. Lyrics. Offline or downloads. A separate
music library. Audio quality selection beyond what §4 decides.

## Stop conditions

- **`vid=no` neither stops the fetch nor can be set live**, and (a) costs a full
  reopen. Report both numbers before designing around either.
- **Removing the `VideoController` destabilises the shell player.** Report; the
  player above the `Navigator` is load-bearing for background playback.
- **SMTC is a task in itself.** Say so with a scope rather than half-building it.
