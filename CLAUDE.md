# CLAUDE.md

Native Windows YouTube client. Flutter UI + libmpv playback, backed by a
headless Node/Bun sidecar that talks to YouTube's private InnerTube API.
No browser engine renders any part of the UI.

Read `docs/architecture.md` and `docs/protocol.md` before writing code. They are
decisions-only; rejected alternatives are fenced in an appendix. **Do not revive
a rejected alternative** — if one looks necessary, say so and stop.

---

## Hard invariants

Violating any of these produces bugs that are silent, not loud. That is why
they are listed first.

1. **Never use youtubei.js typed accessors.** No `getHomeFeed()`, `.videos`,
   `.getContinuation()`, no `Parser` classes. Every InnerTube call uses
   `parse: false`. youtubei.js is a session/auth/decipher layer only. Measured:
   its strict type whitelist silently drops live feed content.

2. **Never let an undeciphered URL cross the RPC boundary.** Enforce with a
   branded `SignedUrl` type constructible only by the decipher path. An
   unsigned `n` throttles to ~50 KB/s and presents as a bad network connection.

3. **stdout is protocol only.** All logging to stderr. One stray `console.log`
   corrupts the NDJSON stream. Add a lint rule.

4. **The parser never throws on an unknown renderer.** Skip the item, log the
   type, continue. One unrecognised node must never fail a request.

5. **Never trust `logged_in`.** It reflects cookie presence, not server
   acceptance. A degraded session returns HTTP 200 with an empty feed. Use
   `auth.verify` (fetch home, count tiles, zero = degraded).

6. **Renderer trees never leave the sidecar.** The sidecar walks the messy
   nested JSON in V8 — which is built for it — and emits flat typed DTOs.
   Flutter models stay dumb. See below.

7. **Raw `/player` calls require `signatureTimestamp`.** Without it YouTube
   returns `UNPLAYABLE — "The page needs to be reloaded."`, which reads like a
   dead or region-locked video and is not.

8. **Option acceptance is not evidence of option support. Scan the binary.**
   media_kit's libmpv accepts `stream-lavf-o=request_size=…`, returns success,
   and echoes it back when you read the property — while ignoring it entirely,
   because its FFmpeg has no such AVOption. Anything that probes a media stack at
   runtime is reading a false positive. Only the artefact's own string table is
   evidence, and it has to be the artefact the build actually downloads.

9. **Never poll `NativePlayer.getProperty` from the UI isolate.** It is a
      blocking FFI call that can sit on mpv's core lock and stall the Flutter
      frame loop for seconds during a seek (F15). Use media_kit's event
      streams — `player.stream.position`, `.duration`, `.buffering` — for
      anything the UI renders. Direct property reads are for diagnostics
      only, off the UI isolate.

---

## The flat DTO contract

This is the real boundary between the two processes. Every list method
(`feed.*`, `search.query`, `playlist.get`, `video.related`) returns items in
these shapes and no others.

```ts
type FeedItem = VideoItem | MixItem | PlaylistItem | ChannelItem;

interface VideoItem {
  kind: 'video';
  id: string;
  title: string;
  channelName: string;
  channelId: string | null;
  channelAvatarUrl: string | null;
  thumbnailUrl: string;
  durationSeconds: number | null;   // null when live
  isLive: boolean;
  viewCountText: string | null;     // display string, not parsed
  publishedText: string | null;
  badges: string[];                 // "4K", "New", "Members only"
  canWatchLater: boolean;
  canAddToQueue: boolean;
}

interface MixItem {
  kind: 'mix';
  id: string;                       // RD… playlist id
  title: string;
  subtitle: string | null;
  thumbnailUrl: string;
  videoCount: number | null;
}

interface PlaylistItem { kind: 'playlist'; id: string; title: string;
  thumbnailUrl: string; videoCount: number | null; channelName: string | null; }

interface ChannelItem { kind: 'channel'; id: string; name: string;
  avatarUrl: string; subscriberText: string | null; }

interface Chip {
  label: string;
  token: string;
  selected: boolean;
  scope: 'feed' | 'shelf';          // chipCloudChipRenderer vs ChipsShelfView
}
```

Rules:

- Every field is a value or `null`. Never `undefined`, never omitted, never a
  nested renderer fragment.
- If a field cannot be extracted, set `null` and **still ship the item**. A
  missing view count is not a reason to drop a video.
- `kind` is the only discriminator Flutter switches on.
- Extract IDs by trying `content_id`, `video_id`, `videoId` in that order.
  Never key on a single field name.

## Renderer vocabulary

Both generations interleave *within a single response*, split by item type —
search returns classic `videoRenderer` videos alongside `lockupViewModel`
playlists. Dispatch per tile, never per surface. There is no such thing as a
view-based surface.

| Concern | Classic | View-based |
|---|---|---|
| Video tile | `videoRenderer`, `richItemRenderer`, `playlistVideoRenderer` | `lockupViewModel` |
| Filter bar | `chipCloudChipRenderer` (top level) | `ChipsShelfView` → `ChipView` (shelf) |
| Mix tile | — | `CollectionThumbnailView` + `"Mix"` badge |
| Hover actions | — | `ThumbnailHoverOverlayToggleActionsView` |
| Continuation | `continuationItemRenderer` | `ContinuationItem` |

Shorts are stripped, never rendered.

---

## Layout

```
/sidecar          Node/Bun — InnerTube, parser, RPC
  /src/innertube  session, auth, request execution
  /src/parser     renderer walker + DTO mapping
  /src/rpc        NDJSON transport
  /fixtures       raw captured responses (parse:false) — the test corpus
/app              Flutter
  /lib/domain     freezed models mirroring the DTOs above
  /lib/data       RPC client
  /lib/ui         screens, tiles, player
/docs             architecture.md, protocol.md, tasks/
```

## Commands

```bash
cd sidecar && bun test          # parser tests, offline, no network
cd sidecar && bun run test:network  # live decipher tests — real requests, ~24 MB
cd sidecar && bun run capture   # refresh fixtures (needs YT_COOKIE)
cd sidecar && bun run build     # compile to dist/sidecar.exe — see below
cd app && flutter run -d windows
```

The app prefers `sidecar/dist/sidecar.exe` and falls back to `bun run
src/main.ts` when it is absent, so an unbuilt checkout still runs. The fallback
costs ~6.3 s on first launch: `bun run` transpiles the module graph — youtubei.js
included — on the first import that reaches it, and that lands on the first user
action, not on startup. Rebuild after changing sidecar sources or the fallback is
what you are testing.

---

## Notes that will bite otherwise

- **Cookies rotate.** YouTube invalidates exported cookies when a browser tab
  touches the account. Export from an incognito window parked on
  `youtube.com/robots.txt`, then close it without logging out. Keep main-profile
  YouTube tabs closed while testing.
- **Fixtures must be captured with `parse: false`.** Parsed objects are lossy
  and make a useless corpus.
- **Never mix fixtures across capture runs.** Clear the directory first. A stale
  file once produced a completely wrong reading of the live feed.
- **Fixtures are one moment.** The home feed's renderer mix shifted measurably
  within 8½ hours. Never assert that a given surface contains a given
  generation; search the corpus for wherever it lives.
- **Storyboard hover previews are not video.** Download the sprite sheet and
  shift the image offset with a `CustomPainter` or clipped `Positioned`. Cache
  sheets aggressively in memory or hover lags. Never instantiate a player per
  tile.
- **Browse and resolve are different clients.** Browse and report as `WEB` with
  cookies; resolve streams anonymously, asking as `ANDROID_VR` (ladder tier 1)
  and falling back to `MWEB` (tier 2). Do not attempt to bridge CPNs between
  them — issue two independent calls.
- **The resolution session needs a server-issued visitor id.** `ANDROID_VR`
  refuses a locally fabricated one on ~93% of attempts, with
  `LOGIN_REQUIRED — "Sign in to confirm you're not a bot"`, which reads like an
  age gate and is not. `createSession` fetches a real one by default. Tier 1
  mints a fresh id and retries **once** on any response that is not `OK` with a
  non-empty adaptive ladder — not just on `LOGIN_REQUIRED`, because no one has
  ever seen a server-issued id expire and so nobody knows what shape that
  failure takes. A SABR-only response is not an identity refusal.
- **When `app/pubspec.yaml` is first created**, pin
  `media_kit_libs_windows_video: 1.0.11` exactly (not caret). A bump lands
  modern FFmpeg and reintroduces the F13 seek freeze. See §2.4.
- **`playback.report` is load-bearing.** If watch events stop landing, the
  recommender stops training and the homepage drifts from the real one, which
  defeats the point of the app. Report every 10–30 s plus on state changes.

## Current state

Phase 1: plain `MWEB` URLs, no SABR, no media proxy. Phase 2 (SABR → local DASH
bridge) is specified but **not** to be built speculatively.

Findings in `architecture.md` are dated where they were measured. They are
dated observations, not permanent properties.
