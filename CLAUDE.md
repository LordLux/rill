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

// --- Comments (Task 27) ---
// Not a FeedItem. Sent over video.comments (which wraps /next with continuation).

interface CommentTextRun { startIndex: number; length: number; }
interface CommentStyleRun extends CommentTextRun { weightLabel?: string; }
interface CommentCommandRun extends CommentTextRun {
  url?: string; videoId?: string; startTimeSeconds?: number;
}
interface CommentText {
  content: string;
  styleRuns?: CommentStyleRun[];
  commandRuns?: CommentCommandRun[];
}

interface Comment {
  id: string;
  authorName: string;
  authorAvatarUrl: string;
  authorChannelId: string | null;
  isUploader: boolean;
  isVerified: boolean;
  text: CommentText;
  likeCount: string | null;
  publishedText: string | null;
  replyCount: number;
  depth: number;
  myRating: 'like' | 'dislike' | 'none';   // one field on the wire, so one field here
  creatorHearted: boolean;
  isPinned: boolean;
  repliesContinuation: string | null;
  replyParams: string | null;      // opaque; action.replyToComment
  deleteParams: string | null;     // opaque, own comments only; action.deleteComment
  likeParams: string | null;       // the four vote transitions; action.rateComment
  unlikeParams: string | null;     // server-supplied, never constructed
  dislikeParams: string | null;    // present anonymously too — not permission
  undislikeParams: string | null;
}

interface CommentsResult {
  items: Comment[];
  continuation: string | null;
  chips?: Chip[];
  commentCount: string | null;
  createParams: string | null;     // opaque; action.postComment. null when the viewer cannot comment
}

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
| Video tile | `videoRenderer`, `playlistVideoRenderer`, and their `grid`/`compact` variants | `lockupViewModel` |
| Filter bar | `chipCloudChipRenderer` (top level) | `chipViewModel`, inside `chipsShelfViewModel` / `chipBarViewModel` (shelf) |
| Mix tile | `radioRenderer` family (supported; absent from current captures) | a playlist-type `lockupViewModel` whose id starts `RD` |
| Mix/playlist panel | — | *(none — a bare object, see below)* |
| Hover actions | — | `thumbnailHoverOverlayToggleActionsViewModel`, read by what it holds |
| Continuation | `continuationItemRenderer` | `continuationItemViewModel` |
| Artist panel | — | `officialCardViewModel` (search only) |

**These are the raw `parse: false` keys, and `sidecar/src/parser/vocabulary.ts` is
the authority.** Four corrections to how this table used to read — the first
version (2026-08-01, in `architecture.md` §2.2) printed youtubei.js's *typed*
spellings (`ChipView`, `ContinuationItem`, `ThumbnailHoverOverlayToggleActionsView`),
which never appear in a response this app reads; `normaliseRendererName`
accepts both, but only the raw key is ever there. `richItemRenderer` is not a
tile: it is a wrapper the walker descends through to reach one. A mix is
recognised by its `RD…` id — `collectionThumbnailViewModel` is the thumbnail of
*every* playlist lockup, and a `"Mix"` badge label is only a fallback, since the
label is localised. And the Watch Later / queue actions are found by what the
tile contains (`playlistEditEndpoint` on `WL`, `addToPlaylistCommand`, icon
names; `scanTileActions` in `parser/text.ts`), not by the overlay's key.

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
  /lib            main.dart + probe_task19.dart, probe_comments.dart — the only entrypoints; the probes are measurements, never wired in
  /lib/domain     freezed models mirroring the DTOs above
  /lib/data       RPC client
  /lib/ui         screens, tiles, player
  /test/README.md the Task 19 measurement probes, and why they are not tests
/docs             architecture.md, protocol.md, todo.md, tasks/
/third_party      vendored packages carrying a local fix — media_kit_video (F28)
```

**`docs/todo.md` is the live backlog** — work that is agreed but not done, each
entry carrying enough context to be picked up cold. `docs/tasks/` is the
archive: what was asked for at a moment in time. An item leaves `todo.md` when
the work lands; a task file is never rewritten to match today's code.

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
cd sidecar && bun run capture:viewer-state before|after   # fixtures in a known account state — read its header first
cd sidecar && bun run build     # the sidecar alone — a release app needs `rill build`, see below
setup.bat                       # fresh machine: FVM SDK, pub get, codegen, lint gate
cd app && fvm dart run build_runner build --delete-conflicting-outputs   # codegen — see below
cd app && fvm flutter run -d windows   # debug build with hot reload
rill build                      # compile sidecar and app, bundle, and stop
rill run                        # build, bundle, then launch the exe in this terminal
rill open                       # launch the last release build as-is, no build
rill check                      # flutter test guard + lint gate
# run `rill --help` for the full surface; `rill` works from any directory
```

**Environment variables** are documented in `docs/configuration.md`.

**Generated code is not committed.** `*.g.dart` and `*.freezed.dart` are
gitignored, so a fresh clone does not compile until `build_runner` has run —
`setup.bat` does it once, and it has to be re-run after changing any `freezed`
or `json_serializable` model. If it fails, the `build_runner` note under
"Notes that will bite otherwise" is where to start.

**App commands go through `fvm`, never the global SDK.** `app/.fvmrc` pins
Flutter 3.44.9, and a bare `flutter`/`dart` in `app/` is a different SDK that
breaks things in ways that point nowhere near it — measured 2026-09-16: it
re-resolves `pubspec.lock` against its own pins (`meta`, `matcher`, `test_api`,
`vector_math` move), and after an `fvm` run it cannot read
`.dart_tool/hooks_runner`, so the test guard dies before running a test with
*"Invalid kernel binary format version"*.

**`flutter analyze` and `dart analyze` are not a check for `rill_lints`.** They
stop listening before the plugin's diagnostics arrive, and report
"No issues found!" on code with real violations — the plugin loading fine the
whole time. `tool/lint_gate.dart` is the check; `app/tool/rill_lints/README.md`
has why.

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
because the code being exercised is the old code. **Re-running
`fvm flutter build windows --release` after `bun run build` is *not* enough** —
measured 2026-08-13: the copy step does not re-run for an already-populated
bundle, so the app kept a sidecar nine hours older than the one just built, with
no warning. Copy `sidecar/dist/sidecar.exe` over the bundled one **explicitly**
(`rill build`, `run` and `zip` do this after building), and check it took —
`grep` a string from the new build inside the bundled `.exe` — before trusting
any device measurement. Otherwise the run measures the previous sidecar and says
so nowhere.

**It bit again on 2026-08-19, and it does not look like a stale binary.** It
looks like a half-finished feature: captions rendered position and outline but no
colour or font, because the bundled sidecar predated the change that reads
per-segment pens, while `sidecar/dist/` had it. Two things now make it cheaper to
spot. The client logs `rill: sidecar <path> (built <mtime>)` at startup — in a
release build that line is also in the newest `%LOCALAPPDATA%\rill\logs\rill-*.log` — compare
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
- **But a wholesale clear only knows what it owns, and `sidecar/src/fixtures.ts`
  is where that is declared — added 2026-09-20 (`todo.md` 41, now closed).**
  Three comment fixtures sat in `fixtures/` for weeks with no stage of
  `capture.ts` writing them, and `promoteStaging` replaces that directory
  entirely: one routine `bun run capture` would have deleted all three, and
  every test guarded by `hasFixture('comments…')` would then have **skipped
  silently** — the unloadable-test-file trap, one directory over. `fixtures.ts`
  now declares `CAPTURE_FILES` (what a run writes, each marked required or
  conditional) and `CARRIED` (what it must preserve, each with the reason it
  cannot be rebuilt), and the promote **refuses** rather than guesses: on any
  entry owned by neither, and on any *required* file it failed to produce —
  because replacing a good copy with nothing is the same loss arriving through
  the owner instead of past it. Carried entries are copied, not moved, and
  `prepareStaging` will not clear a staging directory holding one, which is the
  crash window between the copy and the swap. **The rule that follows: a new
  ad-hoc capture is declared in `fixtures.ts` or it is not written to
  `fixtures/`.** Nothing else keeps it. `test/fixtures.test.ts` drives both
  refusals against real directories and checks the declaration against
  `capture.ts`'s actual stages, so a stage added without one fails offline
  rather than a whole capture run later.
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
- **There is no bigger thumbnail, and audio-only mode is not symmetric — F40,
  F41, §2.4.** Three things that each look like a bug and are not. `maxresdefault`
  is byte-identical to `hq720` and **1280×720 is the ceiling**, so "fetch a larger
  one" is not a fix — the watch page's related rail ships 480×360, and for a
  square or vertical video three quarters of that is baked-in black bars. The
  answer is to blur it, not to find a better URL. The shipped libmpv has **no**
  audio-visualization filters, so a spectrum visualizer cannot be built here at
  all (`lavfi-complex` being accepted is invariant 8's false positive). And
  `vid=no` is a *teardown*, not a pause: it drops the demuxer cache to zero, so
  going back to video is a cold refetch costing 2.9–8.0 s, gated on
  `vo-configured` — **not** on any width or `rect`, both of which survive
  `vid=no` untouched and will return instantly if you wait on them.
- **`vid` persists across loads, and a load with no stream selected is
  skipped — F42, measured 2026-09-24.** A variant's video URL is video-only, so
  opening it under a leftover `vid=no` with the audio not yet attached gives
  mpv nothing to play: it moves past the file, no duration arrives, and the open
  waits out its 20 s timeout at 0:00. An audio-only open attaches the audio
  *at load* through `audio-files` instead. Change that list with `change-list`
  (`clr`, `append`), **never** `setProperty('audio-files', '')` — that sets a
  list holding one empty path, and every later open fails with
  `Cannot open file ''`.
- **Two widgets swallow clicks meant for what is under them, and neither
  looks like it.** `MouseRegion` is `opaque: true` by default, so a sibling
  painted beneath `PlayerControls` gets no pointer at all — the audio-only
  layout was unclickable until it moved into the controls' child slot
  (`architecture.md` §2.8). And a `Material` added only for its text styles is
  `MaterialType.canvas` by default, which paints and hit-tests like a wall; use
  `MaterialType.transparency`.
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
  cookies; resolve streams anonymously, asking as `VISIONOS` (ladder tier 1),
  then yt-dlp, then `ANDROID`'s 360p itag 18. **`MWEB` is not a playback tier**
  — it left the ladder on 2026-08-19 (`architecture.md` §2.4), and nothing in
  the ladder deciphers since. **Tier 1 was `ANDROID_VR` until
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
  failure takes. A SABR-only response is not an identity refusal. A "not a
  bot" refusal that survives the fresh id is YouTube throttling the
  connection: `playback.open` answers `RATE_LIMITED` for it (`retry: user`)
  if no lower tier gets through — never "would not open".
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

  `16b70c7` also overrode `source_gen` and `build`, and those two survived the
  2026-09-09 fix undocumented. Tested out and removed 2026-09-16: without them
  the solver picked identical versions, and codegen and both app gates passed.
  `dependency_overrides` is now empty on purpose.
- **Captions render through `LibassLayer` — Flutter, driving the vendored libass
  0.17 via FFI.** The sidecar generates ASS (`sidecar/src/captions/`), and
  `LibassLayer` (`app/lib/ui/player/libass_layer.dart`) calls libass to render
  glyph bitmaps, painting them with `RawImage` and backgrounds with
  `CustomPaint`. mpv's own subtitle path (`sub-add`) is disabled: `LibassLayer`
  sets `setSubtitleVisible(false)` on mount, so there is exactly one renderer
  and no way to draw captions twice. `architecture.md` §2.9 and `protocol.md`
  §3.8. Hover previews are the exception: they run on a separate
  `MediaKitEngine` with no `LibassLayer` mounted, so previews use mpv's
  `sub-add` directly. A quality switch drops the track, and
  `MediaKitEngine.open(retainSubtitle: true)` is what puts it back.
- **`fmt=ytt` answers HTTP 404, and a `WEB` caption URL answers 200 with no
  body.** Two things that look like bugs and are not. YTT is not a fetchable
  format: its styling model *is* the `pens` / `wsWinStyles` / `wpWinPositions`
  arrays already in every `json3` document. And a `WEB` `/player` signs its
  `timedtext` URLs with `exp=xpe`, which makes every one of them return an empty
  body — so the empty-list fallback asks **`MWEB`**, whose URLs work. A `WEB`
  fallback would fill a language picker in which nothing renders.
- **media_kit's own caption renderer is disabled, and the setting is
  load-bearing.** `engine.dart` sets `kLibassEnabled` (→ mpv `sub-ass=yes`,
  which `LibassLayer` needs to receive styled events) and
  `kNoFlutterSubtitles` (→ mpv's own `sub-text` stream is not consumed, so
  Flutter's built-in caption overlay never mounts). Without both, one of two
  things happens: captions draw twice (mpv and LibassLayer), or mpv strips
  every ASS tag and draws tag-stripped plain text while LibassLayer gets
  nothing. **This was invisible on a plain track** — measured 2026-08-18: it
  only shows when a track carries styling.
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
  months. `sidecar/test/contract-docs.test.ts` compares every shape in a
  fenced `ts` block — the DTO block here, and `VideoDetail`,
  `PlaylistMembership` and `SearchFilters` in `protocol.md` — against its one
  declaration in `sidecar/src`: field names, optionality and types, `| null`
  included. A new block is picked up without touching the test, so a shape
  that should be checked only has to be written down. It also fails on any doc
  sentence naming an InnerTube client that appears nowhere in `sidecar/src`.
  **A sentence carrying an `F<n>` reference or an ISO date is exempt** — that is
  how this repo writes history, and history about a retired client has to
  survive. The cost is real and worth knowing: adding a dated note to a
  sentence also stops it being checked.
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
- **A reply list is a tree the UI shows flat, and its count is a snapshot —
  Task 27, measured 2026-09-18.** A reply-to-a-reply (`replyLevel` 2) nests in
  its parent's `subThreads`; "Show more replies" is a *button*-shaped
  continuation, not the `continuationEndpoint` a page of threads uses; and
  `Comment.replyCount` lags removals — a signed-in view kept advertising a reply
  the anonymous view already said was gone. The parser dropped all three until
  then: a thread advertising 962 replies listed 5, with no way to continue.
  `parseComments` now flattens nested replies (only a reply's own children, never
  a top-level thread's inline ones) and reads both token shapes; the client trusts
  the list it has *completely* fetched over the count it was told. `protocol.md`
  §3.3 and `architecture.md` F30 have the shapes. Still open: a reply's own
  "Show more replies" is unreachable (`todo.md` 39).
- **A comment's like and heart are on a different entity than the comment —
  Task 27, measured 2026-09-19.** `isLiked` and `creatorHearted` come from
  `engagementToolbarStateEntityPayload` (via the view model's `toolbarStateKey`)
  and nothing else. The comment's own `toolbar` has `heartActiveTooltip` on
  **every** comment — the tooltip *for* a heart, not evidence of one — and
  reading it marked 120 of 120 comments hearted where 4 were. `likeCount` is the
  viewer's variant (`likeCountLiked` once they liked it). **`heartState` has two
  "hearted" values**: the creator's own view of a video they own says
  `..._HEARTED_EDITABLE`, and the first version of this read only the plain one.
  `architecture.md` F33, F35.
- **Account-derived state is re-read on an identity change, never taken from a
  response cached under the other identity — Task 31, 2026-10-01.** `isSubscribed`,
  `myRating`, playlist membership and a comment's vote params are the viewer's, and
  nothing in the response says whose. `authIdentityProvider` is the value to watch
  (`videoInfoProvider`, `playlistMembershipProvider`, `AccountActions` and
  `CommentsSection` do), and the UI masks the state to "none" the moment there is no
  account rather than waiting for the re-fetch.
- **A viewer-state field is untested until a fixture holds the state —
  measured 2026-09-20.** `creatorHearted`, `isLiked` and
  `PlaylistMembership.containsVideo` were each wrong with an all-green suite,
  because every fixture was captured with the account in whatever state it
  happened to be in, and none held a liked comment, a hearted one, or a video in
  Watch Later. `bun run capture:viewer-state <before|after>` captures a pair with
  the account in a *known* state and refuses to write unless the raw response
  proves it; its header has the recipe (like a video, subscribe, add to Watch
  Later, like and heart your own comment on your own video, then undo it all).
  `capture.ts` carries `fixtures/viewer-state/` across instead of deleting it,
  because `src/fixtures.ts` declares it `CARRIED` — see the capture note above;
  that declaration is the only thing standing between it and a recapture.
  The assertions are `viewer-state.test.ts` (raw, local) and `corpus.test.ts`
  (sanitised, runs anywhere). `canWatchLater` is *not* viewer state: it is `true`
  on every tile, anonymous ones included. `architecture.md` F35.
- **A release `rill.exe` is two processes, and the first one is the log.**
  In a Release build the process you start is a launcher: it starts a second
  `rill.exe` with stdout/stderr on a pipe and writes every line, redacted and
  timestamped, to `%LOCALAPPDATA%\rill\logs` (newest 10 runs), ending with the
  app's exit code — `CRASHED with code 0x…` for a crash. `architecture.md`
  §2.11 has why it cannot be a redirect inside one process. So: a debugger
  started on `rill.exe` lands on the launcher (set `RILL_LOG_CAPTURE=0`), and
  **a crash is diagnosed from that file first.** A crash dump, if Windows took
  one (`%LOCALAPPDATA%\CrashDumps`), holds the session cookie: read the stack,
  then delete it; never attach it.
- **`bun run export-contract-corpus` runs the auditor itself, and exits 1 if it
  is red.** Not a courtesy — the export is what breaks `corpus.test.ts`, by
  writing a field with no sanitiser, and it breaks it *in a different file from
  the one being edited*. Run after the last `bun run check` of a session, it
  reports success while leaving the suite red and possibly real capture data in
  `corpus/`. Measured 2026-09-04, which is how this note exists.
- **The compiled sidecar can fail to start under some virtualization, and it
  is not a packaging bug.** `sidecar.exe` is a `bun build --compile` binary;
  Bun's JS engine can require CPU features (AVX2) that some virtualized CPUs
  do not expose to the guest. Measured 2026-09-28: an installer with an
  identical, correctly bundled `sidecar.exe` ran fine in a Windows Sandbox
  (which passes the host's real CPU straight through) and on real hardware,
  but failed with "Failed to start sidecar process" in a VirtualBox VM with a
  more restrictive virtual CPU profile — no crash log, no useful message from
  the app's side, since the process fails before it can print anything.
  Diagnosing this needs running `sidecar.exe` directly in a terminal on the
  machine in question, not trusting the app's generic wrapper message.
- **A second `import()` of an already-broken module does not reject the way
  the first one did — measured 2026-09-30, compiled, against a deliberately
  reverted `css-tree` patch.** A dynamic `import()` whose target module threw
  during evaluation rejects the first time, predictably. Every `import()` of
  that *same* module specifier after that — even from an unrelated call
  site, even much later — resolves successfully instead, with every named
  export `undefined`. Nothing throws at the import line the second time; the
  failure only surfaces later, wherever the code first tries to call or
  construct one of those `undefined` exports, as a bare `TypeError` with no
  clue it came from an import. A `try`/`catch` wrapped around a dynamic
  import on the reasonable assumption that a caught first failure means a
  correctly-caught path every time is wrong: check what actually came back
  (`if (!theExport) throw ...`) rather than trusting that reaching the code
  after the `await` means the import succeeded. `architecture.md` F50 has
  the specific case this was found in (`po-token.ts`'s dynamic import in
  `rpc/server.ts`) and `sidecar/test/po-token-scope.test.ts` the regression
  test.
- **A Material `Slider` must never be built where its semantics are skipped —
  Task 32, measured 2026-10-01, and nothing in `flutter test` can see it.** At
  opacity 0, clipped to zero width, or under `ExcludeSemantics`, the `Slider`'s
  `OverlayPortal` child is still visited and serialises an orphan node; Windows'
  accessibility bridge rejects the update and then every one after it, so the log
  fills with `Failed to update ui::AXTree` and the tree is frozen. Fade with
  `alwaysIncludeSemantics: true` or do not mount it while collapsed. Re-run
  `RILL_SEMANTICS_PROBE=1` (`ui/semantics_probe.dart`) after touching a `Slider`
  or a fade above one, and on every Flutter bump. **So does a `Focus` added only
  to watch focus** — it carries a semantics node by default, and one above the
  player brought the fault back (~1 450 errors a run, 2026-10-02): an observer is
  `Focus(canRequestFocus: false, skipTraversal: true, includeSemantics: false)`.
  **The semantics probe alone proves little: run it with the focus probe**
  (`RILL_SEMANTICS_PROBE=1 RILL_FOCUS_PROBE=watch`), because the volume `Slider`
  failed whenever it opened (now `VolumeBar`, not a `Slider`) and an animated
  `Scrollable.ensureVisible` through the comments failed every frame (now a jump),
  and neither runs without Tab presses. `architecture.md` F51.
- **Keyboard navigation is a state: on at Tab, off at any click, off at Escape.**
  Flutter calls the *mouse* "keyboard-like" (`FocusHighlightMode.traditional`), so
  anything keyed to it draws and scrolls on clicks. Key it to
  `KeyboardNavigation.active` instead (`ui/focus_ring.dart`). `architecture.md` F52.
- **A modifier whose release went to another window stays "held" in Flutter, and then no
  shortcut or Tab fires — measured 2026-10-03.** Alt+Tab (also Win+Ctrl+Arrow, Win+Tab)
  gives the keyboard to another window between the modifier going down and coming up, so
  the key-up is never delivered here. Every `RILL_KEY_DIAG` line after it read
  `down=[Alt Left+…]`; the report was "the keyboard dies after a video change", which was
  only when the user happened to Alt+Tab. `ui/keyboard_resync.dart` asks the platform what is
  really down when the window regains the keyboard and releases the rest — Flutter's own
  `syncKeyboardState` only ever *adds* keys. Anything new that matches key presses "without
  modifiers" depends on this.
- **A new surface gets its own `FocusSurface`, and the keyboard cannot reach
  anything above the `Navigator` — Task 32.** Tab order is declared in
  `ui/focus_surface.dart`, not inherited from the tree: title bar, rail, search,
  actions, page, and on the watch page the main column before the rail. Tab never
  leaves a route's scope, so the miniplayer is reached with F6; `PlayerShortcuts`
  runs before the focus tree, so Space yields to a control the keyboard walked
  onto. An overlay is only done when `test/focus_traversal_test.dart`-style
  checks say focus moves in, Tab stays in, Escape closes it, and focus returns.
  **A control that exists only while something has focus or the pointer is over it
  cannot be Tabbed to** (it unmounts as focus moves onto it) — show it while focus
  is anywhere *inside*, and make hover-only duplicates `ExcludeFocus`. A bare
  `Focus`, `SelectionArea` or `GestureDetector` is a ghost stop, a missing one, or
  both; use `KeyboardTap` and `NoTabSelectionArea`. **A disabled control cannot hold
  focus** — keep a control enabled (and ignore the press) while its action is in
  flight. The ring is app-wide (`ui/focus_ring.dart`) and takes each control's own
  shape; a new custom `InkWell` declares `customBorder`/`borderRadius`, and a
  full-bleed row says `FocusRingShape(inflate: -1)` — do not draw a ring per widget. Walk the real app with
  `RILL_FOCUS_PROBE=feed|watch` before calling a keyboard change done.
  `architecture.md` F52.

## Current state

Phase 1: plain URLs — `VISIONOS`, with yt-dlp and a 360p `ANDROID` floor behind
it — no SABR, no media proxy. Phase 2 (SABR → local DASH
bridge) is specified but **not** to be built speculatively.

Findings in `architecture.md` are dated where they were measured. They are
dated observations, not permanent properties.

## Deferred items

- **Task 19 §14 lists six open caption items**: stale in-flight render flash,
  windowed/theatre one-frame flicker, dead `subtitleTextStream`
  (`engine.dart:143,483`), no karaoke track rendered end to end, and authored
  background colour not painted.
- `ShortcutTooltip`'s plain tooltips show with no delay (the layout-crash risk described in architecture.md §2.8).
- `deletePlaylist` does not assert that the delete actually succeeded (`assertSucceeded`).
