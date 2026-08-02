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
{"id": 42, "error": {"code": "AUTH_DEGRADED", "message": "...", "retry": "no"}}

// unsolicited
{"method": "event.authChanged", "params": {"state": "degraded"}}
```

`id` correlation is mandatory — feed loads, previews and search race constantly.

**Cancellation.** `{"method": "$cancel", "params": {"id": 42}}` maps to an
`AbortController`. Without it, fast scrolling stacks up dead continuation
requests.

**Handshake.** The sidecar emits `event.ready` before accepting requests.
Mismatched versions fail fast rather than misbehaving.

```jsonc
{"method": "event.ready", "params": {
  "protocolVersion": 1,
  "capabilities": {"ytDlp": false}     // yt-dlp on PATH or at YT_DLP_PATH
}}
```

`capabilities` reports optional pieces of the machine the app cannot discover on
its own. `ytDlp: false` means ladder tier 4 is gone: the ladder is four rungs,
and age-restricted or Vevo videos fail with `STREAM_UNAVAILABLE` and no way for
the UI to say why. The sidecar also warns about it at startup — a missing
fallback that removes a capability without removing anything visible is exactly
the kind of degradation this protocol makes explicit rather than leaving to be
inferred from a video that will not play.

---

## 3. Methods

### 3.1 Auth

| Method | Params | Result |
| --- | --- | --- |
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
| --- | --- | --- |
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
| --- | --- | --- |
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
| --- | --- |
| `action.addToWatchLater` | `{videoId}` |
| `action.addToPlaylist` | `{videoId, playlistId}` |
| `action.like` / `action.dislike` | `{videoId}` |
| `action.subscribe` | `{channelId}` |

All execute against the authenticated `WEB` session.

### 3.5 Playback

| Method | Params | Result |
| --- | --- | --- |
| `playback.open` | `{videoId, preload?}` | `PlaybackSource` |
| `playback.report` | `{sessionId, positionMs, state}` | `{}` |
| `playback.close` | `{sessionId}` | `{}` |

```jsonc
// PlaybackSource — identical in Phase 1 and Phase 2
{
  "sessionId": "…",
  "durationMs": 634000,
  "storyboardTemplate": "https://…",
  "qualityDegraded": false,
  "transport": "plain",            // "plain" | "sabr-dash" | "ytdlp"
  // Ranked best-first. The client picks one and may switch without
  // reopening — all variants come from a single /player response.
  "variants": [
    {
      "videoUrl": "https://…", // Phase 2: http://127.0.0.1:PORT/…manifest.mpd
      "audioUrl": "https://…", // Phase 2: null (multiplexed in the manifest)
      "itag": 401,
      "height": 2160,
      "fps": 60,
      "videoCodec": "av01",
      "audioCodec": "opus"
    },
    {
      "videoUrl": "https://…", // Phase 2: http://127.0.0.1:PORT/…manifest.mpd
      "audioUrl": "https://…", // Phase 2: null (multiplexed in the manifest)
      "itag": 399,
      "height": 1080,
      "fps": 60,
      "videoCodec": "av01",
      "audioCodec": "opus"
    }
  ]
}
```

Quality selection is client-side. The sidecar ranks; it does not choose.
`variants` is ordered best-first and every entry is playable — all are signed
from one `/player` response, so switching costs no round trip. The client
starts at its preferred variant and steps down when sustained frame drops
warrant it (F16: 2160p60 dropped 16–29% of frames on an Intel iGPU while
1080p60 dropped none, so "tallest available" is not "best"). A cap chosen by
the sidecar would be wrong differently on every machine.

Flutter never learns which tier served the request. `transport` is telemetry;
`qualityDegraded` drives a badge, never a dead end.

**Resolution ladder**, tried in order inside `playback.open`:

1. `ANDROID_VR` plain adaptive URLs — the primary path; no `n`, and libmpv can
   consume them directly (F5, F11, F13)
2. `MWEB` plain adaptive URLs — the decipher path, kept as a fallback
3. SABR → local DASH bridge — Phase 2
4. `yt-dlp` subprocess with PO token provider — age-restricted, Vevo, edge cases
5. itag 18 progressive, 360p — the floor: usually present, **not guaranteed**
   (F9); sets `qualityDegraded`

The floor is a very good bet, not a promise. On 2026-08-02 an `MWEB` response
came back carrying no progressive format at all, so every rung can decline and
`playback.open` can answer `STREAM_UNAVAILABLE` for a video that is perfectly
fine. The UI obligation follows from that: **"Unavailable" is a state the user
can retry out of, not a verdict on the video.** That is what `retry: "user"`
means in §4 — show the error, offer the retry, and do not loop silently.

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

`retry` is a three-valued field, not a boolean. "Retryable" collapsed two
different instructions — *the sidecar should try again* and *the user should be
allowed to try again* — and the difference is the whole UI contract.

| Value | Meaning |
| --- | --- |
| `auto` | The sidecar retries with backoff. The app shows a loading state, not an error |
| `user` | Do **not** retry silently. Show the error with a retry affordance and let the user decide |
| `no` | Retrying changes nothing until something external changes — a login, a cookie, a policy |

**Envelope errors.** These are what a failure envelope carries, and every one of
them has a `retry` value:

| Code | `retry` | UI response |
| --- | --- | --- |
| `AUTH_DEGRADED` | `no` | Re-authentication prompt |
| `AUTH_REQUIRED` | `no` | Login flow |
| `STREAM_UNAVAILABLE` | `user` | "Unavailable" state on the video, with a retry affordance |
| `RATE_LIMITED` | `auto` | Backoff, retry silently |
| `UPSTREAM_ERROR` | `auto` | Retry with backoff |

`STREAM_UNAVAILABLE` is `user` rather than `no` because the ladder's floor is a
very good bet and not a promise (§3.5, F9): every rung can decline for a video
that is perfectly fine, and on 2026-08-02 that was observed. It is not `auto`
either — a silent retry loop on a video that really is deleted spends requests
to keep showing a spinner, and hides the honest answer.

**Internal signals.** These are control flow inside the sidecar. They never reach
a failure envelope, so they have no `retry` value — not `no`, which would be a
claim about what the app should do with something the app never sees:

| Code | What it is |
| --- | --- |
| `STREAM_REQUIRES_SABR` | A resolution tier telling the ladder "not my case, keep going". The ladder converts a full set of declines into `STREAM_UNAVAILABLE`; this code reaching Flutter is a bug |
| `PARSE_FAILED` | One unrecognised renderer, skipped. The request still succeeds with the remaining items — it never fails a whole response |

The split is in the types too (`EnvelopeErrorCode` vs `InternalSignalCode`), and
building an envelope from an internal signal throws rather than inventing a
`retry` for it.

---

## 5. Sessions (Phase 2)

- TTL plus keepalive, swept server-side so a Flutter crash cannot leak
- Hard cap of 3 concurrent: current, preloaded next, spare
- LRU eviction

Hover previews never open a session — they use storyboard sprites, which need no
session and no PO token.

---

## 6. Supervision

- Sidecar dies → restart with backoff, fail in-flight with `retry: "auto"`,
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
