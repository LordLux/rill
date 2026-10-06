# Environment Variables Configuration

This document lists all the environment variables read across the Rill project (both the sidecar process and the app).

## Sidecar (`sidecar/src/`)

| Variable | File | Purpose |
| --- | --- | --- |
| `YT_COOKIE` | `innertube/auth.ts` | Seeds the browse session's cookie |
| `YT_DLP_PATH` | `capabilities.ts` | Path to yt-dlp binary |
| `YT_DUMP_ASS` | `probe-playback.ts` | Dump generated ASS documents |
| `YT_VIDEO_STANDARD` | `capture.ts`, `probe-playback.ts` | Standard video id for captures/probes |
| `YT_SEARCH_QUERY` | `capture.ts` | Search query for capture runs |
| `YT_ARTIST_QUERY` | `capture.ts` | Artist search query for capture runs |
| `YT_VIEWER_VIDEO` | `capture-viewer-state.ts` | Video id for viewer-state captures |
| `YT_VIEWER_COMMENT_VIDEO` | `capture-viewer-state.ts` | Comment video for viewer-state captures |
| `YT_VIEWER_DISLIKED_VIDEO` | `capture-viewer-state.ts` | Disliked video for viewer-state captures |
| `SIDECAR_LOG_LEVEL` | `log.ts` | Sidecar log verbosity |
| `SIDECAR_PLAYER_RESPONSE_TTL_MS` | `innertube/player-response.ts` | `/player` response cache TTL override |
| `SIDECAR_PLAYER_TTL_MS` | `innertube/player.ts` | Player-JS/decipher cache TTL override |
| `SIDECAR_STORYBOARD_TTL_MS` | `video/storyboard.ts` | Storyboard cache TTL override |
| `SIDECAR_CAPTIONS_NEGATIVE_TTL_MS` | `captions/service.ts` | Negative caption cache TTL override |
| `FLUTTER_PARENT_PID` | `main.ts` | Flutter parent process PID (auto-set) |

## App (`app/`)

### Runtime overrides

| Variable | File | Purpose |
| --- | --- | --- |
| `RILL_STREAM_LAVF_O` | `data/playback/engine.dart` | Replaces the mpv stream-lavf-o option string |
| `RILL_MPV_LOG` | `data/playback/mpv_log.dart` | Path: write both players' mpv log to this file |
| `RILL_LOG_FILE` | `data/log_capture.dart` | Override the release log path |
| `RILL_LOG_CAPTURE` | `windows/runner/log_capture.cpp` | Set to `0` to disable release log capture |
| `RILL_LOG_TEST` | `main.dart` | Enable test logging |
| `RILL_OPEN_VIDEO` | `main.dart` | Open a specific video on launch |
| `RILL_SEEK_TO_END` | `main.dart` | Seek to end on open |

### Probes (measurement entrypoints, not wired in)

| Variable | File | Purpose |
| --- | --- | --- |
| `RILL_AUTH_PROBE` | `main.dart`, `ui/auth_probe.dart` | Launch the auth probe |
| `RILL_AUDIO_PROBE` | `main.dart` | Launch audio delay probe |
| `RILL_AUDIO_PROBE_VERBOSE` | `main.dart` | Verbose audio probe output |
| `RILL_AUDIO_PROBE_VIDEO` | `main.dart` | Video id for audio probe |
| `RILL_AUDIO_PROBE_OUT` | `main.dart` | Output path for audio probe |
| `RILL_AUDIO_PROBE_NO_AWAKE` | `ui/audio_delay_probe.dart` | Skip awake step in audio probe |
| `RILL_LAUNCH_PROBE` | `main.dart`, `ui/player/launch_probe.dart` | Launch the launch probe |
| `RILL_LAUNCH_PROBE_OUT` | `ui/player/launch_probe.dart` | Output path for launch probe |
| `RILL_FEXP_PROBE` | `ui/player/launch_probe.dart` | Feature experiment probe |
| `RILL_CAPTIONS_PROBE` | `ui/player/captions_probe.dart` | Launch the captions probe |
| `RILL_CAPTIONS_MEDIA` | `ui/player/captions_probe.dart` | Media file for captions probe |
| `RILL_CONTROLS_PROBE` | `ui/player/controls_probe.dart` | Launch the controls probe |
| `RILL_SEMANTICS_PROBE` | `ui/semantics_probe.dart` | Scripted run with semantics on; count `Failed to update ui::AXTree` per step in the release log (`architecture.md` F51). `RILL_SEMANTICS_PROBE_VIDEO=<id>` picks the video |
| `RILL_FOCUS_PROBE` | `ui/focus_probe.dart` | `feed` or `watch`: walk Tab through the real app and log each stop, with `OFFSCREEN` and `NAMELESS` markers. `RILL_FOCUS_PROBE_STOPS`, `RILL_FOCUS_PROBE_REVERSE=1`, `RILL_FOCUS_PROBE_VIDEO=<id>`, `RILL_FOCUS_PROBE_DWELL=<ms>` (wait at each stop and log whether the player bar is still up). `hover` sweeps a mouse pointer over the feed, watch page and miniplayer; `openclick` rests the pointer on a tile (`RILL_FOCUS_PROBE_AT=<x>,<y>` as window fractions), clicks it and waits. `RILL_FOCUS_PROBE_SIZE=1700x950` resizes first. Semantics are on in every mode (`architecture.md` F52) |
| `RILL_KEY_DIAG` | `ui/key_diag.dart` | `1`: log every key press with what has focus (`keydiag:` lines), plus app-lifecycle and window-focus changes. For "the keyboard stopped working": presses that keep appearing mean the app is receiving keys; presses that stop mean the window lost keyboard focus |
| `RILL_FOCUS_PROBE=monkey` | `ui/focus_probe.dart` | A screen reader's hands, at random: presses allow-listed nodes from the semantics tree (never like/subscribe/vote/delete), scrolls, Tabs, opens videos, and logs every step (`MONKEY n: …`) so an `AXTree` error's preceding steps are in the same log. `RILL_MONKEY_SEED=<n>`, `RILL_MONKEY_STEPS=<n>`. About 1 run in 20 reproduced an error (`architecture.md` F51) |
| `RILL_FOCUS_PROBE=scrollchange` | `ui/focus_probe.dart` | Scrolls the watch page into its comments, Tabs deep into it, then opens another video; eight times |
| `RILL_FOCUS_PROBE=videochange` | `ui/focus_probe.dart` | Keyboard on a control, then Shift+N twice and a new video; logs whether the `t` shortcut still works and what has focus after each (`SHORTCUT …`, `TAB …`) |
| `RILL_SEMANTICS_DUMP` | `ui/semantics_probe.dart` | **On by default in a dev build (no `RILL_VERSION`) until 2026-11-28 (`todo.md` 87); `0` turns it off, `1` turns it on in a released build.** Semantics on, and the whole semantics tree (with node ids) written once a second to `%TEMP%\rill-semantics-ring-<n>.txt`, the last 300 seconds kept (`RILL_SEMANTICS_DUMP_KEEP=<seconds>`), nothing logged per dump. Also writes `%TEMP%\rill-semantics-changes.txt`: every node that appears or disappears, frame by frame, with label, tooltip, size and parent (about the last 4 MB) — a node that lives a few frames is invisible to the once-a-second dumps. An `AXTree` error names only a node id; find that id in the file written at that moment (`architecture.md` F51) |
| `RILL_PROBE_PHASES` | `probe_comments.dart` | Phases for comments probe |
| `RILL_PROBE_OUT` | `probe_comments.dart` | Output path for comments probe |

### Compile-time (dart-define)

| Variable | File | Purpose |
| --- | --- | --- |
| `RILL_VERSION` | `data/update/update_config.dart` | App version string |
| `RILL_UPDATE_FEED` | `data/update/update_config.dart` | Update manifest URL |
| `RILL_UPDATE_PUBKEY` | `data/update/update_config.dart` | Ed25519 public key for manifest verification |
| `RILL_UPDATE_ASSET_PREFIX` | `data/update/update_config.dart` | Asset download URL prefix |

### Debug player

| Variable | File | Purpose |
| --- | --- | --- |
| `NY_MODE` | `main.dart`, `ui/debug_player.dart` | Debug player mode |
| `NY_TRACK` | `ui/debug_player.dart` | Debug player track |
| `NY_OPTIONS` | `ui/debug_player.dart` | Debug player options |
| `NY_VIDEO_ID` | `ui/debug_player.dart` | Debug player video id |
| `NY_OUT` | `ui/debug_player.dart` | Debug player output path |
| `NY_RUN` | `ui/debug_player.dart` | Debug player run config |
| `NY_HWDEC` | `ui/debug_player.dart` | Debug player hwdec setting |
| `NY_LOGLEVEL` | `ui/debug_player.dart` | Debug player log level |

### Other

| Variable | File | Purpose |
| --- | --- | --- |
| `YT_COOKIE` | `main.dart` | Cookie for the app process |
| `PROBE_SCENARIO` | `ui/player/audio_mode_probe.dart` | Audio mode probe scenario |
| `LOCALAPPDATA` | `data/update/`, `data/ytdlp/` | Windows local app data path |
| `PATH` | `data/ytdlp/ytdlp_paths.dart` | System PATH for finding yt-dlp |
| `FLUTTER_TEST` | `ui/smtc_controller.dart`, etc. | Dart test environment flag |
