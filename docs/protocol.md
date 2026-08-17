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

`premiereAtMs` is on every `VideoItem` (unix ms, null for anything already
published) so a card can offer a reminder without a `/player` call per tile — a
feed of premieres would otherwise cost one round trip each to discover something
the feed response already said.

`chips[]` merges both generations: top-level `chipCloudChipRenderer` and
shelf-scoped `ChipView`. Each carries `{label, token, selected, scope}` where
`scope` is `'feed' | 'shelf'`.

### 3.3 Video and playlists

| Method | Params | Result |
| --- | --- | --- |
| `video.info` | `{videoId}` | `VideoDetail` |
| `video.storyboard` | `{videoId}` | `{storyboard}` — §3.7 |
| `video.related` | `{videoId, continuation?}` | `{items[], continuation?}` |
| `video.comments` | `{videoId, continuation?}` | `{items[], continuation?}` |
| `playlist.get` | `{playlistId, continuation?}` | `{items[], continuation?}` |
| `mix.start` | `{videoId}` | `{playlistId, items[], continuation?}` |
| `search.query` | `{q, continuation?}` | `{items[], continuation?}` |
| `search.suggest` | `{q}` | `{suggestions[]}` |

Mixes are `RD*` radio playlists that auto-extend; fetch the continuation as the
user nears the end. Same code path as queue autoplay.

**`video.info` composes two responses.** `/next` carries the watch page but no
duration — `lengthSeconds` is only on `/player` — so it fetches both. The
`/player` half asks as **`ANDROID_VR` over the anonymous resolve session**, which
is the same client and the same cached response ladder tier 1 uses, so opening a
video costs **one** `/player` call rather than two. Reading a length out of a
response already fetched is not the cross-client CPN bridging A5 rejects; nothing
is carried across. `/next` stays on the authenticated `WEB` session, because a
personalised sidebar, the like count and subscription state are what the cookie
is for.

### 3.4 Actions

| Method | Params |
| --- | --- |
| `action.addToWatchLater` | `{videoId}` |
| `action.addToPlaylist` | `{videoId, playlistId}` |
| `action.like` / `action.dislike` | `{videoId}` |
| `action.subscribe` | `{channelId}` |

All execute against the authenticated `WEB` session.

**The surface is write-only, for now, and three pieces of UI are shaped around that.**
Nothing here, for now, reads state back, nothing undoes, and nothing enumerates:

| Missing | What the UI does instead |
| --- | --- |
| No way to ask whether a video is *already* in Watch Later | The pill means "you saved it just now", never "is saved" — it starts unlatched on every video, including ones saved last week |
| No inverse for `action.addToWatchLater` | A latched pill says removing is not wired up rather than quietly re-adding |
| No `playlist.list` (only `playlist.get`, for a playlist you can already name) | The save dialog ships one real row and placeholders, with a line saying so |

When these land, all three should be revisited together — they are one gap, and
each workaround is a lie the UI is currently telling carefully. `videoDetail`
gaining `inWatchLater` / `playlistIds` would settle the first, an
`action.removeFromWatchLater` the second, a `playlist.list` the third.

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
      "itag": 401,             // null for the yt-dlp fallback tier
      "height": 2160,
      "fps": 60,
      "videoCodec": "av01",
      "audioCodec": "opus"
    },
    {
      "videoUrl": "https://…", // Phase 2: http://127.0.0.1:PORT/…manifest.mpd
      "audioUrl": "https://…", // Phase 2: null (multiplexed in the manifest)
      "itag": 399,             // null for the yt-dlp fallback tier
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

`state` is one of `playing` | `paused` | `buffering` | `ended`, and a malformed
one is `BAD_REQUEST`. A closed set rather than a free string because the failure
mode of a typo here is silent: the stats endpoint answers 200 to nonsense, so a
client reporting `"Playing"` forever would look healthy from every angle except
the homepage slowly ceasing to resemble the account.

`sessionId` is the one a **non-preload** `playback.open` returned. A preload
opens no session (§3.6), so its `sessionId` is not reportable — a preloaded item
that is never played must not appear in anyone's history. Reporting against an
unknown or closed session is `BAD_REQUEST`.

The report itself goes out over the authenticated `WEB` session with a CPN of the
sidecar's own, one per session (F6, and A5 which rejects bridging a resolution
client's CPN). That needs a `WEB` `/player` response for its playback-tracking
URLs — the `ei`/`of`/`vm` parameters on them are minted for the request that
produced them, so the anonymous resolution response's URLs are not a substitute.
It is fetched on the first report and cached for the whole watch: one extra call
per video actually watched, and none for a video merely opened.

**Never let a raw URL cross this boundary.** An undeciphered `n` parameter
throttles to ~50 KB/s and presents as a network problem. Enforce with a branded
`SignedUrl` type that only the decipher path can construct.

### 3.6 Preloading

`playback.open {preload: true}` resolves and caches without opening a session.
Use for the next queue item so transitions are instant.

### 3.7 Hover previews

**Revised 2026-08-11.** A hover preview is **the real video, muted, played in
the tile** — see `architecture.md` §2.6 for the decision and what it replaced.
It needs no method of its own: it is `playback.open` and `playback.report`, used
in a particular way, and that is the whole point of specifying it here.

**Resolving is `playback.open {preload: true}`.** §3.6's preload resolves and
caches *without opening a session*, and §3.5 says a preload's `sessionId` is not
reportable — a report against one is `BAD_REQUEST`. That is exactly the property
a hover needs, and it is why the preview does not simply open normally and
decline to report: it makes **"a hover is not a watch" structural** rather than a
rule someone has to keep remembering, so no amount of pointer traffic can put a
video the user never chose into their history.

**Past 30 s a preview stops being a preview.** The point of playing video in the
feed is that it is watching, and a watch that never reports is one the
recommender never learns from — the exact failure `playback.report` exists to
prevent, and one that would make the homepage drift further from the account the
more the feature is used. So past the threshold the client opens a **second,
non-preload** `playback.open` for the same video and reports against that session
on the ordinary §3.5 cadence. The `/player` response is already cached from the
preload, so this costs one RPC round trip and no request to YouTube.

Below the threshold nothing is reported at all. Thirty seconds is long enough
that a pointer resting on a tile while the user reads something else is not a
view, and short enough that anything deliberate is one.

**A preview that reaches the end of the video reports `ended`**, not `paused`,
before closing its session — a video watched through is a much stronger signal
than one the viewer walked away from, and the difference is invisible from every
angle except the homepage slowly ceasing to resemble the account. A preview that
never crossed the threshold reports nothing when it ends, the same as when the
pointer leaves.

**The client picks a low variant.** `variants` arrives ranked best-first and
§3.5 leaves the choice to the client; a preview takes the best entry at or under
720p. F16 measured 2160p60 dropping 16–29% of frames on an Intel iGPU for the
video the user actually chose, at full size — a thumbnail-sized preview has
neither that budget nor that justification.

#### `video.storyboard` — the scrubber's input, currently unused

```jsonc
// video.storyboard {videoId} → one fetchable sprite sheet, or null
{
  "storyboard": {
    "url": "https://i.ytimg.com/sb/…/storyboard3_L0/default.jpg?sqp=…&sigh=rs$…",
    "columns": 10,
    "rows": 10,
    "frameCount": 100,   // ≤ columns × rows; trailing cells may hold no frame
    "frameWidth": 48,
    "frameHeight": 27,
    "intervalMs": 6350,  // video time per frame — NOT a playback cadence
    "level": 0           // the $L this came from; telemetry
  }
}
```

**Nothing calls this yet.** It was built for hover previews, which now play
video; it is kept for the **scrubber**, where showing one frame at a pointer
position is what its ~6 s frame spacing is actually good for. It is documented
rather than deleted because the substitution below was measured against real
responses and verified by fetching, and re-deriving it from the shape would be
expensive.

It reads one field out of the **`ANDROID_VR` `/player` response that
`video.info` and ladder tier 1 already share** (§3.3), so it opens no session,
resolves no stream, and needs no PO token.

**`storyboard: null` is an ordinary answer, not a failure.** YouTube does not
build sheets for everything — `jNQXAC9IVRw` (19 s) carries zero levels on both
clients, measured 2026-08-11, and so does `uQ0LGwPBC2c` in the live feed. That
unpredictability is also why sprites are not a hover-preview fallback: they are
missing exactly when they would be needed.

**Exactly one sheet, always.** The sidecar picks the largest zoom level whose
entire frame set fits a single sheet and substitutes every placeholder — `$L`
(level), `$N` (the level's name field) and `$M` (sheet index) — so `url` is
fetchable as-is and the client constructs no URLs.

Three things about that URL are not obvious and are all load-bearing:

- **`sqp` and `sigh` are both required.** Dropping either answers HTTP 403.
- **The response is not necessarily JPEG.** The path ends `.jpg`, but `sqp` is a
  transcode request: the same video's level 0 came back `image/webp` on
  2026-08-01 and `image/jpeg` on 2026-08-11. Decode by content, never by
  extension.
- **They are long-lived.** URLs captured 2026-08-01 still fetched on 2026-08-11.
  The sidecar caches the resolved spec for 6 hours; it cannot "re-sign" one,
  because `sqp` and `sigh` are minted inside the `/player` response and
  re-signing would mean re-resolving.

**`intervalMs` is what a frame *represents*, not how fast to show it.** Level 0
spreads a fixed frame count across the whole runtime, so a 10-minute video puts
6.35 s behind every frame.

---

## 4. Errors

`retry` is a three-valued field, not a boolean. "Retryable" collapsed two
different instructions — *the sidecar should try again* and *the user should be
allowed to try again* — and the difference is the whole UI contract.

| Value | Meaning |
| --- | --- |
| `auto` | **The app** retries with backoff; the sidecar reports and does not retry. The app shows a loading state, not an error |
| `user` | Do **not** retry silently. Show the error with a retry affordance and let the user decide |
| `no` | Retrying changes nothing until something external changes — a login, a cookie, a policy |

**`auto` retry belongs to the app, not the sidecar.** This is the one place the
obvious division of labour is the wrong one — the sidecar is closer to the
failure, so it looks like the natural place to retry, and it is not.

A sidecar-side retry cannot be superseded. Switch chip filters while the sidecar
is on attempt 3 of 4 and it keeps working on a request nobody wants, holding a
slot and spending requests on a filter the user has already left. `$cancel`
arrives while it is asleep between attempts, and the retry loop is not listening.

The app already has both mechanisms this needs. `$cancel` releases the sidecar,
and the generation counter drops any answer that arrives for a superseded
request — so a retry scheduled by the controller is cancelled by the same thing
that cancels everything else, for free, rather than needing a second cancellation
path plumbed through the sidecar's retry loop to reach it.

So: the sidecar answers once, with an envelope whose `retry` says what kind of
failure it is. Deciding what to do about it is the caller's, because only the
caller knows whether anyone still wants the answer.

This governs *envelope-level* retry — answering a request that already failed. It
says nothing about a tier retrying inside a single call before there is an answer
at all, which stays the sidecar's business: tier 1 minting a fresh visitor id and
retrying once (§3.5) is not covered here and must not be removed on the strength
of this rule.

**Envelope errors.** These are what a failure envelope carries, and every one of
them has a `retry` value:

| Code | `retry` | UI response |
| --- | --- | --- |
| `AUTH_DEGRADED` | `no` | Re-authentication prompt |
| `AUTH_REQUIRED` | `no` | Login flow |
| `BAD_REQUEST` | `no` | This is a client bug. Surface it — never retry, never swallow |
| `STREAM_UNAVAILABLE` | `user` | "Unavailable" state on the video, with a retry affordance |
| `VIDEO_UPCOMING` | `no` | The premiere slate: thumbnail, scheduled time, reminder. **Not** an error state |
| `RATE_LIMITED` | `auto` | App backs off and retries silently |
| `UPSTREAM_ERROR` | `auto` | App backs off and retries silently |

**`BAD_REQUEST` is for an unknown method or params that fail validation** — the
request was malformed before anything upstream was asked. It is `no` because
retrying is *provably* pointless: the same bytes will fail the same way forever.
That is the one case where `no` is a certainty rather than a judgement.

It exists because the alternative was worse. A malformed request used to answer
`UPSTREAM_ERROR`, which is `auto`, so the app dutifully backed off and retried a
request that could never succeed — four attempts before it degraded to `user`.
Bounded, but each of those attempts is a client bug being hidden by a spinner.

Keep `UPSTREAM_ERROR` for genuine upstream failures: YouTube answered badly, or
did not answer. If the sidecar rejected the request itself, it is `BAD_REQUEST`.

**`VIDEO_UPCOMING` is not a failure wearing an error envelope.** A premiere is a
video that exists, is fine, and has a start time; no rung of the ladder will ever
resolve one, so it terminates the ladder rather than declining down it — four
further `/player` calls to reach "every tier declined" would be slower and wrong.
It is `no` because retrying cannot beat a clock, and that is the one case where
`no` is a statement about arithmetic rather than about policy. The UI obligation
is the opposite of `STREAM_UNAVAILABLE`'s: **do not offer a retry**, show the
scheduled time and a reminder. It arrives with YouTube's own prose as its message
("Premieres in 9 days"), which is enough to render the slate before `video.info`
answers; the machine-readable time is `VideoDetail.premiereAtMs` (§3.3), on a
call the watch page already makes.

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

**Hover previews open no session while they are previews** (§3.7). They resolve
through `playback.open {preload: true}`, which §3.6 defines as resolving and
caching without registering one — so a pointer sweeping a grid cannot consume the
cap above, and a preload's `sessionId` is not reportable.

A preview that runs past 30 s is no longer a preview and does open one, exactly
like any other watch. That is the only path from a hover to a session, and it is
deliberate rather than incidental: reaching it takes a video playing in a tile
for half a minute.

`video.storyboard` (§3.7) opens no session either, and the registry staying empty
across a call is asserted live rather than left as a claim about the code.

---

## 6. Supervision

- Sidecar dies → the app restarts it with backoff, fails in-flight requests with
  `retry: "auto"`, replays auth
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
