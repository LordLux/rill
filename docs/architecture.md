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
| F3 | `WEB` player responses are SABR-only, defined over adaptive formats only. `MWEB` still returns plain adaptive URLs | `WEB` → `SABR-ONLY`; `MWEB` → 41 adaptive formats, max 2160p |
| F4 | `MWEB` streams at full speed with the `n` parameter deciphered | itag 315 (VP9 2160p) + itag 258, 4.0 MB/s sustained across 3 runs |
| F5 | `ANDROID_VR` and `TV` are being actively refused with youtubei.js's default request shape | 0 formats on 3 of 4 runs; `PlayerErrorCommand` carrying `auth_required_command`. yt-dlp resolves `ANDROID_VR` successfully for the same videos (tier 3, verified 2026-08-01), so this describes our request construction rather than the client being refused |
| F6 | Watch history reporting from the authenticated `WEB` session lands | 183 history entries readable; target video present after reporting |
| F7 | Cookie sessions degrade **silently** — auth endpoints return empty shells while the client still reports `logged_in: true` | Home + history both returned 0 items with no error, after browser-side cookie rotation |
| F8 | No moving-thumbnail media in the feed. Storyboards are present | 0 mp4/webm URLs; `PlayerStoryboardSpec` with a resolved template URL |
| F9 | A SABR-only `WEB` response still carries a working itag 18 progressive stream | 40/40 adaptive formats have neither URL nor cipher; itag 18 present with a working URL. Confirms ladder tier 4 is reachable on both clients |
| F10 | **`MWEB` stream URLs refuse open-ended range requests; `ANDROID_VR` URLs accept them.** ffmpeg opens every HTTP stream with `Range: bytes=0-`, so a deciphered `MWEB` URL cannot be handed to libmpv directly | `c=MWEB` itag 315: HTTP 403 on `bytes=0-` at offsets 0, 100 MB and 1000 MB; HTTP 206 on `bytes=0-1048575`. `c=ANDROID_VR` itag 401 (via yt-dlp): 206 on both. mpv plays the `ANDROID_VR` URL and 403s on the `MWEB` one. Both URLs carry `rqh=1`, so the client — not that parameter — is the discriminator. Confirmed against ffmpeg's `libavformat/http.c`: the Range header is emitted as `Range: bytes=<off>-` whenever no explicit Range header is set, the request is not a POST, and an offset, end offset, or seekability is in play. Open-ended by construction. `seekable=0` suppresses the header entirely but a bare GET is also refused (403), so it is not a workaround |

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

### 2.3 Two-client model

| Purpose | Client | Auth |
|---|---|---|
| Browse — feed, chips, search, playlists, history | `WEB` | cookies |
| Stream resolution | `MWEB` | anonymous |
| Watch reporting | `WEB` | cookies |

Per **F6**, playback reporting works from the authenticated `WEB` session using
its own CPN. There is no need to bridge the `MWEB` CPN across clients — issue
two independent calls. This removes the cross-client CPN problem entirely.

### 2.4 Playback

media_kit (libmpv) receives two deciphered URLs — video and audio — and merges
them via `--audio-file`. No local media proxy in Phase 1.

**F10 leaves the last step of this open.** libmpv cannot consume an `MWEB` URL
directly: ffmpeg's initial open is an open-ended range request, and `c=MWEB`
answers those with 403. Deciphering is not the problem — the same URL streams at
4.0 MB/s under a bounded range. Closing this needs a decision that has not been
made: a different playback client, yt-dlp promoted from ladder tier 3 to the
primary path, or a chunking proxy — which is adjacent to rejected alternative A6
and must not be revived without re-opening it deliberately.

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

**Phase 1 — plain URLs.** Browse as `WEB`, resolve as `MWEB`, hand mpv two
signed URLs. No SABR, no manifest generation, no media proxy. This is the
current build target.

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
| ffmpeg opens with `Range: bytes=0-` | HTTP 403 on an `MWEB` URL that fetches fine under a bounded range | Undecided — see F10 and §2.4 |

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
