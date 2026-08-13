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

10. **A `copyWith` over nullable fields needs a sentinel.** The reflex
    `value ?? this.value` cannot *clear* anything — passing `null` means "leave
    it alone", so a field can be set but never unset, and the call that looks
    like a reset silently isn't one. `FeedState.copyWith` had exactly this:
    `continuation: null` at the start of a fresh load was a no-op, so switching
    chip filters kept the previous filter's continuation and the next page
    would have been paged from the *old* feed. Use
    `Object? field = _unchanged` with an `identical(field, _unchanged)` test.
    The failure is silent in both directions — nothing throws, the field simply
    keeps a value that is now wrong — and it gets rewritten the same wrong way
    in every new controller.

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
  premiereAtMs: number | null;      // unix ms; null unless it is a premiere
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
cd sidecar && bun run check     # typecheck + lint + tests — run before calling it done
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

**A release build carries its own copy, and `bun run build` does not update it.**
`flutter build windows` copies the whole `sidecar/` tree into
`app/build/windows/x64/runner/Release/sidecar/`, and `findSidecarRoot` checks the
directory beside the executable *first* — so a release app runs that copy, not
the one in the repo. Rebuilding the sidecar alone leaves the app on whatever was
current when Flutter last built. This is silent and it wastes whole measurement
runs: a fix verified this way appears not to work, with no error and no clue,
because the code being exercised is the old code. Either re-run
`flutter build windows --release` after `bun run build`, or copy
`sidecar/dist/sidecar.exe` over the bundled one. **Re-running
`flutter build windows --release` is *not* enough** — measured 2026-08-13: the
copy step does not re-run for an already-populated bundle, so the app kept a
sidecar nine hours older than the one just built, with no warning. Copy the
binary over the bundled one **explicitly**, and check it took — `grep` a string
from the new build inside the bundled `.exe` — before trusting any device
measurement. Otherwise the run measures the previous sidecar and says so
nowhere.

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
- **Hover previews are the real video, muted, in the tile** (revised 2026-08-11;
  this note used to say sprite sheets, and `architecture.md` §2.6 records why it
  changed). **Never instantiate a player per tile** — that part is unchanged and
  is the rule that matters: one shared preview player moves between tiles, and it
  is a *second* player from the shell's, because opening media on the shell's
  would destroy a paused video's position. Suppressed while anything is playing,
  ~800 ms delay, 720p cap, muted, and the static thumbnail until the first frame.
  Sprite sheets survive in `storyboard_sheets.dart` and `video.storyboard`, wired
  to nothing, as the scrubber's input: at ~6 s between frames they are good for
  showing one frame at a pointer position and nothing else.
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
- **A premiere is not a broken video.** `playback.open` answers `VIDEO_UPCOMING`
  (`retry: no`) for anything YouTube reports as `LIVE_STREAM_OFFLINE` or
  `isUpcoming`, and that code **ends the ladder** instead of declining down it —
  no lower tier can resolve a stream that has not started. The UI shows the
  thumbnail, the scheduled time and a reminder, never a *Try again*. The time
  itself rides on `VideoItem.premiereAtMs` and `VideoDetail.premiereAtMs`; the
  extraction is one shared rule in `parser/premiere.ts`, because three parsers
  need it and YouTube puts it in three different places.
- **`playback.report` is load-bearing.** If watch events stop landing, the
  recommender stops training and the homepage drifts from the real one, which
  defeats the point of the app. Report every 10–30 s plus on state changes.

## Current state

Phase 1: plain `MWEB` URLs, no SABR, no media proxy. Phase 2 (SABR → local DASH
bridge) is specified but **not** to be built speculatively.

Findings in `architecture.md` are dated where they were measured. They are
dated observations, not permanent properties.
