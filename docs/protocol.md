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
{"id": 42, "error": {"code": "STREAM_UNAVAILABLE", "message": "...", "retry": "user"}}

// unsolicited
{"method": "event.ready", "params": {"protocolVersion": 1, "capabilities": {"ytDlp": true}}}
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
its own. `ytDlp: false` means ladder tier 4 is gone, leaving only `VISIONOS`
and the 360p floor (§3.5), so age-restricted or Vevo videos fail with
`STREAM_UNAVAILABLE` and no way for the UI to say why. The sidecar also warns about it at startup — a missing
fallback that removes a capability without removing anything visible is exactly
the kind of degradation this protocol makes explicit rather than leaving to be
inferred from a video that will not play.

---

## 3. Methods

### 3.1 Auth

| Method | Params | Result |
| --- | --- | --- |
| `auth.status` | — | `{state, accountName, accountHandle, accountAvatarUrl}` |
| `auth.verify` | — | `{state, tileCount}` |
| `auth.setCookie` | `{cookie}` | `{state}` |
| `auth.signOut` | — | `{}` |

`state` ∈ `authenticated` \| `degraded` \| `anonymous`.

**`auth.verify` is not optional.** A degraded session returns HTTP 200 with an
empty feed and no error. Verify by fetching home and counting tiles: zero means
degraded. Run on startup and after any empty feed. Never trust a `logged_in`
flag derived from cookie presence.

**`auth.status` is wider than it was, and its fields are never omitted — Task
22 §7.** This row read `{state, accountName?}`; the top bar needs a picture as
well as a name, and a handle is what tells two accounts with the same display
name apart, so all three ship. They are **values or `null`**, following the DTO
rule the rest of this document holds to, because the alternative is a client
that cannot tell "this account has no name" from "this sidecar is older than
the field".

```jsonc
// auth.status → the account behind the avatar in the top bar
{"state": "authenticated", "accountName": "Ada Lovelace",
 "accountHandle": "@ada", "accountAvatarUrl": "https://yt3.ggpht.com/…"}

// every other state — the account fields are null, not absent
{"state": "degraded", "accountName": null,
 "accountHandle": null, "accountAvatarUrl": null}
```

**They come from `/account/account_menu`, not from the home feed.** The home
response's topbar carries an avatar and an "Account menu" accessibility label
and no account *name*, and the name is the half that distinguishes one account
from another — which is the entire reason for showing it. The menu response is
fetched once and cached with the session, so a status call after the first is
free; `parser/account.ts` walks for the `accountItem` node by shape rather than
by path, preferring `isSelected`, because every layer above it is menu chrome.

**A failed account fetch is not a failed status.** `state` is what drives a
re-authentication prompt and it is measured independently; the name and picture
are decoration. Reporting `degraded` because a menu endpoint hiccuped would
send a perfectly good session to a login page.

**`auth.setCookie`'s `{state}` is measured before it answers.** It replaces the
browse session, **drops the base-browse cache**, then fetches home and counts
tiles — so the state it returns is the same one the `auth.verify` a client
sends next will give, and that second call is free because it hits the cache
this one filled. Dropping the cache is not an optimisation detail: an entry
written by the session a sign-in replaced would otherwise answer that verify
with an empty feed, reporting `degraded` for a sign-in that worked. Silent, and
indistinguishable from a genuinely stale cookie.

An empty or non-string `cookie` is `BAD_REQUEST`, **not** a sign-out. A caller
that sends one believed it had credentials, and answering "you are now
anonymous" would make that bug look like a successful sign-out. The rejection
names the field and never the value.

**`YT_COOKIE` seeds; the client overrides — Task 22 §8.** The environment
variable is still the development path and still works unchanged: it is the
cookie the first session is built with. Note that it does not have to be *set*
in the environment to arrive: Bun auto-loads a gitignored `.env` from the
sidecar's working directory (the repo root), compiled binary included, so a
checkout can be signed in with `YT_COOKIE` nowhere in `env`. Measured
2026-09-08, after a session came up authenticated with the variable unset in the
process, the user environment and the machine environment alike. Any `auth.setCookie` or `auth.signOut`
replaces it for the life of the process, because a user's own action is more
recent and more specific than an environment variable — and because the
alternative means a developer who once exported `YT_COOKIE` can never sign in
as anybody else, with the UI reporting success either way. The consequence is
worth stating: **sign-out cannot unset an environment variable**, so a sidecar
restarted with `YT_COOKIE` still set comes back signed in. That is the
environment restoring it, not the sign-out failing, and `auth.signOut` logs a
warning saying exactly that.

**`auth.signOut` drops four things and the list is the point:** the cookie, the
session, the base-browse cache and the cached account. Leaving any one of them
is a sign-out that reads as successful while the next request still carries the
old identity, or serves the signed-in home feed to an anonymous session for the
next thirty seconds. It is not an error to sign out of nothing.

**No cookie value ever reaches this wire, or stderr.** Two chokepoints —
`logger()` and the error envelope — pass every outbound string through
`redact.ts`, which strikes both the values the process was handed and anything
shaped like a Google auth cookie. The sidecar's own code interpolates a cookie
nowhere; what this guards against is a third party doing it (youtubei.js
quoting a failed request, a `fetch` rejection carrying headers), which is
unreachable by reading the source and silent when it happens.

### 3.2 Feeds

| Method | Params | Result |
| --- | --- | --- |
| `feed.home` | `{chipToken?, continuation?}` | `{chips[], items[], continuation?}` |
| `feed.subscriptions` | `{continuation?}` | `{items[], continuation?}` |
| `feed.watchLater` | `{continuation?}` | `{items[], continuation?}` |
| `feed.history` | `{continuation?}` | `{items[], continuation?}` |
| `subscriptions.channels` | `{continuation?}` | `{items[], continuation?}` — Task 21 §4 |

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
| `captions.list` | `{videoId}` | `{tracks[]}` — §3.8 |
| `captions.get` | `{videoId, trackId, style?, offset?}` | `CaptionTrackContent` — §3.8 |
| `video.related` | `{videoId, continuation?}` | `{items[], continuation?}` |
| `video.comments` | `{videoId, continuation?}` | `{items[], continuation?, chips?, commentCount, createParams}` — `createParams` is the comment box's submit token, null when the viewer cannot comment |
| `playlist.get` | `{playlistId, continuation?}` | `{items[], continuation?}` — **not implemented** |
| `mix.start` | `{playlistId, videoId?, params?}` | `{playlistId, title, items[]}` |
| `mix.extend` | `{playlistId, afterVideoId}` | `{items[], exhausted}` |
| `search.query` | `{q, continuation?, filters?}` | `{items[], continuation?}` |
| `search.suggest` | `{q}` | `{suggestions[]}` |

**`playlist.get` is specified and does not exist.** There is no handler for it
in `rpc/server.ts` — calling it answers `Unknown method`. The row stays because
the shape is still the intended one, but it is marked so the table cannot be
read as a list of things that work. Found while implementing Task 26, which hit
the same thing with `mix.start`.

#### Comments — Task 27

**`video.comments` is not a dedicated endpoint.** It is just a `/next` call with a continuation token, exactly like every other list continuation. The watch page (`video.info`) carries the first token inside its `comment-item-section`; fetching that token returns the first page of threads and the sorting options. The RPC method `video.comments` handles this conceptually, but underneath it executes `/next`.

**Sort options are chips.** "Top" and "Newest" are tokens the server hands back inside the first page of comments, so they are mapped as `chips[]` on the response and treated exactly like feed chips, rather than client-constructed parameters like search filters. Changing the sort clears the list and requests `/next` using the new chip's token.

**Reply and delete, deferred by Task 27 §5, picked back up and shipped.** Each
`Comment` now carries `replyParams`/`deleteParams` alongside everything else, and
`CommentsResult.createParams` is the "Add a comment…" box's own submit token —
see §3.4 for the request shapes and what was actually measured live.

**A reply list is a tree that the UI shows flat — measured 2026-09-18, and the
parser got both halves of it wrong until then.** Level-1 replies arrive as the
list's top-level items; a reply *to* a reply (`replyLevel` 2) arrives nested
inside its parent's own `replies.commentRepliesRenderer.subThreads`. Two
consequences, both silent:

- **Nested replies were dropped.** Only top-level items were read, so a thread
  advertising 2 replies listed 1. `parseComments` now flattens a reply's nested
  replies, depth-first, into the same list — but only for a comment that is
  itself a reply, so a main-list thread's inline children are still not spliced
  in among the top-level comments.
- **"Show more replies" never appeared.** A reply list's pagination token is a
  *button* — `button.buttonRenderer.command.continuationCommand.token` — not the
  `continuationEndpoint` shape a page of threads uses, and only the latter was
  read. A thread advertising 962 replies listed 5 with no way to load the rest.
  Both shapes are read now. **Known gap:** a nested reply can carry its *own*
  "Show more replies" button (more replies to that one reply); its token lands
  on that `Comment.repliesContinuation`, but nothing in the client offers it yet.

**The advertised count is not the list — and that is YouTube's, not rill's.**
`Comment.replyCount` is a display string baked into the page it arrived on.
Measured 2026-09-18 on a comment whose only reply had been removed by someone
else: the signed-in view still advertised 1 reply and its replies token
returned zero renderers, while the *anonymous* view of the same comment, at the
same moment, advertised 0 and carried no token. The client therefore trusts the
list it has actually fetched over the count it was told (`comments_section.dart`).

**A comment's like state and the creator's heart are on their own entity, not on the comment — measured 2026-09-19 (`architecture.md` F33).**
`isLiked` and `creatorHearted` are read from `engagementToolbarStateEntityPayload`
(`{likeState, heartState}`, reached through the view model's `toolbarStateKey`)
and from nothing else. The comment entity's own `toolbar` looks as though it
should carry them and does not: it holds `heartActiveTooltip` (`"❤ by @creator"`)
on **every** comment, which is the tooltip *for* the hearted state, present
whether or not there is a heart. Reading it as one marked all 120 comments of a
six-video sample hearted where the state entity says 4, and the key the parser
read for `isLiked` was never there, so that was `false` throughout. `likeState`
is the *viewer's* — an anonymous session reads `INDIFFERENT` on every comment —
while `heartState` is public, with one exception found 2026-09-20 (F35): on a video
the viewer *owns*, the creator's own view says `TOOLBAR_HEART_STATE_HEARTED_EDITABLE`
for a comment they hearted and `..._UNHEARTED_EDITABLE` for one they have not,
because they can toggle it. Both "hearted" values read as `creatorHearted`. `Comment.likeCount`
follows the state as well: the toolbar ships the count with the viewer's like in
it and without, and a comment the viewer liked is shown with the first.

**What this does and does not show about "shadowbanned" replies.** It shows the
count lagging the list in a signed-in view after a removal, which is enough to
explain "I deleted my reply and it still says 1 reply" with no hiding involved.
It does *not* rule hiding out: a reply that YouTube hides from everyone but its
author while still counting it would also produce "count > list" for a
non-author. The two are told apart by the **author's own view** — a hidden reply
is still listed for the account that wrote it, a merely-removed one is not — and
no such case has been measured. The reply that vanished from the measured
thread was not this account's, so its author's view was not available.

#### Mixes — Task 26, measured 2026-09-12

**This section used to specify `mix.start {videoId}` →
`{playlistId, items[], continuation?}`. Every part of that was wrong, and it was
wrong in the direction that reads as working.** What a live `/next` actually
does:

- **The playlist id is the parameter.** One video has at least three valid
  mixes — `RD<id>`, `RDMM<id>`, `RDAMVM<id>` — returning different contents, so
  a video id cannot name one. `videoId` survives as the optional *seed*.
- **There is no continuation token.** Not a missing one: zero occurrences of
  `"continuation"` anywhere in a mix response.
- **`index` and `playlistIndex` are ignored.** The server resolves position
  from `videoId` and corrects the caller — asking for the seed at `index: 24`
  comes back `currentIndex: 0`.

A mix response is a **sliding window centred on the anchor video**: at most 25
items of history, and exactly 24 of lookahead, every time. So extension is
re-anchoring rather than paging, and `mix.extend` is where that lives — the
client says which item it last holds, and the sidecar anchors there, slices the
tail and returns only what is new. **The window arithmetic never crosses the RPC
boundary** (hard invariant 6): a client handed a raw window would have to
reimplement InnerTube's history/lookahead semantics in Dart.

```jsonc
// mix.start {playlistId: "RD…", videoId?: "…"} — videoId is the seed, not the identity
{"playlistId": "RDdQw4w9WgXcQ", "title": "My Mix", "items": [ /* FeedItem[] */ ]}

// mix.extend {playlistId, afterVideoId} — afterVideoId is the last item the client holds
{"items": [ /* FeedItem[] */ ], "exhausted": false}
```

**`exhausted` is a field rather than an empty `items[]`, because a mix ends two
different ways** and a client cannot tell them apart from the item count alone:
the anchor is the last item the server has (how a curated `RDCLAK…` list
finishes, at ~51 items), or the server no longer places the anchor in this
sequence and answers with a re-seeded window (an auto radio, after ~169). Both
mean stop asking; the sidecar logs which fired.

**Nothing branches on `isInfinite`, which every mix sets to `true`** — including
the curated ones that demonstrably run out.

**Mixes need no auth, but they are heavily personalised.** Anonymous always
returns a full panel. The same list ids opened anonymously and signed-in at the
same moment shared 2 items of 25 (`RD`/`RDAMVM`), 1 of 25 (`RDMM`) and 7 of 25
(`RDEM`) — while a curated `RDCLAK…` was identical both ways. That is why §4 of
the task forbids caching mix contents, and why nothing here does.

**A plain watch page does not carry its own mix.** `/next {videoId}` with no
`playlistId` has no panel at all, and the video's own `RD<id>` appears nowhere
in it. `mix.start` is not redundant for the watch-page entry path.

#### A mix opens on the song it advertises — decided 2026-09-14

**Decision: starting a mix from a tile always plays the video that tile
advertises first**, whatever YouTube's response puts first. The tile is titled
"Mix - <song>" and thumbnailed with that song, so opening it on anything else is
a user clicking one thing and hearing another. It is also a consistency rule:
the same tile opens the same way every time. youtube.com does not hold this —
signed in, it regularly opens such a mix on a different song, sometimes one that
is not in the mix at all — and this app deliberately does better than it here.

**`MixItem` carries what that needs, read off the tile itself** — `seedVideoId`
and `startParams`, the `videoId` and `params` of the tile's own click target
(`watchEndpoint`). They are read from the click target rather than derived: an
auto-radio's `RD<id>` suffix happens to equal the seed, but `RDMM…` and
`RDGMEM…` mixes have no suffix while their tiles still name the video. Every
mix tile sampled carried a click target; where one does not, both fields are
`null` and the mix opens on YouTube's choice. `mix.start`'s `videoId` and
`params` are these two, passed back verbatim; `params` is opaque to the client
like a `continuation`.

**Measured, signed in, 2026-09-14** — first item is the advertised video:

| Request | Result |
| --- | --- |
| `{playlistId}` only (what a tile sent before) | 1 / 3 |
| `{playlistId, videoId}` | 86 / 90 — the misses clustered in one session |
| `{playlistId, videoId, params}` | **114 / 114**, including on a fresh session |
| `{playlistId, videoId}`, signed out | 9 / 9 |

So personalisation is what overrides the seed, and the click target's `params`
is what makes the server honour it. `params` was the same constant on every tile
sampled (`OALAAQE%3D`); it is carried from the tile rather than hardcoded so
that a change to it arrives with the response.

**The sidecar enforces the rule rather than trusting those numbers**, because a
miss appeared in roughly one session in four and 114 clean runs is evidence, not
proof. When the seed is in the returned window but not first it is moved to the
front — everything after it keeps the radio's order, and the tail `mix.extend`
anchors on is untouched. When it is absent, the same `/next` response is also
the watch page for whatever it opened on: if that page is the seed's, the seed is
prepended from it at no extra cost; otherwise the request is retried once. Only
if the seed is still absent after that does the mix open on YouTube's choice,
logged as the one case the rule cannot keep.

**`search.query`'s `filters` — decided in Task 20 §3, not chips.** A chip is a
token the server hands back in a response; a filter (upload date, type,
duration, sort by) is a token the client *constructs* from a closed set the
sidecar owns. Reusing `chips[]` with a different `scope` was rejected: nothing
about a filter comes from the response, so shipping one there would invite a
caller to render it as if the server had suggested it. A distinct `filters[]`
was also rejected — it implies a set of *options* the server offers, and there
is no such response to read them from. What ships is the third option: an
opaque, client-constructed request parameter.

```jsonc
// search.query {q, continuation?, filters?}
{"q": "lofi hip hop", "filters": {"type": "playlist", "sortBy": "viewCount"}}
```

```ts
interface SearchFilters {
  uploadDate?: 'hour' | 'today' | 'week' | 'month' | 'year';
  type?: 'video' | 'channel' | 'playlist' | 'movie';
  duration?: 'short' | 'medium' | 'long';
  /** The only verified value — see below. */
  sortBy?: 'viewCount';
}
```

`filters` is client vocabulary, not YouTube's. `search-filters.ts` is the only
place that turns it into the `params` string `/search` actually reads, and
every value in it was **measured against the live endpoint on 2026-08-27**, not
derived from a spec — `capture.ts` already leaned on one of these
(`EgIQAw%3D%3D`, type=playlist) before this task generalised it. Each
single-dimension filter is a small protobuf entry (`uploadDate`/`type`/
`duration` nest inside one field-2 submessage at inner tags 1/2/3; `sortBy` is
a bare top-level field-1 varint), and dimensions **compose by concatenating
their raw bytes** — confirmed live: protobuf merges repeated entries of an
embedded-message field as if the submessages were merged, so `type=playlist`
bytes followed by `sortBy=viewCount` bytes decode server-side as both at once.

**`duration`'s values are not 1=short, 2=medium, 3=long — they are short=1,
long=2, medium=3.** Trusting the UI's presentation order here would have
silently swapped medium and long; the real mapping was pinned by checking the
resolved videos' own `durationSeconds` (short: 66–186s, long: 1466–12202s,
medium: 254–1170s).

**`sortBy` ships only `'viewCount'`.** YouTube's picker has four options —
relevance (the default, sent as no filter at all), upload date, view count and
rating — and repeated live probes against the other three candidate field
values could not distinguish any of them from relevance by result ordering.
Most likely a search response interleaves an unsorted shelf (a live-news card
was one observed case) ahead of the sorted list, which defeats ordering as a
verification method from outside the response. `viewCount`'s effect was
unambiguous (the top results are consistently the account's highest-view
videos in the set) and is the only value shipped; the other three are a known
gap, not an oversight — see the Task 20 report.

**`search.query` carries an optional `artist` field alongside `items[]` —
Task 21 §3.** A search for an official artist's name (confirmed live with
`"Ado"`, matching `sidecar/scratch/task21-probe.ts`) returns
`officialCardViewModel`, a distinct panel above the ordinary results: avatar,
handle, subscriber/video count, description, a Subscribe action and the same
"Official Artist Channel" badge described below. Confirmed **absent** for an
ordinary creator search (`"MrBeast"` — the top result is a plain
`channelRenderer` item instead), so the panel's presence *is* the "is an
official artist channel" signal; nothing else needs to gate it.

```jsonc
// search.query {q: "Ado"} → {items[], continuation?, artist}
{"items": [...], "continuation": "...", "artist": {
  "channelId": "UCln9P4Qm3-EAY4aiEPmRwEA",
  "name": "Ado",
  "handle": "@Ado1024",
  "avatarUrl": "https://yt3.googleusercontent.com/…",
  "subscriberText": "9.51M subscribers",
  "videoCountText": "739 videos",
  "description": "Ado is a Japanese singer.",
  "isSubscribed": true,
  "mixPlaylistId": "RDEMCI2wPNzV0xPhm5R9l6ofvw",
  // Task 23 — the panel's own palette, backdrop, and top-videos shelf.
  "backdropUrl": "https://yt3.googleusercontent.com/...=w600-h176-p",
  "backgroundColor":     {"light": 4287945716, "dark": 4278999928},
  "baseBackgroundColor": {"light": 4293983231, "dark": 4278261278},
  "shelfItems": [ /* one MixItem, then VideoItems — ordinary flat DTOs */ ]
}}
// or "artist": null on an ordinary search — every other list method's
// response is unchanged; this field exists only on search.query's.
```

**The panel carries its own colour, and it is YouTube's, not a sampled one
— Task 23.** `officialCardViewModel` ships `backgroundColor` and
`baseBackgroundColor`, each an ARGB int (`0xAARRGGBB`) per theme, already
derived server-side from the artist's imagery: measured for `"Ado"` as
`#FF0C5B78` / `#FF01161E` on dark and `#FF94DBF4` / `#FFF0FBFF` on light.
Both halves ship because the sidecar has no idea which theme Flutter is
painting. This is why the client samples nothing: a palette pass over the
avatar would cost a decode, and would paint the first frame in the wrong
colour while it ran. Null when the payload omits them, which the client
renders as an ordinary untinted card.

**The backdrop is its own image, and it is not the avatar — Task 23.**
`pageHeaderViewModel.background.cinematicContainerViewModel.backgroundImageConfig`
carries a wide artwork strip (measured 600x176 for `"Ado"`, against the
avatar's square) that YouTube bleeds off the panel's top-right corner,
alongside `gradualBlurConfig` and `fadeToThemeConfig` describing how it fades
into the tint. Shipped as `backdropUrl`, null when absent. Worth stating
because the obvious substitute — blurring the avatar — renders artwork the
artist never chose for that slot, and looks like it.

**The panel's embedded shelf is modelled, and it is lifted out rather than
walked into — Task 23.** `officialCardViewModel.contents[]` holds a
`horizontalShelfViewModel` whose `items[]` are ordinary `lockupViewModel`
tiles: for `"Ado"`, one `RD…` mix followed by ten of the artist's
most-viewed videos. They map through the *existing* lockup mapper with no
new parsing, so `shelfItems` is `FeedItem[]` — the same flat DTOs every grid
already renders. `mapArtistPanel` reaches into the panel for them instead of
letting the renderer walker descend, because descending would also splice
those tiles into the surrounding search results, where YouTube does not show
them and where they would read as duplicates.

**Their metadata sits in one row, not two, and that was a live parser bug.**
An ordinary feed or search lockup splits its metadata across two rows —
channel on row 0, view count and date on row 1 — while the shelf packs all
three into a single row. `mapLockup` scanned only `rows.slice(1)` for the
detail fields, so every shelf tile arrived with `viewCountText: null` and
`publishedText: null` while the strings sat right there in row 0. The scan
is now row-agnostic (flatten first, then classify), which yields the
identical result for the two-row layout and recovers both fields for the
one-row one. The channel name stays row-0-scoped: widening it would let a
view count win that field on a tile carrying no channel at all.

**Shelf tiles carry no avatar, so the panel's is filled in.** Measured: the
shelf's lockups have no `image` key and no avatar host anywhere in the
subtree, so `channelAvatarUrl` maps to null and every tile draws a
placeholder glyph. These are the artist's uploads on the artist's own panel,
so `mapArtistPanel` backfills `avatarUrl` — but only onto items whose
`channelId` matches the panel's, leaving a guest upload (or a tile whose
channel could not be extracted) with its honest null rather than the wrong
face.

Shipped as a field on the search response rather than a new `FeedItem` kind,
per the task's own preference: `FeedItem` is a sealed union every surface
switches over, and a panel is not a grid item — widening the union would make
every surface responsible for skipping it, and `UnknownItem`'s fallback-union
behaviour is unaffected either way since nothing here touches that union.

**The panel does not carry its own subscription state inline, and reading the
obvious field is wrong.** `subscribeButtonContent.subscribeState.subscribed`
and `unsubscribeButtonContent.subscribeState.subscribed` both ship on every
response — `false` and `true` respectively — because each describes what
*that* button variant represents, not which one is currently showing. The real
answer is resolved server-side into the response's own entity store,
`frameworkUpdates.entityBatchUpdate.mutations[]`, keyed by the panel's
`stateEntityStoreKey`; `parser/feed.ts` resolves that map once per response
before mapping the panel. Confirmed live against this account's own
subscription to Ado (`isSubscribed: true`), matching the account's real state.

**`mixPlaylistId` is found structurally, not by the button's label.** The
panel's "Mix" action is a `buttonViewModel` alongside "View Channel" and
"YouTube Music", and matching on `title === "Mix"` would be matching a
localised string (the same trap `search-filters.ts` avoids elsewhere in this
document). It is found instead by shape: the one action whose endpoint carries
a `playlistId` starting `RD`, the same discriminator `isMixId` already uses
throughout `parser/items.ts`.

**Verified and "Official Artist Channel" badges — Task 21 §2, on `VideoItem`
and `ChannelItem` both.** Two closed-vocabulary signals, both
`metadataBadgeRenderer` (under `ownerBadges` on a classic search tile, or the
panel's title attachment above), disambiguated by `style` rather than
`tooltip`/`accessibilityData.label` — those are localised (this account
browses `tz=Europe.Rome`), `style` is not:

| Badge | `style` | `icon.iconType` |
| --- | --- | --- |
| Verified | `BADGE_STYLE_TYPE_VERIFIED` | `CHECK_CIRCLE_THICK` |
| Official Artist Channel | `BADGE_STYLE_TYPE_VERIFIED_ARTIST` | `AUDIO_BADGE` |

`isVerified` is the uploading/owning channel's checkmark; `isArtistChannel` is
the artist badge. Neither duplicates `badges[]` — confirmed live, no
`"Verified"`/`"Official Artist Channel"` string has ever appeared there.

**The `♪` on a music video's duration badge — Task 21 §2, `VideoItem.isMusic`,
per video rather than per channel.** Distinct from `isArtistChannel`: an
artist channel can upload a non-music video, and — confirmed on a real capture
— an ordinary channel's upload can carry the music note too.
`thumbnailBadgeViewModel.icon.sources[].clientResource.imageName === "MUSIC"`,
co-located with the duration text on the same badge node. Seen only on the
view-based badge shape in this corpus; classic tiles carry no equivalent icon
field, so `isMusic` stays `false` for anything that never reaches that node —
a real answer, not a gap, per the task's own "say so plainly" instruction.

**Shorts are classified, not stripped — Task 21 §1, and this reverses the
original "no Shorts" requirement deliberately.** Two structurally different
shapes carry a Short, and only one is changed:

- An ordinary `videoRenderer`/`lockupViewModel` carrying a `SHORTS`-styled
  duration overlay (`thumbnailOverlayTimeStatusRenderer.style === "SHORTS"`)
  is the leak this task is about — confirmed reaching search interleaved with
  ordinary videos, previously landing in `badges: ["SHORTS"]` unflagged. Now
  extracted into `VideoItem.isShort`, the same way the existing `LIVE` badge
  is pulled out rather than left as a label, and no longer duplicated in
  `badges[]`.
- The dedicated Shorts shelf (`reelShelfRenderer` → `shortsLockupViewModel`)
  is a structurally different renderer — no `content_id`, no
  `lockupMetadataViewModel` — that the existing video mapper cannot produce a
  tile from at all. It stays stripped; building a second mapper for a shelf
  this app still does not render is out of this task's scope.

**A 24/7 station is `VideoItem.isStation` — `architecture.md` F22.** YouTube
labels continuous radio/music content `"STATION"` instead of `"LIVE"`, and
F22 found it is not tied to a particular client: a plain `youtube.com`
session was observed flipping from `"LIVE"` to `"STATION"` mid-session with
nothing on the viewer's end changing, so the label is a rollout any client
can serve at any time. **Its `badgeStyle` is `THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE`**
— the same style an ordinary live badge carries, confirmed live 2026-09-11
against a real search result — so `isStation` has to be read from the label
*before* the generic style-based LIVE match runs, not instead of checking the
style at all: checking style first classifies every station as an ordinary
live tile and never reaches the label. It ships **alongside** `isLive: true`,
never instead of it: the null-duration and "watching" behaviour a live tile
needs is unaffected, this only tells the client which pill text to draw.
Kept out of `badges[]`, the
same rule `isShort` and `isLive` already follow.

**`search.suggest` is not an InnerTube endpoint — Task 20 §2 asked to confirm
rather than assume, and it does not hold.** There is no `/youtubei/v1/*` POST,
no session, and nothing to run `parse: false` over. It is a plain,
unauthenticated `GET` against Google's classic suggest service, answering
JSONP:

```
GET https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&q=<query>

window.google.ac.h(["lofi hip h",[["lofi hip hop",0,[512,433]], …]])
```

— confirmed live 2026-08-27. Only the first element of each triple
(the suggestion text) is read; the rest is client-side telemetry hinting this
project has no use for. youtubei.js has its own wrapper
(`Innertube.getSearchSuggestions`), but it sits outside hard invariant 1's
session/auth/decipher boundary — not a renderer parser, so not the failure
mode that invariant guards against, but fetching and unwrapping the JSONP
directly (`sidecar/src/search/suggest.ts`) keeps this endpoint's shape inside
code this project owns, the same as every other network boundary in
`sidecar/src`.

**`feed.subscriptions`'s empty-page ambiguity is handled exactly like
`feed.home`'s.** No chip bar (it never had one), same
`auth.verify`-after-an-empty-base-load check §3.1 already specifies, driven
client-side by the same generalised surface config Task 20 §1 built —
`checkAuthOnEmpty` in `FeedController`'s `SurfaceConfig`. Search opts out of
it: an empty search result is a real, un-ambiguous answer ("no results"), not
a signal worth spending an `auth.verify` round trip on.

**`subscriptions.channels` is a different browse endpoint from
`feed.subscriptions`, not a parameter on it — Task 21 §4.** `feed.subscriptions`
returns the video feed (`browseId: 'FEsubscriptions'`); this returns every
channel the user is subscribed to (`browseId: 'FEchannels'`, confirmed live by
its own `GetChannels_rid` tracking param and a page title of "All
subscriptions"). Items are plain `channelRenderer` nodes — the existing
`ChannelItem` mapper, Task 20's protocol-relative-avatar and
`videoCountText`-carries-subscribers fixes included, all confirmed live on
this endpoint too, so it needed no parser code beyond the badge fields §5
below adds to every surface. **Pagination is confirmed working**: a live
continuation round-trip returned a second page of 100 more channels through
the same generic `parseFeed`/`contentRoots` machinery, unchanged. **Sort order
is not exposed as a request parameter.** The response does carry a single
`A-Z`-labelled shelf-scope chip — a sort-menu trigger, not a set of
alternatives to pick between — but replaying it was not explored for this
task, and this method ships `ItemListResult` only, with no `chips[]`, matching
`feed.subscriptions` and `search.query`. Client-side search over the already-
loaded list is UI work, not a request parameter (the task's own framing).

**The A–Z scrubber depends on that unspecified default order, so the sidecar
checks it.** `AllSubscriptionsPage`'s letter index (Task 22) has no ordering of
its own: it maps a letter to a scroll offset by trusting that the response
already arrives `#`, then A–Z. That was confirmed empirically — across a page
boundary, on a real account — and it is specified *nowhere*. There is no sort
parameter to pin it with, so if YouTube's default ever changes, every letter
jump lands on the wrong row while the list still renders and the scrubber still
scrolls: a wrong answer with no error attached to it.

`parser/channel-order.ts` holds the rule (`channelBucket` must stay in step
with `letterBucketOf` in `app/lib/ui/widgets/alphabet_index.dart`), the
`subscriptions.channels` handler runs it on every **base** page and logs an
error to stderr when the order goes backwards, and `parser.test.ts` asserts it
against the real capture. The check is bucket-wise, not a full string compare:
collation *within* a letter is YouTube's business, and only `M` landing after
`N` breaks the index. Note that the corpus cannot carry this assertion —
`export-contract-corpus` rewrites every channel name to
`Sanitised Channel <n>`, which is sorted by construction.

**`VideoDetail` — the whole of `video.info`'s result.** The same DTO rules as
CLAUDE.md's list shapes: every field a value or `null`, never omitted. The
paragraphs below explain the fields that are not obvious;
`sidecar/test/contract-docs.test.ts` checks this block against `types.ts`,
types and nullability included.

```ts
interface VideoDetail {
  id: string;
  title: string;
  description: string | null;
  channelName: string;
  channelId: string | null;
  channelAvatarUrl: string | null;
  subscriberText: string | null;
  durationSeconds: number | null;     // null when live
  isLive: boolean;
  viewCountText: string | null;       // display string
  viewCount: number | null;           // exact, or null when only a rounded string exists
  publishedText: string | null;       // relative ("14 years ago")
  publishedDateText: string | null;   // exact ("Dec 6, 2009")
  likeText: string | null;
  myRating: 'like' | 'dislike' | 'none';
  isSubscribed: boolean;
  isVerified: boolean;
  isArtistChannel: boolean;
  badges: string[];
  isMembersOnly: boolean;             // structural; the members slate reads this
  premiereAtMs: number | null;        // unix ms; null unless it is a premiere
  related: FeedItem[];                // the watch page's rail
  relatedContinuation: string | null; // → video.related
  commentsContinuation: string | null; // → video.comments
}
```

**`video.info` composes two responses.** `/next` carries the watch page but no
duration — `lengthSeconds` is only on `/player` — so it fetches both. The
`/player` half asks as **`VISIONOS` over the anonymous resolve session**, which
is the same client and the same cached response ladder tier 1 uses, so opening a
video costs **one** `/player` call rather than two. Reading a length out of a
response already fetched is not the cross-client CPN bridging A5 rejects; nothing
is carried across. `/next` stays on the authenticated `WEB` session, because a
personalised sidebar, the like count and subscription state are what the cookie
is for.

**`VideoDetail.viewCount` — the exact number, measured 2026-09-13.** Derived
from `viewCountText`, the same string a client shows on hover, so a short form
("1.8B views") and the exact one cannot disagree.

**`videoViewCountRenderer.originalViewCount` looks like the answer and mostly
is not.** It is a bare integer string, but across 24 watch pages it was `"0"`
on 18 of them — each with a real count in `viewCountText` beside it — and the
actual number on the other 6. `"0"` there means "not filled in". This note first
said the watch page "ships it outright", from a measurement of one video that
happened to be one of the six, and reading the field first put "0 views" on
most videos (`0 ?? fallback` never falls back). It is kept as a fallback for
when the text cannot be parsed, and only when positive.

**Where it is `null`, the exact number is genuinely not recoverable, and that
is the field's whole point.** The three surfaces differ, and this was measured
rather than assumed:

| Surface | Exact string | Rounded string | Raw integer |
| --- | --- | --- | --- |
| Watch page (`videoViewCountRenderer`) | `"1,815,347,797 views"` | — | `originalViewCount` — `"0"` on 18 of 24 |
| Search (`videoRenderer`) | `"57,253,345 views"` | `"57M views"` | — |
| Home feed (`lockupViewModel`) | — | `"1.8M views"` only | — |

A view-based feed tile carries *only* a rounded string, so no amount of
parsing recovers the exact figure there — which is why `viewCount` is on
`VideoDetail` and not on `VideoItem`. Where a layout omits `originalViewCount`
the sidecar falls back to reading `viewCountText`, and that fallback
**refuses anything already rounded rather than guessing**: `"1.8M views"`
yields `null`, never 18. `parser/text.ts`'s `exactCountFromText` is
deliberately not `countFromText`, which strips every non-digit and would
answer 18 — right for `"1,234 videos"`, wrong for the one metadata string
YouTube routinely pre-rounds. A wrong number here is worse than none: it
would be shortened and shown as fact.

**`VideoDetail.myRating` — Task 25 §3, `'like' | 'dislike' | 'none'`.** A like
button needs to know it is already liked before the first render, or the
first click toggles the wrong way; a closed set rather than two independent
booleans, because `isLiked`/`isDisliked` both `true` at once is a state
YouTube cannot produce and the type should not admit it either. Read off
`/next`'s like/dislike toggle button, which carries the state itself
(`likeButtonRenderer.likeStatus` on the classic layout, the view-based
button's own inline `likeStatusEntity.likeStatus` on the newer one) — neither
resolved through `frameworkUpdates.entityBatchUpdate`, unlike the search
artist panel's subscribe button (§3.3 above), because this button's own
subtree already says which way it is toggled. **The view-based path is
unverified against a live capture** — built from a community reference
implementation's typed accessor for this renderer, read as documentation of
the raw shape only (hard invariant 1), not from a fixture in this repo. If
`myRating` reads wrong on a real account, start there.

### 3.4 Actions

| Method | Params | Result |
| --- | --- | --- |
| `action.addToWatchLater` | `{videoId}` | `{}` |
| `action.addToPlaylist` | `{videoId, playlistId}` | `{}` |
| `action.removeFromPlaylist` | `{playlistId, removeToken}` | `{}` |
| `action.like` / `action.dislike` | `{videoId}` | `{}` |
| `action.removeRating` | `{videoId}` | `{}` |
| `action.subscribe` / `action.unsubscribe` | `{channelId}` | `{}` |
| `action.postComment` | `{createParams, commentText}` | `{comment}` — the created `Comment`, or `null` if the response carried none |
| `action.replyToComment` | `{replyParams, commentText}` | `{}` |
| `action.deleteComment` | `{deleteParams}` | `{}` |

All execute against the authenticated `WEB` session.

**`action.postComment`, `action.replyToComment` and `action.deleteComment` —
added once Task 27 §5's deferral was picked back up, verified live 2026-09-18.**
`postComment` answers the created comment (parsed from the create response by
the same `parseComments` every list uses, so it carries a real `id` and the
author's own `deleteParams`/`replyParams`), where the other two answer `{}` —
reply is the one still to get the same treatment. All three were checked
against a real request/response rather than against youtubei.js, which has no
typed support for either (its `InteractionManager`/`CommentView` cover
like/dislike/subscribe/translate only; posting a reply goes through a
dialog-button endpoint whose real `apiUrl` its own code never surfaces, and
deleting has no method at all — `LuanRT/YouTube.js#744`, open, confirms
nothing exists there to copy).

- **A reply is a different endpoint from a top-level comment, not the same one
  with different params.** `comment/create_comment_reply` takes
  `createReplyParams`, not `createCommentParams`. The two look interchangeable
  from the outside — same `commentText` field, same general shape — and are not.
- **Delete has no endpoint of its own.** It reuses `comment/perform_comment_action`
  — the same call a comment like/dislike makes — differentiated only by a
  pre-built, opaque `action` string. There is no client-constructed delete
  request; the string comes from the comment's own data or it doesn't happen.
- **The opaque params are deterministic, not session-minted — measured
  2026-09-18.** `CommentsResult.createParams` was byte-identical across three
  separate sessions, and `Comment.replyParams` is the video id and the parent
  comment id in a protobuf. An earlier version of this note called them
  "short-lived" on the strength of one `404 NOT_FOUND` on a reply sent ~15
  minutes after its token was read; that inference did not survive the data.
  `NOT_FOUND` names an *entity*, and the parent comment that request targeted
  could no longer be found in any later listing. A 404 on a reply or delete
  means "that comment is gone", not "the token expired".
- **A `STATUS_SUCCEEDED` is not proof a comment is visible.** The create
  response carries a separate `runAttestationCommand` (BotGuard, asked of a real
  browser, after the fact) that this process cannot honour and the write does
  not wait for. Whether skipping it changes what spam filtering does to the
  comment is **not established**; the only evidence is the 2022 report
  (`LuanRT/YouTube.js#224`) of successful posts that never appeared.
- Neither response's success field sits where `action.like`'s does. Reply's is
  a top-level `{actionResult: {status}}` (matching `comment/create_comment`
  itself); delete's is one level deeper, `actions[0].removeCommentAction.actionResult.status`.
- No botguard requirement was found for either, in the same sense none was
  found for posting a top-level comment (see the comment/create_comment
  research this followed): both succeeded over a plain authenticated `WEB`
  session with no attestation field sent. `comment/create_comment` did return
  a separate, non-blocking `runAttestationCommand` alongside its success —
  worth a client honouring if it ever runs inside something that can (a real
  browser can; this sidecar cannot and did not need to for the write to land).

**Task 25 closed the write-only gap this section used to describe.** Before
this task, nothing here read state back, nothing undid a like or a Watch Later
save, and there was no way to list a video's playlists — three pieces of UI
were shaped around admitting that rather than pretending otherwise (a pill
that means "you saved it just now" rather than "is saved", a latched Watch
Later pill saying removal is not wired up). `VideoDetail.myRating` (§3.3),
`action.removeRating`, and `playlist.forVideo` below are what closed each one.
**Two of the four table rows existed only as calls the Flutter app already
made** — `action.subscribe` (`ArtistPanelCard`) and `action.like`/`dislike`
were nowhere in `rpc/server.ts`'s dispatch, so every one of those calls had
been answering `BAD_REQUEST: Unknown method` in production. `action.subscribe`
is the sharper version of the same gap `action.addToWatchLater` was in before
this task ("written and never exercised") — this one was written and could
never have run at all.

**`action.like`/`dislike`/`removeRating` do not switch `context.client`.**
youtubei.js's own `InteractionManager.like`/`dislike`/`removeRating` force the
request to `client: 'TV'` for that one call; `subscribe`/`unsubscribe` do not.
Switching client for a single call is the shape the "an action needs a client
other than WEB" stop condition describes, so it was not replicated without
evidence it is required.

**And live testing found a 400, but `client` was very likely never the
cause — measured 2026-09-11.** A first version sent `target` as the bare
video-id string `InteractionManager.like`/`dislike` build, and that same
method is the one forcing `client: 'TV'` — so the live HTTP 400 against plain
`WEB` briefly read as evidence for the client stop condition. It was more
likely a shape bug: this library's own declared type for the request is
`LikeRequest { target?: LikeTarget }` with `LikeTarget = { videoId: string }`
— an object — and the `buildRequest()` method that ships the bare string
never matches the type declared two files away, which is a stronger sign of
"written against whatever `client: 'TV'` happens to tolerate" than of "WEB
needs different treatment." Fixed to `{ target: { videoId } }` in
`actions/interaction.ts`. **Still not confirmed against a real request** —
if the object shape still 400s on `WEB`, that reopens the client question for
real.

**`action.removeFromPlaylist` takes an opaque `removeToken`, not a
`{videoId, playlistId}` pair symmetric with `addToPlaylist`.** Removing a
video from a playlist needs a `setVideoId` — the playlist *entry's* id, not
the video's, because a video can appear in one playlist more than once —
where adding does not. Recovering a `setVideoId` by browsing the playlist and
matching (what a community reference implementation's `removeVideos` does) is
an extra round trip, unbounded on a long playlist, and this task's own scope
excludes building pagination for it (`docs/tasks/25-actions.md`, "Playlist
reordering" is out of scope). `playlist.forVideo` below already receives a
ready-made removal endpoint per playlist row from YouTube's own
`get_add_to_playlist` service — the same one the real "Save to…" dialog
removes a checkbox with — so `removeToken` is that payload, round-tripped by
the client exactly like a feed `continuation` token: opaque, minted by one
call, replayed verbatim by another, never constructed or read by anything
outside the sidecar. `playlistId` is required and checked against the token
rather than trusted from it alone, so a stale token from a previous video's
dialog cannot edit the wrong playlist silently.

**Measured 2026-09-20 (F35): for Watch Later that endpoint removes by *video* id, not
by an entry id.** The token was
`{playlistId: 'WL', actions: [{action: 'ACTION_REMOVE_VIDEO_BY_VIDEO_ID', removedVideoId}]}`,
and replayed verbatim it removed the video — the first time this path ever ran
against the real service, because `containsVideo` was always false until then and
so no row ever carried a token. Whether a playlist that holds the same video twice
gets an entry-id form instead was not measured; the opaque-token design does not
depend on the answer.

### 3.9 Playlists — the save dialog

| Method | Params | Result |
| --- | --- | --- |
| `playlist.forVideo` | `{videoId}` | `{playlists: PlaylistMembership[]}` |
| `playlist.create` | `{title, privacy?}` | `{playlistId}` |
| `playlist.delete` | `{playlistId}` | `{}` |

```ts
type PlaylistPrivacy = 'public' | 'unlisted' | 'private';

interface PlaylistMembership {
  id: string;
  title: string;
  privacy: PlaylistPrivacy | null;   // null when the response carried no recognised value
  containsVideo: boolean;
  removeToken: string | null;        // opaque; hand back to action.removeFromPlaylist. Present only when containsVideo
}
```

**`containsVideo` is read from a string, not a boolean — measured 2026-09-20
(`architecture.md` F35).** `containsSelectedVideos` is `"ALL"` for a video in that
playlist and `"NONE"` for one that is not (`"SOME"` exists for a request naming
several videos and cannot occur here). The parser tested `=== true` for as long as
this section has existed, so `containsVideo` was `false` for every row of every
video and `removeToken` was always `null`; the unit test fed it `true`, a value
YouTube does not send. Anything but `"ALL"` is now "not in it".

**One call answers both halves the save dialog needs** — Task 25 §5 asked for
"the user's playlists" and, separately, "which playlists already contain this
video." `playlist/get_add_to_playlist` is the single InnerTube endpoint
YouTube's own dialog is backed by, and it answers both at once: splitting them
into a generic playlist listing plus a per-video membership check would
invent a round trip that dialog never pays. Watch Later needs no special
case either (Task 25 §7): it is one row of this same response, at its fixed
id `'WL'`.

**Not paginated, as a property of the endpoint rather than a choice made
here.** The request (`{videoIds, playlistId?, params?, excludeWatchLater}`)
and the response carry no continuation-shaped field in the shape this was
built against. **Unverified against a live capture in this repo** — read from
a community reference implementation's typed request/response classes,
treated as documentation of the raw shape only (hard invariant 1), not from a
fixture. Confirm against a real account, especially one with many playlists.

**Reading it structurally, not by a fixed container path, for the same
reason every other parser in this codebase does.** The exact wrapping
renderer name above `playlistAddToOptionRenderer` was not confirmed against a
live response either; `playlistsForVideo` scans for that renderer by key
wherever it sits.

**The Save dialog's checkbox does not wait for `action.addToPlaylist` /
`action.removeFromPlaylist`, and does not revert on failure — a deliberate
exception to §4's optimistic-then-revert rule, not an oversight.**
`ACTION_ADD_VIDEO` and `ACTION_REMOVE_VIDEO` are idempotent server-side (an
already-added video or an already-removed one both just no-op), so there is
nothing a client waiting for the answer could still get right that tapping
alone did not already settle. An earlier version *did* wait — for a
`playlist.forVideo` refetch meant to confirm the edit took — and that produced
a worse bug live: the refetch could still answer "not in the playlist" for an
entry its own preceding write had just created (propagation lag, not a client
bug), silently un-ticking a save that had, in fact, already landed, and
driving a real duplicate-add loop as the user retried a checkbox that kept
looking like it failed. Not waiting removes the failure mode instead of
timing around it. The UI shows a brief (~150–300 ms) spinner unrelated to the
real round trip, purely so a tap reads as registered; a failure still reaches
the user as a snack bar, it just does not roll the checkbox back.
`playlist.delete` has no UI entry point in the dialog by product decision —
the method stays for whatever surface picks it up later.

**`playlist.create`'s `privacy` is optional**, and omitting it sends no
`privacyStatus` at all — untested what YouTube defaults a bare
`playlist/create` to. **`playlist.delete` asks for no confirmation of its
own**; that step is the client's job, like any other destructive action in
this app.

### 3.5 Playback

| Method | Params | Result |
| --- | --- | --- |
| `playback.open` | `{videoId, preload?, playlistId?}` | `PlaybackSource` |
| `playback.report` | `{sessionId, positionMs, state}` | `{}` |
| `playback.close` | `{sessionId}` | `{}` |

```jsonc
// PlaybackSource — identical in Phase 1 and Phase 2
{
  "sessionId": "…",
  "durationMs": 634000,
  // Unix ms when a live broadcast started, for the "how long has this been
  // live" clock (§2.9-adjacent UI, not documented further here) — null for
  // anything that is not live, and for a live stream whose own /player
  // response carried no start time (an MWEB fallback then fills it in;
  // see the live-manifest note below).
  "startTimestamp": null,
  "storyboardTemplate": "https://…",
  "qualityDegraded": false,
  "transport": "plain",            // "plain" | "hls" | "dash" | "sabr-dash" | "ytdlp"
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

**Resolution ladder**, tried in order inside `playback.open`. The numbers are
names rather than positions — code, tests and logs use them — so tiers 2 and 3
keep theirs while not being in the ladder:

1. `VISIONOS` plain adaptive URLs — the primary path; no `n`, and libmpv can
   consume them directly (F5, F11, F13)
2. *Not in the ladder.* `MWEB` plain adaptive URLs, retired 2026-08-19: they
   refuse the open-ended range ffmpeg always sends (F10), so this tier could
   resolve a video but never play it. `architecture.md` §2.4
3. *Not in the ladder.* SABR → local DASH bridge — Phase 2, unbuilt
4. `yt-dlp` subprocess with PO token provider — age-restricted, Vevo, edge cases
5. itag 18 progressive, 360p, from an `ANDROID` `/player` response — the floor:
   usually present, **not guaranteed** (F9); sets `qualityDegraded`

**Nothing in this ladder deciphers.** `VISIONOS` and `ANDROID` URLs carry no
`n`, and yt-dlp runs its own transform. Every address still passes through the
`SignedUrl` door below, so the boundary holds; what no longer runs in
production is the signature and `n` transform behind it.

The floor is a very good bet, not a promise. On 2026-08-02 an `MWEB` response
came back carrying no progressive format at all, so every rung can decline and
`playback.open` can answer `STREAM_UNAVAILABLE` for a video that is perfectly
fine. The UI obligation follows from that: **"Unavailable" is a state the user
can retry out of, not a verdict on the video.** That is what `retry: "user"`
means in §4 — show the error, offer the retry, and do not loop silently.

**Tier 1 has a second path, gated on `response.isLive`, for a stream that
is actually live** (Task 24; `architecture.md` F23). A `VISIONOS` `/player`
response for a live broadcast carries `hlsManifestUrl`/`dashManifestUrl`
instead of (or alongside) the ordinary adaptive ladder; when `isLive` is set,
`tierPlainAdaptive` hands that manifest URL to mpv directly — signed through
the same `sign()` door as everything else, per hard invariant 2 — and reports
`transport: "hls"` or `"dash"`. **The gate is load-bearing, not defensive
boilerplate**: `VISIONOS` includes an `hlsManifestUrl` on ordinary VOD
responses too (confirmed on four unrelated non-live videos), so without the
`isLive` check this path took over essentially every tier-1 open — F23 has
the full story, including the reported symptom, and it is the reason Task
24's own test list says "assert the VOD case too" rather than only the live
one.

**`isLiveContent` is a permanent tag, not a current-status signal.** Confirmed
live 2026-09-11 on a VOD that ended a year prior: `isLiveContent` stays `true`
forever, while `isLive` becomes absent and `liveBroadcastDetails.isLiveNow`
becomes `false`. OR-ing `isLiveContent` into an `isLive` check breaks VODs
because it nulls the duration, causing the player to treat an ordinary VOD
as a live stream computing its "live edge" from a year-old `startTimestamp`
and refusing to seek backward. The authoritative signal is `liveBroadcastDetails.isLiveNow`,
with `isLive` as the fallback for clients that carry no microformat.

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

**A watch inside a mix is reported as one — Task 26, measured 2026-09-12.**
`playback.open`'s optional `playlistId` is recorded on the playback session and
reaches the watchtime ping as `list=`. It has to travel this way because
`playback.report` takes a `sessionId` and nothing else, so the session is the
only thing that still knows which playlist the watch belonged to by the time a
report goes out. Measured: a `WEB` `/player` asked with a `playlistId` carries
`list=<id>` in its `videostatsWatchtimeUrl` and one asked without carries no
such parameter at all — so before this, every mix watch trained the recommender
as a standalone watch, which is the signal F6 exists to protect.

**The playlist id is part of the `/player` cache key, not a variant of it.**
`client:videoId` was already wrong — it served one entry for two responses that
genuinely differ — and the mix work is what made that visible rather than what
caused it. A call with no playlist keeps exactly the old key, so every existing
caller still shares one entry and one fetch; `player-response.test.ts` pins
that, including that an explicit `null` keys the same as an absent one. **The
resolution ladder deliberately asks without a playlist id**: a mix changes
nothing about which streams exist, and splitting the resolve cache by playlist
would buy a second `/player` round trip per open for nothing.

**Each cached response also records the player revision its
`signatureTimestamp` was sent for — Task 04 §1.** The script that deciphers a
response's `s`/`n` comes from a separate, TTL-bounded lookup that can move to a
newer revision in between: a cache entry minted minutes earlier, or a rebuild
landing between one call's fetch and its decipher. Deciphering that pair is the
failure hard invariant 2 exists to prevent — a wrong `n` is not rejected, it
streams at ~50 KB/s. So the tiers check at the point of use: once playability is
settled, and before anything is signed, the response's recorded revision is
compared with the player about to decipher it. On a mismatch the response is
refetched once under the current revision; if the revision has moved again by
then, the tier declines rather than decipher a mismatched pair. The revision is
not part of the cache key, because the point-of-use check already covers a stale
entry and a second mechanism would add nothing. The check is skipped when nothing
in the response would reach a player script — no `signatureCipher`, no `n` on
any URL — which is true of `VISIONOS` and `ANDROID` today, so a player rollout
costs the production ladder nothing.

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

It reads one field out of the **`VISIONOS` `/player` response that
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


### 3.8 Captions

**Added 2026-08-18.** Two methods, because the two questions have different
costs: *does this video have captions* is answered from a response already in
hand, and *give me this one* is a fetch.

```jsonc
// captions.list {videoId, allowFallback?, includeStyled?}
{"tracks": [
  {"id": ".en", "languageCode": "en", "label": "English",
   "isAutoGenerated": false, "styled": null, "isTranslatable": true},
  {"id": "a.en", "languageCode": "en", "label": "English (auto-generated)",
   "isAutoGenerated": true, "styled": null, "isTranslatable": true}
]}

// captions.get {videoId, trackId, style?, offset?}
{"trackId": "a.en", "languageCode": "en", "format": "ass",
 "content": "[Script Info]
…", "cueCount": 402,
 // Task 19. Eight numbers per *track*, not per cue.
 "layout": {"fontFamily": "Arial", "fontSize": 48,
            "playResX": 1920, "playResY": 1080, "margin": 60,
            "outlineWidth": 2.5, "boxPadding": 6,
            "defaultAlignment": 2, "defaultX": 960, "defaultY": 1020,
            "lineSpacing": 1.2},
 // §2.10. The same values as on the track entry in captions.list, but
 // populated here unconditionally — captions.get always fetches the document,
 // so classification is never deferred. null only if classification threw.
 "styled": "plain",          // plain | styled | karaoke | null
 "positional": false}        // true → multiple anchors; drag is suppressed
```

**Both optional parameters are Task 19's, and both change the *document* rather
than anything about the fetch.** Each is omitted by a client that has not touched
the style menu or dragged a caption, and a request without them is
byte-identical to what §3.8 returned before they existed.

There were two more. `metrics` carried a client-measured advance table so the
sidecar could estimate a cue's width and clamp a dragged `\pos` inside the frame,
and `renderer` told it which of two caption pipelines the document was for. Both
were removed with the mpv pipeline in phase 5 — see `architecture.md` §2.9 — and
a request that still sends either is not an error, only ignored: they are read
nowhere.

```jsonc
// style — the caption style menu. `null` on a field means "the track decides".
{"fontFamily": null, "fontSizePercent": 150,
 "textColor": {"r": 255, "g": 255, "b": 0, "a": 1},
 "background": {"r": 0, "g": 0, "b": 0, "a": 0.75},
 "window": {"r": 0, "g": 0, "b": 0, "a": 0},
 "edgeStyle": "outline"}          // none | outline | dropShadow

// offset — the drag, as a fraction of the frame. Added to whatever position
// the source gives, so one rule covers plain, ASR and styled tracks alike.
{"dx": -0.2, "dy": -0.3}
```

**They are applied here and not through mpv properties**, and that is measured
rather than preferred: `sub-ass-override=force` overrides the ASS `Style` and not
the inline override tags a styled track is made of, so the property route works
on plain tracks and silently does nothing on styled ones — on exactly the tracks
a style menu is aimed at. `architecture.md` §2.9 has the rest.

**`offset` is a delta and the sidecar does not clamp it.** The position it
produces is the cue's own anchor plus the delta, rounded, and nothing else. It
used to be pulled back inside the frame against the estimated width `metrics`
supplied, because the mpv pipeline could not see where libass had put the line;
the client renders the document itself now and clamps against the boxes
`ass_render_frame` returns, so the no-overflow rule is enforced where the real
geometry is. A client that sends an offset is asking for a position, and gets it.

**`layout` is the document's own constants**, sent rather than duplicated in the
client because two copies of a layout constant are two things that have to agree
and eventually will not. Always populated — the document is in hand, so it costs
nothing — whether or not the caller reads it. Absent from an older sidecar, and
the client falls back to these defaults.

**No URL crosses this boundary.** A `timedtext` address is signed —
`sparams`, `signature`, `expire` — and the sidecar is what fetches it. `id` is
YouTube's `vssId`, an opaque handle the client hands back. This is hard
invariant 2's reasoning applied to a second endpoint: nothing outside the
sidecar holds a URL whose signing it does not own. `id` rather than
`languageCode` because a language has up to two tracks — `.en` manual and `a.en`
auto-generated — and a code cannot address them separately.

**Every format converts to ASS in the sidecar; Flutter draws no captions.**
`content` is a complete ASS document the client hands to libmpv. The decision and
what it rules out are in `architecture.md` §2.9. `format` is `"ass"` today and is
sent anyway, because the client passes the body straight to a subtitle demuxer
and a silent format change renders as nothing at all rather than as an error.

**A track list far shorter than youtube.com's picker is correct.** YouTube ships
one real track beside ~156 `translationLanguages`; those are machine
translations of that track, reachable by appending `&tlang=`, and they are not
tracks. Translations are out of scope.

**`tracks: []` is a settled answer, not a not-yet.** The `VISIONOS` → `MWEB`
fallback has already run by the time `captions.list` answers, so an empty array
means the UI hides the CC control rather than waiting. Measured 2026-08-18 over
a 45-video feed sample: 32 videos carried tracks, 13 carried none, and no video
had tracks on one client and not another — the fallback fired 13 times and
rescued nothing. It is kept because the gap was observed before and a fire rate
that moves is how a client-behaviour change gets noticed; the INFO line it logs
per fire is what makes that visible. It is **not** on the video-open path — see
below.

**The fallback asks `MWEB`, not `WEB`.** A `WEB` `/player` signs its caption URLs
with `exp=xpe` inside `sparams`, and every one of them answers **HTTP 200 with a
zero-byte body** — isolated to that one parameter, since removing it invalidates
the signature and answers 404 while the same URLs from `VISIONOS` and `MWEB`,
which carry no `exp`, return the document. A `WEB` fallback would therefore
populate a language picker in which every entry renders nothing, which reads as
broken captions rather than as absent ones. `WEB` `/player` is also reserved by
§3.5 for the authenticated report path.

**Captions are not on `VideoDetail`, and that is what keeps §3.3 true.** The
track list is free — it rides on the `/player` response `video.info` already
fetches — but a *complete* list costs the fallback's second `/player` call, and
on the ~29% of videos with no captions that would fire on every open. §3.3's
"opening a video costs **one** `/player` call rather than two" would stop
holding. So the watch page issues `captions.list` **alongside** `video.info`
rather than reading a field out of it: the fallback runs concurrently with the
open instead of inside it, and nothing about playback waits for captions.

**`styled` is opt-in, and `null` is its ordinary value.** It is `'plain'`,
`'styled'` or `'karaoke'` — a closed set rather than a bag of flags, because the
picker badges it with one word and deciding *which* word belongs on the side that
can see the document.

**`'karaoke'` is a subset of `'styled'` and is only answered when nothing wider
is true** — a track that karaokes *and* changes font is `'styled'`. It is also
not a field: the first attempt keyed on a `pPenId` on a `seg` and badged all
three styled test videos, because per-segment pens are equally how a track
colours one word or sweeps a gradient across 23 000 pens. What karaoke actually
is, is temporal — the same line re-emitted with the split between two pens moving
forward. Measured 2026-08-19, that finds the two cues in `L-BgxLtMxh0` that
visibly karaoke and nothing in `1S7uIQmkRzk` or `8Oos6D4_Bjo`.

A client that meets a value it does not know **badges nothing** rather than
printing the token — the set is expected to grow.

It cannot be answered from the `/player` response: the styling arrays are in the *caption document*, one
`timedtext` GET per track. Measured 2026-08-19 on `dQw4w9WgXcQ`: six real tracks,
**69 KB and 73 ms** fetched together, because they parallelise into one round
trip's latency. That is affordable for a menu and not for a video open, so the
caller asks with `includeStyled: true` and the watch page's own call does not.
The sidecar caches the answer per track, so reopening the menu is free.

**The predicate is `pens`, and the obvious one is wrong.** *Every*
auto-generated track has `wsWinStyles` and `wpWinPositions` populated — that is
how its rolling window is expressed — so "any of the three styling arrays" marks
every ASR track in the app as styled and means nothing. On that same six-track
sample, `pens` was empty on all six and the two window arrays were populated on
the ASR track alone.

There is no equivalent flag for auto-generated, and none is needed: `label` is
YouTube's own and already reads `English (auto-generated)`.

**`trackName` is the only other thing YouTube declares, and it is usually `''`.**
Measured 2026-08-19, a caption track entry carries exactly `name`, `vssId`,
`languageCode`, `kind`, `isTranslatable` and `trackName` — nothing about styling,
which is why the flag above needs the document. `trackName` is how a channel
tells apart two tracks in one language ("Commentary", "Forced"); when it is set,
`label` alone renders two identical rows.

Two tracklist-level fields are read by nothing today and are worth knowing about:
`captionsInitialState` (YouTube's own recommendation for whether captions start
on) and `audioTracks[].defaultCaptionTrackIndex`.

**`cueCount` counts lines on screen, not events in the document.** A styled track
transmits one caption as several overlapping events with different pens, and the
sidecar merges them — `L-BgxLtMxh0` is 511 events and 265 cues. See
`architecture.md` §2.9; nothing on the wire changed, but a client comparing the
two numbers would find them unequal on every styled track.

`captions.get` caches **parsed cues** per video and track, and rendered documents
per track *and render options* — so switching between two languages costs one
fetch each and nothing after that, and a style change or a drag costs a render
rather than a fetch and a parse. Measured 2026-08-20: ~1.2 ms of render on an
ordinary document, 33 ms on the largest in the corpus. The options are part of
the document cache's key on purpose; keyed on the track alone it would hand back
the previous colour and the menu would appear not to work. Asking for a
`trackId` the video does not have is `BAD_REQUEST` — a stale track list or a
constructed id, and the same request fails identically forever.

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
| `AUTH_REQUIRED` | `no` | Login flow |
| `BAD_REQUEST` | `no` | This is a client bug. Surface it — never retry, never swallow |
| `STREAM_UNAVAILABLE` | `user` | "Unavailable" state on the video, with a retry affordance |
| `VIDEO_UPCOMING` | `no` | The premiere slate: thumbnail, scheduled time, reminder. **Not** an error state |
| `VIDEO_MEMBERS_ONLY` | `no` | The members slate: thumbnail, the channel, a Join affordance. **Not** an error state |
| `RATE_LIMITED` | `user` | "YouTube is limiting requests from this connection", with a retry — never "would not open" |
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

**`VIDEO_MEMBERS_ONLY` is `VIDEO_UPCOMING`'s shape, for a different clock —
added 2026-09-09.** A members-only video exists and works; it is behind the
channel's paid tier, and no rung of the ladder can buy a membership. So it ends
the ladder rather than declining down it, and it is `no` because retrying is
arithmetic-proof in the same way a premiere's is. It is deliberately **not**
`AUTH_REQUIRED`: signing in does not help, and the user is usually signed in
already.

**Two signals, and only one of them is structural.** The flag on the DTOs —
`VideoItem.isMembersOnly` and `VideoDetail.isMembersOnly` — comes from
`BADGE_STYLE_TYPE_MEMBERS_ONLY` (or the `SPONSORSHIP_STAR` icon) on a
`metadataBadgeRenderer`, which YouTube does not localise. **The error code does
not have that luxury.** Measured 2026-09-09 on `rAWLNJoE5_Y`, the whole of
`playabilityStatus` on the resolve clients is `{status, reason,
playableInEmbed}`: VISIONOS carries no `errorScreen` at all, MWEB's is a generic
`playerErrorMessageRenderer`, and only the authenticated `WEB` response — which
the resolve path never makes — has the specific
`playerLegacyDesktopYpcOfferRenderer`. So `playback.open` classifies from the
`reason` prose.

That is tolerable only because of where it sits: it refines a response that has
**already failed**, so a locale the pattern misses falls back to
`STREAM_UNAVAILABLE` — today's behaviour — and it can never make a working video
fail. The watch page draws its slate from the structural flag on `video.info`,
not from the error, for exactly this reason.

**The slate does not claim the user is not a member**, and that is a correctness
point rather than a wording one. Stream resolution is anonymous (§2.3), so a
members-only video refuses even for a paying member; YouTube's own "Join this
channel" prose describes the anonymous session that asked, not the person
reading it.

**`RATE_LIMITED` is YouTube throttling this connection — decided 2026-09-17.**
Anonymous resolution is limited per connection: F20 hit "Sign in to confirm
you're not a bot" after ~180 resolutions in an hour. `playback.open` answers
`RATE_LIMITED` when a tier gets that refusal (`LOGIN_REQUIRED` with YouTube's
"not a bot" wording) and no tier gets through:

- **Not `LOGIN_REQUIRED` alone.** An age gate answers with the same status
  ("Sign in to confirm your age") and is a different problem. Like
  `VIDEO_MEMBERS_ONLY`, this reads prose on a response that has already
  failed, so a locale the pattern misses falls back to `STREAM_UNAVAILABLE`.
- **Not a bad visitor id.** Tier 1 has already retried once with a fresh id by
  the time the refusal is believed (§3.5).
- **Not terminal.** yt-dlp or the 360p floor may still get through, so the
  ladder keeps going, and only a ladder that ends with nothing — having seen a
  throttle on the way — answers `RATE_LIMITED` instead of `STREAM_UNAVAILABLE`.
- **`user`, not `auto`.** A throttle lasts minutes to an hour, so a silent
  automatic retry would be a spinner that never ends. The watch page names the
  cause and leaves the retry to the user.

**There is no `AUTH_DEGRADED` — removed 2026-09-17.** A degraded session is not
a failure the sidecar can see: it answers HTTP 200 with an empty feed (F7). So
it is a *state*, reported by `auth.verify` / `auth.status`, which the app
checks after an empty base feed (§3.1, `checkAuthOnEmpty`). The code sat in this
table with a UI response for months while nothing ever sent it.

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

`fixtures/` is replaced wholesale by one run of `bun run capture`, so every
fixture there needs an owner and `sidecar/src/fixtures.ts` is where ownership is
declared — `CAPTURE_FILES` for what a run writes, `CARRIED` for what it must
preserve because another tool made it. The promote refuses on anything in
neither list, and on any required file the run failed to produce. A fixture
written into `fixtures/` by hand and left undeclared is a fixture one recapture
away from gone, and the tests that read it then skip in silence rather than
fail — which is how three comment fixtures spent a month one command from
deletion (`todo.md` 41, closed 2026-09-20).
