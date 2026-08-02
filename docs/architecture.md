# Architecture — Native Windows YouTube Client

**Status:** Accepted, verified by spike 2026-08-01
**Scope:** Desktop YouTube client for Windows. No browser engine rendering UI.

This document records decisions, not deliberation. Rejected alternatives are in
the appendix so they are not accidentally revived. Every claim in "Verified
findings" was measured, not assumed.

---

## 1. Verified findings

These were established empirically. Do not re-litigate them without re-running
the spike; do not assume they still hold six months from now.

| # | Finding | Evidence |
|---|---|---|
| F1 | `WEB` + cookie auth returns the full personalised home feed | 24 `lockupViewModel`, 54 `richItemRenderer`, 21 `chipCloudChipRenderer`, 1 `continuationItemRenderer` in the raw response |
| F2 | **youtubei.js drops content during parsing.** The raw response has items the typed accessors do not expose | `getHomeFeed().videos` returned 0 against a raw response containing 24 tiles; `ParsingError: Type mismatch, got RelatedChipCloud expected …` |
| F3 | `WEB` player responses are SABR-only, defined over adaptive formats only. `MWEB` still returns plain adaptive URLs — **but not on every request, as of 2026-08-02** | `WEB` → `SABR-ONLY`; `MWEB` → 41 adaptive formats, max 2160p (2026-08-01). **Amended 2026-08-02:** one `MWEB` `/player` response in ~17 live suite runs came back **SABR-only**, while 12/12 controlled calls in the same hour were plain (`ANDROID_VR` was 12/12 plain alongside them). One response, not a flip — but "MWEB still returns plain adaptive URLs" is now a statement about *most* responses rather than all of them, and a bucketed rollout is exactly what this looks like from outside. The live tripwire therefore samples three times per run: **one** SABR-only sample warns and is recorded, **two or more of the three** fails the suite — at that point most requests are SABR-only and tier 2 is effectively gone whatever the third does. Every run is appended to `sidecar/tripwire-mweb-sabr.ndjson` (gitignored, machine-local), because a rollout is a rate and a rate needs the denominator: this sighting was 1 response in ~17, which is indistinguishable from noise without one. **What it costs today: ladder tier 2 only.** Tier 1 is `ANDROID_VR` and is unaffected, which is the whole reason the reorder mattered more than it looked |
| F4 | `MWEB` streams at full speed with the `n` parameter deciphered | itag 315 (VP9 2160p) + itag 258, 4.0 MB/s sustained across 3 runs. **The rate is per-format pacing, not a property of `MWEB`:** F11 measured 4.02 MB/s on the same itag 315 from `ANDROID_VR`, and 2.11 MB/s on itag 401 — each almost exactly 2× realtime for that format's own bitrate. Bounded and open-ended requests come back identical to two decimal places, so request shape costs nothing either. Read F4 as "the deciphered `n` is not throttled", which is all it was ever evidence for |
| F5 | **`ANDROID_VR`'s refusal tracks the visitor id.** A server-issued `X-Goog-Visitor-Id` is sufficient and reliable; a locally-generated one is **unreliable, not rejected outright** | Refines the earlier reading (0 formats on 3 of 4 runs, `PlayerErrorCommand` / `auth_required_command`) on 2026-08-01. Aggregated over every attempt across four runs: server-issued **13/13** `OK` with 28 adaptive formats to 2160p; locally-generated **2/28**; omitted **0/7**. Failures are `LOGIN_REQUIRED / "Sign in to confirm you're not a bot"`. The 2/28 matters — a fabricated id is not categorically refused, it is refused ~93% of the time, which is the same coin-flip the original F5 saw as "3 of 4" and is why one lucky run reads as a fix. Both passes are in the spike corpus (`q1-B-headers-fixed-*.json`, `q1c-tally.json` variant A). `generate_session_locally: true` (what an anonymous session uses) produces a 32-char fabricated id; a `/watch` fetch or `generate_session_locally: false` yields a ~558-char server-issued one. Header spelling is irrelevant: youtubei.js's `X-Youtube-Client-Name: 1` + desktop Chrome UA against a body declaring `ANDROID_VR` is accepted, and correcting all three headers to yt-dlp's values does not rescue a local id (0/14). Cookies are irrelevant (passes with none, fails with a full jar and no visitor id). `TV` was not retested |
| F6 | Watch history reporting from the authenticated `WEB` session lands | 183 history entries readable; target video present after reporting |
| F7 | Cookie sessions degrade **silently** — auth endpoints return empty shells while the client still reports `logged_in: true` | Home + history both returned 0 items with no error, after browser-side cookie rotation |
| F8 | No moving-thumbnail media in the feed. Storyboards are present | 0 mp4/webm URLs; `PlayerStoryboardSpec` with a resolved template URL |
| F9 | A SABR-only `WEB` response still carries a working itag 18 progressive stream | 40/40 adaptive formats have neither URL nor cipher; itag 18 present with a working URL. Confirms the progressive floor is reachable on both clients. **Amended 2026-08-02:** "still carries" is not "always carries" — one live suite run in ~5 got an `MWEB` response with **no progressive format at all**, and tier 5 threw `no progressive format either`. It did not reproduce: 14/14 controlled `MWEB` fetches in the same hour carried itag 18 with an address. Same day, same shape as the F3 sighting and the F11 403 — an anonymous caller intermittently served a degraded response — and in every case tier 1 (`ANDROID_VR`) served normally. The floor is a very good bet, not a guarantee |
| F10 | **`MWEB` stream URLs refuse open-ended range requests; `ANDROID_VR` URLs accept them.** ffmpeg opens every HTTP stream with `Range: bytes=0-`, so a deciphered `MWEB` URL cannot be handed to libmpv directly | `c=MWEB` itag 315: HTTP 403 on `bytes=0-` at offsets 0, 100 MB and 1000 MB; HTTP 206 on `bytes=0-1048575`. `c=ANDROID_VR` itag 401 (via yt-dlp): 206 on both. mpv plays the `ANDROID_VR` URL and 403s on the `MWEB` one. Both URLs carry `rqh=1`, so the client — not that parameter — is the discriminator. Confirmed against ffmpeg's `libavformat/http.c`: the Range header is emitted as `Range: bytes=<off>-` whenever no explicit Range header is set, the request is not a POST, and an offset, end offset, or seekability is in play. Open-ended by construction. `seekable=0` suppresses the header entirely but a bare GET is also refused (403), so it is not a workaround. **Refined 2026-08-01:** bounding the request does not fix it either, it relocates the failure. With `--stream-lavf-o=request_size=1048576` the open succeeds, 1 MB chunks return 206 and mpv plays for ~7 s — then the mid-file seek asks for `Range: bytes=583998372-585046947` and gets **403 on both the video and the audio URL**, ending playback. Reproduced 4/4 across default, 32 MiB, 8 MiB and disabled readahead, so it is the reposition rather than an accumulated-volume ceiling — though with default readahead a purely sequential run also 403s at ~128 MB, matching "the boundary shifted as requests accumulated". `initial_request_size` alone behaves the same |
| F11 | **`ANDROID_VR` URLs clear F10 end to end, but mid-file seeking needs ffmpeg's `request_size`.** The URL was never the obstacle to seeking — ffmpeg was | Measured 2026-08-01 on itag 401 (AV1 2160p60), 315 (VP9 2160p60) and 251. Open-ended `Range: bytes=0-` → **206** at offsets 0, 100 MB and end−5 MB on all three. **Not quite every time, though (2026-08-02):** 2 live suite runs in ~20 saw a **403** to an open-ended range on a URL tier 1 had just resolved normally, and the run captured in full 403'd twice ~200 ms apart — a refusal window rather than an unlucky request. It never reproduced deliberately: **28/28** open-ended requests answered 206 across freshly resolved URLs, URLs that had already served 12 MB, and back-to-back / 1 s / 4 s spacings. **Cause unidentified.** The suite's probe now aborts at the status line instead of cancelling a 712 MB body — that pattern also panicked Bun 1.3.14 twice with `Out of memory while copying request body`, so it was doing more than reading a status — and 12 consecutive live runs have been clean since. Suggestive, not conclusive: at the earlier ~10% rate, 12 clean runs occur by chance about a quarter of the time. The test retries once, five seconds later, on a fresh URL; a *persistent* 403 means F11 has stopped holding. Bare GET, no headers → **200**, not the 403 `MWEB` gives. Sustained over an *open-ended* range: 2.11 MB/s (itag 401), 4.02 MB/s (itag 315), 28 MB/s (audio) — all above the 1.5 MB/s bar. Bounded and open-ended rates are identical to two decimal places, so delivery is paced per format at ~2× realtime rather than penalised by request shape; F4's 4.0 MB/s is that same pacing on that same itag, not a client difference. mpv plays both codecs with audio in sync, and **both hardware-decode here** — Intel Graphics (driver 31.0.101.4953) via `d3d11va`, ~6.2 s CPU across a 40 s run, so the AV1 software-decode risk does not apply on this machine and does not argue for preferring VP9. **Seeking without `request_size` fails 0/4**: ffmpeg never repositions, it soft-seeks — `"Soft-seeking to offset 320812391 by draining 694816224 remaining byte(s)"` — and stalls at the target on one connection, one request. With `--stream-lavf-o=request_size=1048576,short_seek_size=1048576`: **4/4 seeks, forward and backward, both codecs**, playback resuming past every target |
| F12 | **`request_size` is absent from media_kit's bundled libmpv.** Confirmed against the artefact, not the pin | Measured 2026-08-01, **corrected against the real artefact 2026-08-02.** Upstream merged it as `request_size` (with `initial_request_size`), **not** `max_request_size` — that was the mailing-list name and appears nowhere in the tree. Commit by Niklas Haas, Feb 2026: absent from `release/8.0`, present in `release/8.1` and `release/9.0`, so **FFmpeg 8.1 is the floor**. The system mpv used for F10/F11 is v0.41.0-244-gaf9c81fa1 / FFmpeg N-123099-g862338fe3 (libavformat 62.10.101) and has it. **The pin was recorded wrongly.** `20241021` / `0f78584` is the `main` branch of `media-kit/media-kit`, which has never been published. The version a project actually resolves — `media_kit_libs_windows_video` **1.0.11**, latest on pub.dev since 2025-03-24 — downloads `mpv-dev-x86_64-20230924-git-652a1dd.7z` from the **archived** `libmpv-win32-video-build`, tag `2023-09-24`. Archive MD5 `a832ef24…` matches the value in the package's own `windows/CMakeLists.txt`, so the artefact inspected is byte-identical to what CMake fetches at build time. It unpacks to a bare `libmpv-2.dll`: **mpv v0.36.0-403-g652a1dd907, FFmpeg n6.0, libavformat 60.3.100, `MPV_CLIENT_API_VERSION` 2.1** — Sept 2023, ~29 months before the commit, not 16. `request_size` and `initial_request_size` occur **0 times** in its string table; the same scan finds 3 and 1 in both the system mpv and shinchiro 20260610, which is the control that validates the scan. The `main` pin (mpv v0.39.0-179 / FFmpeg N-117622, Lavf 61.9.100, API 2.3) also has **0** — so moving the pin to `main` would not deliver the option either. The Dec 2025 repo activity is `libmpv-win32-**audio**-cmake` (`20251213`); the video repo's newest release is still Oct 2024. **Superseded in effect by F13:** nothing the app does depends on `request_size` |
| F13 | **The shipped libmpv seeks `ANDROID_VR` streams with no options at all. F11's seek failure is an FFmpeg regression, not a property of the stream** | Measured 2026-08-02 through the libmpv **client API** — the C entry points media_kit's FFI binds — driving three real `libmpv-2.dll` artefacts against spike 03's check 4: four seeks 300 → 60 → 500 → 120 s, position asserted **past** target, itag 401 + 251 merged, `vo=gpu`, `hwdec=auto`. mpv v0.36.0-403 / FFmpeg **n6.0**, the build 1.0.11 actually ships: **4/4 with no `stream-lavf-o` whatsoever, reproduced across 5 runs**, and 4/4 on itag 315. mpv v0.39.0-179 / FFmpeg N-117622 (the `main` pin): 4/4 baseline. mpv v0.41.0-744 / FFmpeg N-124930, Lavf 62.19.101 (shinchiro 20260610): **0/4 baseline, reproduced 3/3**, position frozen at exactly 300.0 / 60.0 / 500.0 / 120.0 — F11's signature — and 4/4 once `request_size=1048576,short_seek_size=1048576` is set. The soft-seek regression therefore entered between Lavf 61.9.100 (Oct 2024) and 62.10.101 (Mar 2026); `request_size` is its workaround, not a requirement for `ANDROID_VR`. F11's "0/4 without `request_size`" is correct **for the FFmpeg it was measured on** and does not generalise downward. All runs hardware-decoded via `d3d11va` on both AV1 and VP9, audio track loaded and tracking, 6.6–17.3 s CPU per 40 s run. **Trap worth naming:** the 2023 build *accepts* `stream-lavf-o=request_size=…`, returns success, echoes it back from the property, and ignores it. Option acceptance is not evidence of support — only the binary is |
| F14 | **A server-issued visitor id survives reuse. It is session-scoped, not per-open** | Measured 2026-08-02, the open question spike 03 left behind. One id minted once, then used for `ANDROID_VR` `/player` resolutions in two phases — 10 rounds 5 s apart, then 18 rounds 2 min apart: **28/28 `OK`, 28 adaptive formats to 2160p, over 37.9 minutes**, no degradation and no failure. A freshly minted id was run against the same session in the same minute as a control and also passed 28/28, so nothing here is a rate limit masquerading as an aged id — the failure mode spike 03 spent a whole run chasing. **This is a lower bound: the id never stopped working, so the real lifetime is unmeasured above 38 minutes and 28 uses.** What it settles is the design question — mint at session creation and keep it, rather than paying a round trip per open. A mint costs ~170 ms (`/sw.js_data`, no player, no config), so the `LOGIN_REQUIRED` retry is cheap when it does fire: measured against three deliberately fabricated-id sessions, all three were refused and all three were rescued by one retry. One id, one machine, one video (`aqz-KE-bpKQ`), one session |

**Measurement gap on F13.** It was taken through the libmpv client API against the
real shipped DLL, not through `media_kit` inside a Flutter app — there is no
Flutter SDK, Visual Studio or CMake on the measuring machine, so no Windows
build could be produced. Seeking is decided in ffmpeg's stream/demuxer layer, not
the video output, so `vo=gpu` here versus `vo=libmpv` there should not change it
— but that is reasoning, not evidence. What remains untested is `media_kit`'s
Dart binding and its ANGLE render path, and one video (`aqz-KE-bpKQ`) is one
video.

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

Known-good vocabulary as of 2026-08-01, both generations present simultaneously:

| Concern | Classic | View-based |
|---|---|---|
| Video tile | `videoRenderer`, `richItemRenderer` | `lockupViewModel` (id on `content_id`) |
| Filter bar | `chipCloudChipRenderer` (top level) | `ChipsShelfView` → `ChipView` (shelf-scoped) |
| Mix tile | — | `CollectionThumbnailView` + `"Mix"` badge |
| Hover actions | — | `ThumbnailHoverOverlayToggleActionsView` |
| Continuation | `continuationItemRenderer` | `ContinuationItem` |

Extract IDs by trying `content_id`, `video_id`, `videoId` in order. Never key
on a single field name.

### 2.3 Client model

| Purpose | Client | Auth |
|---|---|---|
| Browse — feed, chips, search, playlists, history | `WEB` | cookies |
| Stream resolution — ladder tier 1 | `ANDROID_VR` | anonymous, server-issued visitor id |
| Stream resolution — ladder tier 2 | `MWEB` | anonymous |
| Watch reporting | `WEB` | cookies |

Per **F6**, playback reporting works from the authenticated `WEB` session using
its own CPN. There is no need to bridge a resolution client's CPN across
clients — issue two independent calls. This removes the cross-client CPN problem
entirely.

The resolution client is chosen per `/player` call, not per session: one
anonymous session serves both tiers, and youtubei.js rewrites `context.client`
to the named client before sending. What that session must carry is a
server-issued visitor id — **F5** puts `ANDROID_VR` at 13/13 with one and 2/28
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

- **`ANDROID_VR` is ladder tier 1.** F10 is a property of `c=MWEB` URLs, not of
  YouTube: `ANDROID_VR` URLs answer ffmpeg's open-ended `Range: bytes=0-` with
  206 at every offset, answer a bare GET with 200, sustain well above the bar,
  and carry no `n` to decipher (**F11**). `MWEB` stays tier 2 — F10 constrains
  how its URLs can be *consumed*, not whether they resolve, and it is the only
  client with a proven decipher path.
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
  removes it as stale. **Not yet applied: no `app/` exists** (**F12** for what
  1.0.11 actually ships; the package has not published since March 2025, so
  nothing is being forgone).

Report watch events on a real cadence, not once at completion. A single
end-of-video ping is a weak training signal, and homepage fidelity is the
product requirement.

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

### 2.6 Hover previews

Per **F8**, feed responses carry no preview video. Use storyboard sprite sheets
from the player response, animated on hover. One shared preview surface, ~400 ms
hover delay. Never instantiate a player per tile.

Tile action buttons (Watch Later, Add to queue) come from
`ThumbnailHoverOverlayToggleActionsView` and the associated
`AddToPlaylistCommand` / `PlaylistEditEndpoint` in the feed payload.

---

## 3. Phasing

**Phase 1 — plain URLs.** Browse as `WEB`, resolve as `ANDROID_VR` with `MWEB`
behind it, hand mpv two URLs. No SABR, no manifest generation, no media proxy.
This is the current build target.

**Phase 2 — SABR → local DASH bridge.** Required when `MWEB` goes SABR-only, as
`WEB` already has. The sidecar manages the SABR session via `googlevideo`'s
`SabrStreamingAdapter` and exposes a generated `.mpd` plus segment endpoints on
loopback, so mpv sees standard DASH. Segment-granular, never byte-range.

Do not build Phase 2 speculatively. Do keep the `playback.open` contract
identical across both so the swap touches only the transport.

---

## 4. Failure modes to design for

| Trigger | Symptom | Response |
|---|---|---|
| Cookie rotation | Empty feed, `logged_in: true` | `auth.verify` fails → re-auth prompt |
| `MWEB` goes SABR-only | `adaptive_formats` all lack `url` | Phase 2, or yt-dlp fallback |
| New renderer type | Items silently missing | Tolerant parser skips; log unknown types |
| Undeciphered `n` | ~50 KB/s, constant buffering | Never let a raw URL cross the RPC boundary |
| Age-restricted / Vevo | `playback.open` fails | Fall through to yt-dlp with PO token provider |
| `yt-dlp` not installed | Ladder is four rungs; the videos tier 4 exists for fail as "Unavailable" with nothing naming the cause | Probed and warned at startup, and reported in the `event.ready` handshake as `capabilities.ytDlp` (`protocol.md` §2) |
| ffmpeg opens with `Range: bytes=0-` | HTTP 403 on an `MWEB` URL that fetches fine under a bounded range | Resolve as `ANDROID_VR` — ladder tier 1, whose URLs answer 206 at every offset (F11). `MWEB` remains tier 2; F10 constrains consumption, not resolution |
| The visitor id stops convincing YouTube | `LOGIN_REQUIRED`, or some other status, or `OK` with an empty adaptive ladder — nobody has observed an expired id, so the shape is unknown (F14) | Mint a fresh server-issued id and retry once on **any** non-`OK` or empty-ladder tier-1 response, then decline to tier 2. Gating on `LOGIN_REQUIRED` alone would let an unknown expiry shape stop resolution silently |
| A libmpv pin bump lands modern FFmpeg | Playback looks perfect until the first seek, then freezes at the target with nothing logged | `stream-lavf-o=request_size=1048576` is set unconditionally (F11, F13); the exact pin that would keep the bump from arriving unnoticed is specified in §2.4 and waits on `app/` existing |

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
