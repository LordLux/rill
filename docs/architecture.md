# Architecture — Native Windows YouTube Client

**Status:** Accepted, verified by spike 2026-08-01
**Scope:** Desktop YouTube client for Windows. No browser engine rendering UI.

This document records decisions, not deliberation. Rejected alternatives are in
the appendix so they are not accidentally revived. Every claim in "Verified
findings" was measured, not assumed.

| F37 | **`FractionallySizedBox` inside an unconstrained `Row` throws an infinite width constraint exception.** A flex container like `Row` gives non-flex children unbounded horizontal space. A fractional box asks for a percentage of infinity, resulting in a layout crash. Fixed in `feed_skeleton.dart` by wrapping the fractional bar in an `Expanded` widget. A circular avatar `Container` there was also given a fixed `width` to prevent layout assertion failures. | Measured 2026-09-20 via `flutter test` which red-screened on `feed_skeleton_test.dart`'s matrix of screen widths. |

**The guard names its failures now, and the first thing it named was a
regression rather than the flake — 2026-09-21.** Within minutes of the change
it reported `rpc_client_test.dart: killing the Flutter process leaves no
orphaned sidecar`, which turned out to be **0/8 in isolation, not flaky at
all**: a `package:flutter/foundation.dart` import added to
`data/rpc/client.dart` for `kDebugMode` had broken
`test/orphan_test_helper.dart`, which imports that file and runs on the plain
Dart VM where `dart:ui` does not exist. The helper failed to *compile* and the
test failed with `Helper should print SIDECAR_PID` behind two hundred lines of
framework errors — a message pointing nowhere near the cause. Same shape as the
`animated_vector_gen` trap: a package re-exports `dart:ui` and drags the
framework into a host that has none. Fixed with the `assert` trick, and
`sidecar_lookup_test.dart` now asserts in one line that `client.dart` imports no
Flutter. **The orphan test is not the original flake**: 5/5 after the fix and
4/4 under contention.

**F38, chased again 2026-09-21 and not reproduced — and the guard was the
reason it could not be.** One `rill check` reported `680 tests, 1 not passing`
and an immediate re-run reported 0, with nothing changed between. The failure
could not be named, because `test_suite_guard.dart` counted failures and
printed only the **count** — "1 not passing" was the whole of the output. It now
names each one (suite plus test name, and says explicitly when the failure is a
synthesised load/`setUpAll`/`tearDownAll` rather than a test's own), so the next
occurrence is diagnosable in one line instead of by bisection. Not reproduced in
**nine** runs afterwards: three of `flutter test`, four of the guard, and two of
the guard under deliberate CPU contention (two concurrent `bun test` runs),
contention being the obvious suspect since F19 records machine load moving
timings here by 30×. F38's own `try`/`catch` is still in place in
`subscribe_button.dart` and `media_tile.dart`, and a sweep of every other
`removeListener` in `app/lib` found none with the same exposure — the remaining
two (`comment_composer.dart`, `topbar.dart`) remove listeners from objects they
own and dispose themselves. So: cause still unknown, the instrument that would
identify it is fixed, and the standing advice is to read the guard's named
output rather than re-run until green. Two *new* instances of the same class
were found by inspection in that sweep and guarded before they could bite — a
`setState` in a `Focus.onFocusChange` and a `ValueNotifier` written from a
`MouseRegion.onExit`, both of which fire while a list row is being unmounted.

| F38 | **The Flutter test framework's tear-down sequence disposes `ScrollPosition`s before the widgets that observe them.** A widget's `dispose()` that unconditionally calls `_scrollPosition?.removeListener()` will crash the entire test suite during `(tearDownAll)` if the position was unmounted first, because the framework throws an assertion. Fixed in `subscribe_button.dart` and `media_tile.dart` by wrapping the listener removal in a `try-catch` block. | Measured 2026-09-20 during flaky suite failures (e.g. `player_shell_test.dart` crashing post-test). |

| F39 | **A comment's vote is one field of three and four server-supplied blobs; the client's own model was the part that drifted.** `engagementToolbarStateEntityPayload.likeState` carries `TOOLBAR_LIKE_STATE_LIKED`, `_DISLIKED` and `_INDIFFERENT` — a closed set on one field — so `Comment.myRating` replaces `isLiked` for the reason `VideoDetail.myRating` already had: two booleans admit liked-and-disliked, which YouTube cannot produce. Voting needs no constructed token: `engagementToolbarSurfaceEntityPayload` ships `likeCommand`, `unlikeCommand`, `dislikeCommand` and `undislikeCommand`, each an opaque blob for `comment/perform_comment_action` — the same endpoint as delete, exactly as `types.ts` predicted — so the trap that made a *video*'s like/dislike `target` shape wrong does not apply. **Their presence is not permission:** all four are on anonymous pages too, the `heartActiveTooltip` mistake (F33) in a new place, so the buttons gate on `auth.isSignedIn`. **`_DISLIKED` had never been in a fixture**, so a reader that dropped it was indistinguishable from a correct one — an unvoted comment and a disliked one both read `'none'`. `capture:viewer-state dislike` is its own phase, because a dislike is independent of the before/after pair and folding it in would mean rebuilding the whole after-state to re-prove one vote. **And the app gate stayed green across the rename**: `contract_test.dart` had strict-key groups for `VideoDetail` and `CaptionTrack` only, and its generic corpus loop reads `items` as `FeedItem`s, so a comments page passed through untouched — the model kept a defaulted `isLiked` the sidecar no longer sent, which at runtime reads as "nobody has voted on anything". `Comment` has a group now. | Measured 2026-09-20/21, signed in. Four blobs on 20 of 20 comments of a signed-in page and 20 of 20 of an anonymous one. `_DISLIKED` found by paging a thread's replies to a comment the account had disliked; the top-level capture is `fixtures/viewer-state/comments-disliked.json` (1 of 5), asserted against the capture manifest as oracle. All four transitions driven live through `rateComment` as two round trips — `unlike`→`like` and `undislike`→`dislike` — each verified by re-reading the page, ending with **zero account drift**. The two thumbs had been bare `Icon`s, drawn but not pressable, on every comment in the app; the thumb-down was a hardcoded outline. Widget tests mutation-checked (3). |

---

## 1. Verified findings

These were established empirically. Do not re-litigate them without re-running
the spike; do not assume they still hold six months from now.

| # | Finding | Evidence |
| --- | --- | --- |
| F1 | `WEB` + cookie auth returns the full personalised home feed | 24 `lockupViewModel`, 54 `richItemRenderer`, 21 `chipCloudChipRenderer`, 1 `continuationItemRenderer` in the raw response |
| F2 | **youtubei.js drops content during parsing.** The raw response has items the typed accessors do not expose | `getHomeFeed().videos` returned 0 against a raw response containing 24 tiles; `ParsingError: Type mismatch, got RelatedChipCloud expected …` |
| F3 | `WEB` player responses are SABR-only, defined over adaptive formats only. `MWEB` still returns plain adaptive URLs — **but not on every request, as of 2026-08-02** | `WEB` → `SABR-ONLY`; `MWEB` → 41 adaptive formats, max 2160p (2026-08-01). **Amended 2026-08-02:** one `MWEB` `/player` response in ~17 live suite runs came back **SABR-only**, while 12/12 controlled calls in the same hour were plain (`ANDROID_VR` was 12/12 plain alongside them). One response, not a flip — but "MWEB still returns plain adaptive URLs" is now a statement about *most* responses rather than all of them, and a bucketed rollout is exactly what this looks like from outside. The live tripwire therefore samples three times per run: **one** SABR-only sample warns and is recorded, **two or more of the three** fails the suite — at that point most requests are SABR-only and tier 2 is effectively gone whatever the third does. Every run is appended to `sidecar/tripwire-mweb-sabr.ndjson` (gitignored, machine-local), because a rollout is a rate and a rate needs the denominator: this sighting was 1 response in ~17, which is indistinguishable from noise without one. **What it costs today: ladder tier 2 only.** Tier 1 is `ANDROID_VR` and is unaffected, which is the whole reason the reorder mattered more than it looked |
| F4 | `MWEB` streams at full speed with the `n` parameter deciphered | itag 315 (VP9 2160p) + itag 258, 4.0 MB/s sustained across 3 runs. **The rate is per-format pacing, not a property of `MWEB`:** F11 measured 4.02 MB/s on the same itag 315 from `ANDROID_VR`, and 2.11 MB/s on itag 401 — each almost exactly 2× realtime for that format's own bitrate. Bounded and open-ended requests come back identical to two decimal places, so request shape costs nothing either. Read F4 as "the deciphered `n` is not throttled", which is all it was ever evidence for |
| F5 | **`ANDROID_VR` is refused without a GVS PO Token.** A server-issued visitor id is no longer sufficient. | Amended 2026-08-18: The refusal that previously tracked the visitor id (and was fixed by a server-issued one) has been superseded. YouTube completed a rollout (fexp=51946838 was the A/B flag, tracked in F20) requiring a GVS PO token for all `ANDROID_VR` adaptive formats and most progressive ones. Without a token, the API omits the `url` and `signatureCipher` fields entirely from the adaptive formats. |
| F6 | Watch history reporting from the authenticated `WEB` session lands | 183 history entries readable; target video present after reporting. **Confirmed 2026-09-12:** Verified still landing correctly after the VISIONOS migration, visitor-id updates, and login shipping (Task 25 §6). |
| F7 | Cookie sessions degrade **silently** — auth endpoints return empty shells while the client still reports `logged_in: true` | Home + history both returned 0 items with no error, after browser-side cookie rotation |
| F8 | No moving-thumbnail media in the feed. Storyboards are present | 0 mp4/webm URLs; `PlayerStoryboardSpec` with a resolved template URL. **Read it narrowly:** it says a feed *response* ships no preview media, not that hover previews cannot be video — §2.6 resolves a stream through `playback.open` instead, which F8 says nothing about |
| F9 | A SABR-only `WEB` response still carries a working itag 18 progressive stream, as does `ANDROID` | Amended 2026-08-18: `ANDROID_VR` is dead for progressive formats without a PO token. The floor shifts to the `ANDROID` client's itag 18, which still streams cleanly. |
| F10 | **`MWEB` stream URLs refuse open-ended range requests; `ANDROID_VR` URLs accept them.** ffmpeg opens every HTTP stream with `Range: bytes=0-`, so a deciphered `MWEB` URL cannot be handed to libmpv directly | `c=MWEB` itag 315: HTTP 403 on `bytes=0-` at offsets 0, 100 MB and 1000 MB; HTTP 206 on `bytes=0-1048575`. `c=ANDROID_VR` itag 401 (via yt-dlp): 206 on both. mpv plays the `ANDROID_VR` URL and 403s on the `MWEB` one. Both URLs carry `rqh=1`, so the client — not that parameter — is the discriminator. Confirmed against ffmpeg's `libavformat/http.c`: the Range header is emitted as `Range: bytes=<off>-` whenever no explicit Range header is set, the request is not a POST, and an offset, end offset, or seekability is in play. Open-ended by construction. `seekable=0` suppresses the header entirely but a bare GET is also refused (403), so it is not a workaround. **Refined 2026-08-01:** bounding the request does not fix it either, it relocates the failure. With `--stream-lavf-o=request_size=1048576` the open succeeds, 1 MB chunks return 206 and mpv plays for ~7 s — then the mid-file seek asks for `Range: bytes=583998372-585046947` and gets **403 on both the video and the audio URL**, ending playback. Reproduced 4/4 across default, 32 MiB, 8 MiB and disabled readahead, so it is the reposition rather than an accumulated-volume ceiling — though with default readahead a purely sequential run also 403s at ~128 MB, matching "the boundary shifted as requests accumulated". `initial_request_size` alone behaves the same |
| F11 | **`VISIONOS` URLs clear F10 end to end.** `ANDROID_VR` is no longer viable | Amended 2026-08-18: `ANDROID_VR` requires a PO token. `VISIONOS` (Client ID 101, native in youtubei.js 18.0.0) streams adaptive formats up to 2160p cleanly with open-ended ranges (`HTTP 206` on `Range: bytes=0-`), requiring no cipher and no PO token. |
| F12 | **`request_size` is absent from media_kit's bundled libmpv.** Confirmed against the artefact, not the pin | Measured 2026-08-01, **corrected against the real artefact 2026-08-02.** Upstream merged it as `request_size` (with `initial_request_size`), **not** `max_request_size` — that was the mailing-list name and appears nowhere in the tree. Commit by Niklas Haas, Feb 2026: absent from `release/8.0`, present in `release/8.1` and `release/9.0`, so **FFmpeg 8.1 is the floor**. The system mpv used for F10/F11 is v0.41.0-244-gaf9c81fa1 / FFmpeg N-123099-g862338fe3 (libavformat 62.10.101) and has it. **The pin was recorded wrongly.** `20241021` / `0f78584` is the `main` branch of `media-kit/media-kit`, which has never been published. The version a project actually resolves — `media_kit_libs_windows_video` **1.0.11**, latest on pub.dev since 2025-03-24 — downloads `mpv-dev-x86_64-20230924-git-652a1dd.7z` from the **archived** `libmpv-win32-video-build`, tag `2023-09-24`. Archive MD5 `a832ef24…` matches the value in the package's own `windows/CMakeLists.txt`, so the artefact inspected is byte-identical to what CMake fetches at build time. It unpacks to a bare `libmpv-2.dll`: **mpv v0.36.0-403-g652a1dd907, FFmpeg n6.0, libavformat 60.3.100, `MPV_CLIENT_API_VERSION` 2.1** — Sept 2023, ~29 months before the commit, not 16. `request_size` and `initial_request_size` occur **0 times** in its string table; the same scan finds 3 and 1 in both the system mpv and shinchiro 20260610, which is the control that validates the scan. The `main` pin (mpv v0.39.0-179 / FFmpeg N-117622, Lavf 61.9.100, API 2.3) also has **0** — so moving the pin to `main` would not deliver the option either. The Dec 2025 repo activity is `libmpv-win32-**audio**-cmake` (`20251213`); the video repo's newest release is still Oct 2024. **Superseded in effect by F13:** nothing the app does depends on `request_size` |
| F13 | **The shipped libmpv seeks `ANDROID_VR` streams with no options at all. F11's seek failure is an FFmpeg regression, not a property of the stream** | Measured 2026-08-02 through the libmpv **client API** — the C entry points media_kit's FFI binds — driving three real `libmpv-2.dll` artefacts against spike 03's check 4: four seeks 300 → 60 → 500 → 120 s, position asserted **past** target, itag 401 + 251 merged, `vo=gpu`, `hwdec=auto`. mpv v0.36.0-403 / FFmpeg **n6.0**, the build 1.0.11 actually ships: **4/4 with no `stream-lavf-o` whatsoever, reproduced across 5 runs**, and 4/4 on itag 315. mpv v0.39.0-179 / FFmpeg N-117622 (the `main` pin): 4/4 baseline. mpv v0.41.0-744 / FFmpeg N-124930, Lavf 62.19.101 (shinchiro 20260610): **0/4 baseline, reproduced 3/3**, position frozen at exactly 300.0 / 60.0 / 500.0 / 120.0 — F11's signature — and 4/4 once `request_size=1048576,short_seek_size=1048576` is set. The soft-seek regression therefore entered between Lavf 61.9.100 (Oct 2024) and 62.10.101 (Mar 2026); `request_size` is its workaround, not a requirement for `ANDROID_VR`. F11's "0/4 without `request_size`" is correct **for the FFmpeg it was measured on** and does not generalise downward. All runs hardware-decoded via `d3d11va` on both AV1 and VP9, audio track loaded and tracking, 6.6–17.3 s CPU per 40 s run. **Trap worth naming:** the 2023 build *accepts* `stream-lavf-o=request_size=…`, returns success, echoes it back from the property, and ignores it. Option acceptance is not evidence of support — only the binary is |
| F14 | **A server-issued visitor id survives reuse. It is session-scoped, not per-open** | Measured 2026-08-02, the open question spike 03 left behind. One id minted once, then used for `ANDROID_VR` `/player` resolutions in two phases — 10 rounds 5 s apart, then 18 rounds 2 min apart: **28/28 `OK`, 28 adaptive formats to 2160p, over 37.9 minutes**, no degradation and no failure. A freshly minted id was run against the same session in the same minute as a control and also passed 28/28, so nothing here is a rate limit masquerading as an aged id — the failure mode spike 03 spent a whole run chasing. **This is a lower bound: the id never stopped working, so the real lifetime is unmeasured above 38 minutes and 28 uses.** What it settles is the design question — mint at session creation and keep it, rather than paying a round trip per open. A mint costs ~170 ms (`/sw.js_data`, no player, no config), so the `LOGIN_REQUIRED` retry is cheap when it does fire: measured against three deliberately fabricated-id sessions, all three were refused and all three were rescued by one retry. One id, one machine, one video (`aqz-KE-bpKQ`), one session |
| F15 | **F13 transfers through `media_kit`. The seek result, the artefact and the option hedge all hold through the Dart binding and the ANGLE render path** | Measured 2026-08-02 from the first Flutter build (`app/`, release, Windows). The built app loads exactly F12's artefact: CMake fetches `mpv-dev-x86_64-20230924-git-652a1dd.7z` (MD5 `a832ef24…`), and the DLL beside the `.exe` reports mpv **v0.36.0-403-g652a1dd907 / FFmpeg n6.0**, with `mpv_client_api_version()` **2.1** read at runtime. Rescanned per hard invariant 8 against *that* file rather than the pub cache: `request_size` and `initial_request_size` **0** occurrences, `stream-lavf-o` 1 as the scan's control. One addition to F12: `short_seek_size` occurs **1** time — it is an older FFmpeg HTTP option n6.0 does have — so of the two values spike 05 set together, one is real here and one is inert. Nothing depends on it; `mpv-options.ts` sets only `request_size`. **Seeks: 4/4 with no options set, 5/5 runs** (itag 401 + 251, positions past every target, never equal to it), plus 4/4 on itag 315 through `flutter run -d windows` in debug. **`stream-lavf-o` is reachable**: `(player.platform as NativePlayer).setProperty(…)` before `open()`, echoed back by `getProperty` and still set after 40 s of playback, 4/4 seeks under it. Acceptance is still not support — this is the build whose string table has the option zero times — and **media_kit discards mpv's return code** (`setProperty` calls `mpv_set_property_string` and ignores it), so read-back is the only Dart-side signal and it is a weak one. §2.4's two-URL design is supported: `player.setAudioTrack(AudioTrack.uri(…))` issues `audio-add … select`, the `--audio-file` equivalent, but only *after* a file is loaded and the demuxer reports a duration. Every run: `track-list/count` 2, `aid` 1, `audio-codec` opus, a/v sync 0.04–8 ms. **Trap of its own:** `getProperty` is a blocking FFI call on the UI isolate and can sit on mpv's core lock through a seek — one 6.4 s freeze was recorded, and it manufactured a false 0/4-style "frozen at exactly 300.0" reading before the harness was corrected to time each check from when its seek was issued |
| F16 | **Hardware decode survives the ANGLE path, but as `d3d11va-copy`, and 2160p60 does not present. The decoder properties disagree with each other; only the control settles it** | Measured 2026-08-02, same machine and GPU as F11/F13 (Intel Graphics, driver 31.0.101.4953), so the comparison is clean. media_kit_video's Windows controller sets `vo=libmpv` and `hwdec=auto` itself (`VideoControllerConfiguration`). mpv logs `Using hardware decoding (d3d11va-copy)` on **both** codecs — copy-back, where F11 and F13 got plain `d3d11va` under `vo=gpu`. On AV1 the properties contradict themselves: `hwdec-current` reads `d3d11va-copy` while `video-codec` and `current-tracks/video/decoder-desc` both read `libdav1d`, a software decoder. **The `hwdec=no` control is what settles it**: same track, same build, **166.2 s of CPU instead of 44.6 s**, and the output format changes `nv12` → `yuv420p`. VP9 the same shape, 114.6 s vs 43.7 s, and visibly degraded without it (1205 drops, 787 ms out of sync). So hardware decode is real and F11's conclusion that AV1 needs no special treatment still holds — the two codecs land within noise of each other. **What is new is presentation.** Over a 32 s uninterrupted window at 2160p60: **310–563 frames dropped by the VO** (2 runs each codec), accruing steadily at 10–17/s rather than as a startup burst, with `decoder-frame-drop-count` **0** throughout — 16–29% of frames never reach the screen. At **1920×1080@60, same codecs, same everything: 0 drops** (itag 399 and 303). This is the ANGLE presentation path failing to sustain 4K60 on an iGPU, not a property of media_kit playback. The Q1 seek runs show the same rate between seeks; their low totals are only because mpv resets the counters on every seek. CPU figures include the Flutter engine and are **not** comparable one-to-one with F13's 6.6–17.3 s from a bare libmpv host — the 1080p control burns 34.7 s while dropping nothing, so most of the number is a fixed floor |
| F17 | **Windows orphan prevention: the sidecar watches the parent PID and self-exits.** The earlier conclusion that a bidirectional heartbeat was required was wrong; `TerminateProcess` does skip user-mode cleanup, but the sidecar can poll instead | **Amended 2026-08-04:** Windows Job Objects are the correct kernel-level solution. They successfully kill the child when the job handle closes, but our specific Dart FFI implementation closed the handle prematurely during normal operation. This was a bug in the implementation attempt — a handle lifecycle issue — not a flaw in the Job Object mechanism itself, which remains the ideal long-term fix. As a fallback, the sidecar is passed the parent PID via `FLUTTER_PARENT_PID` and polls it every 3s via `process.kill(pid, 0)`. This leaves an orphan window of up to 3 s during which a killed parent's sidecar still holds cookies and a live session. The `rpc_client_test.dart` orphan test was modified with a 3.5s tolerance to accommodate the polling interval, and `runInShell: false` was used to ensure the tested Dart process is genuinely killed instead of just its shell wrapper. **Re-measured 2026-08-06, and the picture is better than recorded here.** That orphan test had been carrying `skip: Platform.isWindows` with the reason "Failing on Windows" — on Windows-only software, meaning it had never once run, and every report claiming it passed was reporting a skip. It was un-skipped and it passes, 5/5. Mutation testing then established that **two independent mechanisms** each close the orphan on their own, measured by disabling one and leaving the other: with the PID watch disabled the sidecar still exits, and with every pipe handler disabled (and the event loop pinned open so it cannot simply drain) the 3 s PID poll still gets it. So the up-to-3 s orphan window above is the **worst case, not the normal one** — it applies only if the stdin pipe path fails, and in this configuration it does not. That last point contradicts the F16-era claim that `TerminateProcess` leaves stdin EOF unpropagated: with only `stdin.on('end')` and `rl.on('close')` alive, the sidecar still exits. The likely reconciliation is a shell wrapper holding the pipe's write end open in the original repro — `kill_test2.dart` still spawns with `runInShell: true` while the real test uses `false` — but that was **not** tested, so treat the divergence as unexplained rather than resolved. The test's fixed 3.5 s sleep is now a poll with a 12 s deadline: fast when the pipe wins, patient when the watch does, and no longer ~500 ms from going red on a loaded machine. The assertion is unchanged. |
| F18 | **The resume delay is not a seek re-sync, and it is not the audio track running late. Pause/resume and seeking are two different mechanisms, and the long-pause penalty is intermittent** | Measured 2026-08-07 through `app/lib/ui/audio_delay_probe.dart` against the release build, real account, itag 315 (VP9 2160p60) + opus, on the machine of F11/F13/F16. Every figure is read from mpv via `observeProperty`, which fetches on mpv's event thread — no `getProperty` polling, per hard invariant 9. **Milliseconds from `play()`/`seek()` until `time-pos` passes the resume point, n=10 each:** resume after a **2 s** pause — min 59, med 170, max 232; after **30 s** — min 113, med 284, max 485; after **5 min** — min 290, med 596, max 1573; **seek +60 s** — min 796, med 2600, max 4609; **seek −60 s** — min 359, med 1758, max 4965. **The 5-minute arm is bimodal**, which a median hides: five samples at 290–427 ms, indistinguishable from the 30 s arm, and five at 765–1573 ms. Two further samples from an earlier run were both slow (1472, 1895), making 7 of 12. So this is a **~1 s penalty that either fires or does not**, seen only after long pauses and never once at 2 s or 30 s — not a delay that grows smoothly with idle time. **Audio never lags video.** A detector watching for `audio-pts` frozen while `time-pos` advances — which is what the reported symptom would look like — fired **0 times in 52 samples**; wherever both clocks are measurable they cross the resume point within 1 ms. What a user experiences as late audio is the whole player taking up to 1.5 s to start. **Seeks and resumes have different fingerprints.** Seeks are ~95% `core-idle` (med 2458 ms of 2600) — mpv waiting on data after repositioning. Long-pause resumes never touch `core-idle` or `paused-for-cache` at all, and the demuxer cache is **9–21 s full** at the moment of resume. So the resume penalty is not data starvation, and `cache-secs` / `demuxer-readahead-secs` would raise a buffer that is already full and unused. **Idle connections do die, but off the critical path.** At `--msg-level=all=v`, every long-pause resume with a full log window shows `[ffmpeg] https: Will reconnect at <offset> in 0 second(s), error=I/O error` — 6 of 8 samples, the other two truncated. It always arrives **after** playback has already resumed (+300 to +900 ms past the moment `time-pos` moved), because mpv restarts out of the cache it still holds and ffmpeg only finds the dead socket when the demuxer next reaches for bytes. Every observed reconnect offset (49.9, 71.5, 72.2, 87.3, 88.5 MB) tracks the ~20 Mbps **video** stream; **no reconnect was ever observed on the audio URL** in 8 long-pause resumes. So `multiple_requests=1` also targets something that is not the bottleneck. **What co-occurs with the slow resumes** is an `[ao/wasapi] OnPropertyValueChanged` on the output device, present in every sample — but it too lands at or after the resume moment (+2 to +415 ms past it), so it is a correlate and not a demonstrated cause. **The cause is not isolated.** **Method limits, stated rather than left as gaps:** `demuxer-cache-state` describes **one** demuxer and a two-URL setup has two — mpv exposes nothing for the external audio track, so the log is the only per-track evidence and "video has frames buffered while audio has none" is not directly measurable. `audioResumeMs` is unreliable wherever `audio-pts` sat >0.05 s ahead of `time-pos` when the pause began, since the detector then trips on a pre-pause value (shows as a large negative); it affected 2 of 10 five-minute samples and every backward seek, and those rows are excluded rather than quietly kept. **Lever availability, scanned rather than assumed** (hard invariant 8, and `strings` is not on this machine — its absence returns 0 for everything, which reads exactly like a missing option, so the scan carries controls): in the shipped `libmpv-2.dll`, `audio-wait-open`, `cache-secs`, `demuxer-readahead-secs`, `multiple_requests`, `reconnect`, `reconnect_delay_max` and `audio-stream-silence` are all **present**, while `request_size` is **absent** — reproducing F12/F15 on this same artefact, which is what says the scanner works. **No playback option was changed.** Three of the four candidate levers are ruled out by the evidence above rather than by trial, and setting the fourth on a correlation would be the same mistake in a different coat. **Amended 2026-08-11, and this supersedes an amendment of 2026-08-10 that was confounded.** Wiring `player.stream.error` in — mpv reports socket failures there, distinct from its log — identified the mechanism, and extending the pause ladder corrected the magnitudes. **The cause is an idle-killed connection to the *video* stream.** On resume, `tcp: ffurl_read returned 0xffffd8ba` (`WSAECONNRESET`) arrives close to playback starting: of the **15** samples taken after `player.stream.error` was instrumented, **13** show the error and **10 of those 13** resume within ~300 ms of it. (An earlier count of "15 of 16" was wrong — four of the samples it included predate the instrumentation and could not have shown an error at all.) The delay is the dead socket being discovered, or the reconnect and refill behind it — not buffering: `paused-for-cache` is **0 in all 75 samples** and the demuxer cache is 9–15 s full at every resume. **Audio never dies.** Reconnect offsets (34.0, 46.8, 49.6, 71.8, 88.5, 97.3 MB) all track the ~20 Mbps video stream and rise with position; **no audio-URL reconnect was ever observed**, at 5, 15 or 30 minutes. A fix would need to cover video only. **Corrected magnitudes, machine held awake, default options** — the 2026-08-10 figures of 2790 and 5756 ms came from the one run where the machine was left free to idle, which is a 2–4× effect on its own and must not be compared against: **2 s** med 170 (n=10); **30 s** med 284 (n=10); **5 min** med 596, range 290–1573 (n=10); **15 min** med 768, range 541–1529 (n=5); **30 min** 974 and 2298 (n=2). **It plateaus rather than growing** — doubling the idle from 15 to 30 minutes stays in the same band. Left free to idle, the same 15-minute pause gives 2790 and 5756 (n=2), so **the machine's own power state during the pause matters more than the length of the pause**. **Every candidate lever is ruled out, three of them by experiment rather than by argument.** `reconnect` is **already enabled by default** — setting `reconnect=0` made the `Will reconnect` line vanish, and with reconnection disabled entirely a resume still took 1120 ms, so the wait is upstream of it. `reconnect_delay_max` has no backoff to shorten: the log already reads *"in 0 second(s)"*. `reconnect_streamed` applies to non-seekable inputs and these are seekable with range support (F11). `rw_timeout=300000`, tested **alone**, n=5, identical conditions: median **2063 ms against the baseline's 768** — worse, and it never bounded the read it was aimed at (first error still at 690–2434 ms, never near the 300 ms cap), so it does not govern this wait. `cache-secs` / `demuxer-readahead-secs` raise a buffer that is already full and never drained. **No option was applied to the app.** **Honest edges.** The coupling is 10/13, not universal — one baseline sample resumed slowly (1262 ms) with no socket error and no reconnect at all, so the dead connection is the usual cause and not the only one. At 30 minutes the coupling loosens further: one sample errored 1467 ms *after* a 974 ms resume, another errored at 82 ms and still took 2298 ms, so the delay is sometimes detection and sometimes reconnect-and-refill. n=2 at 30 minutes and n=5 at 15, on one machine, one video, one codec pair. **So the state of it: 0.5–1.5 s occasionally with the machine awake, 1–2.3 s at half an hour, 2.8–5.8 s when the machine is left to idle — cause identified, no available lever fixes it, documented and left alone.** That is a limitation to be aware of, not polish |
| F19 | **A mode change does not touch the video output. A quality switch does — it rebuilds the texture and costs 0.55–12 s before the picture moves, which is a stall and is why the automatic stepper stays out of scope** | Measured 2026-08-12 through `RILL_CONTROLS_PROBE=1` against the release build, `aqz-KE-bpKQ` (22-rung ladder, 7 distinct height+fps rows), two full runs on the machine of F11/F13/F16/F18. **Modes: `VideoController.id` is unchanged across all four transitions** — theatre on, fullscreen on, fullscreen off, theatre off — in both runs (`2016289986736` and `2337064972400` throughout their runs), with playback continuing across them (position 4.5 → 12.7 s) and no second `engine.open`. Task 16's stop condition, "a mode change tears down the video texture", does **not** fire: the player lives above the `Navigator` and a mode change moves the controls, not the surface. **The baseline has to be taken after a settle, and this is the trap**: media_kit frees and recreates the texture ~1 s after an open, once the video's real size is known (`Free Texture` → `Create Texture` → `VideoOutput.Resize` to 3840×2160), so a baseline read at the first frame reports every later comparison as a rebuild — the first version of this probe did exactly that and called four unchanged ids "REBUILT". **Fullscreen restores the window exactly.** `GetWindowPlacement`'s `rcNormalPosition` read either side of a fullscreen round trip: `[10, 10, 1290, 730]` → `[0, 0, 2560, 1080]` (the whole monitor, borderless) → `[10, 10, 1290, 730]`. Read from Win32 rather than from the fake, because `flutter test` has no window and can only assert that the window was *asked*. **A quality switch, by contrast, does rebuild the texture** — every one logs `Free Texture` / `Create Texture` with a new id and a resize to the new dimensions. That is the media reopen, not the mode, and it is what §3.5 permits: no `playback.open` is issued, so the RPC session, the history entry and the report cadence carry on. **Cost, n=14 (7 rungs × 2 runs), stepping down the ladder while playing:** the `switchQuality` call returns in **306–743 ms**, but what a viewer waits for is the picture moving again — **551, 577, 672, 1130, 1925, 2833, 3072, 5074, 5243, 5285, 5702, 11676, 11874, 11954 ms; median 4073, range 0.55–12.0 s.** **The long tail does not track the rung**: 480p was 1925 ms in one run and 11676 ms in the other, and each run had two samples near 11.9 s at different rungs — so this is intermittent, 3 of 14 above 11.6 s, not "low rungs are slower". It is consistent with **F18** rather than additional to it: a switch is a reopen plus a seek back, F18 measured seeks alone at 0.8–4.6 s, and the seek dominates. **What that settles for automatic quality stepping** (out of scope in task 16, and this is the evidence for keeping it there): a stepper reacting to sustained frame drops would spend 1–12 s of visible stall per step, on a machine where F16 says the only step worth making is 2160p60 → 1080p60. Choosing once at open costs nothing and buys the same thing. One video, one machine, one sample per rung per run. **Amended 2026-08-12 — the stall is not a frozen UI, and the two were being read as one thing.** The app blocking and the video not moving are different durations, and they were measured separately after the app was reported as freezing during a switch. A persistent frame callback recording **wall-clock** gaps between frames is the instrument — no frames are produced while the UI isolate is blocked, so the largest gap across a switch *is* the freeze, and it has to be wall clock rather than the frame timestamp Flutter passes, which is the vsync the frame was scheduled for and hides exactly the delay being looked for. **On an idle machine the frame loop is not blocked at all**: worst gap **17, 18, 18, 19, 22, 23, 24 ms** across the seven switches of one run — one frame each, indistinguishable from ordinary playback. So the 1–12 s above is the picture not moving while the controls stay live, and not the app being unresponsive. **The first pass at this said otherwise and was confounded, in the same way F18's 2026-08-10 figures were.** It reported 19–650 ms (median 148), and that run was taken while a full `flutter test` suite was compiling and running on the same machine — it measured contention for the CPU, not the switch. Recorded rather than deleted because the confound is the finding: two runs of the same instrument differ by 30× on machine load alone, so any future "the app freezes" number is worthless without stating what else was running. **A second correction from the same run, and this one was a real bug**: `time-pos` reaches the seek target as soon as mpv *accepts* the seek, not when it decodes there — one switch reported the target at **448 ms** and did not move past it until **5343 ms**. Anything keyed on "position is at or past where we were" therefore fires in the middle of the stall; the black cover over the switch waits for strictly *past* it, which is the predicate this finding's own resume figures were measured with. **Re-measured 2026-09-17, because `bitsdojo_window` now owns the frame too** (`BDW_CUSTOM_FRAME`, alongside `Win32WindowChrome`'s own borderless fullscreen, so two things touch the window). Same probe (`RILL_CONTROLS_PROBE=1`, `aqz-KE-bpKQ`), a profile build, one run, now also reading `GWL_STYLE` — a restored rectangle with a changed style would be a native title bar coming back, which the bounds alone cannot see. **The round trip still restores exactly:** `rcNormalPosition` `[640, 160, 1920, 880]` → `[0, 0, 2560, 1080]` → `[640, 160, 1920, 880]`, and the style `0x16cf0000` → `0x96000000` → `0x16cf0000`. `setFullscreen` saves the style it finds rather than assuming one, which is why bitsdojo's frame comes back intact. `VideoController.id` was unchanged across all four transitions, with playback continuing (5.1 → 13.2 s). Quality switches, 7 samples: 353–11 627 ms until the picture moved, worst frame gap 18–29 ms — inside the range above, and the UI isolate still never blocks. **One thing this run surfaced that the measurement did not cause:** the process ended with `0xC0000602` (fail-fast) after the probe's `exit(0)`, and the Application log holds four earlier `0xc0000602` crashes of the release build in `coremessaging.dll` (2026-09-09 and 09-10, before bitsdojo). Not investigated here; `docs/todo.md` tracks it |
| F20 | **Failing launches were the rollout of the PO token requirement.** The A/B flag was `fexp=51946838` | Amended 2026-08-18: F20 is resolved and was never a bug. The 26.7% failure rate was the rollout share of `fexp=51946838`, which mandated GVS PO tokens for `ANDROID_VR`. The rollout is now at 100%. The re-minting workaround only worked because it randomly drew unflagged buckets, which no longer exist. Re-minting is now retired (escape rate is 0%). | Measured 2026-08-13 through `RILL_LAUNCH_PROBE=1`, **20 consecutive launches of the release build**, one process each, `aqz-KE-bpKQ`. **Rate: 5/20 = 25%** (the 2/6 that prompted this is consistent with it; F11's ~2/20 is not, and see below). Every failure is identical: tier 1 resolves normally (22 variants, itag 315), mpv logs `ffmpeg: https: HTTP error 403 Forbidden` → `stream: Failed to open …` → `finished playback, loading failed (reason 4)`, and the app waits **21.7–21.9 s** before saying anything — that is `MediaKitEngine.open`'s 20 s audio-attach guard (§4) plus ~1.8 s of resolution, not a hang. Successful launches settle in 2.0–2.9 s (median 2.3), so the two populations do not overlap at all. **The URL is not dead, and mpv did not fail to open it — it opened it and was told no.** The same URL answers `Range: bytes=0-1` with **206** from the app's own probe, from `curl`, and from Bun's `fetch`. Isolated with one variable: `curl` against the failing URL, **open-ended → 403, bounded → 206, bare GET → 403**, and **5/5 over 40 s** plus a repeat six minutes later. So the refusal is **persistent for that URL**, not a window in time. **This is F10's signature on the client F10 said was clear.** F10 recorded open-ended refusal as a property of `c=MWEB` URLs, and F11 measured `ANDROID_VR` at 28/28 `206` and treated the two 403 sightings as "a refusal window rather than an unlucky request". Both readings need amending: what is observed here is not a window, it is a *particular URL* that will never accept the only request shape ffmpeg makes. **Re-resolving does not recover — but the first reading of *why* was wrong and is corrected here.** Two `playback.open` calls return the **byte-identical URL** (5/5 in the app, 10/10 standalone), and this was initially written down as YouTube answering deterministically. It is not: `innertube/player-response.ts` holds a TTL'd `/player` cache keyed by video and client, and both calls were served from it. So what was measured is the sidecar's own cache doing exactly its job, and it says **nothing** about what YouTube would return. The observation that survives is narrower and still useful: **a naive retry cannot recover, because it never reaches YouTube.** **Measured since: a cache-bypassing re-resolve does not recover either.** With `SIDECAR_PLAYER_RESPONSE_TTL_MS=0` the retry genuinely reaches YouTube and comes back with a **different** URL — 8/8 — and **0/8 of them play**; every rung of the new mint is refused exactly like the old one (48/48 `403`). So the bucket is sticky to something that survives a fresh `/player`, and a retry *within the same session* can never escape it. What is left untested is whether a **new session** — a new visitor id — lands outside the bucket. That is now the only candidate recovery, and it is a much bigger hammer than a retry: F14's whole point is that the visitor id is minted once per session and reused. The user-visible shape is therefore 22 s of nothing, then "This video would not open" over a *Try again* that re-resolves the same dead URL and fails the same way 22 s later. **The discriminator is a YouTube experiment flag, and it separates the two populations perfectly.** Diffing every query parameter of the failing URLs against the healthy ones — 12 failures and 13 successes across two independent 20-launch runs — finds exactly one that separates them: **`fexp=51946838`, present in 12/12 failures and 0/13 successes.** Its neighbour `51946837` appears only on successes (2/13) and `52089683` on everything, so this is one arm of a live A/B bucket rather than noise. Everything else is either constant across both populations (`c`, `itag`, `rqh`, `sparams`, `svpuc`, `vprv`, `mime`, `clen`, `ip`, host, `mvi`, …) or unique per request by construction (`ei`, `id`, `sig`, `lsig`, `spc`, `bui`, `expire`, `met`) — **and the latter must not be read as discriminating**, which the first pass of this analysis did: a set-disjointness test flags every unique-per-request parameter, so only low-cardinality ones can carry signal. `pcm2cms`, which looked promising on a sample of one, appears in both populations. So the cause is **in the mint, decided server-side, before the app sees anything**: URLs stamped with this experiment refuse ffmpeg's request shape for their whole lifetime. That also explains the shape of everything above — the rate is the bucket size, the refusal is persistent because the URL was minted that way, and it covers the entire response rather than one format. **The whole mint is poisoned, not one URL.** On a failing launch every distinct rung is refused — 2160p, 1440p, 1080p, 720p, 480p and 360p all answer the open-ended range with `403` — and so does the **audio** URL from the same resolution (`403` open-ended, `206` bounded). This kills the obvious cheap fix before it was built: **declining down `variants[]` has nowhere healthy to go.** It also corrects the reading that "audio is never the one that 403s": mpv only ever *reports* the video URL because that is the one it opens first, and it never reaches the audio track at all. **The bucket is assigned per *session*, and that is measured rather than inferred.** Twelve launches, each resolving twelve times through the one session the app mints at startup — the same video six times with the `/player` cache disabled, plus six *different* videos, because a flag constant across repeats of one video but varying across different ones would be per-video and the first arm alone would misread that as a session property. **The flag was constant across all twelve resolutions in 12/12 launches — 144 resolutions, zero variation within a launch — and varied between launches, 5/12 flagged.** So a session lands in the bucket when it is created and carries it for its whole life; it is not per request and not per video. That single fact explains every other observation at once: why all rungs of a mint are poisoned, why a cache-bypassed re-resolve still fails (same session), and why the rate is what it is — **33% is the share of *sessions* in the bucket, not the share of requests**. It also means the reproduction gap was a design flaw in the standalone probe rather than a mystery: a script that mints a fresh session per run and resolves once samples the bucket once per run and then throws the session away, which is a different experiment from the app's one-session-many-resolutions.

**The reproduction gap is closed, and the difference was the binary.** Every probe that failed to reproduce ran `bun run src/…`; the app runs the **compiled `dist/sidecar.exe`**. Driving that binary over its own NDJSON RPC — one process per session, exactly as the app does, importing none of the sidecar's modules — flags **6/20 sessions**, against 5/12 in-app and 0/32 for every in-process script. So the bucketing keys on something that differs between a compiled Bun binary and `bun run` — TLS fingerprint and header ordering are the obvious candidates and neither is confirmed — and *not* on the session's client type, its lifetime, the video, the request, the machine or the IP, all of which were held constant across the two populations. The practical consequence is larger than the curiosity: the bucket can now be sampled from a script in seconds per session, so anything that needs many flagged sessions no longer needs to launch Flutter.

**What is not explained: which property of the binary the bucketing keys on.** The obvious reading of the gap — that a short-lived session never gets sampled into the bucket while a long-lived one carries it — was tested directly and is **dead**: one standalone session resolving 20 times across 8 videos over 230 s was flagged **0/20**. With the earlier fresh-session runs that is **0/32** standalone against 5/12 in-app, using the same code, the same `clientType: 'MWEB'`, the same machine and the same IP. So the bucket is decided at session creation, and something about how the app's session is minted differs from a bare `createSession` in a script in a way not yet named. The app remains the only instrument that can sample this. The correlation and the per-session scope stand on 45 launches; what *assigns* the bucket does not.

**What is not explained, and the honest edge of this finding: it does not reproduce outside the app.** Resolving the same video standalone through the same code — 20 fresh URLs, **95 open-ended requests** across single-resolve, double-resolve and repeat-request designs — produced **zero** refusals. Five hypotheses were tested and are dead: the second `/player` that `video.info` issues for the same video does **not** poison the first one's URLs (0/10); the open-ended form is **not** single-use (4 consecutive per URL, 20/20 `206`); `pcm2cms=yes`, absent from 4 of the 5 failing URLs and present on healthy ones, is **not** the discriminator — failure #4 carried it, and a larger sample puts it in both populations; the session's `clientType` is **not** it either (`MWEB`, the app's own, 0/12); and falling back to another variant cannot help, because every rung of a poisoned mint is refused. Everything else in the query string differs per request by construction (`ei`, `id`, `sig`, `spc`, `expire`, `mt`, `bui`, `cps`, `initcwndbps`). Same edge host (`rr7---sn-fpoq-hm2z`) on both populations. **Re-minting the session is an independent draw, which is the middle of the three possible answers and the one that decides the fix.** Driving the compiled sidecar 90 times — one process, one session, one resolve each — flags **24/90 = 26.7%**, and immediately replacing each flagged session clears it **18/24 = 75%** of the time. An independent draw at that base rate predicts 73.3%, so within this sample the replacement carries **no memory of the session it replaced**: the assignment is not sticky to the client, the machine or the IP, all of which were constant across all 90 mints. That rules out both of the other outcomes — it does not escape reliably (so a single re-mint is not a cure) and it does not never escape (so the fix is not a loop). **What it implies for a detect-and-re-mint fix, arithmetic rather than opinion**: with a cap of 1 re-mint the residual failure rate is 0.267² = **7.1%**, with 2 it is **1.9%**, with 3 it is **0.5%** — against 26.7% today. The flag is in the URL the sidecar already holds, so detection costs nothing; each re-mint costs one session creation (~170 ms, F14) plus one `/player`. **Built and measured end to end, 2026-08-13.** 30 launches of the release build, paced 10 s apart, `LOGIN_REQUIRED` in **0/30** so the run is not throttled: **failures 1/30 = 3.3%** against 26.7% before, predicted 1.9%. Re-mints needed: **23 launches none, 4 one, 3 two** — 7/30 = 23.3% needing at least one, against the ~27% base rate. The one failure exhausted both attempts and fell through to fast-fail, surfacing in 3.97 s. A successful open still costs nothing extra (median 2.44 s, against 2.34 s before the retry existed). n=30, so 1/30 carries a wide interval — it is consistent with 1.9% rather than a confirmation of it. **The pacing is part of the experiment, not incidental**: an unpaced 30-launch run an hour earlier tripped YouTube's anti-bot throttle (18/30 `LOGIN_REQUIRED — Sign in to confirm you're not a bot`) after ~180 anonymous resolutions in an hour, and that run measures rate limiting rather than the fix. The retry now stops on a throttle signal instead of spending re-mints against a limit that is already refusing. n=24 flagged sessions for the escape rate, one machine, one video, one afternoon; the independence is consistent with that sample rather than established, and a rate that is really a slow-moving server-side rollout would look identical over ninety mints taken in ten minutes.

**One fix was made, and it is about the symptom rather than the cause.** The 21.8 s was the guard waiting for a duration that the 403 had already ruled out, so `MediaKitEngine.open` now races the duration wait against `player.stream.error` with the timeout kept as the backstop for a stream that is merely slow. Measured over 20 launches on the fixed build: **failures settle in 1.72–1.95 s** instead of 21.7–21.9, which is *faster than a successful open* (2.1–2.5 s). The user still cannot watch the video — nothing here fixes that — but they find out in under two seconds instead of staring at a black rectangle for twenty. **The variant fallback that was the other candidate is not worth building**, and that is a measurement rather than a judgement: every rung of a poisoned mint is refused. **The next step is a decision rather than an experiment:** whether to spend a capped re-mint on the 26.7%, at the residual rates above. Rate across three runs of 20: **5, 7 and 8 of 20 — 20/60, 33%.** One machine, one video, one afternoon |

**F18 has no earlier conclusion to correct.** This investigation was opened on the
understanding that Task 04 had measured the delay on seeks and concluded it was
inherent to mpv re-syncing an external audio track. It did not. `docs/tasks/04-
player-revision-safety.md` is the player-revision race and the `yt-dlp` stderr
pipe deadlock, and the word *audio* does not appear in it; a search of `docs/`,
`docs/tasks/` and all six task reports finds no audio-delay finding anywhere. The
only a/v datum previously on record is F15's `a/v sync 0.04–8 ms` in steady
state, which F18 does not contradict — F18 is about the transition, not the
steady state. Recorded here because "the documented conclusion does not exist" is
itself worth not re-discovering.

**Amended 2026-08-10 — a second finding that was not one.** This section previously
recorded that the player does not survive the machine sleeping while paused. That
was **wrong, and the error was mine**. Two probe processes did exit mid-run on
2026-08-07 with an orderly `VideoOutput: Free Texture` / `~VideoOutput` and no
Dart stack, and neither was killed. The attribution to standby does not survive
checking:

- **No crash.** The Windows Application log has no `Application Error`, no
  Windows Error Reporting entry, nothing for `rill.exe`. Both processes exited
  cleanly.
- **No power transition.** Modern Standby entries and exits that day were at
  10:27, 11:20 and 11:32 local; the deaths were at **11:57:55** and **12:04:35**
  local — nothing within twenty minutes of either.
- **The timing argument was an artefact of a timezone mistake.** "Died 21 minutes
  in, standby is 20 minutes" compared the probe's **UTC** log timestamps against
  a **local** clock, and Rome is UTC+2 in August.
- **It does not reproduce.** A deliberate attempt — two 15-minute pauses, thirty
  minutes, `SetThreadExecutionState` explicitly *not* held — ran to completion
  and exited normally.

The wakelock mechanism cited is real: media_kit's `Video` widget releases its
wakelock when playback pauses
(`media_kit_video-1.3.1/lib/src/video/video_texture.dart:346`). It is simply not
what killed these two processes, and **no app behaviour was changed on the
strength of it**. The cause of those two exits is **unknown**; the probe now
carries the instruments to catch a third (see below).

Also learned while chasing it, and worth not re-deriving: `VideoOutput: Free
Texture` is **not** a teardown signal on its own. The reproduction run freed and
recreated its texture mid-run — `Free Texture` → `ANGLESurfaceManager: Direct3D
Feature Level: 11_0` → `Create Texture`, with `VideoController.id` changing from
`2981946491712` to `2982224235824` — and playback carried on. Only the
`~VideoOutput` destructor is the end.

**What is observable, for whatever needs it later.** media_kit exposes more than
Flutter's lifecycle: `VideoController.id` and `.rect` are `ValueNotifier`s and
`id` changes when the output is rebuilt, which is the hook a recovery would hang
on; `player.stream.error` carries mpv's failures; `player.stream.audioDevice(s)`
carries device changes. Flutter's `AppLifecycleListener` also works on Windows —
the reproduction run logged `inactive` → `resumed` twice. What does *not* exist
is a device-loss callback: there is no "your texture just died" event, only the
`id` change after the fact.

**Parked as cosmetic, 2026-08-11 — a ~1 ms stale-audio blip after a seek.**
Observed by hand on both machines: when audio and video come back after a seek,
roughly a millisecond of audio from the *pre-seek* position plays first, then
everything is normal. Rate is informal — "about 2 times out of 30", the user's
own estimate and explicitly rough. It is unrelated to everything F18 measures:
that is start *latency*, this is a stale sample already decoded. The likely
mechanism is residue in the audio output path being drained before the post-seek
samples arrive, possibly a flush racing the resume, and the two-URL design gives
it room — the external audio track is a second demuxer with its own buffers.

**Not investigated, deliberately, and the reason is measurability rather than
laziness.** `audio-pts` observations arrive at ~10–20 ms granularity, so a 1 ms
artefact will not move the property at all; the existing traces cannot confirm or
deny it. Establishing it needs audio loopback capture and waveform comparison
against the source — a new rig, not a probe flag. Against that cost: the artefact
is three orders of magnitude smaller than the 0.8–4.6 s seek latency this same
finding already records as a limitation, and the one available lever
(`audio-buffer`, present in the artefact) would trade the residue for less output
headroom, which is exactly what the slower machine cannot spare.

Worth revisiting **only** if it becomes frequent, or on the way into Phase 2 —
where a muxed DASH stream has no second demuxer, so the bridge may dissolve it
without anyone touching it.

**Measurement gap on F13 — closed 2026-08-02.** F13 was taken through the libmpv
client API against the real shipped DLL, not through `media_kit` inside a Flutter
app, because the measuring machine had no Flutter SDK, Visual Studio or CMake at
the time. The reasoning offered then — seeking is decided in ffmpeg's
stream/demuxer layer, not the video output, so `vo=gpu` here versus `vo=libmpv`
there should not change it — turned out to be right, but it is no longer what
the finding rests on: **F15** measured the same four seeks through media_kit's
Dart binding and ANGLE render path, 4/4 across five runs plus a debug run, on the
same DLL. What the ANGLE path *does* change is the decoder, not the seek: see
**F16**. Still one video (`aqz-KE-bpKQ`), one machine, one GPU.
| F21 | **The `ANDROID` client response fundamentally breaks the sidecar parser.** | Measured 2026-09-10. While spoofing `ANDROID` returns the same conceptual data, its API responses heavily use protobuf arrays or mobile-specific JSON renderers (like `compactVideoRenderer`, native carousels, or Android ad blocks). The sidecar is explicitly built around `MWEB`/Desktop JSON vocabulary (`src/parser/vocabulary.ts`); encountering these undocumented renderers causes the parser to safely skip them, resulting in empty/broken feeds. Thus, `MWEB` remains strictly superior for stable metadata scraping. |
| F22 | **YouTube issues `"STATION"` badges for 24/7 radio streams, it is not `ANDROID`-exclusive, it is a live rollout rather than a fixed per-client difference, and its `badgeStyle` says `LIVE` too.** | Measured 2026-09-10 on DECO*27's channel. First measured on the `ANDROID` client only, against `MWEB`, with `MWEB` returning `"LIVE"` — reasoned from that pair alone that `WEB`/`MWEB` were unaffected and the regex needed no change. Same day, same channel: a user on the plain `youtube.com` web client (not `ANDROID`, not a spoofed client) saw `"LIVE"` that morning and `"STATION"` later the same session, with nothing on their end changing in between — YouTube flipped it under them. So this is not "some clients say STATION, some say LIVE"; it is a label YouTube can move to any client, mid-session, without warning. That rules out any fix that keys on which client is asking (there is no stable answer), which is why the fix introduces a distinct `STATION_LABEL` regex in `src/parser/text.ts` instead — a label match holds regardless of who serves it or when it changes. **That first fix shipped wrong anyway, for a second reason** — confirmed live 2026-09-11 against a real search result for `h4hy2Gn-FVE`: the badge's `text` is `"STATION"` but its `badgeStyle` is `THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE`, the same style an ordinary live badge carries. `scanBadges`'s generic style-based LIVE check ran first, classified the badge as live, and returned before the label was ever read — so `isStation` stayed `false` in production while a synthetic test built on the untested assumption "no LIVE-ish style accompanies it" kept passing. Fixed by checking `STATION_LABEL` before the style-based LIVE match. F21's `ANDROID` parser findings are unrelated and still stand. |
| F24 | **A mix is a sliding window with no continuation, its panel is not a renderer, and `isInfinite` lies.** `protocol.md` §3.3's specified `mix.start` shape was wrong in three independent ways | Measured live 2026-09-12, `WEB`, anonymous and authenticated. **Shape.** `/next {playlistId[, videoId]}` returns the panel as a **bare object** at `contents.twoColumnWatchNextResults.playlist.playlist` — no wrapping renderer key, so `isRendererKey`'s `Renderer`/`ViewModel`/`Model` suffix test cannot see it and the walker descends through it as ordinary JSON, interleaving its rows with the related rail's (45 items for a page whose panel holds 25). `playlistPanelRenderer` occurs **zero times**, for a mix *and* for an ordinary `PL…` playlist. **No continuation exists**: zero occurrences of `"continuation"` anywhere in the response. **`index`/`playlistIndex` are ignored** — the server resolves position from `videoId` and corrects the caller (seed at `index: 24` → `currentIndex: 0`). **Window.** At most 25 items of history and *exactly* 24 of lookahead around the anchor: index 0 → 25 items, 10 → 35, 23 → 48, 24 → 49, capping at 50 from index 25 on. So extension is re-anchoring, and a client that accumulates (anchor on its last item, append the tail) grows +24 per fetch with **zero duplicates** — verified to 217 items over 8 hops on two different radios. **Every mix is finite and `isInfinite` is `true` on all of them**, including curated `RDCLAK…` lists that exhaust at ~51 items (lookahead tapering 24 → 2 → 0); an auto radio exhausted at ~169. Two distinguishable endings: an empty tail, and an anchor the server no longer places in the sequence (`indexOf === -1`, a re-seeded window) — which is why `mix.extend` answers `{items[], exhausted}` rather than a bare list. **Sub-types do not diverge**: `RD`, `RDMM`, `RDAMVM`, `RDEM`, `RDCLAK` share panel location, lookahead, extension and termination; `RDAMVM<id>` was byte-identical to `RD<id>`. (`RDWS…`/`RDP…`/`RDKOO…` seen in the feed are **not** sub-types — they are `RD` + an 11-character video id beginning with capitals.) **No auth needed, heavy personalisation**: anonymous always returns a full panel, but the same ids opened anonymously and signed-in at the same moment shared 2/25 (`RD`, `RDAMVM`), 1/25 (`RDMM`) and 7/25 (`RDEM`) — while curated `RDCLAK…` was **25/25 identical**. That is the evidence behind "do not cache mix contents". **A plain watch page carries no mix**: `/next {videoId}` with no `playlistId` has no panel, and the video's own `RD<id>` appears nowhere in the body; the `RD…` ids present belong to other videos' radios in the related rail. So `mix.start` is not redundant for the watch-page entry path. |
| F25 | **`playback.report` was reporting every mix watch as a standalone watch**, because `list=` rides on the `/player` request rather than on the ping | Measured 2026-09-12. A `WEB` `/player` asked with a `playlistId` returns `videostatsWatchtimeUrl` carrying `list=<playlistId>`; the same call without one carries no `list` parameter at all (watchtime params `cl,docid,ei,fexp,ns,plid,el,len,of,subscribed,uga,vm` versus the same plus `list`). `playback/report.ts` called `getPlayerResponse(browse, videoId, 'WEB')` with no playlist, so the context was never requested and could not be added at ping time. Fixed by carrying the playlist id on the playback session (`playback.report` takes a `sessionId` and nothing else, so the session is the only thing that still knows by report time) and into the `/player` request. **The `/player` cache key `client:videoId` was already wrong** for the same reason and independently of mixes: it served one entry for two responses that genuinely differ, so whichever caller landed first decided what the other got. The key now includes the playlist id, with a call carrying none keeping exactly the old key — verified by test that sequential and concurrent no-playlist callers still share one fetch, and that an explicit `null` keys identically to an absent one (mutation-checked: keying `null` distinctly costs every ordinary watch a second `/player` round trip). The resolution ladder deliberately still asks without a playlist id — a mix changes nothing about which streams exist. |
| F26 | **Signed in, a mix tile's advertised video is not reliably the first item unless the tile's own click-target `params` is sent** — decided 2026-09-14 to always open on it | Measured 2026-09-14. Every mix tile carries the song it advertises in three agreeing places — the thumbnail's video id, the tile's click target `watchEndpoint.videoId`, and (for `RD<11>` auto radios only) the playlist id's suffix; `RDMM…`/`RDGMEM…` have no suffix, so the click target is the source. First item is the advertised video: `{playlistId}` alone 1/3; `{playlistId, videoId}` 86/90, with the misses clustered in one session (a Hoshimachi Suisei mix opened on a Daft Punk track absent from its window); `{playlistId, videoId, params}` 114/114 including replay on a fresh session; signed out, bare `videoId` 9/9 — so personalisation is what overrides the seed. `params` was the same constant (`OALAAQE%3D`) on every tile sampled. **Decision and why:** a tile titled and thumbnailed after one song must open on that song — not confusing a user who clicked expecting it, and consistent across opens — so `MixItem` carries `seedVideoId`/`startParams` from the tile, `mix.start` sends both, and the sidecar enforces seed-first on top (move to front if present; prepend from the same response's watch page if that page is the seed; else retry once). `protocol.md` §3.3 has the rule. |
| F27 | **The `0xC0000602` fail-fast in `coremessaging.dll` is an order-of-teardown bug in `flutter_inappwebview_windows_plugin`.** | Read 2026-09-17 with WinDbg from one minidump (release build, pid 15384, the 2026-09-09 17:41 crash, process 25 s old). The faulting stack runs `ucrtbase!execute_onexit_table` inside `flutter_inappwebview_windows_plugin` → a `Compositor` `Release` → `dcomp!Compositor::Destroy` → `coremessaging!…EnumerateItems` → `Cn::FailFast::IndexOutOfRange`. So it is a static destructor at DLL unload, after the app has shut down. The static is `InAppWebViewManager::compositor_` (`inline static`, 0.6.0 `in_app_webview_manager.h`), created when the plugin registers — **every launch, whether or not a webview is ever opened**. **It is intermittent, not every exit**: the Application log holds four such events (2026-09-09 04:01, 04:17, 17:41; 2026-09-10 18:40) against far more closes, and what decides it is unknown. Only the 17:41 crash was dumped; the other three and the controls probe's `exit(0)` on 2026-09-17 are presumed the same, not shown. **Cost:** a logged crash event; nothing the app writes is lost, since everything has already run. Possible fixes (plugin upgrade, `TerminateProcess` after engine shutdown) are `todo.md` item 30. |
| F28 | **The 2026-09-17 engine abort (`0xC0000409` in `flutter_windows.dll`) is a race in `media_kit_video` 1.3.1's texture resize**, not the engine's | Read 2026-09-17 from the full dump of that crash (pid `0x133F4`, release build; the user was moving the pointer over home-page tiles, a live one among them). Stack: `flutter::TextureLayer::Paint` → `FlutterWindowsTextureRegistrar::PopulateTexture` → `media_kit_video_plugin` → `std::_Xout_of_range` → `__C_specific_handler_noexcept` → `terminate` → the engine's own `abort` (`FAST_FAIL_FATAL_APP_EXIT`). The source (`windows/video_output.cc`, `VideoOutput::Resize`): the new texture is registered and its id assigned to the member `texture_id_` *outside* `textures_mutex_`, and only then inserted into `textures_`; the raster thread's populate callback — still serving the *old* texture in the frame being painted — reads the member, not its own id, and calls `textures_.at(texture_id_)`. A paint that lands between the two steps throws, and a C++ exception cannot cross the engine's `noexcept` boundary. `Resize` runs whenever the decoded size changes, which an adaptive live stream does on its own — consistent with the hover over a live tile, not proven by it. **Evidence, three independent routes, 2026-09-17.** (1) The two unsymbolised plugin frames, disassembled in a build of the same unmodified source: `+0xb2fe` returns into a function that locks the mutex, tests `texture_id_`, calls `surface_manager_->Read()`, FNV-hashes `texture_id_` into an `unordered_map` and, on a miss, throws `"invalid unordered_map<K, T> key"` — the H/W callback, instruction for instruction; `+0xd887` returns from the `std::function` thunk that calls it. (2) A Gemini 3.1 Pro agent given only the unmodified source, this stack and a two-line description of the app — nothing about when it happened — named the same line (`video_output.cc:317`) and the same interleaving. A second agent given the source alone did not find it (it reported four other problems; `todo.md` item 35). (3) **Reproduced deterministically**: with the window widened by two injected sleeps (20 ms at the top of the H/W callback, 50 ms between `RegisterTexture` and the insert) and resizes driven by `RILL_CONTROLS_PROBE`'s quality switches, upstream 1.3.1 aborted `0xC0000409` on the first switch in **3 of 3** runs, every dump showing this stack; the patched plugin with the *same* sleeps finished all 7 switches in **3 of 3**, each switch getting a new texture and resuming playback. **Fixed** by vendoring 1.3.1 into `third_party/media_kit_video` (a path `dependency_overrides` entry): the callback looks up with `find` and returns `nullptr` on a miss, and `Resize` publishes `texture_id_` only after the insert, under the lock — so an in-flight paint of the old texture skips a frame instead of aborting. 2.0.1 (the latest, 2025-12-02) still has the race, and no upstream issue names it. The old texture's own descriptor is deliberately *not* returned: `SetSize` has already destroyed the surface its handle names. |
| F29 | **Comments are view-based and live in the entity store, not the renderer tree.** Every other parser walks a nested DOM; comments decouple the tree from the data. The response tree holds only `commentThreadRenderer` → `commentViewModel.commentViewModel` containing string keys (like `commentKey` and `sharedKey`). The actual data (author, text, likes, reply count) ships in a separate dictionary: `frameworkUpdates.entityBatchUpdate.mutations[]`. The parser has to resolve these keys to extract a comment. `commentEntityPayload` holds the unique facts per comment, while `commentSharedEntityPayload` deduplicates static localisation strings across all comments (like "View all replies"). Mutations arrive in the same response as the threads that reference them, so they do not need to be accumulated across pages. An unresolvable key means the data is missing and the comment must be skipped silently. | Measured 2026-09-17 against a live `/next` continuation for comments. Renumbered from F27 on 2026-09-18: it collided with the coremessaging finding above. |
| F30 | **A reply list is a tree that the UI shows flat, its load-more control is a button, and the count it advertises is not the list.** Level-1 replies are the response's top-level items; a reply-to-a-reply (`replyLevel` 2) is nested in its parent's `replies.commentRepliesRenderer.subThreads`; and the "Show more replies" token is `button.buttonRenderer.command.continuationCommand.token`, not the `continuationEndpoint` shape a page of threads uses. The parser read neither, so nested replies vanished and a 962-reply thread listed 5 with no way to continue. `Comment.replyCount` is a display string that lags removals, and the signed-in and anonymous views of one comment can disagree. | Measured 2026-09-18 on live threads. Advertised 2 / listed 1, with 2 raw `commentThreadRenderer`s (one nested); 962 → 5, 106 → 4, 248 → 7, each with 2–4 button-shaped tokens; after the fix a 106-reply thread pages to 104 unique replies in 10 pages. A comment whose only reply had been removed by someone else advertised 1 signed in (its replies token returned zero renderers) and 0 anonymously, at the same moment. `protocol.md` §3.3. |
| F31 | **Comment writes need only the authenticated `WEB` session; their tokens are deterministic; a success is not proof of visibility.** `comment/create_comment`, `comment/create_comment_reply` and `comment/perform_comment_action` (delete) all landed with no attestation field sent. Their opaque params are the video id (and the parent comment id) in a protobuf — byte-identical across sessions, not session-minted — so an earlier reading of one 404 as "the token expired" was wrong: the parent comment was gone. The create response also carries a separate `runAttestationCommand` this process cannot honour; whether skipping it affects spam filtering is unestablished. | Measured 2026-09-18 with live writes on a test account: `STATUS_SUCCEEDED` for post, reply and delete; the comment-box token identical across three sessions; a posted comment visible to an anonymous session. `protocol.md` §3.4. |
| F32 | **A link to a comment (`&lc=`) is the comments token plus one protobuf field.** The `comment-item-section` token on a linked watch URL differs from the plain page's only by `#16 = "<commentId>"` inside the same nested message; a token built that way from the plain one puts the target first, exactly once, and marks it `linkedCommentText: "Highlighted comment"` (server-supplied and localised). A link to a *reply* returns the parent thread first, with the reply in `replies.commentRepliesRenderer.teaserContents` — a shape the parser does not read. | Measured 2026-09-18, anonymous, against a live linked URL: plain and linked tokens decoded and diffed, then the constructed token replayed through `/next`. Not built — `todo.md` item 40. |
| F33 | **A comment's like state and the creator's heart are on their own entity, and the comment's `toolbar` only looks as if it carried them.** `engagementToolbarStateEntityPayload` — `{likeState, heartState}`, keyed by the view model's `toolbarStateKey` — is the only place either lives. `commentEntityPayload.toolbar` holds `heartActiveTooltip` (`"❤ by @creator"`) on **every** comment: it is the tooltip for the hearted *state*, not a sign of one. `likeState` is the viewer's (an anonymous session reads `INDIFFERENT` on all); `heartState` is public and identical in both views. The toolbar ships the count twice — `likeCountLiked` (with the viewer's like in it) and `likeCountNotliked` — and `likeCountA11y` follows whichever the state selects, so a liked comment is displayed with the first. | Measured 2026-09-19, six videos, 120 comments, signed in and anonymous. The parser reported **120 of 120 hearted** (from the tooltip) where the state entity says **4**, and **0** liked where it says 1, 4, 0, 0, 2, 0 per video. The count: a liked comment read `likeCountLiked` 737 / `likeCountNotliked` 736, a11y "737 likes"; the anonymous view of the same comment read 738 / 737, "737 likes". Fixed. The corpus gained `comments-viewer-state.json` (4 liked, 1 hearted) — the first fixture holding either; the earlier ones held neither, which is how an all-green corpus sat on both bugs for weeks. **Incomplete as first shipped:** `heartState` also reads `..._HEARTED_EDITABLE` / `..._UNHEARTED_EDITABLE` in the creator's own view; see F35. |
| F34 | **A thread's replies were built eagerly and died with their row; they are now rows of the one virtualised list, and a thread's state is held by the section, not by a row.** `SliverList.builder` virtualised the threads, but inside one the replies were a plain `Column`, and three things followed. Every loaded reply existed while the thread was expanded, and the thread built a *new* widget per reply on each rebuild (a page arriving, the reply box opening, a delete), so the framework updated all of them each time: ~0.1-0.18 ms per loaded reply, per rebuild. Collapsing and re-expanding a thread mounted every loaded reply in one frame. And the expansion, the loaded replies, the "Show more replies" token and a half-typed reply lived in the thread row's `State`, which the list disposes when the row scrolls out of the viewport, so a thread scrolled away and back was collapsed with its replies gone. Memoising the reply rows fixed the first of the three and nothing else. `comments_section.dart` now flattens the section into one list of rows (a thread, each of its loaded replies, its footer), built lazily by one `SliverList.builder`, keyed by comment id, with a `findChildIndexCallback`. What a thread needs to outlive its row (`_ThreadState`: expansion, replies, token, reply box) and which comments are expanded past four lines are held by the section. **A re-sort or a change of video forgets all of it; a delete forgets the deleted thread's.** A reply box's controllers are disposed the frame after their thread leaves the list, and at once with the section. **What it costs:** the flat list is rebuilt on every build, O(threads + loaded replies), so a whole-section rebuild now grows a little with N (below); and every thread's loaded replies and reply draft are held for as long as the section lives, on screen or not. | Measured 2026-09-19 (before, memoised) and 2026-09-20 (rewrite), release/AOT, 1280x721, the real `CommentsSection` over a synthetic `CommentsSource` with real-sized (88 px) avatars served from loopback and comment lengths taken from a live page (`app/lib/probe_comments.dart`; `app/test/README.md`). **The runs compare like for like at N >= 100:** phase A's scrolling build p50 reads 0.84-0.88 ms at N=100/500/1000 in "before", in "after-1" (memoised) and, at 0.82-0.87, in the rewrite run, so they ran under the same load; "after-2" (memoised, a quiet machine) reads ~0.6x on that control and is left out of the comparisons below. **Top-level list**, N=20/100/500/1000 threads: scrolling at 4000 px/s build p50 0.4-0.9 ms, p99 <= 1.4 ms, unchanged by the rewrite, at most 3 of ~510-560 frames over 8.33 ms and 2 over 16.67 ms (isolated frames of 23 to 149 ms turned up in some of the runs, unexplained); a full sweep of 1000 threads at 20000 px/s leaves **1000 decoded avatars, 29.5 MB** in the image cache (its default cap is 1000 entries, so bounded, and not reduced). **The rewrite's cost:** a whole-section rebuild per frame, build p50 at N=20/100/500/1000, was 1.67/1.65/1.92/1.86 ms before and 1.60/1.60/1.79/1.87 memoised, and is **1.63/1.66/2.26/2.63** now: flat in N up to 100, then +0.4 ms at 500 and +0.8 ms at 1000 threads, from rebuilding the flat list and its key index. A sixth of a frame at the worst, and the price of the rest. **A thread's replies**, M=20/100/500/1000 loaded (before -> memoised -> rewrite): *rebuild of the expanded thread while on screen*, build p50, 2.57/10.28/79.77/183.41 -> 0.50/0.69/1.13/1.81 -> 1.49/0.89/1.88/1.29 ms (memoising took it from ~0.18 ms per loaded reply to ~0.001; the rewrite's is flat in M, at 0.9-1.9 ms, and slower than the memoised `Column` at small M, which skipped the rows and this rebuilds the ~8 on screen, a reading of the numbers and not separately measured); *collapse, then expand again*, worst frame, 8.42/48.53/345.12/663.25 -> 9.07/53.92/328.56/623.80 -> **4.32/2.47/2.56/3.03 ms**; *all M replies arriving in one page* (the app cannot ask for that, YouTube pages 10-23 at a time), worst frame, 12.14/60.09/341.36/673.46 -> 11.76/59.51/641.75/675.07 -> 5.74/2.88/6.04/3.33 ms; *still expanded after scrolling a screen away and back*: false/false/true/true -> false/false/true/true -> **true at all four** (before, true at 500 and 1000 most likely because a thread that tall never left the viewport entirely, an inference). **A click as the app makes it** (12 replies per page, worst build frame) with N already loaded, N=0/12/60/120/240/480: before 8.3/9.9/13.5/25.9/50.3/86.4 ms; memoised 7.2/9.3/6.7/6.9/7.2 (480 not reached; 7.5 on the quiet run); **rewrite 2.7/3.1/2.8/2.7/3.7/2.7 ms, none of 24-43 frames over 16.67 ms**. Phase C was run alone, after the first rewrite run died in it on a probe bug (the list had become lazy, and the harness looked a button up before scrolling to it); that run's two points, 3.3 and 3.5 ms, agree with these within the spread between processes. **Retained:** after expanding and scrolling for 8 s through M loaded replies the image cache holds 40/120/508/1000 decoded avatars (1.2/3.5/15.0/29.5 MB) before and 40/120/140/140 (1.2/3.5/4.1/4.1 MB) now: the eager list decoded every loaded reply's avatar on expand, the lazy one decodes what it builds, and a full sweep of a thread would still reach the cache's 1000-entry cap. **Not measured:** what the retained `_ThreadState`s cost in memory (`Comment` objects, small), scroll anchoring when a thread expands (Task 27 section 7), a live page, real avatar fetch cost, and the running app, in which none of this has been seen. |
| F35 | **Viewer-state fields were checked against whatever state the captured account happened to be in, so a wrong reader passed; three were wrong, one of them the fix for another.** `PlaylistMembership.containsVideo` was `false` for every playlist of every video and `removeToken` always `null`: `containsSelectedVideos` is the string `"ALL"` or `"NONE"` and the parser tested `=== true`, so the save dialog never showed a playlist as holding a video and "remove from playlist" was unreachable from the UI. Its first live run was 2026-09-20 and it worked, with the removal endpoint YouTube supplies for Watch Later (`ACTION_REMOVE_VIDEO_BY_VIDEO_ID`, `removedVideoId`), not the entry id `protocol.md` §3.4 assumed. `Comment.creatorHearted` (F33's fix) missed `TOOLBAR_HEART_STATE_HEARTED_EDITABLE`, which is how the *creator* sees a comment they hearted (`..._UNHEARTED_EDITABLE` when they have not): it was verified on six videos, all seen as a non-creator. **Read correctly:** `VideoDetail.isSubscribed` agrees with the account's full subscription list (1,332 channels over 14 pages) on 34 of 34 single-owner videos, both states present; a collaboration video (`channelId` null, per-channel subscribe flags) is unresolved. `myRating` agrees with the page's own `likeStatus` on 35 of 35, and all three values were seen live (`like`, `dislike`, `none`). **Not viewer state:** `canWatchLater` and `canAddToQueue` are tile capabilities, `true` on every tile measured (24 of 24 signed-in home, 20 of 20 signed-in and 20 of 20 *anonymous* search, 100 of 100 Watch Later), and a feed tile does not say whether its video is already in Watch Later (`isToggled` false on the one of 111 subscription tiles that is; n=1), so that state has to come from the save dialog. | Measured 2026-09-20, signed in: first against the account's own lists as oracles, then with the account put in known states by `capture-viewer-state.ts`, which refuses to write a fixture unless the raw response proves the state, checked by paths of its own rather than the parsers under test. States set: on Big Buck Bunny, like it, subscribe to its channel (Blender) and add it to Watch Later; on a video the account owns, like and heart the account's own comment (hearting is creator-only, and the account owns 7 videos). All of it was reverted and the account reconciled against its subscription list (1,332, unchanged) and Watch Later list (3,200, no Big Buck Bunny); the own comment ends as it began, liked and hearted. Fixtures live in `sidecar/fixtures/viewer-state/`, which `capture.ts` now carries across instead of deleting; the sanitised pair is `corpus/viewer-state-*.json`, asserted in `corpus.test.ts` and, raw, in `viewer-state.test.ts`. Aside: `parseFeed` extracts no continuation from the liked-videos browse (`VLLL`), whose raw response has one (about 4,865 items over 48 pages); the app has no such page. |
| F36 | **A `Stack` hit-tests its children only inside its own bounds, so a child that hangs off a small one is partly unclickable, and a disabled control never shows it.** The tile's 3-dot button (a 48 px tap target) hung off the *title row*, which is one text line, so on a tile with a one-line title the lower half of the button hit nothing. It had never been clicked: `MediaTile.onMore` was wired to nothing (the b2549cb review), so every 3-dot button in the app was drawn disabled. Fixed by hanging the button off the whole text column, which is taller than the button and sets the same offsets: the rectangles of the tile, its title, channel and views lines, and the button itself are identical before and after in ten layouts (standard at two widths, wide, large and shorts, each with a one- and a two-line title), so nothing moved on screen. The menu is `MediaTile.menu`, built by `tileMenuFor`: Add to queue, Save to Watch Later, Save to playlist… (the save dialog Task 25 §5 said this menu opens) and Share (the share dialog) for a video; Copy link alone for a mix or a playlist, which are not videos. The first cut had Add to queue third and ended in Copy link for a video too; the entries were reordered and Share replaced it afterwards. | Measured 2026-09-20 in `flutter test`, whose Ahem font makes the title row 20 px: a tap at the button's centre (y 211) ended its hit path in the tile's background, because the row ended at y 208 and the button spans 187 to 235. `tile_menu_test.dart` taps a point inside the button and below the title in the standard and wide layouts, and fails when the button is hung off the title row again (mutation-checked, with three others). The first cut was not looked at in the running app (no screenshot tool was available); the reworked menu was seen there on 2026-09-20, by the user, who reports that it works. |
| F40 | **1280x720 is YouTube's thumbnail ceiling, the URL a surface ships varies by nearly 3x, and for a square or vertical video most of that frame is baked-in black.** `maxresdefault.jpg` is not bigger than `hq720.jpg` — they are byte-identical — and a `WEB` player response *declares* maxres as 1920 wide while the served bytes are 1278x720, so the declared width lies. Home and subscriptions tiles ship ~720; the **watch page's related rail ships 336**, which fetches as 480x360, and that rail is where queue items come from. Worse for a square or vertical video: its 4:3 `hqdefault` is the art pillarboxed with black, so only the middle 75% of the width is picture. **No available URL fixes this** — a fullscreen audio-only backdrop was upscaling a 360x360 crop ~3.3x, which is why §2.4's artwork is blurred rather than merely fetched larger | Measured 2026-09-22. `maxresdefault` and `hq720` byte-identical at 1280x720 on five videos (`dQw4w9WgXcQ`, `kJQP7kiw5Fk`, `9bZkp7q19f0`, `L-BgxLtMxh0`, `aqz-KE-bpKQ`); `x8PCNqH-Dm8` 404s both, returning a 120x90 placeholder. Widest-per-tile across the corpus: `home.json` and `subscriptions.json` mostly 720, `watch.json` 336 — and that same video's bare `hq720.jpg` fetches 1280x720. The fullscreen pillarbox measured at exactly 75% of width, which is what identifies the source as 4:3 |
| F41 | **The shipped libmpv has no audio-visualization filters, so an audio-reactive visualizer is not possible here.** `lavfi-complex` the *option* is present and accepted, which is hard invariant 8's false positive exactly — the option existing says nothing about the filters existing. Getting them would mean bumping `media_kit_libs_windows_video` off 1.0.11, which reintroduces the F13 seek freeze, so this is closed rather than deferred. **Any visualizer built here is time-driven and must not be presented as reacting to sound** | String-table scan of the shipped `libmpv-2.dll`, 2026-09-22: `showcqt`, `showspectrum`, `showspectrumpic`, `showwaves`, `showwavespic`, `showfreqs`, `avectorscope`, `showvolume`, `ahistogram`, `aphasemeter`, `abitscope`, `astats`, `ebur128`, `volumedetect`, `silencedetect` all absent; `asplit` and `amix` absent too, so the graph could not be built even if a filter existed. Only `aresample`, `aformat`, `anull`, `abuffer`, `abuffersink` are present. `af-metadata` exists but nothing can populate it |
| F42 | **A file loaded with `vid=no` and no audio attached is skipped, so its open never gets a duration.** A variant's video URL is video-only and its audio is a second URL. `vid` is an mpv *option*, so a `vid=no` left by an audio-only track persists into the next load; mpv then finds no stream to select, moves past the file, and `open`'s duration wait runs to its 20 s timeout. That was the 0:00 stall (`todo.md` 43, closed), and it only ever happened in audio-only mode. `9299ed3` forced video on for every open, which cured it by fetching and decoding video only to drop it; `02f2768` attaches the audio **at load** instead, through `audio-files`, so the file has a selected stream from the start and the video is never read. **`setProperty('audio-files', '')` does not clear that list** — it sets a list of one empty path, and every later video-mode open failed with `Cannot open file '': Invalid argument`. Clear and add through `change-list` (`clr`, `append`), which also keeps a `;` in a URL from splitting it. A muxed variant has no separate audio, so it still opens with video on and drops it afterwards | Measured 2026-09-24 by `audio_mode_probe.dart` (`PROBE_SCENARIO=open`), one 1080p variant opened three ways, sampled every 250 ms: video forced on then dropped — first audio at 5512 ms, 329 KB to 1.36 MB of video read, a frame decoded; audio at load — 5501 ms, **0 bytes**, no frame; video mode straight after — 5000 ms, 1.36 MB, exactly one audio track in `track-list`. The empty-path failure was caught by that third leg, before it shipped |
| F43 | **A song credited with no art still ships a cover URL, and it points at a stock image.** `videoAttributeViewModel.image.sources[0].url` is `https://www.gstatic.com/youtube/img/watch/yt_music_channel.jpeg`, a grey square with a white note, and nothing structural marks the card: same keys, same shape, and `onTap` is absent from some real covers too. `parser/music.ts` ships `coverUrl: null` for any `gstatic.com` source, so the client falls back to the video's own still, and the audio-only view's click-to-switch between cover and thumbnail went with it — there is only ever one best image. Matched on the host rather than the file name, so a renamed stand-in is caught too; being wrong that way costs a thumbnail where a cover could have been | Measured 2026-09-24, anonymous `/next` on 22 videos: the 6 cards without art all carried that URL, 3,080 bytes with one SHA-256 at `=s1200` and `=s544`; every real cover was on `yt3.googleusercontent.com`. **All six were one song** ("M11 re-arrange and re-mix") credited on six uploads, so this is one observed case, not a survey. A claim that the placeholder's bytes differ per track was not reproduced. Seen in the release build on `Y5u8ZZqFca4`: the video's still, with the song's credits under it |
| F44 | **Flutter's `MouseRegion` hit-testing silently fails inside deep Sliver layouts, and `PointerScrollEvent` is cloned as it bubbles.** This broke `SilkyScroll`'s `HoverStack` completely, causing nested scrollables to scroll simultaneously. Furthermore, because Flutter clones pointer events to translate local coordinates, an `Expando` cannot be used to track event consumption across widgets. The innermost scrollable must track consumption using the event's `timeStamp`, handle the scroll synchronously to outrace Flutter's native desktop scrolling engine, and manually delegate unhandled delta to its ancestor's animator at the edge instead of relying on native bubbling. | Measured 2026-09-26 across the Spike app and the main Rill app. Nested `SilkyScroll` inside a `SliverCrossAxisGroup` perfectly reproduced the `HoverStack` failure. An `Expando` failed to consume the event between inner and outer listeners. Using `PointerSignalResolver` allowed the native `Scrollable` to run first, falling back to choppy native scrolling and breaking edge-forwarding. Tracking consumption via `event.timeStamp.inMicroseconds` and manually invoking `forwardAlwaysMouseWheelDeltaAtEdge` solved all issues flawlessly. |

---

## 2. Component architecture

```
┌──────────────────────────────────────────────┐
│  Flutter (Windows, AOT native)               │
│  Presentation  HomeFeed · Watch · Queue      │
│  State         Riverpod controllers          │
│  Domain        pure Dart models (freezed)    │
│  Playback      media_kit / libmpv            │
└───────────────┬──────────────────────────────┘
                │ JSON-RPC over stdio (NDJSON)
┌───────────────┴──────────────────────────────┐
│  Sidecar (Node/Bun, single compiled binary)  │
│  youtubei.js   session · cookie auth ·       │
│                SAPISIDHASH · player fetch ·  │
│                signature + n decipher        │
│  Own parser    raw renderer tree walker      │
│  yt-dlp.exe    extraction fallback           │
└──────────────────────────────────────────────┘
```

### 2.1 youtubei.js is a session layer, not a parser

Because of **F2**, every InnerTube call uses `parse: false` and returns raw JSON.
youtubei.js is retained for exactly these jobs:

- session creation and cookie authentication
- `SAPISIDHASH` request signing
- JS player retrieval, signature and `n` deciphering
- request execution against `/youtubei/v1/*`

Renderer interpretation is **ours**. Do not call `getHomeFeed()`,
`.videos`, `.getContinuation()`, or any other typed accessor in production code.

### 2.2 Tolerant renderer parsing

The parser walks the raw tree, recognises known renderers, and **silently skips
unknown ones**. It never throws on an unrecognised type. This is not defensive
polish — F2 shows strict parsing loses real content on the live feed today.

Both generations are present simultaneously — measured 2026-08-01, and still
true: they interleave within a single response, split by item type. The
vocabulary itself lives in one place, `sidecar/src/parser/vocabulary.ts`, and
the table of which renderer carries what is in CLAUDE.md's "Renderer
vocabulary" section rather than repeated here, where a second copy drifted: the
2026-08-01 version of this table printed youtubei.js's typed spellings
(`ChipView`, `ContinuationItem`) where a `parse: false` response carries the raw
keys, listed `richItemRenderer` — a wrapper — as a tile, and keyed mixes on
their thumbnail view model, which every playlist tile shares. A view-based tile
carries its id on `content_id`.

Extract IDs by trying `content_id`, `video_id`, `videoId` in order. Never key
on a single field name.

### 2.3 Client model

| Purpose | Client | Auth |
| --- | --- | --- |
| Browse — feed, chips, search, playlists, history | `WEB` | cookies |
| Stream resolution — ladder tier 1 | `VISIONOS` | anonymous, server-issued visitor id |
| Stream resolution — tiers 4 and 5 (yt-dlp's metadata, the itag 18 floor) | `ANDROID` | anonymous |
| Caption-track fallback, a live stream's start time — not playback | `MWEB` | anonymous |
| Watch reporting | `WEB` | cookies |

Per **F6**, playback reporting works from the authenticated `WEB` session using
its own CPN. There is no need to bridge a resolution client's CPN across
clients — issue two independent calls. This removes the cross-client CPN problem
entirely.

The resolution client is chosen per `/player` call, not per session: one
anonymous session serves every resolution client, and youtubei.js rewrites `context.client`
to the named client before sending. What that session must carry is a
server-issued visitor id — **F5** puts tier 1 at 13/13 with one and 2/28
with a fabricated one, so `createSession` fetches one by default
(`generate_session_locally: false`).

The id is minted once per session and reused, not per open: **F14** measured one
surviving 28 resolutions across 38 minutes with no degradation. That is a lower
bound rather than a TTL, and it is why the retry below is written the way it is.

**The retry trigger is deliberately wider than `LOGIN_REQUIRED`.** Tier 1 mints a
fresh id and re-asks once whenever the response is anything other than `OK` with
a non-empty adaptive ladder. F14 never saw an id expire, so nobody knows what an
expired one produces — and if it is not `LOGIN_REQUIRED`, a narrow gate would
never fire and stream resolution would stop working silently on a session that
still looks healthy. That is F7's shape again. The empty-ladder case is not
hypothetical either: F5's first reading was "0 formats on 3 of 4 runs", a refusal
that arrived as a shape rather than a status. A SABR-only response is explicitly
*not* an identity refusal — it is `OK` with a full ladder, and it belongs to
Phase 2. Cost of the broad trigger: one mint (~170 ms) and one `/player` call on
a genuinely unplayable video, before tier 1 declines as it would have anyway.

### 2.4 Playback

media_kit (libmpv) receives two URLs — video and audio — and merges them via
`--audio-file`. No local media proxy in Phase 1.

**Resolved 2026-08-02.** F10 left this open; F11, F12 and F13 close it, and the
answer needs none of the three options that were on the table.

- **`VISIONOS` is ladder tier 1.** F10 is a property of `c=MWEB` URLs, not of
  YouTube: tier-1 URLs answer ffmpeg's open-ended `Range: bytes=0-` with
  206 at every offset, answer a bare GET with 200, sustain well above the bar,
  and carry no `n` to decipher (**F11**). `MWEB` stayed tier 2 at the time,
  on the reading that F10 constrains how its URLs can be *consumed*, not whether
  they resolve — until that reading ran out (below).
- **No proxy.** The chunking proxy F10 floated is adjacent to rejected
  alternative **A6** and is not needed: nothing has to reshape these requests.
- **media_kit's default DLL is retained.** The shipped build — mpv v0.36.0-403 /
  FFmpeg n6.0 — seeks `ANDROID_VR` streams 4/4 with no options at all, across
  five runs (**F13**). Vendoring a newer libmpv would mean owning a binary and
  an unexercised API-version surface to buy an option the app does not need.
- **`request_size` is set unconditionally anyway.** `stream-lavf-o=request_size=1048576`,
  wherever playback options are constructed. The shipped build accepts it and
  ignores it; on FFmpeg from Lavf 62.10.101 onward it is the difference between
  0/4 and 4/4 seeks (**F11**, **F13**). One option string covers both and makes a
  future pin bump a non-event.
- **Pin `media_kit_libs_windows_video` exactly.** The risk inverted: it is no
  longer that the pin is too old to work, but that a bump lands a modern FFmpeg
  and reintroduces the seek freeze. The constraint belongs in the Flutter app's
  `pubspec.yaml` as `media_kit_libs_windows_video: 1.0.11` — an exact version,
  not a caret range — with a comment naming F13 as the reason, or the next person
  removes it as stale. **Applied 2026-08-02 in `app/pubspec.yaml`**, with
  `pubspec.lock` committed and the resolved artefact verified against F12 from
  the built app (**F15**). See **F12** for what 1.0.11 actually ships; the
  package has not published since March 2025, so nothing is being forgone.

**`MWEB` left the ladder on 2026-08-19 (`c53fb54`), and nothing in the ladder
deciphers since.** Resolving is not the goal; playing is. F10 means an `MWEB`
URL refuses `Range: bytes=0-`, which ffmpeg sends by construction, so an `MWEB`
rung could resolve a video and still never play it — it was never a playback
path. The same commit replaced `ANDROID_VR` with `VISIONOS` at tier 1 (F11) and
moved the floor to `ANDROID`'s itag 18 (F9). The ladder is now `VISIONOS` →
yt-dlp → itag 18, keeping the original tier numbers because code, tests and logs
name them.

- **What it means for hard invariant 2.** `VISIONOS` and `ANDROID` URLs carry no
  `n`, and yt-dlp runs its own transform. Every URL still crosses `sign()` or
  `adoptExternallyDeciphered()`, so the `SignedUrl` boundary holds — but the
  signature and `n` transform behind `sign()` runs nowhere in production. Only
  the network suite exercises it, by calling `tierPlainAdaptive` with `MWEB`.
- **What stays, on purpose.** The decipher path: it is the only proven one,
  `WEB` is already SABR-only, and Phase 2 may need it. F3's tripwire, which now
  watches the SABR rollout rather than a live tier. And `MWEB` itself, for two
  jobs that are not playback: the caption-track fallback (`protocol.md` §3.8)
  and a live stream's start time when tier 1's response lacks one.
- **What not to do.** Do not delete the decipher path, and do not put `MWEB`
  back as a playback tier; F10 settles the second.
- **A side effect worth knowing, since closed.** Task 04 §1 — the `/player`
  response and the deciphering script coming from different player revisions —
  had no production exposure while nothing deciphers, which is not the same as
  fixed. Fixed 2026-09-17: each response records the revision it was minted
  under, and the tiers compare it with the deciphering player before signing,
  refetching once or declining on a mismatch. `protocol.md` §3.5 has the
  mechanism.

Report watch events on a real cadence, not once at completion. A single
end-of-video ping is a weak training signal, and homepage fidelity is the
product requirement.

**Quality is switched inside mpv, never by reopening the RPC session** (F19,
`protocol.md` §3.5). All variants are signed from one `/player` response, so the
client reopens the media on the existing player and seeks back — no
`playback.open`, no second `sessionId`, and no second history entry for one
watch. It costs a visible stall (median 4.1 s to the picture moving, worst 12 s),
which is the measurement that keeps automatic frame-drop stepping out of scope.

**Audio-only mode toggles `vid`, it does not reopen the media — decided
2026-09-22.** The first implementation opened the audio URL as the primary
media in audio-only mode (`isAudioOnly ? variant.audioUrl : variant.videoUrl`),
which meant switching back to video was a cold reopen: duration wait, audio
attach, seek, picture wait — the full `switchQuality` path, measured at 6+ s.
The reverse direction (video → audio) appeared fast (~100 ms) only because
opening a single audio URL skips most of those steps.

The fix is to **always open the video URL** and toggle mpv's `vid` property:
`vid=no` stops video, `vid=auto` re-enables it. The playback position and the
audio stream are undisturbed either way, which is what makes this better than
reopening. `vid` is present in the shipped `libmpv-2.dll`'s string table (the
same scan hard invariant 8 requires), and the `setProperty` call is the same
write binding `stream-lavf-o` already uses — not a `getProperty` read, so hard
invariant 9 does not apply.

**Two sentences here used to be wrong, and were corrected 2026-09-22 by
measuring rather than reasoning.** They said `vid=no` left the demuxer reading,
and that both directions were therefore instant. Neither is true. `vid=no` is a
teardown: sampled through `demuxer-cache-state` across two 120 s phases either
side of the toggle, the video cache goes from 33.97 MB and ~1782 s of
read-ahead to `total-bytes: 0`, `fw-bytes: 0`, `cache-duration: 0`, and
`stream-pos` freezes to the byte (427,790) for the whole phase while `time-pos`
keeps advancing in real time. The harness is
`app/lib/ui/player/audio_mode_probe.dart`.

Two things follow from that, and they point opposite ways:

- **It does save bandwidth**, not just CPU — the premise of the feature holds.
  Measured on the real app over 242 s each, CPU fell from 11.8% to 5.3% of one
  core. The saving scales with the video's bitrate.
- **The directions are not symmetric.** Dropping the track is immediate;
  restoring it is a *cold refetch and re-decode* — **measured at ~5.0 s** on a
  96-minute 1080p video (`Gx8CPWxlsOc`), and observed as low as half a second
  elsewhere. So leaving audio-only raises `PlaybackState.isRestoringVideo`,
  which feeds the control bar's existing busy spinner; its grace delay means
  the fast case still shows nothing. Entering audio-only raises nothing.

**`vo-configured` is the only signal that says the picture is back — measured
2026-09-23, after shipping the wrong one.** The first version waited on
`widthStream` and the spinner never appeared once, because media_kit's cached
`width` survives `vid=no` untouched; so does the `VideoController`'s `rect`.
mpv's own `width` *does* clear, but comes back the instant the track is
re-enabled, a full 5 seconds before anything is on screen. Only `vo-configured`
tracks the picture: `no` for the whole audio-only phase, `yes` at the moment it
returns. `dwidth` lands ~2 s early and `video-bitrate` ~3 s late. It is
**observed, not polled** (`MediaKitEngine._observeVideoOutput`), so mpv
delivers it on its own event thread and hard invariant 9 holds.

**Do not re-derive any of this from network totals.** Windows' per-process I/O
counters do not see mpv's socket reads at all (10 KB of process I/O against
1.2 MB at the NIC over the same 20 s), and the system-wide NIC total carried
several times more background traffic than the signal — read alone it gives
the opposite answer, which is exactly what it did here before the probe
settled it.

Consequences:
- `engine.open` takes no `audioOnly` parameter. The engine remembers what
  `setVideoTrack` was last asked for, and `open` honours it: in audio-only mode
  the audio is attached at load and the video is never read (**F42**). The
  controller sets it *before* the open, so the first track after launch loads
  the right way too, and reconciles in either direction if the mode flipped
  while the open was in flight.
- The `audioModeProvider` listener in `PlaybackController` calls
  `_applyAudioMode`, which toggles the track and, in the restore direction
  only, waits for a picture.
- A quality switch reopens through the same `open`, so it keeps whichever
  mode is active with no second step.
- Because the cache is dropped rather than paused, bytes already buffered when
  the mode is enabled are **wasted** — up to the 32 MiB cap. Opening in
  audio-only mode reads no video at all (F42); toggling mid-playback cannot
  avoid it.
- **A restore is watched, because one can wedge — added 2026-09-25.** Rarely,
  leaving audio-only never finishes: "playing", position frozen, no picture or
  sound, and going back to audio-only resumes it at once. Cause unknown
  (`todo.md` 44). `_armRestoreWatchdog` samples the engine's cached state
  once a second, and after 15 s of playing without moving it toggles the video
  track off and on — the fix found by hand — then, if that wedges too, reopens
  the variant through the quality-switch path, once. The grace sits well above
  the restores measured here, because the recovery drops the video cache
  again and would make a merely slow restore slower.

**The 0:00 stall was this, and it is closed — 2026-09-24.** `todo.md` 43
described opens that succeeded everywhere and then never played, and guessed
they were not audio-only. They were only audio-only: a `vid=no` persisting into
the next load (F42). The one-shot watchdog `46a235a` added while the cause was
unknown stays, as containment for whatever else might stall an open; its
stderr line `rill: stream never started` is still the tripwire.

### 2.5 Authentication and the silent-degradation problem

Cookie auth is the only option: OAuth device-code no longer works against
YouTube, and `TV`-context feeds do not carry the web chip bar regardless.

**F7 is a first-class design constraint.** A degraded session returns HTTP 200
with an empty feed and no error. The sidecar must therefore:

- expose `auth.verify` — fetch home, count tiles, zero means degraded
- run it on startup and after any empty feed response
- surface a re-authentication prompt, never an empty homepage
- treat `logged_in` from youtubei.js as unreliable; it reflects cookie presence
  only

Login is a one-time WebView2 flow owned by the app. Because nothing else touches
that session, browser-side cookie rotation cannot invalidate it.

#### The WebView2 binding, decided by what it can read — built 2026-09-08

Task 22's stop condition was whether a Flutter Windows WebView2 package can hand
back cookies at all. It is a real fork in the road and the answer decides the
package:

- **`webview_windows` cannot.** Its method channel has some twenty methods and
  none of them reads a cookie; `clearCookies()` is the only cookie operation it
  exposes. `executeScript('document.cookie')` is not a way around that — every
  Google session cookie is `HttpOnly` and invisible to page script, which is the
  point of `HttpOnly`.
- **`flutter_inappwebview_windows` can.** It goes through the DevTools protocol:
  `Network.getCookies` for the read, `Network.clearBrowserCookies` for the
  clear, both against WebView2's default environment. CDP returns `HttpOnly`
  cookies, which is what makes the whole task possible.

So the dependency is `flutter_inappwebview` (6.1.5, endorsing
`flutter_inappwebview_windows` 0.6.0). It is used on one screen and renders no
app UI.

#### Completion is a cookie set, never a URL — 2026-09-08

The flow polls the jar every two seconds and on every `onLoadStop`, and treats
the presence of **`SAPISID` and `SID` together** as "worth trying". Not a URL
match: Google's redirect chain differs by sign-in method (password, 2FA,
passkey, account picker) and interstitials land on pages that look final and are
not.

`SAPISID` specifically, and not one marker among several — youtubei.js builds
the `Authorization: SAPISIDHASH …` header by hashing that literally-named
cookie. A jar carrying only the `__Secure-` variants produces a request with no
`Authorization` at all: HTTP 200, an anonymous feed, no error. F7's shape,
reached by a different road.

And the cookie set is only a **precondition**. Hard invariant 5 applies here as
everywhere: the flow hands the header to `auth.setCookie`, which fetches home
and counts tiles, and only a tile count above zero closes the window. A cookie
set by a half-finished flow leaves the user exactly where they were.

#### The login WebView must not load YouTube — crash, 2026-09-09

The first real sign-in crashed the app the instant it succeeded, and the crash
is worth recording because nothing about it points at its own cause.

`continue` used to be `https://www.youtube.com/`, so a successful login handed
the WebView the entire YouTube SPA to render — at precisely the moment
`login_page.dart` tears the WebView down. Windows Error Reporting caught it:
`0xc0000005` in `flutter_inappwebview_windows_plugin.dll` at RVA `0x7aff5`.
Disassembling the shipped DLL at that offset gives
`mov rsi,[r8]` / `cmp byte ptr [rsi+40h],0Bh` — a `std::get<flutter::EncodableMap>`
on an `EncodableValue` (index 11 is `EncodableMap`; the index byte sits at
`+0x40` because MSVC's `std::any`, inside `CustomEncodableValue`, makes the
variant that wide). The only unguarded call of that shape in the plugin is
`WebViewChannelDelegate::PermissionRequestCallback::decodeResult`.

So: the page asked for a permission, the plugin sent `onPermissionRequest` to
Dart and kept a callback, and Dart's reply came back after the native webview
had been freed. A use-after-free in the plugin's lifetime handling, reachable by
any caller that closes a webview while a page is still asking for things.

Three changes, in order of how much they matter:

1. **`continue` lands on `youtube.com/robots.txt`.** A few bytes of text that
   ask for no permissions, run no script and play nothing. The cookies are set
   by the `SetSID` bounce before that target is reached, so detection is
   unchanged. This removes the trigger rather than racing it.
2. **Every permission request is denied synchronously.** There is then never a
   pending reply to outlive the page — and a login WebView with no permission UI
   has no honest answer but no anyway.
3. **The WebView is stopped and parked on `about:blank` before the route pops.**
   This narrows the window rather than closing it; the defect is the plugin's,
   and a caller can only stop feeding it.

Worth knowing for the next Windows plugin that owns a native view: a crash like
this leaves no application log at all, because stderr goes nowhere when the app
is launched from a shortcut. The evidence was entirely in WER
(`Application Error` event 1000, plus a minidump under `%LOCALAPPDATA%\CrashDumps`).
**That minidump contains the session cookie in process memory** — it is a
credential artefact under §5's rule, and should be deleted rather than kept or
attached to a bug report.

#### Where the cookie lives, and what that actually is — 2026-09-08

`flutter_secure_storage`, as Task 22 §5 requires. What that maps to on Windows
is worth writing down, because it is not what the task assumed: as of
`flutter_secure_storage_windows` 3.1.2 it is **not DPAPI**. The plugin generates
a 16-byte AES key, stores that in Windows Credential Manager (`CredWriteW`,
`CRED_TYPE_GENERIC`), and writes values AES-GCM-encrypted to a file in the app's
data directory. So the credential store holds the key and the app directory
holds the ciphertext.

That also happens to be why it works at all here: Credential Manager's blob
limit is 2560 bytes and a real YouTube cookie header is routinely larger. A
version of this plugin that wrote the value straight to `CredWrite` would fail
on a real session.

### 2.6 Hover previews

**Revised 2026-08-11.** Hovering a tile plays the real video, muted, in the
tile. The goal is watching from the feed without opening anything.

Per **F8** a feed *response* carries no preview media — 0 mp4/webm URLs across
nine captures — so the stream is resolved the same way any other playback is,
through `playback.open`. F8 constrains where preview media comes from, not
whether video previews are possible.

- **One shared preview player, never one per tile.** The player moves between
  tiles; only one video ever decodes.
- **It is a second player, separate from the shell's.** The shell's holds a
  paused video's position and its texture, and opening media on it would destroy
  exactly what the suppression rule below protects. Created lazily, on the first
  preview that actually starts.
- **~800 ms hover delay**, longer than a sprite preview would need, because this
  one opens a video stream and only a hover somebody meant should do that.
- **Suppressed while a video is playing**; a paused one does not suppress. Two
  decoders and two soundtracks is not a preview, it is a competition. Playback
  starting takes a running preview down.
- **Muted, at 720p or below** (F16: 2160p60 dropped 16–29% of frames on an Intel
  iGPU at full size, and a thumbnail has none of that budget).
- **Static thumbnail until the first frame.** Mounting the surface while mpv
  loads paints a black rectangle, which reads as a broken tile.
- **Past 30 s it stops being a preview** and is reported as a watch. See
  `protocol.md` §3.7.
- **When the video ends, the preview deactivates** — thumbnail back, mute
  toggle gone, Watch Later and Add to queue back — exactly as if the pointer had
  left, and without looping or restarting under a pointer that never moved. It
  is the same teardown call, so the two paths cannot drift apart.

**Sprite sheets were the previous decision and are not a fallback.** Three
reasons, all measured:

1. Level 0 is 100 frames spread across the whole runtime, so consecutive frames
   are ~6 s apart. Animating them to cover the gap before video starts scrubs
   ~25 s forward and then cuts back to 0:00 — it cannot bridge anything, and
   holding frame 0 still is just the thumbnail.
2. Videos carry zero storyboard levels unpredictably (`jNQXAC9IVRw`,
   `uQ0LGwPBC2c`, and others in the live feed), so a sprite fallback is absent
   exactly when it would be needed.
3. YouTube shows nothing when a stream will not resolve. Matching that is
   simpler and more familiar than a degraded animation.

So the answer to "suppressed, unresolvable, or not yet decoding" is the static
thumbnail, in all three cases.

The sprite machinery is kept, wired to nothing, as the **scrubber's** input —
one frame at a pointer position is what its ~6 s spacing is actually good for.
`video.storyboard` and its substitution were measured against real responses and
verified by fetching, and re-deriving that would be expensive.

There is no CC button on a preview. Captions do not exist anywhere in this app
yet; they are their own task, where the watch page gets them too, and a dead
control is worse than no control.

### 2.7 Player controls

The shell player's overlay. Four decisions here are not obvious from the code and
were each corrected once, so they are written down rather than left to be
rediscovered.

**Theatre grows sideways only.** The player keeps the height it has in the
ordinary layout and spans the full content width, so a 16:9 video gains larger
side bars and everything below it stays where it was. The other reading of
"expands to fill the content area" — filling the viewport's *height* — was built
first and is wrong: on a 2560×1080 window it is a player nearly three times as
tall as before, and the description and related rail leave the screen. Theatre is
also what drops the page to one column, so the rail moves below the player rather
than being squeezed.

**Previous and next are absent, not disabled, when there is nowhere to go.** The
queue stops rather than wrapping, and an ordinary video has no queue at all — so
a disabled pair would be two permanently dead controls on almost every video.
They appear exactly when a playlist, mix or queue has given them a destination.
`Shift + P` / `Shift + N` fire either way, so the keyboard is not the thing that
disappeared with the buttons.

**A quality switch covers the video in black until the picture is back.** The
switch reopens the media inside mpv, which starts the new stream at zero and only
then takes the seek back — so an uncovered switch shows black, then one real
frame of the new stream from position zero (on most uploads, the thumbnail), then
the resumed picture. The middle third reads as a bug. `isSwitchingQuality` is
therefore held until the position returns to where the user was, not until the
calls have been issued; F19 measures those as 4.1 s and 0.3–0.7 s respectively,
which is the whole gap the cover exists to fill. A frozen last frame
(`Player.screenshot()`, which media_kit runs in a background isolate) would read
as a pause rather than a reload and is the obvious upgrade; black is what is
built, because it cannot fail and adds no mpv call to a transition that is
already stalling.

**The displayed position is held across a quality switch, and so is the reported
one — and the duration is held with it.** A reopened media reports position
*and duration* zero until the seek back lands, so for the seconds F19 measures,
mpv is telling the truth about a stream nobody asked for. `PlaybackState.hold`
carries both; the scrubber, the clock and the mini-player's bar all prefer it, in
the order *drag > hold > stream*. **They are one object rather than two nullable
fields because holding half of it is worse than holding none**: with the position
held and the duration not, the scrubber's range collapses to `max(0, 1) = 1 ms`,
a held 3:00 clamps into it, and the thumb pins to the **far right** for half a
second — which is what shipped in the first attempt at this. The seek clamps read
it too, or `J` near the end and the `0`–`9` deciles go dead for the length of a
switch. **`playback.report` prefers it
too**, and that half is not cosmetic: without it a switch posts a position of
zero to the account's history, telling YouTube the viewer went back to the start
— the load-bearing call whose failures only ever surface as a homepage that stops
resembling the account. **The hold is not a freeze**: every seek in the app goes
through `PlaybackController.seek`, which moves the hold with the user, and the
wait that lifts the cover re-reads the target on every position event rather than
capturing it — otherwise scrubbing *backwards* mid-switch leaves the cover up
until the 25 s deadline, still waiting to pass a point the user has just chosen
to be behind. Note where this does *not* live: the sidecar has no idea where
playback is. It resolves URLs and receives reports; position is mpv's, through
`player.stream.position`, and there is nothing upstream to pause.

**One spinner for every kind of waiting, after a 250 ms grace period.** mpv
buffering, a quality switch, and the initial load are the same thing to a viewer.
The signal is media_kit's `buffering`, which it raises from **`core-idle`** as
well as `paused-for-cache` — that matters, because F18 measured seeks as ~95%
`core-idle` with `paused-for-cache` at **zero in all 75 samples**, so a spinner
keyed on cache starvation alone would never appear on the thing that actually
makes anyone wait. media_kit suppresses the `core-idle` a `pause` raises, so a
deliberate pause shows nothing. The grace period is what keeps a fast seek from
flashing a spinner for two frames, which reads as a glitch rather than feedback.
**Known gap:** F18's long-pause resume penalty (0.5–2.3 s) touches neither
property, so nothing fires for it and there is no signal to hang it on.

**The spinner carries a `Key`, and it does not work without one.** It is the only
child of the controls `Stack` that owns `State`, and the quality-switch cover
above it comes and goes. Flutter's list diff scans forward while widgets match,
scans backward from the end, then rematches everything in between **by key
alone** — unkeyed children in that middle range are discarded and inflated fresh.
The cover appearing breaks the forward scan at index 0 and the quality menu
breaks the backward scan, which puts the spinner squarely in the middle: unkeyed,
its `State` was destroyed and its grace timer cancelled at the exact moment a
switch began, so the spinner could never appear for the case it was written for.
Diagnosed by tracing `initState`/`dispose` — a second `initState` ran before the
first `dispose`, which is the signature of this rematch and not of an ordinary
rebuild.

**The volume slider opens on hover and takes room in the row.** It sits between
the mute button and the clock, so opening it pushes the clock and everything
after it to the right rather than floating over them — a clock you cannot read
while changing the volume is a worse trade than a clock that moves. It closes on
a 200 ms delay, because the pointer travelling from the speaker to the slider is
briefly over neither and an immediate close would collapse it out from under a
pointer heading for it. The slider stays mounted at width zero rather than being
swapped out, so open and close are one continuous motion.

**The bar's background is a gradient, not a wash.** A flat scrim darkens a band
of the picture and ends on a hard horizontal edge; a ramp from 50% at the bottom
to nothing at the top has no edge to notice and puts the density where the
controls actually are. Fullscreen adds the same gradient mirrored at the top,
carrying the title and channel — fullscreen hides the watch page, which was the
only thing on screen that said what was playing.

**Captions are a disabled button, not a reserved gap.** The gap read as a missing
control. A disabled button says "later"; a live one that did nothing would lie.
This reverses task 16's "leave a gap rather than shipping a dead one" at the
user's request.

**The theatre icon reports state; every other icon reports action.** Theatre has
no glyph anyone recognises, so the icon is more useful as a status than as an
instruction. Fullscreen keeps action semantics beside it, because
`fullscreen_exit` reads as a verb in a way the crop icons do not. The
inconsistency is deliberate and confined to this one control.

**`i` and the mini-player button pop the route rather than entering a mode.** The
mini-player is already what the shell draws whenever something is playing and the
watch route is not on top, so going back to wherever the user came from *is* the
feature — and it lands on the previous page rather than a fixed one. Fullscreen
is dropped first, or popping would leave the window borderless over the monitor
with a feed in it.

**One flex child between the control bar's clusters.** `Flexible(clock)` followed
by a `Spacer()` leaves the right-hand cluster hundreds of pixels short of the
right edge: both are flex 1, `Row` gives each half the free space, and the loose
`Flexible` returns what the clock does not use — to the *end* of the row under
the default `MainAxisAlignment.start`, not to the `Spacer`, which has already
been sized. One `Expanded` holding a left-aligned clock has no share to return.

**A player with nothing to play disables its scrubber and its play button —
decided 2026-09-26.** A premiere, a members-only video, a rate limit and a plain
failure all end in `PlaybackState.error` (`isUnplayable`), with the engine stopped
by `_failOpen`. The controls used to stay live regardless: a click or Space
reached an engine with no media, and the bar could be dragged along a track with
no duration. The `Slider` is now disabled — no thumb, no hover growth, no bubble —
and so is play/pause. **Previous and next are not**: skipping past a video that
will not open is exactly when they are wanted. What covers the keyboard, the media
keys and a click on the picture is `PlaybackController` itself: `togglePlayPause`,
`setPlaying`, `seek` (and so `seekBy` and `seekToFraction`) and `stepFrame` return
without acting while `isUnplayable`, because none of those has a disabled look to
show. The mini-player's and the taskbar's play buttons are disabled to match.
**The slates keep clear of the bar.** The control bar is drawn over them, so they
start `playerControlsClearance` (76 px) up from the bottom rather than the 20 px
they were laid out with before the bar was drawn over them — the members-only
"Join this channel" button sat behind the progress bar. A test measures the
button against the bar's top instead of trusting the number.

Tile action buttons (Watch Later, Add to queue) come from
`ThumbnailHoverOverlayToggleActionsView` and the associated
`AddToPlaylistCommand` / `PlaylistEditEndpoint` in the feed payload.

#### Controls outside the window — built 2026-09-24

Two surfaces control playback without the window in front, and each answers a
different hand. **The system media flyout** (`smtc_controller.dart`) answers
the keyboard's media keys. **The taskbar thumbnail toolbar**
(`taskbar_controller.dart`, `ITaskbarList3::ThumbBarAddButtons`) answers a
pointer on the taskbar: like, previous, play/pause, next and dislike under
the hover preview. **Play/pause is in the middle, with the two ratings at the
ends — decided 2026-09-24.** The first version had no dislike, as used far
less than like; it came back as the counterweight that centres play/pause.
Like and dislike are disabled when signed out, with the reason as their
tooltip, the rule of the account-gated controls below.

- **Every button goes through the on-screen control's own entry point** —
  `PlaybackController.previous`/`togglePlayPause`/`next`, and `rateVideo` in
  `account_actions.dart`, which the watch page's rating buttons call too. A
  second copy of the rating logic is how the two would come to disagree.
- **One artwork resolver, `nowPlayingArtProvider`**, read by the flyout and
  by the audio-only layout: the song's cover, else the video's poster, else the
  tile's thumbnail. Never YouTube's stock no-art square (F43).
- **`windows_taskbar` is vendored** (`third_party/windows_taskbar`, 1.1.2) for
  two fixes marked `rill patch`. It never freed the icon handle `LoadImage`
  returns, one leak per button per update, and this app updates on every
  play/pause against a 10,000-object cap per process; measured after the fix,
  40 updates left GDI objects at 19 and USER objects at 44. And a failed
  first add still marked the buttons added, so every later call updated
  buttons that never existed and the toolbar never appeared.
- **The buttons exist from startup, and nothing playing is all of them
  disabled, never none — measured 2026-09-24.** A flyout opened before the
  buttons were first added keeps showing none: hover the taskbar, then play,
  and `ThumbBarAddButtons` returned success while the flyout stayed empty,
  across reopenings, until something re-laid out the taskbar (another app
  starting). Opened *after* the add, the same flyout shows them and follows
  every later update live. Adding them only once something played therefore
  made an empty toolbar the ordinary first experience. The first add at
  startup usually lands before the window is shown and fails, so it is retried
  every 2 s.
- **The toolbar lives in Explorer's process, so nothing in ours can see it.**
  The first success logs `rill: taskbar toolbar ready`, a failure that
  outlasts the startup race logs, and that is the whole of the evidence a
  release log holds. A button press arrives as `WM_COMMAND` with `THBN_CLICKED`, so
  the click path can be driven without Explorer by posting that message to the
  window (command id `40001` plus the button's index). **The buttons
  themselves are visible to UI Automation**: the flyout
  (`TaskListThumbnailWnd`) holds a `ToolbarWindow32` whose buttons carry the
  tooltips as names and the disabled state as `IsEnabled`, which is how the
  states above were read while it was open — a control app's flyout (MPC-HC)
  confirmed that an empty tree means no buttons, not an unreadable one.
- **While a video loads, play and both ratings are disabled and previous and
  next are not — decided 2026-09-24.** Skipping through tracks without waiting for
  each to load is what those two are for, and a load that never finishes must
  not trap the listener on it; they are disabled only at the ends of the
  queue. The ratings stay disabled until the watch page's data says how the
  video is already rated, because until then a press could only guess which
  way to toggle. A disabled button keeps its ordinary icon and Windows dims
  it; dedicated faded icons, dimmed again by Windows, were too faint to read.
- **The icons' sources are the SVGs in `app/assets/icons/taskbar/`**, started
  from Material glyphs and redrawn by hand; `app/tool/gen_taskbar_icons.py`
  renders each to a multi-size `.ico` in `app/assets/taskbar/`. The PNGs beside
  them are not read: they are cropped to the icon, so they have lost where it
  sits in its square.

#### Chapters on the progress bar — built 2026-09-26

The scrubber is one segment per chapter, the segment under the pointer grows,
and a bubble above the pointer names the time and the chapter. The code is
`ui/player/scrubber_chapters.dart` (geometry, mapping, growth, bubble) plus
`_Scrubber` and `_RillSliderTrackShape` in `controls.dart`; every size in it is
`ScrubberMetrics`, in one place, because they are tuned by eye.

- **The `Slider` stays.** It is what carries focus, keyboard and semantics, and
  what the tests find. Only what it paints changes — the track shape draws the
  segments — and what surrounds it. Seeking is untouched: still on release, never
  during the drag (F15).
- **Segments are painted from the real track rect.** A chapter is a fraction of
  the duration, so the time-to-x mapping stays linear and the thumb and the buffer
  cross a boundary without noticing it; the gap is carved out of the two segments
  either side of it, so nothing shifts. A segment too narrow to afford one is drawn
  gapless, so an hour of short chapters on a small window degrades to a plain bar
  rather than to slivers. The bar with no chapters is the same code with one
  segment, and grows on hover the same way.
- **Only the ends of the bar are rounded** — the first segment's left corners,
  the last one's right, all four for a bar of one. The segment is clipped to its
  shape, so the three layers inside stay plain rects and the position crosses the
  curve without knowing it is there. `ScrubberMetrics.endRadius` is 1.5 at rest
  and 2.75 on hover, animated with the growth. Skia scales a radius down to half
  the height (2 and 3.5 px), so a larger one reads as a semicircular end. The
  plain track — a live stream, or a bar whose duration is not known yet — is a
  separate path and is not shaped this way.
- **The duration is `hold?.duration ?? engine.duration`, the one `max` is built
  from** (above), so the segments and the thumb cannot disagree in a quality
  switch. A zero duration draws the plain track.
- **A chapter list that is not a segmentation draws none, and names none:**
  fewer than two, starts that do not strictly ascend, a first chapter more than
  ten seconds in, or a start at or past the end. Time before the first chapter
  belongs to the first segment. All chapters `VideoDetail` carries are used,
  including the ones the sidecar parsed from the description (§2.12).
- **A live stream — `durationMs` null — has no segments and no bubble.** Its bar
  is a moving window, not a timeline. The clock already calls any source without a
  duration live, and this follows it, not just the ones with a `startTimestamp`.
- **Chapters are one video's.** They are read from `videoInfoProvider` for the
  playing item's id, and the hover state is dropped when the item changes.
- **Hover is mapped through the slider's own track**, which the theme's padding
  insets, not through the widget's width: the ends read exactly `0:00` and the
  duration. `scrubberTrackSpan` is that arithmetic, and a test taps and hovers at
  the same x and requires the click and the bubble to agree, which is what keeps
  it the slider's own. Do not use `1.0`: the slider's box ends where its track
  does, so a tap on that last pixel reaches nothing.
- **The bubble is in the tree, not a `Tooltip`.** Nothing above the `Navigator`
  has an `Overlay` (§2.8), and a tooltip that appears after a delay is the wrong
  behaviour for a scrubber anyway. It overflows the scrubber's box, so the `Stack`
  must not clip and no ancestor may — `expectUnclipped` walks the render tree in
  each layout, fullscreen included. It is `IgnorePointer`, and being outside the
  box already keeps it out of hit-testing; the wrapper is for the day it is not.
- **A `Listener` beside the `MouseRegion`.** `onHover` does not fire while a
  button is down, so a drag would leave the bubble where the pointer was before the
  press. While the thumb is held the bubble reads the drag position (from the
  controls, as the clock does), not the pointer's.
- **Not built: a "most replayed" graph, and thumbnails in the bubble.** The
  mini-player's `LinearProgressIndicator` shows no chapters, deliberately.

### 2.8 Watch page, queue panel, and the UI's sharp edges

The rules below were each paid for once. The code points here rather than
carrying the argument inline.

**One texture, three mount points.** The player lives in a provider on the
`ProviderScope`, above the `Navigator`, so popping the watch route cannot destroy
it — that is what makes the mini-player and background audio properties of the
structure rather than features. The watch page, the mini-player and the
fullscreen layer each mount the *same* `Video` widget; moving between them
creates and frees nothing. Only one may be mounted at a time.

**Nothing above the `Navigator` has an `Overlay`.** The mini-player and the
fullscreen layer are drawn there, so a `tooltip:` on any of their buttons throws
"No Overlay widget found" the first time it is drawn. The fullscreen layer
carries an `Overlay` of its own precisely because Material's `Slider` renders its
value indicator through an `OverlayPortal` — without it, the scrubber and the
volume slider take the whole layer down.

**A tooltip inside a list that reflows needs a non-zero `waitDuration`.** When a
row is removed the rows below rise past a stationary cursor, so `MouseTracker`
reports a hover *enter* from inside `handleDrawFrame`, after layout has begun. At
the default zero wait `RawTooltip` opens synchronously from that enter, and
opening one mounts an `OverlayPortal` into an `Overlay` that sits under a
different `LayoutBuilder` than the one mid-layout:

    A _RenderLayoutBuilder was mutated in _RenderLayoutBuilder.performLayout.

Any non-zero delay routes the show through a timer, which fires between frames.
Dismissal already worked this way (`exitDuration`, 100 ms), which is why only the
enter ever threw. The same shape exists wherever tooltipped controls sit in a
list that can reflow under the pointer — the feed's hover actions included.

**A queue entry is an identity, not a position.** `QueueEntry` has no `==`, so
two entries holding the same video are two different entries. The panel applies a
removal ~340 ms after the click that asked for it, and in that window the list
moves: three quick clicks on rows 3, 5 and 4 all resolve against a list that is
shifting under them. Removing by entry cannot hit the wrong video; removing by
index does it silently. The same identity keys the panel's per-row animation
controllers and keys, which removes the old index-diffing entirely — that diff
compared video ids, and `[a, a, b]` minus index 0 diffs as "removed at 1".
Mutations carry entries forward rather than re-minting them, or every survivor of
a clear would read to the panel as a new arrival and play its entrance.

**An undecoded frame size is not 16:9.** `PlaybackEngine.open` clears `width` and
`height`, and mpv reports them again only once the first frame of the next video
has decoded — so between two videos there is a window, as long as the load takes,
in which the engine knows nothing. Answering with the reference aspect there made
the player snap back to 16:9 mid-transition and morph twice for one change,
showing a shape neither video has. The last real ratio is held until the next
real one arrives; 16:9 is only the answer before anything has decoded.

**`silky_scroll` already owns "which scrollable does the wheel belong to".** Every
`SilkyScroll` pushes itself onto `SilkyScrollGlobalManager.keyStack` from its own
`MouseRegion` and ignores wheel events it is not the top of. A hover flag of our
own would be a second, blunter answer to a question the library is already
answering, and the two would have to be kept agreeing forever.
`SilkyScrollAbsorber` extends the same mechanism to the parts of a floating panel
that are not themselves scrollables — headers, padding, edges — by taking a seat
on that stack, and steps aside when the panel's own list has nowhere to go, so a
wheel over a panel that visibly cannot move still scrolls the page.

**Lazily-created `AnimationController`s in the queue panel are deliberate.** The
nullable backing field plus `??=` getter (`__squeezeCtrl` and friends) exists so
a `State` object that predates the field survives a hot reload — `initState` does
not re-run for it, and an eagerly-initialised `late final` would throw on the
first frame after the reload instead. They are disposed normally. This is dev
ergonomics for a file that is iterated on almost entirely by hot reload; it has
been flagged as non-idiomatic twice, so it is written down rather than argued
again.

**The queue does not open as a modal sheet.** `showQueuePanel` — a bottom sheet
wrapping the panel in a fixed-height box — was deleted: a cleared queue draws
nothing while the sheet stays up as an empty rectangle. The queue belongs under
the mini-player, opened by a button on it and expanding in place, which puts it
in `player_shell.dart` rather than behind a route.

**The drawer's stored state is read before `runApp`.** `SharedPreferences` has no
synchronous read, so a provider that defaults and then restores is several frames
late — long enough for the drawer's `AnimatedContainer` to slide 240 → 72 in
front of the user on every launch. `main` reads it and seeds
`drawerStateProvider` with an override; the default is only reached where nothing
overrode it, which is tests.

**The watch page's layout branches at 16:9, not at portrait.** A 16:9 video is
the widest one whose full-column height still fits the viewport, so it is the
exact point where "as wide as the column" and "as tall as the space" agree — the
two branches meet to the pixel there, which is what makes the boundary invisible.
Which *controls* to draw is a separate question answered by portrait; one flag
answering both is what broke square video.

**A `TabBarView` cannot live inside a `CustomScrollView`, measured 2026-09-18.**
The single-column watch page's Up Next / Comments switch (Task 27's narrow-
layout follow-up) was first built as a `TabBarView` inside a
`SliverFillRemaining`, one independently-scrolling `SilkyCustomScrollView` per
tab — the standard shape for "header above, tabs below." It fails two ways.
With a real scrollable as a tab's child (needed for Comments' virtualization):
`RenderViewport does not support returning intrinsic dimensions`, thrown from
inside `SliverFillRemaining` — something above the page's own outer viewport
(`page_wrapper.dart`'s body `Row`) ends up asking it for intrinsic height, and
a nested `Viewport` can never answer that. With plain non-scrolling
placeholder children instead — ruling out the nested-viewport explanation —
`TabBarView` still fails on its own, with a `!semantics.parentDataDirty`
assertion repeating every settle frame. Both reproduce from a bare
`TabBarView` with no other code from this feature involved, so this is a
framework limitation, not a mistake in how it was wired up.

The fix in `watch.dart` swaps which sliver group is present instead of
switching pages in a nested `Scrollable`: Up Next's and Comments' slivers are
both ordinary members of the single outer `SilkyCustomScrollView`, and a
`_narrowTab` field decides which one is currently included. This costs each
tab its independent scroll position and `CommentsSection`'s fetched state —
switching away and back re-fetches — which is an accepted tradeoff against a
combination that does not work at all. If Flutter fixes this, `TabBarView` is
worth revisiting for the state-preservation win alone.


**A pasted link to one video plays that video; it is not searched — decided
2026-09-26.** Submitting the search box calls `openSearchOrVideo`
(`pages/search_results.dart`), and `videoIdFromLink` (`domain/youtube_link.dart`)
is the rule. YouTube's own search answers a `watch?v=` link with the video but a
`/shorts/` link with **nothing** — measured 2026-09-26, the raw `/search` response
held no result at all, only the query echoed in its filter links and an ad the
parser strips — so a Short could not be reached by pasting its link. Accepted:
`watch?v=`, `/shorts/`, `/live/`, `/embed/`, `/v/` on youtube.com and its `www.`,
`m.` and `music.` subdomains, and `youtu.be/`, with or without a scheme and with
`?feature=share`, `&t=` and `&si=` ignored. **A link and nothing else**: a sentence
that contains one is a search, and so is a bare 11-character id, which is
indistinguishable from a word. A `list=` is ignored — the video opens, not the
playlist — and a playlist or channel link is still searched. The video opens
through the same `openWatch` a tile tap uses, on a placeholder tile that
`video.info` replaces a moment later (`placeholderVideoItem`, shared with
`RILL_OPEN_VIDEO`).

#### A control that needs an account is disabled and says why — decided 2026-09-21

Every action-gated control in the app reads one function,
`signedInActionBlocker(status, verb)` in `ui/auth_controller.dart`, which
answers the *reason* it is unavailable or null. The watch page's like and
dislike, Save to playlist, Watch Later, the subscribe pill and a comment's two
vote buttons all use it, and each shows that reason as its `ShortcutTooltip`
label in place of the ordinary one.

**What it replaced:** those controls were pressable signed out. The optimistic
state applied, the call came back `AUTH_REQUIRED`, and it reverted under a
toast — a control that looks available, acts, and then undoes itself. The
comment vote buttons would have been the worst case, because a vote that
silently does not stick looks exactly like one that did.

**Degraded is not folded into "signed out", and that is the point of having a
function rather than a boolean.** `AuthState.isSignedIn` is strictly
`status == authenticated`, and `degraded` is its own status fed by
`auth.verify` — hard invariant 5, since `logged_in` is cookie presence rather
than server acceptance. The two need different actions from the viewer: one has
to sign in, the other has to sign in *again*, and a degraded session looks
signed in on every other surface. So the sentences differ ("Sign in to vote" /
"Your session expired. Sign in again to vote") and the wording matches the
account button's own badge.

**Not gated on the tokens the action needs.** A comment's four vote blobs are
present on anonymous pages too, so a button enabled by their presence would be
enabled always and fail always — F33's mistake (a tooltip read as state) in a
new place. The session decides.

#### The audio-only layout — built 2026-09-22 to 09-24

`AudioModeView` is the song's cover and credits, with the queue beside it in
the shell's fullscreen player. It is not a separate screen: it is one of the
**player slates**, mounted by `PlayerSlates` beside the premiere, members-only
and unavailable slates, in all three places a slate can appear.

- **A slate sits inside `PlayerControls`' child slot, not beneath it.** The
  controls' `MouseRegion` is opaque by default, so anything under it receives
  no clicks at all — the first cut of this view could not be interacted with.
  Where the slates need a `Material` ancestor (`injectMaterial`), it is
  `MaterialType.transparency`: a default `Material` is a canvas, which paints
  and swallows the pointer just the same.
- **The queue can be hidden**, and that choice persists (`HideQueueController`,
  `SharedPreferences`), because it is a listening preference rather than a
  per-track one.
- **Theatre belongs in audio-only mode too — decided 2026-09-24.** The bar's
  miniplayer, theatre and fullscreen buttons are one widget (`_ViewControls`),
  mounted by the video bar and the audio bar alike, so the modes cannot drift
  apart.
- **The cover is the best image there is, and there is only ever one.** It
  reads `nowPlayingArtProvider` (§2.7). The first version let a click switch
  between cover and thumbnail, because some covers were YouTube's stock no-art
  square; the sidecar now ships those as no cover (F43), and the switch is gone.
- **The frame takes the image's shape: square for a cover, 16:9 for a video
  still — 2026-09-24.** A still in the square frame sat letterboxed under a
  square shadow, with an empty band between it and the title. It keeps the
  cover's width and gives up height rather than growing wider, since it is
  often a 480x360 thumbnail (F40); the column stays centred, so the title comes
  up to meet it. The change animates, which is visible on every track that has
  a cover: the still shows first and the cover arrives with the credits. **The
  image only fills the frame because the `AnimatedSwitcher` is given an
  expanded layout** — its default is a loose `Stack`, in which the image keeps
  its own shape whatever `fit` says, and that is what the square was showing
  around.

### 2.9 Captions render through libass, not Flutter

**Decided 2026-08-18.** The sidecar converts every caption format to ASS and
hands mpv a subtitle track. Flutter draws no captions.

**The alternative was a Flutter overlay, and it was tried and rolled back.** It
works for plain text and cannot ever work for **YTT** — YouTube's own caption
format, which carries per-word timing, absolute positioning, colours, fonts,
edge effects and karaoke. libass renders exactly that class of styling natively;
a Flutter overlay would mean writing a subtitle layout engine and then throwing
it away when YTT lands. Choosing ASS now makes YTT an additional converter behind
an interface that already exists.

Option D (rendering libass natively inside Flutter via FFI) is viable via an own FFI bridge. It was rejected only in its `dart_libass` pub package form, with the 0.14 segfault and the full-frame allocation attributed exclusively to the package. By building directly against libass 0.17+ and handling the `ASS_Image` crop masks, Option D achieves 60fps frame-perfect Flutter compositing without relying on mpv's `sub-add` latency.

**The order these landed in, since it reads as a contradiction without it.**
A Flutter overlay was rejected first (Task 17) for being unable to express
YTT. `mpv sub-add` plus a Flutter-drawn drag ghost was built on that decision
(Tasks 17–19). `dart_libass` — the pub package, libass 0.14 — was evaluated
next and rejected: wrong `BorderStyle: 4` window geometry, and a reliable
segfault on the two-event layering this task's own background/window split
needs. An own FFI binding against libass 0.17 was spiked, adopted, and the
mpv path removed entirely (phase 5,
`docs/tasks/19-caption-drag-and-style.md` §10.1). The middle step is the
hinge: evaluating `dart_libass` is what surfaced `ASS_Image` carrying the
exact rendered box per glyph — the fact that makes leaving the ghost-and-
estimate approach for a direct FFI binding the same argument as adopting the
ghost in the first place, rather than its reversal.

The pipeline is `fetch → parse → cues → group (ASR only) → ASS`, with one
intermediate model (`sidecar/src/captions/cues.ts`) as its waist. Every styling
field on that model is optional and unset by the `json3` parser; they exist so
YTT extends the pipeline rather than replacing it.

**libass is present in the artefact, not merely in the version number.** Hard
invariant 8 applies, so the check was a string-table scan of
`app/build/windows/x64/runner/Release/libmpv-2.dll` — the DLL the build actually
loads, F12/F15's mpv v0.36.0-403 / FFmpeg n6.0 from Sept 2023. It carries libass
statically alongside HarfBuzz and FriBidi (`ass_render.c`, `ass_shaper.c`,
`Shaper: FriBidi 1.0.13 … HarfBuzz-ng`, `[Events]`, `ScriptType`), plus
`sub-add`, `sub-remove`, `sub-visibility`, `sub-scale`, `sub-pos` and
`secondary-sid`. So positioning and inline overrides are reachable on this pin;
YTT is not blocked by the artefact.

**Two media_kit defaults have to be overridden, and neither is optional.**
Found 2026-08-19, after Task 18: the section's first sentence was true of the
pipeline and false of the running app. `PlayerConfiguration.libass` defaults to
**`false`**, which media_kit turns into `sub-ass=no` *and* `sub-visibility=no` —
mpv strips every ASS tag and then draws nothing — and `Video` mounts a Flutter
`SubtitleView` by default, which paints mpv's now-plain `sub-text` in a Flutter
`TextStyle`. So Flutter *was* drawing the captions, from text with all styling
removed, for the whole of Tasks 17 and 18.

It is invisible until a track carries styling: plain captions look correct.
`app/lib/data/playback/engine.dart` holds both settings, named and adjacent,
because each alone is wrong — `libass: true` on its own draws every caption twice
in two fonts, and `visible: false` on its own draws none. Reproduced against the
bundled libmpv: rendering the same document with `sub-ass=no` yields exactly the
reported frame, two windowed cues stacked bottom-centre in document order.

A consequence worth recording: **Task 17's "stacked duplicates" were not libass
colliding two events.** They were two entries in `player.state.subtitle`, which
is a list. The merge rule §2.9 describes is still correct — a caption composited
from two pens *is* one caption — but the symptom that motivated it had this cause.

**Delivery is `SubtitleTrack.data`, media_kit's own path.** It writes the
document to a temp file and issues `sub-add <uri> select`, which adds a track
without touching the media — no reopen, so a caption change costs nothing where
a quality switch costs 0.55–12 s (F19). Two consequences worth knowing: the temp
file media_kit creates has **no extension**, so format detection is by content
and an ASS document must start `[Script Info]`; and media_kit registers the file
for deletion on `Player.dispose` rather than on track change, so a long session
that switches languages repeatedly leaves one small file per switch until exit.

**A quality switch drops the subtitle track**, because it reopens the media
(F19). The controller reattaches after the switch rather than relying on mpv to
carry it, and that is the only place captions and quality interact.

**ASR tracks are a rolling window, not a cue list.** Measured on real tracks
2026-08-18: an auto-generated track transmits heavily overlapping events — one
starting at 18800 ms declares 7160 ms while the next starts at 21800 ms — plus a
window-definition event whose duration covers the whole video and `aAppend` roll
markers carrying a lone newline. Emitted verbatim that is three or four cues on
screen at once, a caption pinned for the entire runtime, and a blank line between
every real one. The grouping rule that resolves it is in `captions/cues.ts`.

**`fmt=ytt` answers HTTP 404.** YTT is not a fourth format to fetch. Its styling
model *is* the `pens` / `wsWinStyles` / `wpWinPositions` arrays already at the
top of every `json3` document — empty for a plain track, populated for a styled
one. So the styling parser is an extension of `captions/json3.ts`, resolving the
per-event `pPenId` / `wsWinStyleId` / `wpWinPosId` references into a `CueStyle`.

**Built 2026-08-19, and it was not only that file.** This section used to end
"and nothing else in the chain changes"; two things in the chain did.

**A styled caption is composited from more than one event, so `edgeStyle` had to
become a set.** YouTube emits the same text twice at the same time with
different pens: one with `foForeAlpha: 0`, whose glyphs are invisible and which
therefore contributes only its `etEdgeType: 4` drop shadow, over one with
visible glyphs and an `etEdgeType: 3` outline. Measured on `L-BgxLtMxh0`, 240 of
its 257 cue groups are exactly that pair. On screen it is *one* caption with a
shadow **and** an outline, which a single-valued field cannot express — hence
`CueStyle.edgeStyles`. The parser merges the layers; ASS emits `\bord` and
`\shad` on one line. **This is the fix for the stacked-duplicates bug**, which
was two events at one position rendering as two lines.

Where the layers genuinely conflict — two *visible* pens with different fills,
as in that document's chromatic-aberration cue — they cannot merge and are
emitted as they arrived. That is sound because they are positioned: measured
against the bundled libmpv, **`\pos` suppresses libass's collision avoidance**.
Positioned duplicates superimpose; unpositioned ones stack, which is what the
bug looked like.

**Positions are mapped into the caption area, not the raw frame.** YTT's
`ahHorPos` / `avVerPos` are percentages of the video, and `avVerPos: 100` — the
default window of every manual track — taken literally puts a caption's baseline
flush against the bottom edge, under the player's own controls. The generated
`Style` already reserves a 60 px margin for that reason, so `\pos` is computed
inside the same box. The property that makes it the right inset rather than an
arbitrary one: a cue at the default window lands on exactly the pixel an
*unpositioned* cue lands on, so turning styling on moves nothing that did not
ask to move.

**Two ASS details that look like they work and do not.** `\c` and friends take
six hex digits and no alpha; alpha rides on `\1a` / `\3a` / `\4a`. An eight-digit
value renders correctly while it is opaque and silently comes out opaque and the
wrong hue once it is not. And a caption *background* is `BorderStyle: 3`, a
`Style` property with no override tag, so the renderer emits a second `Boxed`
style — under which libass fills the box from the outline colour, `\3c`, not from
`\4c`. Both measured; neither errors or logs.

**Honouring the ASR window moves auto-generated captions, and that is a product
decision.** An ASR track's window is `apPoint: 6`, `ahHorPos: 20`,
`avVerPos: 100` — bottom-left at 20% — and a line does not name it directly:
it carries `wWinId`, and the position lives on the window-definition event. So
auto-captions were previously centred and are now left-anchored at 20% of the
width. Faithful, and what youtube.com does; but on a short line it is visibly
left of centre. `docs/tasks/18-caption-styling.md` §4 is where that trade is
recorded.

**Karaoke is per-segment pens, and needs no `\k`.** A `pPenId` sits on a `seg` as
well as on an event, and YouTube animates a highlight by emitting the whole line
repeatedly with the split moved:

```
16991  seg pen=21 "Ba"       seg pen=22 "sic karaoke timing."
17191  seg pen=21 "Basic "   seg pen=22 "karaoke timing."
```

So the stepping is already in the timings and `\k` would be a second, redundant
mechanism — which is why §5 of the task brief scoped karaoke out "unless it falls
out for free", and it did. `CueSegment.style` carries the run's pen and `ass.ts`
emits an override block per run.

Two consequences that are not obvious. **Edges are collected to the line**, not
left on the run: a segment pen restates its layer's edge, and a per-run `\bord`
could otherwise cancel the shadow the layer union just established. And **layer
visibility becomes a property of the segments** — the karaoke cues carry no
event pen at all and three layers of segment pens, two fully transparent, so a
merge reading only the event level sees three visible layers, calls them a
conflict and emits the line three times.

### Known limits of the libass route

Measured against `L-BgxLtMxh0`, which exercises all of them. None is a bug and
none is worth approximating:

- **Vertical text** (`pdPrintDir: 2`). libass has no writing mode. The only
  approximation is one character per `\N`, which then needs its own font size and
  line spacing to fit the frame — a layout engine, not a conversion, and §2.9
  chose ASS precisely to avoid writing one.
- **Packed text.** Downstream of the above rather than separate: the cue is two
  windows, at 100% and 97% of the height, and the lower one is vertical. Rendered
  horizontally they overlap. **The geometry is already faithful; the content is
  not.**
- **Sub- and superscript** (`ofOffset`). No ASS tag, and the YouTube web player
  does not render them either — so an approximation would be less faithful than
  omitting them, not more.
- **Raised and depressed edge styles collapse into a drop shadow.** ASS has no
  bevel: `\bord` and `\shad` are the only two knobs, and a bevel is neither. YTT
  names four edge styles (`etEdgeType`) and libass can express two of them, so
  raised and depressed both render as a shadow — which is what mpv's own WebVTT
  converter does with the same CSS values. Offering them in a user style menu
  means offering two entries that produce one result.
- **A caption box cannot have rounded corners.** ASS has two boxes and both are
  rectangles: `BorderStyle: 3` fits one to each line — YouTube's *background* —
  and `BorderStyle: 4` adds a rectangle around the whole block, which is
  YouTube's *window*. So the two-box model survives the conversion and the
  rounding does not. Rounding would need vector drawing commands computed per
  cue from text metrics libass has and we do not. **Knowingly dropped** as part
  of the decision below, rather than missed.
- **Colour emoji render in one colour.** libass rasterises the glyph outline and
  fills it with the text colour; a font's own colour layers are not used.
  Measured 2026-08-19 against the bundled libmpv rather than inferred: the same
  emoji rendered under `\c` red, green and gold came out red, green and gold.
  (The binary carries FreeType's `CBDT`/`sbix`/`COLR` machinery but no `CPAL`,
  the palette `COLR` needs.) It matters less than it sounds — YouTube assigns the
  emoji run its own pen, so `✨` arrives gold and renders gold; what is lost is
  the two-tone gradient, not the hue. Fixing it needs a newer libass, and the
  `media_kit_libs_windows_video` pin is load-bearing for F13.

Each is counted per document and logged, so a track leaning on one is visible in
the log rather than silently plain.

**A styled track's authored background colour is not painted — chosen, not
discovered missing.** `json3.ts` still parses it onto `CueStyle.backgroundColor`;
nothing downstream reads it, on either side. Phase 5 moved the caption
background off the ASS document to client-side compositing
(`LibassLayer._BackgroundPainter`, "What phase 5 deleted" above), driven by the
user's own colour choice, and never carried the per-cue authored one over to
that new path. Two things make this a real decision rather than an oversight
nobody has gotten to: the wire protocol carries one ASS document per track and
nothing per-cue (`protocol.md` §3.8), so wiring authored background through
needs a new time-indexed channel the client can resolve against the currently
showing cue; and the ASS-native alternative — put the box back in the document
— is the one this section's "What phase 5 deleted" already walked back, because
`BorderStyle: 3` replaces the outline rather than sitting behind it, so a
background sharing an event with the text would silently kill every edge style
again. Measured 2026-08-20 (§2.10's sample): **0 of 23 tracks across 20 ordinary
videos were styled at all**; every styled track in this project's corpus is a
caption-art demo (`L-BgxLtMxh0`, `1S7uIQmkRzk`, `8Oos6D4_Bjo`). **What would
change this:** a styled track with a real, non-demo authored background turning
up in the wild — the case for the channel is the frequency, not the
difficulty, and right now the frequency is zero.

### Who draws a caption — decided 2026-08-20

Draggable captions need three things libass will not hand over: a rounded box, the
caption's on-screen rectangle for a hit target and a hover cursor, and text
metrics. That reopened §2.9, and the answer is **unchanged — libass draws every
caption, Flutter draws none.** Flutter measures the same string only to place an
*invisible* hit rectangle; a few pixels of slop on a hit target is imperceptible,
and rounded corners are given up (above).

**The reason is a measurement, not a preference, and it is the opposite of the
intuition.** Sampled 2026-08-20 across 34 ordinary videos off live search — 20 had
captions, 23 tracks read:

| | tracks | share |
| --- | --- | --- |
| `plain` | 23 | **100%** |
| `styled` | 0 | 0% |

Every styled track in this project's corpus belongs to a caption-art demo
(`L-BgxLtMxh0`, `1S7uIQmkRzk`, `8Oos6D4_Bjo`). Ordinary videos — including all six
tracks of `dQw4w9WgXcQ` — are plain, and **every** auto-generated track is plain by
construction, because ASR carries a rolling window and no pens.

That number is what rules out the split renderer:

- **B — Flutter draws plain tracks, libass keeps styled ones.** *Rejected.* The
  split is not 50/50 and not even minority/majority: it is ~100/0. Flutter would
  draw effectively every caption a user ever sees, and libass would be left
  serving demo videos — so the styling pipeline this section describes would
  become the path that almost never runs, while the risk of *two* things being
  able to draw a caption would apply to the common case rather than an edge one.
  That risk is not hypothetical: `PlayerConfiguration.libass` defaulting to
  `false` let Flutter draw every caption from tag-stripped text for two entire
  tasks without anyone noticing, precisely because a plain caption looks correct
  either way.

- **C — Flutter draws *all* captions, libass removed.** *Rejected for now, not
  rejected.* It is the coherent version of the above and it would give exact
  geometry, a rounded box and a real hit target. Its cost is that it rebuilds what
  `captions/ass.ts` and libass already do between them: custom line metrics,
  multi-pass painting, collision tracking, and scaling — a bespoke subtitle
  rendering engine. Recorded here because someone will propose Flutter rendering
  again, and this is the answer: the objection is the engine, not the idea.

### Dragging a caption, and the style menu — built 2026-08-20

Four things had to be settled before any of it worked, and three of them are
measurements against the bundled libass rather than readings of the ASS spec.
`sidecar/scratch/probe-task19.ts` re-runs the whole thing end to end against real
YouTube tracks and reports every claim below as OK or FAIL.

**A caption is up to three events, one per layer, and that is not tidiness.**
*(Removed in phase 5 — see "What phase 5 deleted" below. Kept because it is the
reasoning a future reader will otherwise reinvent the moment they consider
putting a background back into the document.)*
ASS makes the background a `BorderStyle` on the `Style`, and `BorderStyle: 3` —
the box — *replaces* the outline rather than sitting behind it: `\bord` becomes
the box's padding and no outline is drawn at all. So a document that puts the box
on the text event cannot draw an edge style, and since the background is now on
by default (YouTube draws one, and it is the drag handle), every *Character edge
style* the menu offers and every edge a styled track authored would have silently
stopped working. Splitting them fixes it: the box is its own event with invisible
glyphs (`\1a&HFF&`), sized by the same text at the same `\pos`, on the layer
below; the text event keeps `BorderStyle: 1` and its outline; the window is a
third event lower still, `BorderStyle: 4`, drawing a rectangle round the whole
block from `\4c` with its own per-line box made transparent. Verified by
rendering, not by reading: `scratch/probe-layers.ts` confirms the box draws with
no glyphs, that the text above keeps its outline, and that on a two-line cue the
window fills the gap between the lines and extends past the per-line boxes.

This is the same compositing YouTube transmits and that Task 18 spent its length
*undoing*, which is worth being explicit about. The difference is what the two
events are: YouTube's duplicates were two halves of one line's styling, which
belong merged; these are a backdrop and a line, which belong apart. **A document
that draws neither backdrop emits neither, and no layer numbers**, so a track
with the background turned off is byte-identical to what Task 17 rendered —
asserted in `captions.test.ts`.

**What phase 5 deleted, and what byte-identity means now.** For one release
there were two caption renderers behind a debug toggle (`libassEnabledProvider`):
Option A, the `sub-add → mpv → libass` pipeline described above, and Option D,
`LibassLayer`. A `renderer: 'mpv' | 'libass_layer'` parameter on `captions.get`
told `renderAss` which one it was writing for, because `LibassLayer` paints its
own background and window and a document carrying the box and window `Dialogue`
events would have drawn both — the double-draw bug. Phase 5 removed Option A.
`LibassLayer` is the only caption renderer, and with it went `CaptionDragLayer`,
the box and window events, the layer split, the `renderer` parameter, and the
`metrics` parameter and everything behind it.

So there is no divergence to reason about any more, and **Task 18's
byte-identity claim is unconditional again** — not "identical for a given
renderer", just identical, because there is one renderer. Precisely:

- A **zero-offset, unpositioned** track is byte-identical to what Task 17
  rendered, with no options and no opt-out. It was Task 19 that needed the
  caveat (the background was on by default, so the comparison had to turn it
  off); backgrounds are not something this document expresses at all now, so
  asking for none and asking for nothing produce the same bytes. Both halves are
  asserted in `captions.test.ts`.
- A **dragged or positioned** track is *not* byte-identical to Task 19's output,
  and that is a deliberate change rather than a drift. Its `\pos` values used to
  be pulled back inside the frame by the clamp below; they are now the anchor
  plus the delta and nothing else, so any cue whose old position had been nudged
  moves. Nothing asserts equality with old output here, and nothing should.

**The retired width estimate, and why "retired" does not mean "wrong".** The
clamp described below — the advance table Flutter measured and shipped, the
`Fontsize`-vs-em correction, `estimateWidth` and `clampSpan` in `ass.ts`,
`CaptionMetrics` on the wire — is gone. It is worth being exact about why,
because a future reader finding only its absence cannot tell whether it was
removed as a bug or as surplus, and the two lead to opposite conclusions about
whether to rebuild it.

It was surplus, and it was correct. Every measurement recorded below still
holds: the advance table really does beat any single pixels-per-character
number, it really does land within +1–2% of what libass draws, and the
0.895 correction really is Arial's units-per-em over its ascent-plus-descent.
The estimate existed because **mpv cannot see its own output.** libass
composited into the video texture, media_kit exposed no subtitle surface, and
nothing published a caption's rectangle — so a client that wanted to draw a hit
target or stop a drag at the frame edge had no choice but to approximate a box,
and the sidecar had to approximate the same box independently for the cues that
had not appeared yet. Two estimates of one invisible thing, kept in step by
shipping the instrument across the wire.

`ass_render_frame` returns the rendered boxes. That is the whole argument for
Option D over Option A, and it is not an implementation detail: it converts a
quantity that had to be predicted into one that can be read. `LibassLayer`'s
`_computeNudges`/`clampOffset` clamp against real geometry every rendered frame,
at rest and mid-drag alike, which is strictly better than what the estimate
could do at its best — and it removes the class of bug where the two
approximations disagree. The sidecar therefore emits the honest, unclamped
position, and the client is the only thing that decides where a caption may sit.
`assLayout()` and the `layout` field survive and are still populated on every
`captions.get`; they are the document's own constants, never an estimate, and
sending them is cheaper than keeping a second copy in Flutter.

**Position is a delta, not a coordinate.** The drag is stored as a fraction of
the frame and added to whatever position the source gives — none, an ASR rolling
window, or a per-cue styled position — so one rule covers every kind of track and
nothing has to ask which kind it is holding. A zero delta emits nothing new. This
keeps the `styled` classification **cosmetic** (it drives a picker badge) rather
than load-bearing, which matters: two of the three predicates tried for it during
Task 18 were wrong, and a misclassification that costs a wrong badge is a very
different thing from one that picks a renderer.

**The no-overflow rule needs a width neither side has.** *(Removed in phase 5 —
see "The retired width estimate" above for why the measurements below all still
hold and the mechanism went anyway. The rule itself did not go: `LibassLayer`
enforces it against real geometry.)* libass does not help — a
positioned line wider than the frame runs straight off the edge, no clamp and no
wrap — so the clamp is ours, and it needs the rendered width of text. The sidecar
holds every cue's text and has no font engine; Flutter has the font engine and,
under the decision above, never sees a cue it is not currently displaying. Three
measurements resolve it:

- **mpv publishes the current cue's text for free.** `sub-text` stays populated
  while libass is drawing (measured 2026-08-20 with `sub-ass=yes` and
  `sub-visibility=yes`, the shipping configuration), and media_kit already
  observes it. So the hit rectangle, the hover cursor and the drag ghost need no
  protocol at all.
- **A width table beats any single pixels-per-character number, decisively.**
  Advances at Arial 48 through the bundled libass run from 8.3 px (`'`) to
  40.5 px (`W`) — a 4.9× range. A scalar calibrated on a representative sentence
  under-estimates an all-capitals caption by **26%** and a run of `M` by 46%;
  the alphabet mean over-estimates lowercase by ~20% and still under-estimates
  capitals by 12%. Under-estimating is the one direction that lets text clip off
  the edge of the player. Summing per-character advances lands within **+1–2%**
  on every real caption line tried, always on the safe side.
  `scratch/measure-advances.ts` is the harness; 74 numbers cross the wire.
- **ASS `Fontsize` is not an em size.** libass scales the face so that its
  *ascent + descent* equals `Fontsize`, so Arial's advances at `Fontsize: 48`
  come out at 0.895× what an em-sized 48 px `TextPainter` gives — and 2048/2288,
  Arial's units-per-em over its ascent-plus-descent, is exactly that. Measuring
  at the nominal size would over-estimate every caption by ~11.7%: safe, but
  enough to visibly stop a drag short of a corner. `caption_geometry.dart`
  derives the equivalent Flutter size from the face's own metrics rather than
  hard-coding a ratio for one font.

So Flutter measures, once per font and size, and the table is sent with the drag
commit. The sidecar applies it to the cue texts it already holds. **One
instrument, one outward bias, applied in the two places a position is decided** —
and no cue list on the wire, which would have re-created the "two representations
of one caption" shape this project has already been bitten by.

`captions.get` therefore gained a `layout` field in its result (eight numbers per
*track*, sent rather than duplicated as constants in Flutter) and three optional
parameters — `style`, `offset`, `metrics`. Phase 5 took `metrics` back off;
`layout` and the other two remain. `protocol.md` §3.8 has the shapes.

**A width table can be missing, and it cannot be missing when it matters.**
*(Also removed in phase 5, with the table it hedged.)* The client learns the font
from `layout` on the *first* `captions.get` for a track, which by definition
carries no offset because the offset resets when the track changes; every later
request has both. What is left is an older client or a restored offset that
outlived its measurement, and `captions/style.ts` carried a measured Arial-48
fallback for those rather than failing the request.

**The style menu applies during generation, and it has to.** mpv's live
properties act on the ASS `Style`, and `sub-ass-override=force` — the switch that
is supposed to make them win — overrides the `Style` too, **not** the inline
override tags Task 18 emits a styled track as. A user setting a font colour would
see it apply to plain tracks and silently do nothing on styled ones. So the
sidecar folds the overrides in as it writes the document, suppressing the
authored tag rather than racing it. One mechanism, every track type, no control
that is a no-op on some tracks. It costs a re-render plus a `sub-add` per change;
slider input is debounced trailing 120 ms and discrete controls commit at once.

**A font colour on a karaoke track replaces the line's base colour only.** The
sung and unsung runs are two inline colours; replacing both flattens the
highlight, so the caption would look broken while the setting looked like it
worked. A run whose colour differs from the line's base is left exactly as
authored. It generalises past karaoke without detecting it: on a plain track every
run is the base and everything changes, and on a track that colours one word for
emphasis the emphasis survives. Measured on `L-BgxLtMxh0`: all 291 authored inline
colours survive a drag and a colour override.

### What a re-render costs, and whether the outlier is a category

Measured 2026-08-20, `convert()` split into its parts:

| Document | Cues | Segments | Size | `JSON.parse` | → cues | `renderAss` | full | cached |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `1S7uIQmkRzk` | 99 | 417 | 70 KB | 0.2 ms | 1.9 ms | 1.3 ms | 3.4 ms | **1.3 ms** |
| `L-BgxLtMxh0` | 265 | 317 | 127 KB | 0.4 ms | 2.3 ms | 1.0 ms | 3.7 ms | **1.0 ms** |
| `8Oos6D4_Bjo` | 230 | 46 320 | 3.1 MB | 8.7 ms | 17.2 ms | 32.8 ms | 58.8 ms | **32.8 ms** |

So the service caches **parsed cues** rather than rendered documents — Task 18's
cache was right when a track rendered exactly one way and would make every drag
refetch and re-parse. That takes an ordinary style change to ~1.2 ms of render,
and the 3 MB outlier from 59 ms to 33 ms. With `sub-add` at 12–36 ms and one RPC
round trip, a style change is **~15–40 ms** on ordinary content.

**The outlier is an outlier, not a category.** Sampled 2026-08-20 across six
search queries, 219 caption tracks:

| | |
| --- | --- |
| p50 | 29 KB |
| p90 | 60 KB |
| p99 | 405 KB |
| max | 1240 KB |
| over 1 MB | **1 of 219** |
| any per-segment styling | **1 of 219** |

And the driver is not size but *segments per cue*: `renderAss` emits a run per
segment, and the 3 MB document has 201 of them per cue against 4.2 and 1.2 for the
two ordinary ones. Segment-level pens are what produce that, and exactly one track
in 219 has any. The largest track in the real sample is a 1.2 MB ASR document at
4.7 segments per cue — big, but plain, and it renders in the ordinary band. **No
fast path beyond the cue cache is warranted**; if that changes, the number to
watch is segments per cue, not bytes.

### 2.10 Drag Lock: One Anchor vs Many (Decided 2026-08-21)

Dragging a heavily stylized subtitle (e.g., custom words pinned to the corners of the screen) would destroy its layout if a global offset were applied. The original heuristic proposed locking the drag via an `isStyled` boolean (checking for pens or windows). However, this was flawed: ASR tracks theoretically carry custom window positions, which would incorrectly classify them as styled and lock the drag for standard auto-generated captions.

The true distinction that matters is **One Anchor vs Many**. A script run across the Task 19 sample parsed the `json3` response into `cues.ts` and counted the distinct base positions (`positionX`, `positionY`) across every cue in a track.

**The Findings:**

| Track Type | Total | Draggable (≤1 anchor) | Authored (>1 anchors) |
| --- | --- | --- | --- |
| Manual | 109 | 67 | 42 |
| ASR | 34 | 34 | 0 |
| **Total** | **143** | **101** | **42** |

This proves the heuristic is flawless. 100% of ASR tracks and plain manual tracks share exactly one window position (or zero), meaning moving them cannot destroy a layout. Authored art tracks contain dozens of distinct anchors. A track is safely draggable if and only if its distinct base positions count is ≤1.

**Implementation — the `positional` flag.** `classifyDocument` in
`sidecar/src/captions/service.ts` returns `{ styled, positional }`. `positional`
is `true` when either of two conditions holds, checked only on non-ASR tracks (ASR
always uses the rolling window, so its positions carry no authored intent):

1. Any `wpWinPositions` entry has a non-default anchor point / horizontal position /
   vertical position (`apPoint ≠ 7`, `ahHorPos ≠ 50`, or `avVerPos ≠ 100`,
   defaulted via `??` because absent fields mean the default).
2. Any two events overlap by more than 150 ms (a composed subtitle that uses
   multiple simultaneous events to achieve layering or simultaneous-line effects).

The flag rides on `CaptionTrackContent` alongside `styled`, so `captions.get`
always populates it (the document is in hand). `captions.list` with
`includeStyled: true` also fetches documents and back-fills both fields on the
track entries. A track whose document has never been fetched carries `positional:
null` — **not yet known**.

**In Flutter, `positional` is write-once per track per session.** When
`CaptionsController` receives a `CaptionTrackContent` whose `positional` differs
from what the track list entry already holds, it back-fills the list entry with
`copyWith`. The `copyWith` uses a direct assignment rather than a sentinel (hard
invariant 10) because these fields are *only* set to a non-null value and never
cleared — a fetched classification is final for the session. Any future code that
needs to *unset* `positional` must add the sentinel pattern.

**The drag-lock predicate in `LibassLayer`** is `track.positional != true`. A
`null` (not-yet-classified) track is treated as draggable — worst case, a
multi-anchor track is briefly draggable for one `captions.get` round trip before
the flag arrives. This is the safe-side default: an incorrect allow-drag is
recoverable (the document re-applies at the new position); an incorrect lock-drag
is invisible and confusing.

### Whether the isolate design holds — measured 2026-08-25

Phase 5 removes the `sub-add → mpv → libass` fallback and the debug toggle,
making `LibassLayer` — a fresh `Isolate.run` per rendered frame, driven by
`positionStream` — the only caption renderer. Three things about that design
had never been measured against anything real. `app/test/README.md` has the
harnesses; the numbers below are what they found, against the real bundled
`libass-9.dll`/`libmpv-2.dll` in an actual Flutter Windows release build (a
`flutter test` process has no video-output timing loop at all — `media_kit`'s
`Player()` without a `VideoController` emits exactly one `positionStream` event
over 20 s of real playback — so the cadence half of this could not have been
measured any other way).

**`positionStream` ticks once per decoded video frame** — 41.7 ms at 23.976
fps, 33.3 ms at 30 fps, essentially jitter-free (p99 within 2 ms of the mean).
One `LibassLayer._runRenderIsolate` round trip costs **~1 ms at p50** (max
21.6 ms, release/AOT) against a real karaoke document, and **0 of 2,756**
position events were coalesced away by a render already in flight, across
three runs. Every one of 136 cues live during a 25 s karaoke-heavy window got
at least one render (karaoke's ~200 ms steps got ~4.8 each); every one of 34
cues live during a 60 s ASR run got at least 33. Frame scheduler: zero frames
over the 16.67 ms budget in either release run. Drag: the on-screen caption
lags the cursor during a continuous drag by a **bounded ~65 ms**, invariant
across a 2.3× speed range and a 3.75× pointer-cadence range (a fixed-fraction
chaser off `TweenAnimationBuilder`'s 180 ms `easeOutCubic` being re-targeted on
every pointer-move `setState`, not an accumulator), fully settled within
180 ms of release. None of the three needs a fix before phase 5.

**The stated bound, not a footnote: a cue shorter than one video-frame period
can be rendered zero times, silently.** The render loop only sees the world at
`positionStream`'s cadence — it has no notion of "a cue existed and was
skipped," so a cue that starts and ends between two consecutive position
events simply never appears, with nothing logged anywhere. At 24 fps that
period is 41.7 ms. This did not happen in either measurement run — the
shortest live cue was 60 ms, a **1.4× margin**, not the ~40× margin the
200 ms karaoke cadence and the 1200 ms ASR floor (`cues.ts`'s clamp) enjoy —
but 1.4× is a margin a single dropped frame, a 30 fps stream showing 60 ms
cues, or a future content shape can close. If sub-frame-period cues turn out
to matter, the fix is at the source (`cues.ts`'s merge-forward threshold, or
a render call keyed to cue boundaries rather than position ticks alone), not
in `LibassLayer`, which cannot render faster than it is told the clock moved.

**Known follow-ups from phase 5, not yet done — noted here so they outlive this
thread:**

- **`PlaybackEngine.subtitleTextStream` is dead code.** Its only caller was
  `CaptionDragLayer`, deleted in phase 5 (`5b50555`). Left in place rather than
  removed alongside it because deleting it means editing the `PlaybackEngine`
  interface (`app/lib/data/playback/engine.dart`), which is its own small,
  separately-reviewable change rather than a rider on a pipeline removal.
- **No karaoke-classified track has been rendered end to end.** `L-BgxLtMxh0`
  classifies `styled`, not `karaoke`, for its full document (it has font/bold/
  italic styling beyond the colour sweep) — `classifyDocument`'s narrower
  `karaoke` case is exhaustively unit-tested in `captions.test.ts` against real
  document *structure*, but no real frame has been drawn for a track that
  actually lands in that classification, the way `probe-task19.ts` does for
  `plain` and `styled`. Not a known gap in the classifier — a gap in having
  seen it happen. If a real `karaoke`-classified track turns up in ordinary
  use, run it through `probe-task19.ts` (add its video id alongside `PLAIN`/
  `STYLED`) and confirm.

### 2.11 The release log: a launcher process, because the engine's stdio is its own (decided 2026-09-17)

A release build launched from Explorer had nowhere to write: stdout and stderr
were not connected to anything, and when the engine aborted (F28) Windows kept
the only record — a dump — until its report was filed. `rill.exe` in a
**Release** build therefore starts as a launcher (`windows/runner/log_capture.cpp`):
it opens `%LOCALAPPDATA%\rill\logs\rill-<local time>-<launcher pid>.log`,
starts a second `rill.exe` with stdout and stderr on a pipe, and writes every
line it reads, timestamped. When the app exits it writes the exit code, and an
NTSTATUS error code as `CRASHED` — so a crash leaves `0xC0000409` or
`0xC0000602` in the log with no dump at all.

**Why a second process, and not a redirect inside the first.**
`flutter_windows.dll` links its own C runtime (the abort in F28 is
`flutter_windows!abort`), and a CRT binds file descriptors 1 and 2 to the
process's standard handles when its DLL loads — before `wWinMain` runs. A
`SetStdHandle` or `freopen` in the runner changes the runner's CRT and not the
engine's, so the engine's own messages — the ones that matter before an abort
— would never arrive. `FlutterDesktopResyncOutputStreams` does not help: it
reopens `CONOUT$`, a console, not an arbitrary handle. Only handles set at
process creation reach every CRT in the process: the runner's, the engine's,
libmpv's and the Dart VM's. The second process also fixes crash timing for
free: bytes already written to a pipe survive the writer's death, so the last
line before a fast fail is read after it.

**Redaction** is the sidecar's two rules (`redact.ts`), applied by the
launcher to every line whatever wrote it: registered exact values, and
auth-cookie-shaped `NAME=VALUE` pairs. The app registers values over the same
pipe — `\x01rill-secret <value>` lines, consumed by the launcher and written
nowhere — from `log_capture.dart`'s `registerLogSecret`, which does nothing
unless `RILL_LOG_FILE` says the process is the launcher's child (anywhere else
that line would print a cookie to a terminal). The app calls it for the stored
cookie, a newly signed-in one and `YT_COOKIE`. The name list is duplicated in
C++ and must be kept in step with `COOKIE_NAME`.

**Retention:** one file per launch, the newest 10 kept; a file past 10 MB is
renamed to `<name>.old` and a new one started, so the tail — where a crash's
last lines are — is always in the current file.

**What else changes, and why each is acceptable.**

- Two `rill.exe` processes. The launcher does no Flutter work and holds a job
  object with `KILL_ON_JOB_CLOSE`, so ending it ends the app (and whatever the
  app started).
- A debugger started on `rill.exe` attaches to the launcher. `RILL_LOG_CAPTURE=0`
  runs the app in one process, with no log, as before.
- The launcher copies each line to its own stderr or its parent's console, so
  `rill run` / `rill open` still show the output live.
- Not in Debug or Profile (`RILL_LOG_CAPTURE` is defined for the Release
  configuration only): `flutter run` finds the Dart VM service by reading the
  app's stdout, which a launcher would own.
- The launcher waits 3 s for the pipe after the app exits, then cancels the
  read: a grandchild that inherited the pipe must not hold it open.

`RILL_LOG_TEST=lines|flood|abort` checks all of this end to end (redaction,
rotation, a crash's last line); measured 2026-09-17 on a scratch Release build,
with pruning checked against seeded old files. `installErrorLogging` adds
Flutter's and the zone's uncaught errors, with stacks, when there is a log.

### 2.12 What is playing now — chapters, credits, and when to believe them (decided 2026-09-25)

The audio-only layout and the media flyout show a song. The source for it is two
independent things that each answer half the question, and neither is safe to
read alone. `app/lib/domain/now_playing_track.dart` is the one resolver;
`ui/now_playing_art.dart` feeds it, and nothing else reads `VideoDetail.music`.

- **Credits** ("Music in this video") say *which recordings*, and carry the cover.
  They have **no timestamps** and stop at **10 cards** however many songs the
  video holds (measured 2026-09-25, ~45 pages; an 80s mix with 23 songs listed
  10 under a header reading "10 songs"). They are also not only songs:
  `videoAttributeViewModel` is a generic card, and a game is one (`dHPQNc9oa_E`,
  "Portal 2") — told apart in the sidecar by structure (`protocol.md` §3.3).
- **Chapters** say *when*. `Chapter[]` is the uploader's segmentation, which on
  a music mix is one chapter per song. YouTube has already parsed the
  description's timestamps into them, so the sidecar reads the
  `…-description-chapters` panel first and parses the description itself only
  when that is absent. The current chapter comes from `positionStream`,
  distinct-mapped so widgets rebuild at a boundary and not per tick (hard
  invariant 9).

**Chapters are songs only for a video that is music *and* whose chapters are a
tracklist.** A lecture's chapters are sections. So is a lyric video's
"Intro / Verse / Chorus". Music is the tile's ♪, an artist-channel badge, a
Topic channel, or any credit at all; a tracklist is nine or more chapters, or
most of them written "Artist – Song", or most of them naming a credited song.

**The chapter's text wins over the credit's.** A chapter is joined to a credit
by words, only to borrow its cover and album — the credit can be another
version of the song ("(Instrumental)") while the uploader wrote what they meant.
Chapters past the tenth have no credit and no cover: the still stands in.

**A lone credit is believed leniently.** Titles and credits legitimately
disagree (the artist repeated, symbols, another language), so an overlap test
would reject good credits. Any one signal passes — the video is music, or shares
a *single* word with the credit's song or artist. What fails is a credit on a
video that is not about it, which shows the video's own title. Several credits
and no chapters is a guess, so it is left unguessed unless the video's title is
about exactly one of them.

**The chapter's frame is the backdrop, never the cover.** `Chapter.thumbnailUrl`
is a 336×188 video frame. Under the blur that is fine and it changes with the
song; as a sharp cover it would be a smear. The foreground cover stays a
credit's or, failing that, the video's still (F40).

Not built: a cover for the chapters that have no credit. The candidate is
YouTube Music's own search (`todo.md` 45); third-party cover APIs were rejected
— they send what is being listened to to a party that is not YouTube.

### 2.13 Release pipeline — a daily installer, and how an update is trusted (decided 2026-09-26)

`.github/workflows/release.yml`; the pieces it drives are in `release/`.

- **One channel.** There is no nightly/stable split, so a release is just "an
  update". Every push to `main` that touches more than docs (`docs/`, `*.md`) and the
  throwaway folders (`scratch/`, `spiking/`) is built and released,
  about 12 minutes later, and a daily cron retries any release that failed. A
  release exists only if that commit has no release yet *and* the gate and the
  build both pass. Runs are serialised and GitHub keeps a single waiting run, so two
  merges inside one build's length collapse into one release: that run builds the
  newer commit, and its notes cover everything since the previous release, so
  nothing is lost, but the version number skips.
- **The version is a function of the commit, and `release/version` is where you
  set it.** That file is one strict line, `MAJOR.MINOR.PATCH`, and the commit that
  last changed it *is* that version. From there, along `main`'s first-parent
  history (`release/next-version.ts`), each merged pull request adds 1 to the minor
  and resets the patch, and every other commit adds 1 to the patch. A merged pull
  request is recognised by its subject — `Merge pull request #N`, or a squash commit
  ending `(#N)` — so a rebase merge, which leaves nothing to recognise, counts as
  ordinary commits. **To set the next version, edit the line in a pull request:**
  the merge that lands it is exactly that version and counting restarts from it,
  which is how a major bump is made. Because the number is derived from history, a
  commit always has one version, a re-run cannot mint a second, and nothing commits
  back to `main`. `plan` refuses a version lower than the latest release, because
  the app installs only a strictly higher one. `app/pubspec.yaml`'s `version` no
  longer drives anything, and the minor is a count of merged pull requests rather
  than a mark of what they contained.
- **The artifact is a per-user Inno Setup installer**, `Rill-Setup-x64.exe`,
  installing to `%LOCALAPPDATA%\Programs\Rill` with no admin rights, so an update
  never raises a UAC prompt. It clears `data\`, `sidecar\` and `*.dll` before
  copying (the app owns those; user data does not live in `{app}`), so a file
  dropped from one build cannot linger in every install after it. The VC++
  runtime DLLs go in app-local — a machine without them fails before any of our
  code runs. **`rill.ps1` stages the same three DLLs a local `build`/`run`/`zip`
  needs, added 2026-09-28** — it did not before, so a locally built installer
  started with `rill exe: MSVCP140.dll was not found` on any machine that
  doesn't already have the redistributable for some other reason, which is
  every dev machine and no genuinely clean one. Found by installing a locally
  built `Rill-Setup-x64.exe` in a fresh Windows Sandbox — the one environment
  a normal dev loop never exercises, and exactly the one this gap needed.
- **x64 only.** x86 is not buildable (Flutter has no Windows x86 target), and
  arm64 is blocked by the native stack, not by CI (`todo.md` 46). The x64 build
  runs on Windows-on-ARM under emulation.
- **Updates are trusted through a signed manifest, not through the release
  page.** `update.json` carries the version, the installer's URL and its SHA-256,
  and `update.json.sig` is a detached Ed25519 signature over its exact bytes. The
  public key is committed at `release/update-signing.pub` and is what the app
  embeds; the private key exists only as the `UPDATE_SIGNING_KEY` Actions secret,
  read by the `publish` job alone, and in one offline copy — **losing that copy
  strands every installed app**, because none can verify an update signed by a new
  key until it is reinstalled by hand. `make-manifest.ts` verifies its own output
  against the committed public key before writing, so a wrong secret fails the
  release rather than shipping updates that every client silently rejects. The
  client installs only a strictly higher version, so replaying an old signed
  manifest cannot downgrade anyone.
- **The feed is this repo's GitHub Releases**, read through
  `releases/latest/download/update.json` — a redirect, not the API, so no rate
  limit and no token.
- **Release notes are one tool-less Gemini call inside a template that lives in
  code.** `release/make-notes.ts` sends the commits since the previous release (with
  the files each touched, and a short diff excerpt for a terse one) to
  `gemini-flash-latest` and asks for JSON: bullets sorted into the six sections of
  the MyBicocca `release-notes` skill. The alias is deliberate — a deprecation
  should not be a chore — and the stable format comes from the template, not from
  the model: the intro, the headings, their order and the closing SmartScreen and
  download callouts are code. The reply is untrusted, because it is written from
  commit text on a public repository and lands in a release body and an app's UI.
  A bullet has to cite a commit that was in the input (the mechanical form of
  "never invent a change"); only a small markdown subset survives (no HTML, no
  link outside this repository, no @mention but the owner's); and every failure —
  no key, an HTTP error, a reply that does not parse — falls back to the plain
  commit list with the reason on stderr, so **notes can never block a release**.
  The key travels in the `x-goog-api-key` header only and is redacted from
  anything printed. The same bullets feed the manifest's `notes`, minus "Under the
  hood". `notes-preview.yml` (Actions → *release notes preview*) shows what the next
  release would say without releasing anything, and is also the only check that the
  live API still accepts the request: the tests run against a local stand-in.
- **What CI checks about the package.** The sidecar is byte-compared with the
  one built and started (it must print `event.ready`) before packaging; then the
  installer is installed silently, its files are checked, the *installed* sidecar
  is started, and the uninstaller must remove it. That is the check for the
  silent failure `CLAUDE.md` spends a paragraph on (a bundle running the wrong
  sidecar) and for "Failed to start sidecar process" reaching a user.
- **The sidecar is installed by one Bun and compiled by another.** `bun.lock` is in
  a format Bun 1.1.42 cannot read (`todo.md` 50), so CI installs with a current Bun
  under `--frozen-lockfile` and then switches to 1.1.42 for `check` and `build`. The
  compiled sidecar embeds its compiler's runtime, and 1.1.42 is what both shipped
  copies were built with and what it has been measured on. A step asserts the
  switch took, because two `setup-bun` steps in a row is exactly the kind of thing
  that quietly keeps the first.
- **The Flutter pin is committed.** `app/.fvmrc` was gitignored until 2026-09-26
  (FVM's generated `.gitignore` lists it), so no clone had a pin: `fvm install` had
  nothing to read, and `tool/test_suite_guard.dart`, which falls back to a bare
  `flutter` when it cannot see `.fvmrc`, would have tested against whatever was on
  `PATH`. Found by the first CI run failing at exactly that step.
- **CI's gate is weaker than the local one, and says so.** `sidecar/fixtures`
  are personal captures, gitignored, so tests guarded by `hasFixture(…)` skip on
  a runner; `corpus/` is what runs there. A green gate is not a substitute for
  `rill check` plus `bun run check` on a machine holding the fixtures.
- **Not Authenticode-signed**, so SmartScreen shows "unknown publisher" once per
  download (`todo.md` 48). The manifest signature is what makes *updates* safe;
  it does nothing for the first install.

### 2.14 In-app updates — check, download, and install only on a click (decided 2026-09-27)

`app/lib/domain/update/`, `app/lib/data/update/`, `app/lib/ui/update_controller.dart`;
the feed it reads is §2.13's.

- **The app knows its version from the build, not from `pubspec.yaml`.** The
  release workflow passes `--dart-define=RILL_VERSION=$VERSION` to the release
  build. Empty means a dev build: it has nothing to compare, so it never checks.
  A local `rill build` passes nothing and is therefore a dev build too.
- **Trust runs in one order and nothing is read out of order.** The Ed25519
  signature is checked over the manifest's exact response bytes before a single
  field is parsed; then the strict parser (every field a value or null, a wrong
  type is a rejected manifest, never a guess); then the installer URL against
  one allowed prefix; then the version, which must be strictly higher. A schema
  other than `1` is logged and ignored. `minimumVersion` above the running
  version makes the update *required*: it cannot be dismissed and gets a strip
  above the page. The size and SHA-256 are checked after download, before the
  rename out of `.partial`, and again immediately before the installer starts —
  with the file held open without `FILE_SHARE_WRITE` from that check to the
  start, so it cannot change in between.
- **The feed, the key and the asset prefix are compile-time constants, resolved
  in one place** (`UpdateConfig.resolve`, which takes `releaseMode` as a
  parameter so both branches are tested). `RILL_UPDATE_FEED`,
  `RILL_UPDATE_PUBKEY` and `RILL_UPDATE_ASSET_PREFIX` point a debug or profile
  build at a local test feed and are **ignored in any release build**, a local
  one included. A malformed override throws rather than falling back, so a test
  build aimed at the wrong place fails loudly. **The https rule is not a separate
  check**: it is the allowed prefix, `https://github.com/LordLux/rill/releases/download/`
  by default and `http://127.0.0.1:PORT/…` only under the override. Every build
  logs which configuration it uses, an overridden one also logs a loud line and
  shows `TEST FEED` on the Updates page, and no key material is printed.
  `release/dev-feed.ts` is the other end of those overrides: a local feed
  signed with a fixed dev key (its public half is in the script), serving a
  padded stand-in installer slowly enough to watch, and able to offer a
  required update or fail by signature, hash or 404 — so every state of the
  page can be reached from a debug build with hot reload.
  Measured against the artefact (invariant 8), 2026-09-27: a release build given
  all three overrides logged `config embedded`, and its `app.so` contains the
  embedded key and neither the throwaway key nor the local feed address; the
  profile build given the same defines contains both — the control that shows
  the grep can see them.
- **Cadence:** 30 s after launch, then every 12 h ± up to 10 min, and on demand;
  one check at a time (a second request joins the first). A newer verified
  release downloads in the background to
  `%LOCALAPPDATA%\rill\updates\<version>\`, and older version folders are
  deleted. Automatic checking and downloading is one switch, on by default.
  Last-checked time, the dismissed version and the switch persist in
  `shared_preferences`.
- **Failure is quiet when automatic and visible when asked for.** An automatic
  failure is logged and the page goes back to what it showed; a manual one is
  shown with its reason. A bad signature, size or hash deletes the file. Every
  failure backs off — 30 min, doubling, capped at 12 h — and **the failure count
  resets only when a whole cycle succeeds** (up to date, or downloaded and
  verified). Resetting it on a successful *check* would fetch a release whose
  installer never verifies again every half hour, 50 MB each time.
- **Where it shows: the account menu, because there is no settings page.** A
  `Check for updates` row that spins while it checks and then opens an
  `Updates` page in the same overlay. The page leads with one card for what
  the updater has to say — the update on offer, in the accent container, with
  up to five notes, a link to the full release notes, and `Restart to update` /
  `Later`; a download in progress; a failure, in the error container, with
  `Try again`; or that all is well — then the running version, the last check,
  and the switch; the header's refresh button checks again. The page is 300 px
  where the menu is 260, so the card's two buttons fit on one line. A ready
  update puts a dot on the avatar; `Later` removes it for that version and
  goes back to the root menu. Nothing is modal and nothing covers the player, so an update never
  interrupts playback. **Signed out, the avatar opens the menu too** (decided
  2026-09-27): a short root page that says why nobody is signed in, with
  **Sign in** as its first action, then the update row. Before that it opened
  the login flow directly, which left a signed-out user with automatic updates
  and nothing else.
- **Install only on the user's click.** The app starts the installer as
  `Rill-Setup-x64.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
  /CLOSEAPPLICATIONS /RELAUNCH=1 /LOG="…\install-<version>.log"` and closes its
  window, the same close as the title-bar button. `rill.iss` has a `[Run]` entry
  that launches Rill after a silent install only when `/RELAUNCH=1` is passed,
  so CI's silent install and anyone else's still launch nothing. Checked
  2026-09-27 with two scratch installers built around a stub `rill.exe` and
  installed with `/DIR=` into a scratch folder: the upgrade closed the running
  old copy through Restart Manager, replaced it, recorded the new version and
  relaunched it once; a silent install without the flag launched nothing.
- **The installer has to leave the launcher's job.** A release `rill.exe` runs
  inside the launcher's `KILL_ON_JOB_CLOSE` job (§2.11), and anything the app
  starts is in it too — so an installer started the ordinary way dies the moment
  the app it is replacing exits. The job therefore sets `BREAKAWAY_OK`, and the
  installer alone is started with `CREATE_BREAKAWAY_FROM_JOB` through
  `CreateProcessW` (Dart's `Process.start` has no such flag); the sidecar still
  dies with the job. An outer job that refuses breakaway (a terminal's, an IDE's)
  makes `CreateProcessW` fail outright, so the start is retried without the flag
  on **any** failure: `GetLastError` read 0 through Dart FFI for exactly that
  refusal on 2026-09-27, and a fallback gated on `ERROR_ACCESS_DENIED` never
  ran. Measured the same day, a release build started from a shell whose own
  job forbids breakaway: the installer still broke away, and it finished two
  seconds after the launcher had exited.
- **The first updater-enabled release has to be installed by hand.** Every
  release before it has no updater, and no way to know its own version.

### 2.15 yt-dlp: consent, download, and staying current (decided 2026-09-28)

`app/lib/data/ytdlp/`, `app/lib/domain/ytdlp/ytdlp_state.dart`,
`app/lib/ui/ytdlp_controller.dart`; the installer side is `release/rill.iss`'s
`ytdlp` task and `[Registry]` entry (docs/todo.md 49).

- **The registry is read exactly once; after that the in-app choice is the only
  truth.** The installer's `[Tasks]` checkbox (checked by default) writes
  `HKCU\Software\Rill\YtDlpConsent` = `"yes"`/`"no"`, removed on uninstall
  (`Flags: uninsdeletevalue`). `YtDlpController` reads it only when
  `shared_preferences`' own `ytdlp_choice` is unset, seeds that preference, and
  never reads the registry again. A silent update re-running the installer can
  rewrite the registry value back to the checkbox's current default regardless
  of what the user chose originally — Inno applies a task's default state on
  every silent run unless `/TASKS=` is passed, which the updater does not do —
  but this is harmless by construction: nothing reads the key a second time.
- **PATH always wins, and is checked the same way the sidecar checks it.**
  `ytDlpOnPath` walks `PATH` for `yt-dlp.exe`/`.bat`/`.cmd`/bare `yt-dlp`, the
  same names `Bun.which` resolves in `sidecar/src/capabilities.ts`. Only when
  nothing is found there does the app look at its own copy
  (`%LOCALAPPDATA%\rill\bin\yt-dlp.exe`) and only then does it set
  `YT_DLP_PATH` for the sidecar — so a user's own yt-dlp is never shadowed,
  touched, or upgraded by this app, and the resolution both main.dart (before
  the first spawn) and `YtDlpController` (for its own state) use is one
  function (`resolveYtDlp`), not two copies that could drift.
- **Verification is SHA-256 against yt-dlp's own `SHA2-256SUMS`, plus a PGP
  signature check on that file — both checked against real captured yt-dlp
  release data in `app/test/ytdlp_fixtures/`, not synthetic stand-ins.**
  `SHA2-256SUMS.sig` is a **raw binary** OpenPGP detached signature (the
  `gpg --verify` kind), not the ASCII-armored `--clearsign` kind — confirmed by
  inspecting the actual bytes (`0x89 0x02…`, an old-format signature packet)
  before writing the verifier, not assumed. `dart_pg` (pure Dart, same
  reasoning as the updater's `DartEd25519`: no platform plugin between the app
  and the bytes) verifies it, but `SignaturePacketInterface` — the type its own
  `Signature.verify` takes — is never exported from `package:dart_pg/dart_pg.dart`,
  only the concrete `SignaturePacket` is (via `packet/base_packet.dart`'s
  `export 'signature.dart'`). `ytdlp_verifier.dart` therefore decodes the
  packet list and calls the packet's own `verify` directly rather than going
  through the unreachable message-level wrapper. yt-dlp's public key
  (`github.com/yt-dlp/yt-dlp/raw/master/public.key`) is vendored as a constant
  rather than fetched at runtime — fetching a key over the same channel it is
  meant to authenticate would defeat the point, the same reasoning as embedding
  the updater's own Ed25519 key rather than serving it from the feed.
- **The weekly refresh compares hashes, not versions.** The task that named
  this feature suggested comparing `yt-dlp --version` against "the latest
  release tag"; `SHA2-256SUMS` carries no version field at all, so getting a
  tag would mean a second network round trip (resolving the `releases/latest`
  redirect) purely to decide whether the first one already answered the
  question. Comparing the installed file's own SHA-256 against the freshly
  verified expected hash answers exactly the same question — is the installed
  copy current — using data already fetched for verification anyway, with
  nothing to parse out of a URL. `YtDlpDownloader.fetchVerifiedHash` costs
  under a kilobyte both ways and downloads no binary; the 18 MB fetch only
  happens on an actual mismatch. `yt-dlp --version` is still run, once, right
  after a fresh download installs — its output is what the Problems and
  Updates pages display, and this app has no other way to learn it (the
  release lists no version anywhere accessible without downloading the file).
- **A stale or wrong app-managed file self-heals the same way a missing one
  does.** `needsMaintenance` (whether to schedule the weekly check at all) is
  `location == appManaged` OR `(location == missing && choice == download)` —
  unconditional on the *choice* once a copy already exists. Measured directly
  2026-09-28: a debug run found a yt-dlp.exe already present with a hash the
  live `SHA2-256SUMS` no longer matched, and the scheduled check replaced it
  with the current verified release and restarted the sidecar, with no
  registry value and no `ytdlp_choice` ever set — exactly the behaviour this
  rule describes, discovered by the machine's own state rather than staged.
- **The sidecar is restarted wholesale, not re-probed.** `capabilities.ts`'s
  own doc says it plainly: "probed once, said out loud" — there is no RPC to
  ask it to re-read `YT_DLP_PATH` mid-session, and adding one would be new
  sidecar surface for a rare, user-initiated event. `RpcClient.restart()`
  reuses `killForTestAndWait`'s teardown (despite the name: it is exactly the
  signal-then-wait-for-exit primitive this needs, for the same Windows
  pipe-teardown race documented on `_spawn`) and calls `start()` again with
  `extraEnvironment` already updated. This interrupts whatever the sidecar was
  doing — an open playback session included — the same way an unrelated crash
  restart already does; a download is a deliberate, infrequent user or
  once-a-week action, not a hidden cost of ordinary use.
- **The yt-dlp row is always there while it is missing, not hidden behind a
  "Problems" framing — revised 2026-09-28 after live testing.** The first
  version hid a "Problems" row entirely unless `location == missing &&
  (choice == null || choice == download)`, and showed a red warning for that
  whole range once it did. Installed in a fresh Windows Sandbox and watched
  live, that read as "OMG THERE'S A PROBLEM" for the ordinary, harmless case —
  most videos play identically with or without yt-dlp, so its ordinary absence
  is not urgent. `YtDlpRowSeverity` (`ytdlp_state.dart`) now has three levels:
  `none` (PATH or an app-managed copy resolves it — say nothing), `info`
  (missing, but nothing has actively gone wrong — declined, undecided, or
  downloading — a calm `tertiary`-coloured row), and `problem` (an attempted
  download that failed — `error`-coloured, and the only case that lights the
  avatar's dot). `_YtDlpMenuItem` is always present at `info` or `problem`,
  positioned below the update row in both root pages (it was above it, and
  first in the signed-in menu, before this revision) — the same
  "always-there, label and colour follow the state" shape `_UpdateMenuItem`
  already uses, rather than a row that is either invisible or alarming. A
  second future check would still add its own severity-shaped condition and
  its own card, not a new abstraction — there is still only one kind to plug
  in by hand. The avatar's dot and the button's tooltip
  (`"<name> — needs attention"` / `"Needs attention. Log in"`) now key off
  `severity == problem` specifically, not "yt-dlp is merely absent"; the
  degraded-session tooltip is unchanged, since it already names a concrete
  reason. Declining no longer hides the row (it only stops the automatic
  background download) — the card just drops its now-redundant "I don't want
  it" button once `choice == declined`, since offering to decline again would
  be a no-op dressed up as a button.

## 3. Phasing

**Phase 1 — plain URLs.** Browse as `WEB`, resolve as `VISIONOS` with yt-dlp
and `ANDROID`'s 360p floor behind it, hand mpv two URLs. No SABR, no manifest generation, no media proxy.
This is the current build target.

**Phase 2 — SABR → local DASH bridge.** Required when tier 1 stops serving
plain URLs — as `WEB` already has, and as `ANDROID_VR` effectively did (F5). This
read "when `MWEB` goes SABR-only" while `MWEB` was tier 2 (§2.4). The sidecar manages the SABR session via `googlevideo`'s
`SabrStreamingAdapter` and exposes a generated `.mpd` plus segment endpoints on
loopback, so mpv sees standard DASH. Segment-granular, never byte-range.

Do not build Phase 2 speculatively. Do keep the `playback.open` contract
identical across both so the swap touches only the transport.

---

## 4. Failure modes to design for

| Trigger | Symptom | Response |
| --- | --- | --- |
| Cookie rotation | Empty feed, `logged_in: true` | `auth.verify` fails → re-auth prompt |
| `VISIONOS` goes SABR-only, or starts requiring a PO token as `ANDROID_VR` did (F5) | Tier 1 declines on every video; opens fall to yt-dlp or the 360p floor | Phase 2 |
| New renderer type | Items silently missing | Tolerant parser skips; log unknown types |
| Undeciphered `n` | ~50 KB/s, constant buffering | Never let a raw URL cross the RPC boundary |
| Age-restricted / Vevo | `playback.open` fails | Fall through to yt-dlp with PO token provider |
| `yt-dlp` not installed | The ladder is `VISIONOS` then the 360p floor; the videos tier 4 exists for (age-restricted, Vevo) fail as "Unavailable" with nothing naming the cause | Probed and warned at startup, and reported in the `event.ready` handshake as `capabilities.ytDlp` (`protocol.md` §2) |
| ffmpeg opens with `Range: bytes=0-` | HTTP 403 on an `MWEB` URL that fetches fine under a bounded range | Resolve as `VISIONOS` — ladder tier 1, whose URLs answer 206 at every offset (F11). F10 is also why `MWEB` left the ladder (§2.4) |
| YouTube throttles this connection's anonymous resolution (~180 resolutions an hour, F20) | `LOGIN_REQUIRED — "Sign in to confirm you're not a bot"` on every tier, still refused after tier 1's fresh visitor id | `RATE_LIMITED`, `retry: user`: the watch page says the connection is limited and offers a retry. Not terminal — a lower tier may still get through (`protocol.md` §4) |
| The visitor id stops convincing YouTube | `LOGIN_REQUIRED`, or some other status, or `OK` with an empty adaptive ladder — nobody has observed an expired id, so the shape is unknown (F14) | Mint a fresh server-issued id and retry once on **any** non-`OK` or empty-ladder tier-1 response, then decline to the next tier. Gating on `LOGIN_REQUIRED` alone would let an unknown expiry shape stop resolution silently |
| A libmpv pin bump lands modern FFmpeg | Playback looks perfect until the first seek, then freezes at the target with nothing logged | `stream-lavf-o=request_size=1048576` is set unconditionally (F11, F13); the exact pin that would keep the bump from arriving unnoticed is specified in §2.4 and waits on `app/` existing |
| Audio attach race condition | Video buffers forever, progress bar spins | Await `stream.duration.firstWhere((d) => d > 0)` only if `state.duration <= 0` because if the load was fast, the stream already fired the event. On a timeout failure, surface the error and explicitly hide the `Video` widget so the spinner doesn't run forever. (Observed failure rate before fix: 1 in 3 launches; after fix: 0 in 10). **Applied 2026-08-03** |

The `n` case deserves a type-level guard: a branded `SignedUrl` type in the
sidecar that only the decipher path can construct.

---

## Appendix — decisions and rejected alternatives

**A1. Flutter over WinUI3.** The app should look like YouTube, not like a
Windows app, so Flutter drawing everything is an advantage. libmpv handles
YouTube's separate DASH tracks natively; Media Foundation does not.
*Rejected: WinUI3.*

**A2. JS sidecar over pure Dart.** youtubei.js and googlevideo have no
equivalent in Dart. A headless Node process renders nothing and is unrelated to
the Electron objection. *Rejected: reimplementing InnerTube and SABR in Dart.*

**A3. Own parser over youtubei.js's.** Forced by F2, not preference.
*Rejected: typed accessors.*

**A4. Cookie auth over device-code OAuth.** OAuth is closed, and TV context
lacks the chip bar. *Rejected: device-code OAuth.*

**A5. Two independent client calls over cross-client CPN bridging.** F6 shows
reporting works from the WEB session directly. *Rejected: propagating the MWEB
CPN into WEB reporting.*

**A6. Segment-addressed DASH over a byte-range media proxy (Phase 2).** SABR is
time- and segment-addressed; a byte-range interface is an impedance mismatch
that creates seek races and pause timeouts. *Rejected: ring buffers with HTTP
range requests.*

**A7. Inno Setup over MSIX.** MSIX must be signed by a certificate the machine
trusts. Self-signed makes every user install the certificate by hand, which
defeats an update that needs no manual step; the ways out are a purchased
certificate or a Store submission, and neither fits an unattended daily build.
It also makes the install directory
read-only and virtualises writes under `%LOCALAPPDATA%`, which is where the
release log lives (§2.11). *Rejected: MSIX, and `.appinstaller` auto-update with
it.* Also rejected: WinSparkle / `auto_updater`, whose native dialogs would sit
badly in the app's own chrome, and which cannot apply an MSIX.

**A8. One tool-less model call over an agent with a shell, for release notes.** The
notes are written inside the job that holds the signing key, from commit text that
anyone who lands a commit on a public repository can influence. A model that can
only return text can only produce bad text, and that text is validated; an agent
with a shell and the repository is a larger thing to trust in that job, and slower
and dearer for a task that needs no exploration. The one thing an agent does well
here — reading a diff to classify a terse commit — is approximated by putting a
short excerpt in the prompt. *Rejected: `claude-code-action` or any agent with
tools; asking the model for finished markdown instead of JSON that a template
renders.*

**A9. The version derived from history, over a stored counter.** The first scheme was the
commit count as the patch, which could not say "a merged PR adds to the minor" or take
an override. Rejected: a bot that commits a bumped version back to `main` on each merge
(noise, a race between two merges, and a push that needs its own permissions), and an
override held in a repository variable or a dispatch input, which lives outside the
reviewed history: a later computed version could then fall below the override and the
app, which installs only a higher one, would stop offering updates. *Rejected: bump
commits, variables, dispatch-time overrides.*

**A10. The app runs the update, on a click, over a signed manifest.** Rejected:
installing without asking, on exit or on the next launch — the installer closes
the app, and doing that unprompted is exactly the interruption the updater must
never cause. A modal "update available" dialog, for the same reason. A feed URL,
key or asset prefix that can be changed at runtime (a setting, an environment
variable, a file): that would make whoever can write it a trust root, so the
test overrides are compile-time defines that a release build ignores. Verifying
a re-encoded manifest instead of the bytes served, which would make the
signature depend on a JSON encoder agreeing with Node's. Starting the installer
with `Process.start(detached)`: it stays in the launcher's job and is killed
when the app exits (§2.14). `JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK` on the
launcher's job instead of an explicit breakaway: every child would escape, the
sidecar included, and the job exists to take it down. A separate https check
beside the prefix: two rules that must agree are one rule that can drift.
*Rejected: silent auto-install, modal prompts, runtime-configurable trust,
re-encoded verification, detached `Process.start`, silent breakaway.*

**A11. yt-dlp: hash comparison over version/tag chasing, the app as the only
writer of its own copy.** Comparing the installed file's SHA-256 against
`SHA2-256SUMS`'s answers "does this need a refresh" with data already fetched
for verification; resolving `releases/latest`'s redirect to read a tag out of
the URL would be a second round trip for a fact the first one already implies.
*Rejected: parsing the release tag to decide whether to refresh.* PGP
verification runs through `dart_pg`, a pure-Dart OpenPGP implementation,
matching the updater's own pure-Dart Ed25519 choice — no platform plugin
between the app and the bytes it is checking. *Rejected: an FFI-based OpenPGP
library, or shelling out to `gpg` (which the target machine may not have).*
The installer is the only writer of `YtDlpConsent`; the app never writes it
back, even to reconcile a value a silent update's task-default reset —
`ytdlp_choice` in `shared_preferences` is the only state that matters once it
exists, and giving the registry a second writer would make two things capable
of being "the" answer. *Rejected: the app re-syncing the registry key.*
