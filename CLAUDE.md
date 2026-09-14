# CLAUDE.md

Native Windows YouTube client. Flutter UI + libmpv playback, backed by a
headless Node/Bun sidecar that talks to YouTube's private InnerTube API.
No browser engine renders any part of the UI.

Read `docs/architecture.md` and `docs/protocol.md` before writing code. They are
decisions-only; rejected alternatives are fenced in an appendix. **Do not revive
a rejected alternative** — if one looks necessary, say so and stop.

Flutter UI decisions live in `architecture.md` §2.6–§2.8 — hover previews,
player controls, and the watch page's sharp edges (mount points, overlays,
tooltips, queue identity, aspect ratio). Code comments there are deliberately
short and point at those sections; put the reasoning in the doc, not inline.

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
  isStation: boolean;               // 24/7 station (F22) — alongside isLive, not instead
  viewCountText: string | null;     // display string, not parsed
  publishedText: string | null;
  descriptionSnippet: string | null;
  badges: string[];                 // "4K", "New" — never a fact with a field
  isShort: boolean;                 // Task 21 — classified, not stripped
  isMusic: boolean;                 // the ♪ on the duration badge, per video
  isMembersOnly: boolean;           // BADGE_STYLE_TYPE_MEMBERS_ONLY, not the label
  isVerified: boolean;              // the uploading channel's checkmark
  isArtistChannel: boolean;         // the uploading channel's artist badge
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
  seedVideoId: string | null;       // the song the tile advertises — plays first
  startParams: string | null;       // the tile's click-target params, opaque
}

interface PlaylistItem { kind: 'playlist'; id: string; title: string;
  thumbnailUrl: string; videoCount: number | null; channelName: string | null; }

interface ChannelItem { kind: 'channel'; id: string; name: string;
  avatarUrl: string; subscriberText: string | null;
  descriptionSnippet: string | null;
  isVerified: boolean; isArtistChannel: boolean; }

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
| Mix/playlist panel | — | *(none — a bare object, see below)* |
| Hover actions | — | `ThumbnailHoverOverlayToggleActionsView` |
| Continuation | `continuationItemRenderer` | `ContinuationItem` |

**Shorts are split, not simply stripped** (revised by Task 21 §1; this line
used to read "stripped, never rendered" and both halves of that are now
false). A Shorts *shelf* — `shortsLockupViewModel`, `reelItemRenderer`,
`reelShelfRenderer`, `richShelfShorts` — is still stripped whole by the
vocabulary. A Short arriving as an **ordinary video renderer carrying a
`SHORTS`-styled duration overlay**, which is how search returns them, is
classified instead: `VideoItem.isShort`, with `"SHORTS"` deliberately kept
out of `badges[]` so the fact ships once. The client decides what to do with
the flag, and `feed_view.dart` does render them, in a shelf of their own.

**Members-only is a flag, not a badge string — added 2026-09-09.** Same rule as
the two below, and the same reason the verified badge is read by `style`:
`BADGE_STYLE_TYPE_MEMBERS_ONLY` (or the `SPONSORSHIP_STAR` icon) is stable,
while the `"Members only"` label is localised. It ships as
`VideoItem.isMembersOnly` / `VideoDetail.isMembersOnly` and is kept out of
`badges[]`. **A tile carrying it says nothing about whether this account can
watch** — YouTube puts members-only videos in a subscriber's feed either way,
and the resolve path is anonymous besides.

**A 24/7 station is live, and separately flagged — added 2026-09-11 (F22).**
YouTube ships a `"STATION"` label instead of `"LIVE"` for continuous
radio/music content. It is not tied to one client: first measured from
`ANDROID` only, then observed flipping a plain `youtube.com` session from
`"LIVE"` to `"STATION"` mid-session with nothing on the viewer's end
changing — a rollout any client can receive at any time, not a fixed
per-client split. `VideoItem.isStation` ships **alongside** `isLive: true`,
never instead of it — the null-duration/sort behaviour a live tile needs is
unchanged — so the client can draw its own `"STATION"` pill instead of
`"LIVE"` without losing anything `isLive` already provides. Kept out of
`badges[]` for the same reason `"LIVE"` is.

**Its `badgeStyle` is `THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE` — confirmed live
2026-09-11, and this shipped wrong for one round because of it.** The
`"STATION"` label has to be checked *before* `scanBadges`'s generic
style-based LIVE match in `src/parser/text.ts`, not after: checking style
first classifies every station as an ordinary live tile and the label is
never reached, so `isStation` stays false. A synthetic test built on the
(wrong) assumption that the style carried nothing LIVE-ish passed against
exactly this bug.

**A fact with a DTO field of its own does not also travel as a label.** That is
the general rule `isShort` is one case of, and `isLive` is the other. `LIVE`
used to be pushed into `BadgeScan.labels` and then filtered back out by each
mapper separately — redundant, and with a hole in it exactly the size of the
next mapper someone writes. `scanBadges` now never emits either, so there is
one route for each fact and no filter to forget. `parser.test.ts` asserts it
across the whole corpus rather than per mapper, so the rule also covers mappers
that do not exist yet.

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

## Reports

**A report is either text in the chat or an HTML file in the repository root —
never a Markdown file under `docs/`.** `docs/tasks/` holds task specs, not
reports. Root `*.html` is gitignored, so an HTML report is not committed either.
Default to chat text unless asked for HTML.

## Commands

```bash
cd sidecar && bun test          # parser tests, offline, no network
cd sidecar && bun run check     # typecheck + lint + tests — run before calling it done
cd sidecar && bun run test:network  # live decipher tests — real requests, ~24 MB
cd sidecar && bun run capture   # refresh fixtures (needs YT_COOKIE)
cd sidecar && bun run build     # compile to dist/sidecar.exe — see below
cd app && flutter run -d windows
cd app && dart run tool/test_suite_guard.dart   # flutter test + the guard below
```

**Run the app's tests through `tool/test_suite_guard.dart`, not `flutter test`
alone.** A test file that does not compile fails to *load*, and `flutter test`
scores that as a single `-1` — identical to one failed expectation, while every
test in the file silently stops running. That is not hypothetical: nineteen
tests stopped running on 2026-08-18 when `bf2e288` renamed
`PlayerAction.toggleCaptions`, and it went unnoticed for three weeks because the
suite already carried two known failures and `+403 -2` read as normal. The guard
fails on any file in `test/` that produced no tests, which is never intentional
and needs no maintenance. **The sidecar needs no equivalent** — measured
2026-09-10, `bun test` reports an unloadable file as a separate `1 error` and
exits 1, so the ambiguity is specific to `flutter test`'s reporter.

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

**It bit again on 2026-08-19, and it does not look like a stale binary.** It
looks like a half-finished feature: captions rendered position and outline but no
colour or font, because the bundled sidecar predated the change that reads
per-segment pens, while `sidecar/dist/` had it. Two things now make it cheaper to
spot. The client logs `rill: sidecar <path> (built <mtime>)` at startup — compare
that timestamp against `sidecar/dist/sidecar.exe`. And `grep -a` for a symbol
only the new code has (`layerAlpha`, `includeStyled`) inside **both** binaries;
if the bundled one is busy, the app is running and holding it, which is itself
the answer.

---

## Notes that will bite otherwise

- **Cookies rotate.** YouTube invalidates exported cookies when a browser tab
  touches the account. Export from an incognito window parked on
  `youtube.com/robots.txt`, then close it without logging out. Keep main-profile
  YouTube tabs closed while testing.
- **No cookie value goes to stderr or into an error envelope, and two
  chokepoints enforce that rather than a rule per call site.** `logger()` and
  the RPC error envelope both pass their text through `redact.ts`, which strikes
  the values the process was handed *and* anything shaped like a Google auth
  cookie. The sidecar's own code interpolates a cookie nowhere; what this
  catches is a third party doing it — youtubei.js quoting a failed request, a
  `fetch` rejection carrying headers — which is unreachable by reading this repo
  and silent when it happens. `redact.test.ts` proves the redaction;
  `rpc.test.ts`'s end-to-end check is a regression guard and, mutation-checked
  2026-09-08, currently passes for the second reason too.
- **The browse session's cookie changes at runtime now, and the base-browse
  cache belongs to it.** `innertube/auth.ts` owns the cookie, the session, the
  30-second `feed.home`/`auth.verify` cache and the cached account, and drops
  all four together. Keeping the cache beside the session instead of on it means
  a sign-in is verified against the *anonymous* response it just superseded —
  `degraded` reported for a login that worked, silent and indistinguishable from
  a genuinely stale cookie. `YT_COOKIE` seeds the first session and any
  `auth.setCookie`/`auth.signOut` overrides it for the life of the process; a
  sign-out cannot unset an environment variable, and says so on stderr.
- **Community references are hypotheses, not specifications.** An InnerTube request shape or parser path copied from a reference implementation (like youtubei.js or others) is a hypothesis, not a specification, and gets verified against a real response like anything else. The like/dislike `target` shape came from a reference and was wrong, producing 400s until corrected.
- **Fixtures must be captured with `parse: false`.** Parsed objects are lossy
  and make a useless corpus.
- **Never mix fixtures across capture runs.** Clear the directory first. A stale
  file once produced a completely wrong reading of the live feed.
- **Fixtures are one moment.** The home feed's renderer mix shifted measurably
  within 8½ hours. Never assert that a given surface contains a given
  generation; search the corpus for wherever it lives.
- **"Is this an object?" exists three times in the parser, and the three do not
  share a line of code.** `isObject` in `tree.ts`, the inline `Array.isArray`
  branch inside `walk`, and a hand-rolled `traverse()` in `parser/feed.ts`. They
  agree today. Nothing makes them agree, and they are the kind of thing that is
  changed one at a time — so if you touch one, read the other two before
  deciding it was safe.
  **`get()` is where that already cost something.** Every hop was guarded by
  `isObject`, which excludes arrays *by design* (its `value is JsonObject`
  predicate would otherwise be a lie, and ~30 call sites gate on "is this a
  renderer payload"). So `get` could not walk *through* a list: the moment a
  path stepped onto one, every remaining segment answered `null`.
  `parsePlayer`'s `playabilityStatus.messages[0]` fallback for a refusal reason
  was therefore dead from the initial commit — written, documented, believed in,
  and never once firing, with nothing thrown and nothing logged. Fixed
  2026-09-09 in `get` rather than in `isObject`, because only `get` walks a
  *path*; a numeric segment now indexes an array, and a non-numeric one against
  an array is still `null` so that `get(x, 'runs', 'length')` cannot answer with
  a property of the container. `src/` was swept at the same time and had no
  other such caller, so this is a trap rather than a fleet of live bugs — but it
  is a trap that reads as correct code.
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
  cookies; resolve streams anonymously, asking as `VISIONOS` (ladder tier 1)
  and falling back to `MWEB` (tier 2). **Tier 1 was `ANDROID_VR` until
  2026-08-18** — it now requires a PO token and is no longer viable
  (`architecture.md` F11), so any note here still naming it is stale. Do not attempt to bridge CPNs between
  them — issue two independent calls.
- **The resolution session needs a server-issued visitor id.** `VISIONOS`
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
- **`build_runner` works. Never re-add `animated_vector_gen`.** That package is
  the whole reason codegen appeared to be broken, and the error names nothing
  that points at it: `dart compile kernel` crashes inside the FFI use-site
  transformer with `type 'InvalidType' is not a subtype of type 'FunctionType'`
  and a `_verifyAndReplaceNativeCallable` stack, which reads like an FFI bug in
  media_kit or in this app's own code. It is neither, and it blocks **every**
  generator rather than one. build_runner compiles a build script importing every
  builder in the graph, using the plain Dart VM; `animated_vector_gen` →
  `animated_vector_annotations` → `flutter`, and that package re-exports
  `dart:ui`, so the build script drags the Flutter framework into a compiler that
  has no `dart:ui` and every use site in it resolves to `InvalidType`. Bisected
  2026-08-18: freezed, json_serializable, source_gen and build_runner's own
  entrypoint each compile clean alone; that one alone fails. `--force-jit` does
  **not** help — it still runs `dart compile kernel`. The pin is removed with a
  comment in `app/pubspec.yaml`; it generated nothing (no `@ShapeshifterAsset`
  exists), so nothing was lost.

  **This note used to have a companion above it blaming `media_kit`'s
  `dart:ffi` and declaring hand-written DTOs the "permanent policy". That
  diagnosis was wrong and the two sat contradicting each other in the file
  loaded into every session — deleted 2026-09-10.** The symptom it described
  was real and is the one above; the cause it named was not. Codegen works.

  **There were two causes, not one, and `16b70c7` introduced both.** That
  commit ("added initial Watch Later animated icon assets") added
  `animated_vector_gen` *and* added `analyzer` / `dart_style` to
  `dependency_overrides` to make the tree resolve. `bf2e288` removed the
  generator and codegen started running — which is why this note reads
  "build_runner works" — but the overrides survived, and they break a
  *different phase*: the build script compiles fine, then `freezed` fails at
  builder runtime against an analyzer API it was not written for. An override
  bypasses constraint checking entirely, so pub resolved analyzer 13.0.0 while
  freezed needs 12.x and `dart_style` needed 13.1+, and nothing warned. Found
  and removed 2026-09-09; `app/pubspec.yaml` carries a comment saying which two
  are deliberately *not* overridden and why. So: **both diagnoses were real and
  sequential, and this note's "removing it fixes all codegen" was too broad** —
  it fixed the bootstrap, not the builders. If codegen breaks again, check
  which phase fails before assuming either cause.
- **Captions render through mpv/libass, from ASS the sidecar generates.** Flutter
  draws none. `architecture.md` §2.9 and `protocol.md` §3.8; the pipeline is
  `sidecar/src/captions/`. Measured 2026-08-18 against the bundled libmpv:
  `sub-add` costs 12–36 ms and **does not rebuild the video texture**, so a
  caption toggle is free where a quality switch costs 0.55–12 s (F19). A quality
  switch *does* drop the track, and `MediaKitEngine.open(retainSubtitle: true)`
  is what puts it back — with a control proving a reopen without the flag loses
  it.
- **`fmt=ytt` answers HTTP 404, and a `WEB` caption URL answers 200 with no
  body.** Two things that look like bugs and are not. YTT is not a fetchable
  format: its styling model *is* the `pens` / `wsWinStyles` / `wpWinPositions`
  arrays already in every `json3` document. And a `WEB` `/player` signs its
  `timedtext` URLs with `exp=xpe`, which makes every one of them return an empty
  body — so the empty-list fallback asks **`MWEB`**, whose URLs work. A `WEB`
  fallback would fill a language picker in which nothing renders.
- **media_kit does not use libass unless you tell it to, and mounts a second
  caption renderer if you don't stop it.** `PlayerConfiguration.libass` defaults
  to `false` → `sub-ass=no` *and* `sub-visibility=no`, so mpv strips every tag
  and draws nothing; `Video` then paints mpv's plain `sub-text` with a Flutter
  `TextStyle`. Both settings live in `engine.dart` (`kLibassEnabled`,
  `kNoFlutterSubtitles`) and each alone is wrong — one draws captions twice, the
  other draws none. **This is invisible on a plain track**, which is why it
  survived two tasks: it only shows when a track carries styling.
- **A styled caption is more than one event, and merging them is the whole of
  Task 18.** YouTube composites it: an invisible-glyph pen contributing a drop
  shadow over a visible pen contributing the outline — 240 of `L-BgxLtMxh0`'s 257
  cue groups. Emitted verbatim that is two lines stacked, which is what the bug
  looked like. `CueStyle.edgeStyles` is a *set* for this reason. Where two
  *visible* pens conflict, both are emitted instead, which is safe because
  **`\pos` suppresses libass's collision avoidance** (measured). §2.9 has the
  rest, including two ASS tags that look like they work and do not: an inline
  `\c` takes six digits and no alpha, and a caption background is
  `BorderStyle: 3` filled from `\3c`.
- **`bun run check` is the gate, and rendering is checkable offline.** libmpv
  is a DLL and Bun has FFI, so an ASS document can be rendered to frames through
  **the artefact the app actually loads** rather than reasoned about — which is
  how the `\pos` collision question, the `\an` anchor mapping and the missing-font
  fallback were settled. That build's FFmpeg has no PNG encoder and no `color`
  lavfi source: feed it raw frames (`demuxer=rawvideo`) and take `jpg` out.
- **Do not use a bash heredoc for anything containing backslashes.** The Bash
  tool eats one level, so `\an1` reaches the file as a BEL byte and libass
  silently ignores the override — a probe that then "measures" the default style
  and looks like a real result. Write such files with the Write tool.
- **The docs restate the contract in five places, and one test checks they
  agree.** `CLAUDE.md`, `architecture.md`, `protocol.md`, `parser.test.ts`'s
  `SHAPES` and `corpus.test.ts`'s auditor each hold part of it independently.
  Twice a change landed in the code and one doc while the rest went stale in
  silence — `ChannelItem.descriptionSnippet`, and `ANDROID_VR` surviving as
  "ladder tier 1" in thirteen places after `VISIONOS` replaced it (F11). Since
  CLAUDE.md is loaded into every session, that one taught the wrong client for
  months. `sidecar/test/contract-docs.test.ts` compares the DTO block here
  against `types.ts` field by field, and fails on any doc sentence naming an
  InnerTube client that appears nowhere in `sidecar/src`. **A sentence carrying
  an `F<n>` reference or an ISO date is exempt** — that is how this repo writes
  history, and history about a retired client has to survive. The cost is real
  and worth knowing: adding a dated note to a sentence also stops it being
  checked.
- **A mix is a sliding window, and the watch page's playlist panel is not a
  renderer at all — Task 26, measured 2026-09-12.** The panel sits at
  `contents.twoColumnWatchNextResults.playlist.playlist` as a **bare object**
  with no wrapping renderer key, so the walker cannot see it: `isRendererKey`
  needs a `Renderer`/`ViewModel`/`Model` suffix, and a whole-body `parseFeed`
  therefore returns the panel's rows interleaved with the related rail's (45
  items for a page whose panel holds 25). `parser/mix.ts` reaches it by path;
  its *rows* are ordinary renderers and map through the ordinary mappers.
  `playlistPanelRenderer` now occurs **nowhere** — checked for a mix and for an
  ordinary `PL…` playlist — but the `playlistpanel` vocabulary entry is kept
  deliberately, because an unknown container is *pruned, not descended*
  (`handleRenderer`'s default returns false), so removing it would turn a
  reappearance of the wrapper into total silent loss.
  **There is no continuation token**, `index` is ignored, and the response is a
  window of ≤25 history + exactly 24 lookahead around whatever video you anchor
  on. So `mix.extend {playlistId, afterVideoId}` re-anchors and returns only the
  tail — the arithmetic stays in the sidecar (invariant 6). It answers
  `{items[], exhausted}` because a mix ends two distinguishable ways (empty
  tail; anchor absent after a server re-seed) that an empty `items[]` would
  conflate. **`isInfinite` is `true` on every mix, including curated ones that
  run out after ~51 items** — never branch on it.
- **`bun run export-contract-corpus` runs the auditor itself, and exits 1 if it
  is red.** Not a courtesy — the export is what breaks `corpus.test.ts`, by
  writing a field with no sanitiser, and it breaks it *in a different file from
  the one being edited*. Run after the last `bun run check` of a session, it
  reports success while leaving the suite red and possibly real capture data in
  `corpus/`. Measured 2026-09-04, which is how this note exists.

## Current state

Phase 1: plain `MWEB` URLs, no SABR, no media proxy. Phase 2 (SABR → local DASH
bridge) is specified but **not** to be built speculatively.

Findings in `architecture.md` are dated where they were measured. They are
dated observations, not permanent properties.

## Deferred items

- `MediaTile.onMore` is never wired up, so every 3-dot menu button on media tiles is disabled.
- `ShortcutTooltip`'s plain tooltips show with no delay (the layout-crash risk described in architecture.md §2.8).
- `deletePlaylist` does not assert that the delete actually succeeded (`assertSucceeded`).
