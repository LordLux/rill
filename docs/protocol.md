# Protocol — Flutter ↔ Sidecar

**Status:** Accepted, 2026-08-01
**Transport:** NDJSON over stdio (control) + loopback HTTP (media, Phase 2 only)

Phase 1 needs no media channel — the sidecar returns signed URLs that mpv
fetches directly. The HTTP server is specified here so Phase 2 does not require
a protocol revision.

---

## 1. Transport

**Control — stdio.** One JSON object per line, UTF-8, `\n`-terminated. No port,
no firewall prompt, no local auth surface, and process lifetime is bound to the
parent.

> **stdout is protocol only.** All logging goes to stderr. A single stray
> `console.log` corrupts the stream. Enforce this with a lint rule.

**Media — loopback HTTP (Phase 2).** Random port bound explicitly to
`127.0.0.1`, reported via `event.ready`. Requests carry a per-session token;
any local process can reach loopback.

---

## 2. Envelope

JSON-RPC 2.0 in shape, without batching.

```jsonc
// request
{"id": 42, "method": "feed.home", "params": {"chipToken": "..."}}

// success
{"id": 42, "result": {"chips": [], "items": [], "continuation": "..."}}

// failure
{"id": 42, "error": {"code": "AUTH_DEGRADED", "message": "...", "retryable": true}}

// unsolicited
{"method": "event.authChanged", "params": {"state": "degraded"}}
```

`id` correlation is mandatory — feed loads, previews and search race constantly.

**Cancellation.** `{"method": "$cancel", "params": {"id": 42}}` maps to an
`AbortController`. Without it, fast scrolling stacks up dead continuation
requests.

**Handshake.** The sidecar emits `event.ready` with `protocolVersion` before
accepting requests. Mismatched versions fail fast rather than misbehaving.

---

## 3. Methods

### 3.1 Auth

| Method | Params | Result |
|---|---|---|
| `auth.status` | — | `{state, accountName?}` |
| `auth.verify` | — | `{state, tileCount}` |
| `auth.setCookie` | `{cookie}` | `{state}` |
| `auth.signOut` | — | `{}` |

`state` ∈ `authenticated` \| `degraded` \| `anonymous`.

**`auth.verify` is not optional.** A degraded session returns HTTP 200 with an
empty feed and no error. Verify by fetching home and counting tiles: zero means
degraded. Run on startup and after any empty feed. Never trust a `logged_in`
flag derived from cookie presence.

### 3.2 Feeds

| Method | Params | Result |
|---|---|---|
| `feed.home` | `{chipToken?, continuation?}` | `{chips[], items[], continuation?}` |
| `feed.subscriptions` | `{continuation?}` | `{items[], continuation?}` |
| `feed.watchLater` | `{continuation?}` | `{items[], continuation?}` |
| `feed.history` | `{continuation?}` | `{items[], continuation?}` |

`continuation` is a parameter on every list method rather than a separate
`*.more` method — first page and infinite scroll share one path, and chips are
just a different token into the same call.

`chips[]` merges both generations: top-level `chipCloudChipRenderer` and
shelf-scoped `ChipView`. Each carries `{label, token, selected}`.

### 3.3 Video and playlists

| Method | Params | Result |
|---|---|---|
| `video.info` | `{videoId}` | `VideoDetail` |
| `video.related` | `{videoId, continuation?}` | `{items[], continuation?}` |
| `video.comments` | `{videoId, continuation?}` | `{items[], continuation?}` |
| `playlist.get` | `{playlistId, continuation?}` | `{items[], continuation?}` |
| `mix.start` | `{videoId}` | `{playlistId, items[], continuation?}` |
| `search.query` | `{q, continuation?}` | `{items[], continuation?}` |
| `search.suggest` | `{q}` | `{suggestions[]}` |

Mixes are `RD*` radio playlists that auto-extend; fetch the continuation as the
user nears the end. Same code path as queue autoplay.

### 3.4 Actions

| Method | Params |
|---|---|
| `action.addToWatchLater` | `{videoId}` |
| `action.addToPlaylist` | `{videoId, playlistId}` |
| `action.like` / `action.dislike` | `{videoId}` |
| `action.subscribe` | `{channelId}` |

All execute against the authenticated `WEB` session.

### 3.5 Playback

| Method | Params | Result |
|---|---|---|
| `playback.open` | `{videoId, preload?}` | `PlaybackSource` |
| `playback.report` | `{sessionId, positionMs, state}` | `{}` |
| `playback.close` | `{sessionId}` | `{}` |

```jsonc
// PlaybackSource — identical in Phase 1 and Phase 2
{
  "sessionId": "…",
  "videoUrl": "https://…",       // Phase 2: http://127.0.0.1:PORT/s/…/manifest.mpd
  "audioUrl": "https://…",       // Phase 2: null (multiplexed in the manifest)
  "durationMs": 634000,
  "videoCodec": "vp9",
  "audioCodec": "mp4a.40.2",
  "height": 2160,
  "storyboardTemplate": "https://…",
  "qualityDegraded": false,
  "transport": "plain"           // "plain" | "sabr-dash" | "ytdlp"
}
```

Flutter never learns which tier served the request. `transport` is telemetry;
`qualityDegraded` drives a badge, never a dead end.

**Resolution ladder**, tried in order inside `playback.open`:

1. `MWEB` plain adaptive URLs — the Phase 1 path
2. SABR → local DASH bridge — Phase 2
3. `yt-dlp` subprocess with PO token provider — age-restricted, Vevo, edge cases
4. itag 18 progressive, 360p — always works, sets `qualityDegraded`

**`playback.report` is load-bearing.** Watch events must land or the recommender
stops training and the homepage drifts from the real one — which defeats the
product's premise. Report on a real cadence (every 10–30 s plus state changes),
not once at completion.

**Never let a raw URL cross this boundary.** An undeciphered `n` parameter
throttles to ~50 KB/s and presents as a network problem. Enforce with a branded
`SignedUrl` type that only the decipher path can construct.

### 3.6 Preloading

`playback.open {preload: true}` resolves and caches without opening a session.
Use for the next queue item so transitions are instant.

---

## 4. Errors

| Code | Retryable | UI response |
|---|---|---|
| `AUTH_DEGRADED` | no | Re-authentication prompt |
| `AUTH_REQUIRED` | no | Login flow |
| `STREAM_UNAVAILABLE` | no | "Unavailable" state on the video |
| `STREAM_REQUIRES_SABR` | internal | Ladder falls through; never surfaced |
| `RATE_LIMITED` | yes | Backoff, retry silently |
| `PARSE_FAILED` | — | Skip the item, log the renderer type |
| `UPSTREAM_ERROR` | yes | Retry with backoff |

`PARSE_FAILED` never fails a whole request. One unknown renderer drops one item.

---

## 5. Sessions (Phase 2)

- TTL plus keepalive, swept server-side so a Flutter crash cannot leak
- Hard cap of 3 concurrent: current, preloaded next, spare
- LRU eviction

Hover previews never open a session — they use storyboard sprites, which need no
session and no PO token.

---

## 6. Supervision

- Sidecar dies → restart with backoff, fail in-flight with `retryable: true`,
  replay auth
- Sidecar watches the parent PID and self-exits, so no orphans on Windows
- Version mismatch at handshake → fail fast

---

## 7. Contract testing

Two languages means schema drift. Record real InnerTube responses into
`fixtures/` and test **both** sides against them — the sidecar's parser and
Flutter's `freezed` models.

Capture fixtures with `parse: false`. Parsed objects are lossy (see F2 in
`architecture.md`) and make a poor corpus. These fixtures are also the only way
to meaningfully test tolerant parsing, since the live feed cannot be pinned.
