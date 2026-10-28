# Todo

Work that is agreed but not done. Each entry carries enough context to be picked
up cold: what the problem is, where it lives, and what "done" means.

This is not a task spec archive — `docs/tasks/` is that, and those files record
what was asked for at a moment in time. This file is the live backlog, and an
item leaves it when the work lands.

**Ordering is by section, not by line.** Within a section nothing is ranked.

**Numbers are permanent.** Other files cite items by number, so a finished item
is deleted and its number is not reused; gaps are expected.

**Next number: 110.** A new item takes it, and the same edit bumps this line.
The highest number still in the file is not a substitute — once that item is
finished and deleted, it would hand the same number out twice.

---

## Now

### 44. Leaving audio-only can wedge: "playing", and nothing moves

**Reported 2026-09-25, rare, never caught live, cause unknown.** Switching from
audio-only back to video occasionally never finishes: no picture, no sound, the
position frozen, and the player still claims to be playing — space, `k` and
clicks do nothing. It is not the loading state. Going back to audio-only
resumes it at once, and leaving audio-only again then works. Not the 0:00 stall
(item 43, closed — `architecture.md` F42): that was an *open* with nothing
selected; this is a restore mid-playback.

**Contained, not diagnosed.** `PlaybackController._armRestoreWatchdog` watches
every restore: if the player says it is playing while the position has not
moved for 15 s, it does what fixes it by hand — video track off and on — and if
that wedges too, reopens the same variant at the same position through the
quality-switch path, once. `test/restore_watchdog_test.dart` drives the
symptom through the fake engine; nothing there reproduces the cause.

**When it happens again, read the release log first**
(`%LOCALAPPDATA%\rill\logs\rill-*.log`). The watchdog writes
`rill: stuck after leaving audio-only at <ms> (picture …, buffering …, buffer …)`
and which recovery it tried. `picture` is `vo-configured`: `false` means the
video output never came back, `true` means a picture that never moved. The
normal restore writes `rill: audio-only -> video, picture back in <ms>`, and a
restore with no picture after 30 s writes `rill: no picture after leaving
audio-only`. Which of those lines appear, and whether the recovery line is
followed by a resume, is the first real data on this.

**What "done" means.** The cause found and fixed at the source, after which the
watchdog either goes or stays as documented containment. The 15 s grace is
above the 2.9–8.0 s restores §2.4 measured on purpose — the recovery drops the
video cache again, so firing on a merely slow restore would make it slower —
and it is a guess until a real occurrence says otherwise.

---

## Soon

### 56. Sign-in and sign-out: two questions left after Task 31

Task 31 (`docs/tasks/31-sign-in-edges.md`) fixed the five rough edges the user
found on 2026-10-01: the first sign-in landing on the empty-feed message, no window
buttons on the login page, sign-out leaving the old account's state on the open
page, blocked actions looking enabled, and comment votes on rows loaded signed out.
The user checked all five by hand on a release build the same day, and they hold.
Two causes are still unknown; neither blocks anything.

1. **Why the first sign-in answered `degraded` — not reproduced since.** Two fresh
   sign-ins after the fix (2026-10-01) were both `authenticated` on attempt 1, so
   the bounded retry in `login_page.dart` never ran and the log has nothing to
   compare yet. Both successful jars held `APISID, HSID, SAPISID, SID, SSID` and
   the `__Secure-1P*` / `__Secure-3P*` cookies, and **no `LOGIN_INFO`**: so
   `LOGIN_INFO` is not needed, and its absence is not the test for an incomplete
   jar. When a `rill auth: attempt 1 answered degraded` line turns up, compare
   that attempt's full name list with the next one's: different names mean the jar
   was incomplete; the same names mean YouTube had not honoured the session yet.
   Record the answer in `architecture.md` and keep or drop the retry accordingly.
2. **Comment votes: which failure it was is unmeasured.** The list is now
   re-fetched on every identity change, so a vote is always made on rows fetched
   under the identity voting, and the user confirmed votes stick. What the old
   failure was — (a) null params, (b) an RPC error or (c) an RPC success YouTube
   did not record — was not measured: it needs the burner account's `YT_COOKIE`
   (fetch a page anonymously, call `action.rateComment` with its params signed in,
   re-fetch, read `myRating`, undo). From the code, (a) is ruled out (the params are
   present on anonymous pages) and (b) would have shown a snackbar, so (c) is the
   likeliest. If the probe confirms it, it is the next free `architecture.md`
   finding (F51 went to Task 32's AXTree cause): a success
   that did not land.

A third point from the task report was checked and dropped: it said a mix tile
tapped while signed out "fails after the round trip with *Sign in to play
mixes*". Nothing showed that. `architecture.md` F24 measured anonymous mixes
working, `mix.start` runs on the browse session, which is anonymous when signed
out, and that string is only the message `startMixFromTile` would show if the
call ever answered `AUTH_REQUIRED`.

### 39. Comments: four gaps left after replies, delete and the comment box

Found 2026-09-18 while fixing reply lists (`protocol.md` §3.3, "A reply list is
a tree that the UI shows flat"). None is a regression; each is a known hole.
Numbers are stable: item 4 (the viewer's like state and the creator's heart)
landed 2026-09-19 (`architecture.md` F33) and is gone; so is item 6 (a thread
keeping its expansion when it scrolls away, and the reply list being lazy),
landed 2026-09-20 (`architecture.md` F34).

1. ~~**A reply's own "Show more replies" is unreachable.** A reply can carry a
   load-more button of its own (more replies *to that one reply*). The parser
   now puts its token on that `Comment.repliesContinuation`, but nothing in the
   client offers it: a reply's `replyCount` is `""` on the wire, so
   `comments_section.dart` never shows a toggle for one. Measured: a thread
   advertising 106 replies pages to 104.~~ Done 2026-09-21: a reply whose token
   is non-null offers a control loading into the same flat list, and every
   comment carries a real depth. The 106-reply thread (now advertising 700 replies) pages out to 678 replies, proving the gap is structural (deleted/hidden replies).
2. **`action.replyToComment` still answers `{}`,** where `action.postComment`
   answers the created comment. A fresh reply is therefore a local stand-in with
   no id and no delete token until the list is refetched. **Capture a live
   `create_comment_reply` response first** — only its action *name*
   (`createCommentReplyAction`) has been seen, not where the thread sits in it —
   then parse it the way `createdComment` in `actions/comments.ts` does.
3. **`video.comments {videoId}` with no continuation returns nothing.** `/next`
   with a bare `videoId` answers the watch payload, whose comments live behind
   an engagement-panel continuation; `parseComments` then finds no thread and
   returns an empty list that reads exactly like "no comments". The app never
   takes this path (it always sends `commentsContinuation`), so it bites only a
   caller that does. Filed as a separate task when found; recorded here so it
   is not lost if that is dismissed.
5. **The comments widgets are only partly tested.** The page fetch now goes
   through `CommentsSource` (`lib/data/comments_source.dart`), and
   `comments_section_test.dart` covers a re-sort superseding the page in flight
   (`$cancel` plus a generation guard, which the first delivery lacked), leaving
   mid-load, a change of video, the like/heart rendering, and the lazy reply list
   (a thread's expansion, replies and half-typed reply surviving a scroll away,
   and a re-sort or a new video forgetting them). **Still
   untested,** because they call the `RpcClient` singleton directly: post, reply
   and delete — including `_postComment`'s guard against landing in another
   video's list — and the rules in a thread's own state: the reply count
   trusting a *complete* list, load-once, optimistic reply and delete. Task 27's
   own "Tests" section also asks for per-thread pagination isolation (two
   expanded threads must not interfere), which holds by construction and is not
   asserted. **Done when:** post, reply and delete take a seam like
   `CommentsSource`, and those cases are asserted.

   **Half of this landed 2026-09-21, and the half that landed is the seam.**
   `CommentsSource` now carries `post`, `reply`, `delete` and `rate`, so all
   four writes go through something a test can fake, and the widgets no longer
   touch `RpcClient.instance` at all. **Only `rate` is asserted through it**:
   the blob each transition sends, the optimistic flip, the revert on failure,
   the same on a *reply* (a different list from the threads', held by the
   thread's state), and the two disabled states. It was done for `rate` first
   because a vote is the write whose failure is least visible — one that
   silently does not stick looks exactly like one that did. Post, reply and
   delete now have the seam and still have no tests, as do the thread-state
   rules and the pagination isolation above; that is what is left.
7. **Settled 2026-09-21 — the provenance gap this item described does not
   exist, and the one-off fixture stays.** The item claimed that *a third
   party's comment the viewer liked* lived only in the ad-hoc
   `fixtures/comments-viewer-state.json`, and that remaking it would mean
   mutating a stranger's comment. Checked against the fixtures rather than
   assumed: `viewer-state/comments-before.json` and `comments-after.json` each
   hold **three comments by `@edualvarado5091`** — not the account — that the
   viewer has liked and hearted, and `comments-disliked.json` holds three more.
   So that state is in the **state-proven** family already.

   **And the reproducible path was already the one being used.** The account
   likes and hearts other people's comments *on a video it owns*; the mutation
   is entirely on the viewer's side, nobody else's content changes, and
   `capture-viewer-state.ts` captures it every run. Nothing needs inventing.

   **What is genuinely only in the one-off** is a plain
   `TOOLBAR_HEART_STATE_HEARTED` read in a *signed-in* session — the
   `…_EDITABLE` variant is what the creator sees, and the plain one otherwise
   comes from `comments-after-anonymous.json`. F33 established that `heartState`
   is public and identical in the signed-in and anonymous views, so that
   combination proves nothing the anonymous capture does not. Its remaining
   value is breadth: 20 comments from six strangers against the pair's four
   from one.

   **Decision: it stays a one-off and stays `CARRIED`.** That costs nothing —
   the declaration is one line and `capture.ts` already carries it — and the
   stakes are lower than this item assumed, because no assertion depends on it
   uniquely. `parser.test.ts`'s signed-in state check is the only test that
   names it, and it is guarded by `hasFixture`. Nothing further to do.

**Done when:** each is fixed, or deliberately dropped with the reason written
next to it.

### 42. Thread nesting lines in the comments list

youtube.com draws an L-shaped rule from a thread down to each of its replies,
and a vertical rule continuing past a reply that has children of its own. rill
draws none: nesting is conveyed by indentation alone (`_replyIndent`, 44 px),
which at one level reads as a slight offset rather than as structure. The user
asked for this 2026-09-21 with a reference screenshot of youtube.com's own
rendering.

**What is left is the drawing.** The structural prerequisite landed 2026-09-21:
the parser provides real depth, so the flat list carries `Comment.depth` and the
rules can be drawn from it. The constraint on how:

**The widget list is flat by design.** F34 turned the section into one
`SliverList.builder` over `_flatten()`'s `[thread, reply, reply, …, footer]`
rows, so replies build lazily and a scrolled-away row costs nothing. A rule
spanning a thread and its replies spans sibling rows that are never all built
at once, and no widget owns the span. That is not a bug and must not be undone —
the F34 numbers say what owning-the-subtree cost (a 500-reply thread took 345 ms
to re-expand).

Two approaches, and the implementer picks — neither is prescribed:

- **Per-row, stateless.** Each row paints only its own slice: one vertical
  segment per ancestor that still has a sibling below it, plus the elbow into
  its own avatar. Needs only each row's depth and "is this the last child of its
  parent", both of which `_flatten()` can put on `_Row`. Composes with lazy
  building for free, because a row that is not built is a row whose slice is off
  screen anyway. This is the shape the user suggested, and the likelier answer.
- **One painter behind the list.** A `Stack` with a `CustomPaint` under the
  sliver, given the rows' laid-out rectangles. Fewer widgets, but it needs
  geometry the list only knows after layout and has to stay correct while rows
  are recycled, which is the part that usually goes wrong.

**Done when:** a thread with replies
shows a continuous rule from the thread to its last reply and no further, at
every depth the data actually contains; it survives scrolling a long thread in
and out of the viewport; the F34 measurements are re-run and the per-frame build
cost has not moved materially; and it is checked in the running app against the
reference screenshot, both layouts.

### 40. Deep links to a comment (`&lc=`)

Agreed 2026-09-18, measured, not built. youtube.com opens
`watch?v=<id>&lc=<commentId>` on that comment and puts a "Highlighted comment"
badge above it. rill has no deep linking of any kind. **Wanted:** the same badge;
scroll to the comment; **pause** the just-opened video (whoever follows this link
came for the comment); pulse the comment's container two or three times.

**Measured (`architecture.md` F32), anonymous, live:**

- The linked token is the plain `commentsContinuation` plus one protobuf field,
  `#16 = "<commentId>"`, in the nested message at `#6.#4`. A token built that
  way (decode, append, re-encode with the enclosing lengths recomputed) put the
  target **first, exactly once**, in a 20-thread page — **no scraping of the
  watch page**.
- The badge text arrives as `commentViewModel.commentViewModel.linkedCommentText`
  = `"Highlighted comment"` (server-supplied, localised).
- A link to a **reply** (`lc=<parent>.<reply>`) returns the *parent* thread first,
  with the reply in `replies.commentRepliesRenderer.teaserContents[0]
  .commentViewModel` (which carries `linkedCommentText`) and **no** `subThreads`
  — a shape `parseComments` does not read.

**Stage 1 — links to top-level comments:**

1. **Sidecar.** `video.comments {continuation, linkedCommentId}` builds the token
   and asks `/next`; `Comment.isLinked: boolean` from `linkedCommentText`
   (restated in all five places `CLAUDE.md` lists, plus the corpus sanitiser).
   The token is *constructed*, which is exactly the "community references are
   hypotheses" case — it is verified against a real response, but guard it: if
   the first thread is not the requested comment, log it and fall back to the
   ordinary list with no highlight, never a wrong one.
2. **Entry.** No OS protocol handler (`rill://`, registry) — that is a separate,
   larger piece. Instead: a pasted YouTube URL with `lc` in the search box
   (`topbar.dart`, `_submit`) → `openWatch` (`player_shell.dart`) with a stub
   `VideoItem` carrying the id (the watch page fills the rest from
   `video.info`); and a **Copy link** action on every comment producing
   `https://www.youtube.com/watch?v=<videoId>&lc=<commentId>`.
3. **Client.** Badge above the highlighted thread; pulse its container; pause via
   `PlaybackController.setPlaying(false)` — but only once the media is open, or
   the open resumes it; on the narrow layout select the Comments tab first
   (`_narrowTab`, `watch.dart`).
4. **Scroll is the risk.** The watch page is a `SilkyCustomScrollView` with only
   a `PageStorageKey` (`watch_layout.dart`) — no controller — and the comments
   build lazily far down it, so the target has no `BuildContext` to
   `ensureVisible` on when the page opens. Needs a controller plumbed through
   `WatchLayout`, an approximate jump, then a retry until the target mounts.
   Read `architecture.md` §2.8 (the watch page's sharp edges) first.

**Stage 2 — links to replies:** read `teaserContents`, open the parent thread
with the linked reply first and highlighted. Until then a reply link should land
on the parent thread, without the badge.

**Done when:** pasting the example link opens the video **paused**, the comments
section scrolled to the highlighted comment with its badge, pulsing; Copy link
round-trips through the paste; a link whose comment no longer exists degrades to
the ordinary list. Tests: the token builder (mutation-checked, including "field
absent → target not first"), the parser's `isLinked`, and a widget test for badge
and pulse. Run the app and say what you saw — both layouts.

### 33. Playback opens paused while media_kit says it is playing

Seen 2026-09-17 in a release build that had been running for a while, and
once under a debugger; not reproduced in a fresh launch. A video opened from a
tile shows its first frame with the clock at 0:00 while the controls show
*pause* — media_kit's `playing` is `true` — and hover previews do not start
(they are suppressed while the shell reports playing). One play/pause press
starts the video and flips the button to *play*; a second pair resyncs them,
until the next video. Previews that do start show one frame and stop.

The inversion is mechanical once mpv is really paused: `Player.playOrPause()`
flips media_kit's own `state.playing` and sends `cycle pause` to mpv, so if
the two already disagree, each press keeps them disagreeing. So the question is
what leaves mpv paused (or stalled) after `open()` set `pause=no` — media_kit
ignores mpv's `pause` events while `isPlayingStateChangeAllowed` is false,
which is one way a change can go unseen.

A lead, not a cause: this machine's audio devices hotplug every ~15 minutes
(WASAPI `OnDeviceStateChanged`, seen in both engines' logs), and a freshly
launched app, which has not been through any, behaved. A stalled audio output
would hold an external-audio stream at 0:00, but would not by itself explain
the inverted button.

Next time: run with `RILL_MPV_LOG=<path>` and note the time it happens. The log
has the app's calls, media_kit's belief and mpv's real `pause` side by side.

**Done when:** the cause is known and fixed, or recorded if it is outside the
app.

### 59. Playlist detail page

The page is built (Task 35, `ui/pages/playlist.dart`): a header card with the
artwork, title, owner, counts, visibility and description over the playlist's
own tint (`architecture.md` F55, F56), the whole list with paging, Play all, and
Share through `share_dialog.dart`. A playlist tile's title opens it, and so does
"Go to Playlist" in the queue header's menu. What is left:

- **Save, Shuffle, and the owner's Add videos and Edit** are drawn disabled, each
  saying it is not available yet. Shuffle is a queue order; the other three need
  their requests measured first.
- **The header's actions, as decided on 2026-10-14** (replaces the row above
  once built; one row for everyone, no second row for the owner):
  - A split button: **Play all**, and its menu **Shuffle**, **Play in reverse**,
    **Play next**, **Add to queue**.
  - **Save**, on someone else's playlist only. **Share**.
  - A three-dot menu: **Show unavailable videos** (the request is unmeasured);
    and on the viewer's own playlist **Add all to…**, **Edit playlist details**,
    **Settings**, **Delete**.
  - On the viewer's own playlist, an **"Add videos"** row with a dotted border at
    the top of the list. It is not a row of the playlist and takes no number.
    youtube.com's own dialog is a Google web page Rill cannot show; ours would
    be a link or a search, then the edit the Save dialog already makes. Last.
  - Both menus sit in a card that scrolls, so each needs the close-on-scroll
    guard the queue header's menu has (`architecture.md` §2.8).
- **Row numbers stay the playback position** (decided 2026-10-14): 1 is what
  plays first, as in the queue panel, whatever order the playlist is sorted in.
- **Shuffle is done in the client** (F58: youtube.com's server only picks a
  random start). Decided 2026-10-14: start on a random row of what is loaded,
  at once; then load every page and shuffle all the rest, the whole playlist
  and not page by page. Play in reverse loads every page first too.
- **Play next and Add to queue turn the queue into a plain one** (decided
  2026-10-14). Today a queue keeps its source through any edit and keeps
  extending from it. A mix stops being one: what is loaded stays, nothing more
  is fetched. A playlist with pages still unloaded loads them all first, then
  becomes plain. The header then says "Queue", and the number column and
  "Go to Playlist" go. The playlist being added is loaded in full by a loader of
  its own, since the queue has one loader today.
- **Editing the viewer's own playlist** (title, visibility, removing a video):
  `action.removeFromPlaylist`, `playlist.create` and `playlist.delete` exist,
  anything else is measured first.
- **The owner is text, not a link.** `ownerChannelId` is carried and unused until
  channel pages exist (item 61).
- **Unavailable entries** are omitted by YouTube anonymously and need parameters
  not yet sent, so they have no signal besides not arriving.
- **No continuation response has been captured.** `corpus/playlist-get-continuation.json`
  is a first-page capture parsed as a continuation: it pins the answer's shape,
  not how a real continuation body is walked. A real one needs a stage in
  `capture.ts` and a declaration in `fixtures.ts`, then a capture run.
- **The rest of the corpus is older than the fixtures beside it.** Running
  `export-contract-corpus` on 2026-10-13 rewrote 21 committed entries, because
  the local fixtures are a later capture than the one those came from; only the
  two new `playlist-get-*` entries were kept. A full re-export is a decision of
  its own, and it would also bring the playlist entries up to F57's view counts.
- **Not read with Narrator, and not walked with `RILL_FOCUS_PROBE`.** The page's
  Tab order, its tap targets' names and its selectable text are asserted by test
  only (`focus_traversal_test.dart`, `playlist_page_flow_test.dart`). The
  semantics probe does walk it now (steps `7b`–`7f`: open, scroll, Play all,
  back, leave), and logged no `AXTree` error in four release runs on 2026-10-14,
  three on a public playlist and one on a private one the account owns; that
  probe presses no Tab.

**Done when:** the four disabled buttons work or are gone, and the owner's
controls change a real playlist.

### 60. History screen

`feed.history` is specified in `protocol.md` and marked not implemented. Wanted:
a page listing watch history that scrolls back through continuations, and a
**search** over it if YouTube offers one to this client. youtube.com's history
page has a search box, but whether the `FEhistory` browse takes a query from the
`WEB` client is unmeasured. Signed-in only; signed out it says why
(`signedInActionBlocker`). youtube.com also has "remove from history" and
"pause history": record them, build them only if they measure cheap.

**Done when:** a history page reachable from the rail pages back through real
history, search works or the page says it is unavailable, and the protocol
marking is gone.

### 61. Channel (profile) pages

Nothing opens a channel. Clicking a channel's name or avatar should open its
page: banner, avatar, name, handle, subscribers, subscribe button, and tabs
(Home, Videos, Live, Playlists, …) — **never Shorts**, as everywhere. Needs a
sidecar method, measured first: the `/browse {browseId: UC…}` response and each
tab's `params`. Reuse `SubscribeButton` and what the artist panel
(`artist_panel_card.dart`) already draws.

**Done when:** every channel name and avatar (feed, search, watch page, comments)
opens the page, the Videos tab pages, and subscribing follows the identity rules
(Task 31).

### 62. The artist badge is missing on queue items and tiles

The verified badge shows everywhere; the **artist** badge only where the response
itself says so. Queue rows never get it (a mix panel row carries no badge at
all, F24), and media tiles no longer do (they used to; YouTube may have stopped
sending the flag with the tile). The cache cannot fill the gap yet:
`verified_channels_controller.dart` stores channel ids seen **verified**, and
`ChannelBadge` only ever warms it from `isVerified`. `isArtistChannel` is never
cached, so which badge a channel has is lost.

**Fix:** record the badge kind in the cache (verified or artist; keep the id key
and the LRU, and migrate the stored list), warm it from every surface that does
report `isArtistChannel` (the watch page, the artist panel), and have
`ChannelBadge` read it. Before blaming YouTube for the tiles, compare a fresh
capture with an older fixture: a parser change could have dropped the flag.

**Done when:** a channel seen as an artist anywhere shows the artist badge in the
queue and on tiles, with a test for the cache storing and returning the kind.

### 63. Watch page: the skeleton and the loading layout disagree

The watch page loads in two visible stages, the skeleton (`watch_skeleton.dart`)
and then the real page with placeholders while `video.info` is still out, and
the two do not line up, so the content jumps between them. Make the skeleton
match the loaded page's geometry (title block, channel row, action pills,
description, rail) in every layout (normal and theatre, wide and narrow), or drop
one of the two stages.

**Done when:** skeleton → placeholders → data with nothing moving except content
appearing, checked in the running app in each layout.

### 65. Player: the background shows outside the rounded corners

With the controls bar open, the player's background shows a few pixels outside
its corner radius. Likely the controls' backdrop or gradient is clipped
differently from the video (or not at all), or the two clips anti-alias
differently. Everything inside the rounded player should sit under one clip
(`player_shell.dart`, `controls.dart`).

**As of 2026-10-12** the watch page's player clip (`watch.dart`,
`_PlayerSurface`) uses `Clip.antiAliasWithSaveLayer`, which draws everything
first and clips once (`architecture.md` §2.8). Still to check: 150 % scaling,
and whether the miniplayer and the fullscreen layer need the same.

**Done when:** nothing shows outside the radius with the controls open or closed,
at 100 % and 150 % display scaling.

### 66. Rail: the collapsed view lacks entries the expanded one has

`page_wrapper.dart`'s rail shows things expanded that it does not offer
collapsed. List both, decide what each should hold (youtube.com's mini guide is a
deliberate subset), and make sure nothing important is unreachable from the
collapsed rail.

**Done when:** every destination in the expanded rail is reachable collapsed, or
its absence is a decision written in the code.

### 67. Comments: selectable text, clickable links and timestamps

Comment text cannot be selected, its links do nothing, and its timestamps
(`1:23`) do nothing. The text already arrives as runs (`CommentTextRun`,
`CommentStyleRun`, `CommentCommandRun`, `CLAUDE.md` DTO block), so the commands
are there. Wanted: selectable with the mouse (a `SelectionArea`); a link opens in
the browser, or in the app when it is a YouTube link (`domain/youtube_link.dart`
parses those); a timestamp seeks the current video when the comment belongs to
it.

**State on 2026-10-14:** a timestamp run already has a tap that seeks
(`_CommentText` in `widgets/comments_section.dart`), a link run has none, and
neither works in the running app as reported that day. Why the timestamp's tap
does not land is not looked into: start there, since nothing has to be built for
it. A comment under another video than the one playing must not seek.

**Done when:** all three work in the running app, with a widget test for a
timestamp seeking and a link being dispatched.

### 93. Playlist page: links in the description do nothing

A playlist's description is drawn as plain text (`_PlaylistDescription`,
`ui/pages/playlist.dart`), so a link in it cannot be clicked or reached by Tab.
The watch page's description already does this for a video (`LinkifiedText`,
`ui/pages/watch.dart`): it finds the links in plain text, which is all
`PlaylistHeader.description` is.

- A YouTube link opens in the app: a video on the watch page, a playlist on its
  page (`videoIdFromLink`, `playlistIdFromLink`). Anything else opens in the
  browser.
- The link colour has to be legible on every playlist tint; the theme's accent
  is not, which is why "Show more" uses the card's own ink.
- Each link is a Tab stop, in the header's order before "Show more", and only
  the links in the three visible lines while it is collapsed, as on the watch
  page.
- The three-line measure in `_PlaylistDescription` has to measure the same
  spans it draws.

**Done when:** a link in a playlist's description opens, by mouse and by
keyboard, with a widget test for each of the two destinations.

### 68. Search: filter chips

youtube.com shows chips above search results (All, Videos, Unwatched, Recently
uploaded, Live, …). rill has the full filters dialog (`SearchFilters`, Task 20)
but no chips. Measure where they come from in the `/search` response (probably
tokens, like the home chips) and draw them like the home chip bar. No Shorts
chip.

**Done when:** the chips YouTube returns for a query show above the results, and
choosing one reloads through its token.

### 84. Videos with AI dubs can play in the wrong language

Reported 2026-10-01. Some videos open with a dubbed audio track instead of the
original. Example: `MLgrNktS67c` (Xisumavoid, English only) played in another
language in rill, and correctly on youtube.com. It carries dozens of audio
tracks, most of them YouTube's automatic AI dubs.

**The cause is visible in the code.** `rankAudio` (`playback/resolve.ts`) picks
the audio by DRC, then stereo before surround, then **bitrate**. It knows nothing
about languages, and the parser keeps no track information at all
(`parser/player.ts` maps `isDrc` and nothing like it), so with dozens of
same-itag tracks whichever has the highest bitrate wins. Each adaptive audio
format describes its track: an `audioTrack` object (display name, id, an
is-default flag) and track tags in the URL (`xtags`: original, dubbed or
auto-dubbed, and the language). Which of these the `VISIONOS` response actually
carries is unmeasured. Check the other ladder tiers (yt-dlp, the itag 18 floor)
too.

**Wanted, in order:**

1. **Original audio by default.** Parse the track fields into `PlayerFormat`,
   and rank the original (or the track YouTube marks as the default) first.
   This alone fixes the report.
2. **An "Audio track" entry in the player's settings menu,** as youtube.com has,
   to switch track for the current video. Signing every track's URL up front is
   wasteful with dozens of them, so list the tracks and sign the chosen one on
   demand. That is a new protocol method or a `PlaybackSource` field, measured
   and specified first.
3. **Later, with the settings page (item 69):** a switch to "play a dubbed track
   in my language when there is one" (off by default), and an ordered list of
   preferred languages. youtube.com keeps its version of these at
   `youtube.com/account_playback`. Measure whether the account's own setting can
   be read for the signed-in user; otherwise keep it local.

**Done when:** `MLgrNktS67c` and a few other multi-track videos play their
original audio on every tier. A test with a fixture holding several tracks shows
the original ranked first even when a dub has a higher bitrate. Mutation: rank by
bitrate alone, and the test fails.

(Added 2026-10-01 as item 83; that edit was lost when Task 32 rewrote this file, and the number went to its follow-ups, so this is 84.)

### 105. The previous video's last frame stays on the player when another video replaces it

Reported 2026-10-24: click another video while one is playing (or paused), and as soon as the
watch page opens the player still shows the **last frame of the previous video**. After roughly half a
second or less it turns black and the spinner arrives, and from there everything is right. The old
frame belongs to a video the viewer has already left, and for that moment it reads as the new video
being the old one.

**Where to look (a guess, not measured):** the half second is about the time `playback.open` takes to
answer, and `MediaKitEngine.open` only runs after that. Until then the shared video texture still holds
the old frame: `PlaybackController.open` resets the state (`isLoading`, `source: null`) but nothing
tells the engine, whose `open` clears `width`/`height` (what the quality menu reads) and not the
picture, and the only call that blanks it, `stop()`, is made on a failed open. The old audio probably
carries on over that window too, which is worth checking, since stopping it is part of the same fix.

**Two ways, to be tried:**
- Stop the engine when a *different* video starts opening (`_engine.stop()` beside `_endSession` in
  `open`): the picture and the old sound go at once. Care: `open` is also the retry path for the same
  video, where stopping is wrong, and `playback.report` must still get its last position first (it
  reads `currentPosition` in `_endSession`, so it goes before the stop).
- Cover the surface instead: draw the scrim over `engine.videoSurface()` while `isLoading` and no source
  is open yet, as the quality-switch cover does (`playerSwitchCoverKey`, architecture §2.7). Nothing
  about the engine changes, but the old audio would still play, so this one alone is not enough.

**Care:** the watch page, the fullscreen layer and the miniplayer all show the same surface; whichever
is chosen has to work in all three, and the cover must not be an overlay above something that mounts
or fades (CLAUDE.md, Accessibility).

**Status 2026-10-26:** the user saw the old frame go instantly on some clicks and linger for a couple of
frames on others, so the thumbnail cover is in (`VideoLoadCover`, on the watch page, the fullscreen layer
and the miniplayer; it comes off on `videoOutputReady` once the open has ended, with a 10 s safety net).
To be looked at by eye again before this item leaves.

**Status 2026-10-25:** the stop is in (`open` stops the engine when the id differs, after `_endSession`
has taken the position; tests in `new_video_stops_engine_test.dart`, mutation-checked). **Not yet seen
with eyes:** whether the surface goes black on that stop. The black the viewer reported arriving after
the half second is when `MediaKitEngine.open` runs `Player.open`, which stops first, so a stop probably
blanks it; if the last frame still shows, cover it with the new video's thumbnail (not black) while
`isLoading` and no source is open. The cover comes off on the engine's existing first-frame signal (the
one behind `vo-configured`, `videoOutputReady`), not on a timer.

**Done when:** opening another video from the feed, a tile on the watch page, a playlist row and the
queue never shows the previous video's frame, and a test with the fake engine shows the engine being
stopped (or the cover being up) before `playback.open` has answered, and not for a retry of the same
video.

---

## Low priority

### 45. Covers for the songs YouTube does not credit — try YouTube Music search

**Deferred 2026-09-25, on purpose.** A music mix lists at most 10 credits, so
the chapters past the tenth (and any video with chapters but no credits) show the
video's still, not the song's cover (`architecture.md` §2.12). The idea, not yet
tried: search YouTube Music for `"<artist> <song>"` from the chapter's text, as
the `WEB_REMIX` client, take the first *Song* result and its square cover (same
image host as the credits, `=s1200`), one request per uncovered chapter, cached
per video.

**Decide whether to build it after living with chapters for a while** — how
good the result is without it decides whether it is worth a new client. If built:
verify the response shape against a real capture (a reference implementation is a
hypothesis here, `CLAUDE.md`), and reject a result whose title and artist do not
match the chapter with the same word-overlap rule the credits use, so it cannot
put a wrong cover on a right title. **Third-party cover APIs (iTunes, Deezer,
MusicBrainz) are rejected**, not deferred.

**Done means** a chapter with no credit shows a cover that is the right song's,
or the still when nothing trustworthy came back.

### 36. Report the F28 race to media-kit, and drop the vendored copy when fixed

`third_party/media_kit_video` exists only because upstream has the race
(`architecture.md` F28), and nobody upstream knows. The issue is written:
`third_party/media_kit_video.upstream-issue.md` holds the title and body —
summary, stack, root cause, the sleep-based reproduction and a clean diff
without this repo's comments. Before posting, re-check that `main`'s
`windows/video_output.cc` still has the race and that the diff still applies
(`git apply --check`). A PR with the same diff is offered in the text.

Once posted, put the issue URL in F28 and in `app/pubspec.yaml`'s override
comment. When a release fixes it, remove the `dependency_overrides` entry and
`third_party/media_kit_video`, keeping `media_kit_libs_windows_video` pinned
at 1.0.11.

**Done when:** the issue is filed; the vendored copy is gone once a fixed
release is out.

### 35. Check the other `media_kit_video` bugs a blind review reported

While confirming F28, a Gemini 3.1 Pro agent reviewed the unmodified 1.3.1
Windows code with no context and did not find F28 — it reported these four
instead. None is verified; the plugin is vendored now
(`third_party/media_kit_video`), so any that hold can be fixed in place.

1. `video_output_manager.cc` — `Create`/`SetSize`/`Dispose` run on detached
   threads capturing `this`; a plugin destroyed first (hot restart, shutdown)
   is used after free.
2. `video_output.cc`, `~VideoOutput` — the promise it waits on is only
   fulfilled inside `if (texture_id_)`, so a `VideoOutput` disposed while
   `texture_id_` is 0 waits forever. **Read and looks real.** `Resize` leaves
   `texture_id_` at 0 from the unregister until the new texture is published —
   upstream's window, which the F28 patch extends only by the insert.
3. `~VideoOutput` posts `mpv_render_context_free` and returns; an update
   callback firing in between calls `NotifyRender` on a freed object.
4. `Resize`'s unregister callback captures `this` by reference and may run
   after the object is gone (it checks `destroyed_` only after locking a member
   mutex).

Each touches disposal, which the app does on every preview hover-out, so the
cheap test is the same one F28 used: a delay that widens the window, and a
probe that exercises it.

**Done when:** each is confirmed and fixed in the vendored copy, or ruled out
with the reason written here.

### 12. Caption legibility at small render surfaces

Two related pieces, and neither is a renderer problem — it is a size problem that
exists under mpv and under `LibassLayer` alike.

**Previews** are the cheap half. A hover preview runs on a second
`MediaKitEngine` with no `LibassLayer` mounted, so `_isSubtitleVisible` stays at
its `true` default and `hover_preview.dart:298`'s `engine.setSubtitle(ass)`
renders through mpv's `sub-add`. That means the lever is one mpv property —
`sub-scale` or `sub-font-size` on the preview engine. No pipeline work.

**The general case** is a size floor that scales with the render surface, applied
in whichever renderer is active. Worth measuring rather than assuming, because
the two renderers may need different levers to reach the same result: mpv scales
subtitles relative to the window by default, while `LibassLayer` renders at the
document's `PlayRes` and scales down. That measurement is also a good early test
of whether the two renderers can hold parity: `LibassLayer` on the main player,
mpv on previews (`architecture.md` §2.9).

The miniplayer redesign to ~600 px shrinks this problem but does not remove it.

### 13. Suppress caption drag by mount point

The drag-lock predicate in `LibassLayer` is `track.positional != true` — a
property of the **track**, not of where the video is being drawn. There is one
`LibassLayer`, mounted once at `app/lib/ui/player_shell.dart:359` outside all
three mount-point branches and positioned by `CompositedTransformFollower`
against `engine.videoLayerLink`, so it follows whatever the video texture
currently is.

Nothing in that path knows whether the video is in the watch page, the
miniplayer or the fullscreen layer. If dragging is to stay disabled in the
miniplayer — and it should, at any size — that has to enter the predicate.

Settle it before the miniplayer redesign rather than after.

### 14. Consolidate the probe entrypoints

Eight probe files across four directories, each env-gated differently:
`ui/auth_probe.dart`, `ui/audio_delay_probe.dart`,
`ui/player/{captions,controls,launch,libass}_probe.dart`, `ui/debug_player.dart`,
and `lib/probe_task19.dart`.

`lib/probe_task19.dart` is **correctly placed** and should stay at `lib/` root —
it and `main.dart` are the only two files in `app/lib` with a top-level `main()`,
and lib/ root is where Flutter convention puts entrypoints. It only reads as
orphaned because nothing says so.

Churn warning: `architecture.md` references several of these by path inside dated
findings, so moving them costs doc edits for tidiness only. Low priority on
purpose.

### 15. A portable parser corpus

`sidecar/fixtures/` is gitignored and must stay that way — it holds raw InnerTube
responses for the real account's home feed, watch history and subscription list.
Committing it publishes viewing history permanently, and git keeps it after a
later delete.

`corpus/` cannot substitute: it is sanitised **DTO output**, and the parser's job
is raw→DTO, so testing the parser against its own output side proves nothing.

So a fresh clone's green `bun run check` is partly hollow. `parser.test.ts:42`
already says so out loud when fixtures are missing — *"with them skipped, a
parser regression is a green suite"* — but that warning lives only in the test
file.

The real fix is a small hand-authored corpus of **synthetic raw renderer trees**:
a dozen nodes covering each vocabulary entry, written by hand, containing no
account data. Committable, portable, and it makes the offline gate mean
something on a machine that has never run `bun run capture`.

Until then, CLAUDE.md's Commands block should say that `bun test`'s parser half
needs `bun run capture` first.

### 16. Persist the members-only preference

`app/lib/ui/members_only_preference.dart` — every feed surface already reads
`membersOnlyVisibleProvider`, its own comment says *"Not persisted yet"*, and
nothing calls `.set()` / `.toggle()`. There is no settings UI to reach it from.

**Blocked on:** an app settings screen. Listed here rather than nowhere, because
the whole point of this file is that work deferred for good reasons and recorded
nowhere is how Task 04 §1 disappeared for two months.

### 17. Two small UI gaps

- `app/lib/ui/player/settings_menu.dart:749` — `//TODO add fps when it is not 30`
- `app/lib/ui/player/shortcuts.dart:147` — `// TODO add end and home for seeking
  to the start and end of the video`

### 32. Local crash capture with Crashpad

Nothing inside the process can catch the crashes seen so far. A fast fail
(`0xC0000409`, `0xC0000602`) skips every in-process handler, and the engine's
`abort()` is its own statically linked copy, so neither
`SetUnhandledExceptionFilter` nor a `SIGABRT` handler in the runner sees it.
The release log (`architecture.md` §2.11) now records *that* a crash
happened and its code, and whatever was printed before it — but not the stack,
which is what named the cause of F28.

Found 2026-09-17: `HKCU\Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\rill.exe`
exists with `DumpType = 2`, so every rill crash — the exit-time one of F27
included, until it was fixed — currently writes a **full** dump, with the session cookie, to
`%LOCALAPPDATA%\CrashDumps`. That dump is how F28 was solved, and it is also a
cookie on disk after every close. **Kept deliberately (decided 2026-09-17)**
until this item lands: the stack is worth more than the risk, and the rule
stands — read a dump, then delete it, never attach it. Ordinary exits no
longer produce dumps (`architecture.md` F27, fixed 2026-10-01).

Crashpad — directly, or through `sentry-native` with uploading disabled — runs
an out-of-process handler and registers a WER runtime exception module
(`WerRegisterRuntimeExceptionModule`), which *is* called for fast fails. It
writes a minidump to a folder the app chooses.

**The dump is the problem to design around.** A minidump can carry the session
cookie (see above). So: symbolise it into a text stack as soon as it exists —
`flutter_windows.dll.pdb` ships in the FVM engine artefacts, and the runner's
PDB comes from the build — then delete the dump, and keep only the text. The
symbolising step needs those PDBs at hand, which a user's machine does not
have; decide whether that happens on the next launch against bundled PDBs, or
the dump is kept briefly and handed over deliberately.

Also decide the native build: Crashpad's handler is a separate executable that
ships beside `rill.exe`.

**Done when:** a forced fast fail in a release build leaves a symbolised stack
in the app's data directory and no dump on disk.

### 46. Windows ARM64 build

**Blocked by the native stack, not by CI.** The x64 installer already runs on
Windows-on-ARM under emulation (`architecture.md` §2.13), so this is about
running natively, not about running at all.

- `media_kit_libs_windows_video` 1.0.11 (pinned exactly, `CLAUDE.md`) hard-codes
  `mpv-dev-x86_64-20230924-git-652a1dd.7z` in its `windows/CMakeLists.txt`. An
  arm64 libmpv means a different build with a different FFmpeg, so invariant 8
  applies in full — scan *that* binary's string table, do not probe it — and the
  F13 seek freeze the pin exists for has to be re-measured.
- `app/windows/libass_bundle` is MSYS2 MINGW64 (x86_64) DLLs
  (`THIRD_PARTY_LICENSES`); arm64 needs the CLANGARM64 equivalents.
- The ANGLE archive the same plugin downloads has not been checked for arm64.
- `sidecar` compiles with `bun build --compile`; whether the pinned Bun (1.1.42)
  can target Windows arm64 has not been checked, and a newer Bun means
  re-measuring the sidecar.
- Hosted Windows arm64 runners may be public-repo only or absent from the plan;
  check before writing the job.

**Done when:** `Rill-Setup-arm64.exe` is built by the release workflow, starts on
a real arm64 machine, and plays a video.

### 47. macOS port

Not started; there is no `app/macos/`. GitHub-hosted macOS runners can build it
(Flutter emits a universal arm64 + x86_64 `.app` in one build, and Bun
cross-compiles the sidecar for both darwin targets, to be joined with `lipo`), so
CI is not the obstacle. The port is. It is roughly:

- `media_kit_libs_macos_video` is a different libmpv from the Windows one, so
  every finding measured against the Windows build (F13, F19, the invariant 8
  scans, the audio-only teardown costs in `CLAUDE.md`) is unmeasured there.
- Windows-only pieces need a counterpart or a guard: the SMTC / taskbar
  controllers, `log_capture.cpp`, the libass DLL search (`dll_search.dart`),
  `bitsdojo_window` chrome (`window_chrome.dart`) and Ctrl-vs-Cmd shortcuts.
- `rill.ps1` and `setup.bat` are Windows-only.
- Without an Apple Developer account there is no notarisation, so first launch
  needs the "Open Anyway" bypass. The in-app updater has to decide how it replaces
  a `.app`.
- The author has an Intel Mac to test on; arm64 can only be tested in CI or on
  someone else's machine.

### 48. Authenticode-sign the installer

The installer is unsigned, so SmartScreen says "unknown publisher" on each fresh
download. The update manifest is signed separately and is what protects
*updates* (`architecture.md` §2.13); this is only about the first install.
Options are Azure Trusted Signing (about $10 a month; check eligibility for an
individual in the EU) or a purchased certificate. Reputation still has to build
up per certificate, so a signed installer can warn for a while regardless.

**Done when:** the workflow signs `Rill-Setup-x64.exe` before it is hashed into
`update.json`. Signing after hashing invalidates the manifest.

### 50. `sidecar/bun.lock` cannot be read by the Bun the sidecar is built with

**Measured 2026-09-26.** `sidecar/bun.lock` is `lockfileVersion 1` with a
`configVersion` (it has been since the initial commit), a format Bun 1.1.42 rejects
with `InvalidLockfileVersion`. 1.1.42 is what `rill build` uses on this machine and
what both `sidecar.exe` copies embed. So a plain `bun install` here ignores the
lockfile and re-resolves the `package.json` ranges, and `bun install
--frozen-lockfile` fails outright. The installed `node_modules` happens to match the
lockfile's direct dependencies exactly (youtubei.js 18.0.0, typescript 5.9.3, …), so
the lockfile is the record of what was installed; nothing here says which Bun wrote
it.

**Why it matters.** youtubei.js is the session, auth and decipher layer (invariants
1 and 2), so a range that floats to a newer patch is a change to the part of the
sidecar that breaks silently. The release workflow works around it by installing
with a current Bun and building with 1.1.42 (`architecture.md` §2.13), which is
correct but is a workaround for a mismatch that should not exist.

**Done when:** one Bun both reads the lockfile and builds the sidecar — either the
pinned Bun moves (and the sidecar is re-measured: the ~6.3 s `bun run` cold start,
the `sidecar.exe` size, `rill build`) or the lockfile is regenerated in a format
1.1.42 reads — and the workflow's two-step Bun install collapses into one.

### 51. Two Windows plugins still use a feature Microsoft will remove

**Where it stands (2026-10-23).** The app builds on Visual Studio 2026 (MSVC 14.51)
since `ec202a7`, which defines `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`
in `app/windows/CMakeLists.txt`. This machine builds with it, and so does the
release workflow, whose two Windows jobs moved from `windows-2022` to
`windows-latest` (image `windows-2025-vs2026`) after a trial run passed end to end
(gate, build, installer smoke test, publish up to the release step). What is left
is that the define is a silence, not a fix.

- **The plugins.** `flutter_inappwebview_windows` (23 errors without the define) and
  `flutter_media_session` (2) compile against `<experimental/coroutine>` / `/await`,
  which the STL now flags as deprecated for removal. When it is removed the define
  stops helping and the app does not build.

**Measured 2026-09-26, first release-workflow build on `windows-latest`** (before the
define): MSVC 14.51 failed `flutter build windows` with `C2338 … STL1011`. Visual
Studio 2022 accepts `/await` without it.

**Checked 2026-10-01 (task 30).** Neither plugin has a fix to take.

- **`flutter_inappwebview_windows`.** The exit-crash fix (a vendored 0.6.0, F27)
  does not touch this. Its `CMakeLists.txt` does not set `/await` in 0.6.0 or in
  0.7.0-beta.3, and neither version's `windows/` tree mentions `coroutine`, so the
  23 errors above most likely come in through C++/WinRT's headers under Flutter's
  C++17 mode rather than from the plugin asking for it — an inference, not
  verified. (Visual Studio 2026 was not installed on this machine when this was
  checked, so no build was tried; it is now, see above.)
- **`flutter_media_session`.** Not ours: published by `wyrin.dev`, repository
  `wyrindev/flutter-media-session`. 3.0.8 (the app is on 3.0.5) still has
  `target_compile_options(... "/await")` at `windows/CMakeLists.txt:45`, so a
  version bump does not help. Needs a patch upstream, a vendored fix, or a
  replacement.

**Done when:** the app builds on a Visual Studio 2026 toolchain without the
suppression — by moving the two plugins to versions on C++20 `<coroutine>`, or
replacing them.

### 55. Controls overlay visibility transitions when dialogs open/close

The progress and controls bar on a video immediately disappears without fading when a dialog (such as the share dialog) is opened. It also immediately appears again without a fade transition when the dialog is closed. Furthermore, it always reappears upon closing the dialog, regardless of whether the controls were open or closed before the dialog was opened.

**Done when:** the controls bar uses a smooth fade transition when disappearing and reappearing around dialogs, and correctly restores its previous visibility state after the dialog is closed.

### 69. App settings page

There is no settings screen. The account menu's **Settings** entry is a
placeholder (`account_button.dart`, `onTap: () {}`), item 16 is blocked on it,
and the accent colour is still a debug control (`accent_debug_button.dart`).
Build the page, and move into it what is app-wide rather than per-video, starting
with the player's settings menu (`settings_menu.dart`): decide entry by entry
what stays with the video (quality, speed, this video's captions) and what moves
(defaults, caption style, audio-only defaults, updates). Persist with
`SharedPreferences`, like the existing preferences.

**Done when:** the account menu opens the page, item 16 is unblocked, the accent
picker lives there, and nothing is set in two places.

### 70. Miniplayer redesign

**Depends on items 12 and 13** (caption legibility at small sizes; caption drag
disabled by mount point). Item 13 already says to settle it first. Then the
redesign: size (item 12 mentions ~600 px), controls, and how it opens and closes.

**Done when:** redesigned and built, with 12 and 13 done before it.

### 71. Storyboard previews on progress-bar hover

Hovering the progress bar should show the frame at that time, as on youtube.com.
The pieces exist: `video.storyboard` and `storyboard_sheets.dart` fetch and
slice the sprite sheets. Hover previews stopped using them because the smallest
level is 48×27 and upscales badly (Task 15), so use the **largest** level the
spec offers. Some videos have no storyboard: show just the time there.

**Done when:** hovering the bar shows the right frame for the time under the
cursor, sharp at the preview's size, and falls back to the time alone.

### 72. Cover colour for tile hover and mix stacks

Use the cover's dominant colour for a tile's hover container and for the stacked
cards behind mix tiles, instead of the fixed colour. Sample it from a small decode
once per image, cache it by URL, and keep the current colour until it is ready:
it must not cost a frame while scrolling.

**Done when:** both take the cover's colour, and a profile build shows no scroll
jank from it.

### 73. App icon, in the UI and in Windows

`RillLogo` (`topbar.dart`) is a placeholder mark, and the window, taskbar and
`.exe` icon is the runner's `app/windows/runner/resources/app_icon.ico`. Design
the icon once, then apply it everywhere: `RillLogo`, the `.ico` (16–256 px), the
installer, and any artwork fallback that uses the app icon (SMTC, taskbar).

**Done when:** one icon, in every one of those places.

### 74. Account menu: make the placeholder entries work

Most entries in the account menu (`account_button.dart`) have `onTap: () {}`:
Appearance (device theme / Light / Dark), Display language, Restricted Mode,
Location, Keyboard shortcuts, Settings, Help, Send feedback, Google Account and
Switch account.

1. **Appearance.** The app is dark only (`app_theme.dart` builds
   `Brightness.dark`), so Light and "use device theme" need a light theme first.
   Persist the choice.
2. **Keyboard shortcuts.** A sheet listing `shortcuts.dart`'s bindings, generated
   from the same table so it cannot drift.
3. **Google Account.** Open `myaccount.google.com` in the browser.
4. **Restricted Mode.** Find how YouTube applies it for this client (a
   request-context flag or a preference cookie are the likely candidates).
   Measure it, then send it on every request while it is on.
5. **Location.** InnerTube's `gl` (region) changes what the feed shows. Offer it
   if the sidecar's requests honour `gl`, measured.
6. **Settings** is item 69, **Switch account** item 75, **Display language**
   item 82. **Help** and **Send feedback**: point them somewhere real (the
   repository's issues page) or remove them.

**Done when:** no entry is a silent no-op: each works, opens its item, or is gone.

### 75. Switch account

The account menu's **Switch account** is a placeholder. One Google login can
hold several accounts and brand channels; switching changes which identity the
same login speaks for. Measure how youtube.com switches (which request, which
header or cookie changes), then decide: switch within one login, or keep several
logins. Everything Task 31 added for identity changes applies.

**One place is known not to be ready for it.** The playlist page hides what it
shows while it is re-read only when the viewer has *no* account
(`skipLoadingOnReload: signedIn`, `ui/pages/playlist.dart`). Switching from one
account to another keeps the first account's page on screen until the second's
read answers, and that page may be a private playlist. It has to hide whenever
the identity that read the page is not the current one.

**Done when:** switching shows the other account's feed and account state without
signing out, and switching back restores the first.

### 76. Load the SVG icons as `.si` with jovial_svg

The SVG icons are drawn with `flutter_svg` (`channel_badge.dart`,
`share_dialog.dart`, `assets/icons/`), which parses them at runtime. `jovial_svg`
can precompile them to its `.si` format, which loads faster. Convert at build
time with a script (not by hand), swap the widgets, and measure on a badge-heavy
feed scroll before keeping it.

**Done when:** no runtime SVG parsing, the `.si` files are generated from the
`.svg` sources, and the measured difference is written down.

### 77. Audio-only fullscreen: rethink the queue for wide screens

In fullscreen audio-only mode the queue does not suit a 16:9 screen. Rework the
wide layout of `audio_mode_view.dart` (queue beside the artwork rather than under
it; how many rows show), leaving the windowed layout as it is.

**Done when:** fullscreen audio-only on a 16:9 screen uses the width, checked in
the running app.

### 78. Audio-only: artwork inside a vinyl record

**Near future.** An option in audio-only mode to show the cover inside a spinning
vinyl record. The whole vinyl UI was built and tested as a spike in
`scratch/vinyl_spike`, **which is gitignored** (`scratch/` in `.gitignore`), so it
exists only on the author's machine. Bring the code into `app/lib` with tests,
rather than depending on the spike, and make it a setting (item 69).

**Done when:** the option exists, the vinyl code is in the repo with tests, and
nothing references `scratch/`.

### 79. Notifications

**Near future.** The top bar's bell (`topbar.dart`, `_NotificationButton`) is
drawn disabled on purpose: there is no notification source. Measure YouTube's
notification endpoints for the signed-in `WEB` client (the list, the unread count,
marking as read), add the sidecar method and its protocol entry, then give the
bell its count and a panel. Signed-in only.

**Done when:** the bell shows the real unread count and opens the real list.

### 94. The Flutter suite is red in about half of full runs, on different tests each time

Measured 2026-10-19 on an 8-core Windows machine with VS Code's Dart language
server running, after the yt-dlp fix (that one was deterministic and is fixed).
Ten full runs: five passed, five failed 1–5 tests each, never the same set —
`focus_watch_page_test` (two different tests), `focus_traversal_test`,
`nav_rail_selection_test`, `captions_test`, `comments_section_test` ("widget is
off-screen or obscured"), `scrubber_chapters_widget_test` (a drag, and once a
10-minute timeout), and in one run `restore_watchdog_test` and
`rpc_client_test` at 30 s. **Every one of them passes alone** (6 of 6, 5 of 5, and
under a CPU burner) and on a re-run. The failures are in files that share nothing
with each other, and the same ones appear with `flutter test` run directly, so it
is the suite and not the guard.

**Ruled out:** Task 36 (the failing files never remove a route, and the failures
include files that do not navigate at all; a run on the tree without it was
refused here, so this is argued, not measured); the real wait in `openWatch`
(shortened from 400 ms to 20 ms, the Tab-order test still passed); parallelism
(`--concurrency=3`: one run in three still failed, one test); a stray timer from
yt-dlp (fixed, and the failures continued).

**With VS Code closed (2026-10-19, nine `rill check` runs):** seven passed, two
failed one test each — `open_link_test` "anything else is searched" and
`account_identity_test` "the re-fetch keeps the page". Better than half, still not
green. Both wait a fixed real-time 400 ms for the fake sidecar
(`settleReal`) and then assert on what it answered; the first reads the
sidecar's search log, which is empty if the request had not arrived. That is a
suspect, not a finding: running those two files six times with every core
saturated by busy loops passed six of six.

**The guard now prints what a failed test printed** (the last 30 lines, minus the
sidecar's `Shell:` echo), because "Test failed. See exception logs above" was
all it kept and the exception itself is a `print`. The next red run says what
failed and where. Read it before changing a wait.

**First printed failure (2026-10-19):** `scrubber_chapters_widget_test`, "pumpAndSettle
timed out" inside `settleReal`. That is the mechanism: the helper waits a fixed
400 ms of real time for the fake sidecar, and if the answer has not come the page
is still showing a loading indicator, which animates until it does, so
`pumpAndSettle` never settles. Whether 400 ms is enough depends on how busy the
machine is.

**Changed:** `test/sidecar_idle.dart` (`settleReal`, `waitForSidecar`,
`settleWithSidecar`) waits until `RpcClient.pendingCallCount` is 0, pumping frames
meanwhile, for at most 8 s (a test that holds a call open on purpose passes
`timeout: Duration.zero`). The eleven files that each had their own copy of
`settleReal` now import the one, so none waits less than before and a new file
cannot copy the old one; `save_dialog_test`, `open_link_test`,
`one_watch_page_test`, `focus_watch_page_test` and two waits in
`player_controls_test` call the pieces. It settles **once**, not until quiet:
waiting for the call that settling itself starts changed two scrubber tests, which
had been passing with it in flight (found by running them). With the fixed wait
cut to 0 ms the old helper had not finished after 400 s (the file takes about 25 s)
while the new one finished in 29 s, with two failures that need the real wait;
whether the change makes ten full runs pass is **not yet measured**.

**Not changed:** the other real-time waits are not waits for the sidecar
(`keyboard_resync_test` waits on a platform channel, `tile_menu_test` already
polls a condition, the rest in `player_controls_test` and
`scrubber_chapters_widget_test` poll the engine); none was in a failure.

**2026-10-25, a full `rill check` while the machine was busy (a release build had just
finished): 5 tests failed, each passed alone and the next full run passed (1324 tests, 0 failing).**
What the guard printed:
- `playback_queue_test` "jumping to a queue entry plays it": expected `contains 'bbb'`, actual
  `https://fake.invalid/aaa/video/2160` (the jump had not reached the engine after `settle()`'s fixed
  200 ms).
- `rpc_client_test` "decoding a large payload does not block the main isolate": expected less than
  5000, actual 6408.
- `rpc_client_test` "a large payload and the small ones behind it arrive in order, off the frame
  loop": expected less than 150, actual 2000 ("the main isolate stalled for 2000ms — the decode ran
  inline").
- `search_suggest_test` "arrow-down walks 0, 1, 2 and stops at the last suggestion — no wrap":
  expected length 3, actual 0.
- `stall_watchdog_test` "a stalled stream is reopened once": expected 2, actual 0.
Three of them (`playback_queue`, `search_suggest`, `stall_watchdog`) wait a fixed real time for the fake
sidecar, as the earlier ones did; the two `rpc_client` ones are timing assertions, so a busy machine fails
them by construction. Not fixed.
A second occurrence the next day, a full `rill check` right after editing: `rpc_client_test` "a large payload
and the small ones behind it arrive in order, off the frame loop" again, expected less than 150, actual 250
("the main isolate stalled for 250ms — the decode ran inline"); the rerun passed.
Two more on 2026-10-27, after four release and debug builds in a row: one full run died with
"Resource temporarily unavailable" (fork failures) taking `queue_panel_test`, `rpc_client_test` (a 30 s
timeout) and `save_dialog_test` (no tests produced) with it; the next failed one test,
`loading_controls_test` "does nothing once the video has opened", expected `preferredHeight` null and got 360
(its `release` waits a fixed 100 ms, and under load `isLoading` was still true); alone it passed three of three.

**Done when:** ten consecutive full `rill check` runs pass on this machine.

### 98. The watch page shows no player controls while a video loads

Reported 2026-10-23 (issue #21). The controls used to be unmounted until a video had
loaded. **Landed (partly):** `pages/watch.dart` now mounts `PlayerControls` through the
load (the fullscreen layer already did), and:
- **Pause / play** records `PlaybackState.wantPlaying` while `isLoading`; the open ends paused
  if it is false (`MediaKitEngine.open`'s `shouldPlay`), and the button shows the wanted state.
- **Next / previous** supersede the open in flight (the generation counter, as before).
- **The scrubber** is disabled while loading, and `seek` / `stepFrame` do nothing until it ends.
- **Mute / volume** were engine-level already and work.
Tests: `loading_controls_test.dart`.

**Left:**
- **Quality during the load: done 2026-10-24, in a plain form.** The quality button is enabled while
  a video opens and its menu offers the standard heights ("Applies when the video opens"); the one
  picked is the height `open` takes the rung for when `playback.open` answers
  (`chooseHeightWhileLoading`), and one picked while the engine is already opening another is
  switched to once that has opened, since the open in flight cannot be changed. So a pick made late
  costs a load and a switch. The menu offers heights this video may not have (the open takes the
  best rung at or under it). **Captions during the load are not checked:** a preference the open
  applies when it gets there, if it does.
- **The request in flight is not cancelled.** `open` uses `call`, not `callCancelable`, and the
  sidecar's `playback.open` ignores the abort signal anyway, so a skipped video still resolves
  and costs a session that is never reported. Both ends need it.
- **Probes clean, a person has not tried it.** `RILL_SEMANTICS_PROBE=1` and `RILL_FOCUS_PROBE=watch`
  (two runs, release build, 2026-10-23): 0 `AXTree` errors and 0 `Nodes left pending` in both,
  all 25 semantics steps ran including 7g–7k, no `OFFSCREEN` or `NAMELESS` stops. The probes open
  videos, so the bar mounts through a load in them, but they never press anything *during* one,
  and cannot see a Narrator started after the app. Both need a person.
- **A wanted-state object** for muted / quality / captions, if those ever need to survive an open;
  today only `wantPlaying` does.

**Done when:** the semantics probes are clean with the bar mounted through a load, and the
items above are done or dropped with a reason.

---

### 97. `flutter_inappwebview_windows` hangs the process's exit on an Intel GPU

Found 2026-10-21 (`architecture.md` §2.14). After the window is gone the 0.10.x
process never ended. A read-only `cdb` attach (`-pv`, `~*kb`, no dump) named it:
in `DLL_PROCESS_DETACH` the plugin's static destructors release a Direct3D 11
device and the Intel driver `igd10um64xe` spins inside that release. `main.cpp` now
ends the process itself with `TerminateProcess`, so users do not see it; the cause
is upstream (the plugin or the driver) and stays, and any exit that reaches the
ordinary path (a crash handler, `exit()` from elsewhere) would hang the same way.
The probes and diagnostics, which ended with `exit()` and so crashed and left a
~22 MB dump holding the session cookie each time (`0xC0000602`/`0xC0000005`, 5 of 5
in 2026-10-14 and again 2026-10-22/23), now end with `hardExit` (`data/hard_exit.dart`,
the same `TerminateProcess`): the semantics probe's 25 steps ended `app exited
with code 0x00000000`, 0 `AXTree` errors, no new dump (2026-10-23). The five old dumps
are still in `%LOCALAPPDATA%\CrashDumps` and hold the cookie: delete them.

**Open:** whether a machine without an Intel GPU hangs (it was seen on one with
`igd10um64xe`/`igdgmm64` only); whether the plugin can be kept from creating its D3D
device until the login page opens (the device exists after an idle launch with no
WebView); an upstream report to `flutter_inappwebview` with the stack. A newer
driver or plugin may make the hard exit unnecessary — re-test by temporarily
returning from `wWinMain` and closing the window.

**Done when:** an upstream issue is filed or the plugin's device is no longer made
at startup, and the hard exit's comment says which.

---

### 96. A restarted sidecar loses its playback sessions, so watch reporting stops

Found 2026-10-21 from a 0.10.2 log, in the same event as the lost cookie. Thirty
seconds after launch the yt-dlp check installed a newer copy and restarted the
sidecar; from then on every 15 s `playback.report` failed with *"no open session
'…'. Report before playback.close, and only against a sessionId playback.open
returned"* until the next video was opened — two minutes of watching in that log
registered nothing, and `playback.report` is what keeps the recommender trained
(CLAUDE.md, "`playback.report` is load-bearing").

**Already fixed, by 2026-10-21:** the cookie (`RpcClient.onRestarted` →
`AuthController.restore`, so a restarted sidecar is signed in again), and the
trigger (yt-dlp restarts the sidecar only when `YT_DLP_PATH` changes, not when the
file at the same path is replaced). **Still open:** the sidecar is a new process on
every restart, however it comes about (it exits and is supervised back, or a first
yt-dlp download restarts it), and the app's open playback session is an id it no
longer knows. After a restart the playback controller has to open the session
again for the video that is playing, without reloading the stream. Check what
`playback.open` does and costs for a video already open before choosing how; a
second `playback.open` re-resolves the ladder, which is the expensive part, so
a report-only way back in may be needed.

**A gap in the cookie fix, recorded 2026-10-23 (read from `client.dart`, not
reproduced).** `_send` releases calls that were waiting on `_readyCompleter` the moment the
new sidecar reports ready, and `onRestarted` runs only after `start()` returns, in a
microtask. So a call queued during the restart (a like, a feed page) is written to the new,
still anonymous sidecar *before* `auth.setCookie`: the like answers `AUTH_REQUIRED` ("Sign in
to rate videos") and the feed comes back anonymous. The restart-hook tests do not see it,
because they make their calls after the hook has run.

**The fix belongs with the playback-session restore above:** after a restart, every other
call waits until the restore has finished, bounded (a restore that hangs must not hold the app
for ever, so a timeout of a few seconds, then carry on and say so on stderr), and the hook's
own calls (`auth.setCookie`, `auth.status`, the session reopen) do not wait, or it would wait for
itself. One gate, two uses: the account and the playback sessions are both state the new
process must be given before anything else asks it a question.

**Done when:** after a sidecar restart mid-video, `playback.report` carries on
against a session the new sidecar knows, with no reopen of the stream; a call issued while the
restart is in progress is answered as the signed-in account, not anonymously; and a test
restarts the fake sidecar under a playing video, issues a call in that window, and sees both.

---

### 95. No real song card is committed, so the music parser's input shape is pinned by a hand-built one

`sidecar/test/music.test.ts` read the song card out of the local `fixtures/mix.json`.
`fixtures/` is gitignored, and a later capture of a mix did not hold the card
(measured 2026-10-18, a capture from 2026-08-28), so the three tests that read it
now skip, with a warning, when it is absent, and the same assertions run on a card
written by hand. That card encodes what `parser/music.ts` reads (`title`,
`subtitle`, `secondarySubtitle.content`, `image.sources[0].url`, the square image
style), so if YouTube changes the shape the parser and the test change together
and stay green. Wanted: capture a mix whose video credits a song, take the one
`videoAttributeViewModel` out of it, sanitise it and commit it into `corpus/` with
the other sanitised entries, and have the tests read that.

**Done when:** a committed real card is what `music.test.ts` asserts against, on any
machine.

### 100. Show an update download on the taskbar button's progress bar

The installer is ~100 MB, and while it downloads the only sign is the Updates page,
so a user who has switched away cannot tell it is happening or when it is done.
Windows 11's taskbar button has a progress bar for exactly this (`ITaskbarList3`).

- **What exists.** `UpdatePhase.downloading(manifest, received, total)`
  (`domain/update/update_state.dart`) is already updated as bytes arrive
  (`update_controller.dart`). The vendored `third_party/windows_taskbar` already
  exposes `setProgress(completed, total)` and `setProgressMode`, and
  `ui/taskbar_controller.dart` already drives the thumbnail toolbar, so no new FFI
  is needed on Windows.
- **States.** Normal progress while `downloading`; indeterminate for any step after
  the last byte that has no byte count (a verify, if there is one); the error
  colour on `UpdatePhase.error`; cleared at `ready`, `installing` and `idle`. Clear
  it on every path out, or a failed or cancelled download leaves a stuck bar. The yt-dlp download
  (`data/ytdlp/ytdlp_downloader.dart`) is the same shape and could report through
  the same thing.
- **Seam.** The question is whether to hide this behind an interface for a future
  macOS port (the dock tile has a progress bar too) or to hard-code the taskbar.
  The repo's idiom for a platform seam is `WindowChrome` with `Win32WindowChrome`
  and `NoWindowChrome`, chosen by `Platform.isWindows` (`windowChromeProvider`,
  `ui/player/view_mode.dart`). Recommended: a small `TaskbarProgress` interface
  (`set(done, total)`, `indeterminate()`, `error()`, `clear()`) with a Windows
  implementation and a no-op default, which is also what the tests fake. No macOS
  implementation until there is a macOS build; the interface is a few lines and
  the controller has to be testable without a taskbar anyway.
- **Accessibility.** The bar is painted by the shell, not by Flutter, so it adds
  no semantics node. The Updates page still has to say the progress in words.

**Done when:** a download shows its fraction on the taskbar button, an error shows
red, and every end state (done, failed, cancelled, app closed) leaves no bar behind.

### 101. Pick up where you left off after a restart

Keep a copy of the app's state and put it back on the next start, so closing the app (or
updating it) does not cost the viewer their place. Two triggers with different rules:
- **After an update: always.** The updater restarts the app itself, so it is the one restart
  the viewer did not choose, and losing the video they were watching is the worst moment to
  lose it. Needs a marker the updater leaves for the next start (the installer's arguments
  come from the old version, see `rill.iss`), so a restart that follows an update is told
  apart from a launch.
- **After a manual close: only with a setting turned on,** off by default. Opening a fresh
  app is what most people expect from a launch.

**What to keep, as a start:** the page stack's top (which watch page, playlist, channel or
search), the queue (item ids, the current one, the mix and its playlist id), the current
position and whether it was playing, audio-only, volume and the preferred quality. Ids and
numbers only: no cookie, no URL (`playback.open` resolves again), and nothing that was
fetched. Scroll positions and open menus are not worth it.

**Care:**
- **The app ends with `TerminateProcess`** (CLAUDE.md, "The app ends itself"), so there is no
  exit hook to write from. The snapshot is written as things change (debounced), and a
  crash then leaves the last one, which is a feature.
- **A snapshot that crashes the app on restore must not loop.** Delete or mark it before
  applying, and apply it once.
- **Order on start:** the account is restored first (`restoreAuthWhenSidecarRestarts`), then
  the queue and page, then `resumeAt` for the position (`playback_controller.dart`), the same
  one the queue-replacement undo uses. The restored video should open **paused**: sound
  starting by itself on launch is a surprise.
- **A video that is gone** (private, removed, a premiere) lands on the ordinary error slate;
  restoring must not turn that into a retry loop.
- **Settings:** a toggle on the settings page, which needs the keyboard and screen reader
  rules in CLAUDE.md, "Accessibility".
- **Other platforms:** where the file lives and how an update is told apart are the only
  platform parts, so keep them behind one small interface.

**Done when:** after an update the same video is open at the same place, paused; with the
setting on a manual restart does the same, and with it off a launch is a fresh start; a
corrupt or stale snapshot is ignored, never retried; tests cover write, read, the once-only
apply, and the update marker.

### 104. Adding a video to Watch Later answered HTTP 400

Reported 2026-10-24: adding `-jknl-GNjDw` to Watch Later showed "could not add … to WL: Request to
…/browse/edit_playlist … failed with status code 400". The video is ordinary (public, 70 s, not live,
no age limit, per yt-dlp) and the session was authenticated, so it is not the video's availability and
not the anonymous-sidecar fault (CLAUDE.md, "A restarted sidecar"). Not reproduced; one video id.

The sidecar now logs the response body (`addToPlaylist` in `actions/playlist.ts`) when this happens,
which is the missing piece: the `400` says nothing on its own. Next time, read the newest
`%LOCALAPPDATA%\rill\logs` line starting `add <id> to WL:`. Things it could be: Watch Later at its
size limit, a cookie YouTube rejects for this call only, or an id that starts with `-` being mangled
somewhere between the tile and the request (the id begins with a hyphen; check the Dart side and
`requireString` before blaming YouTube).

**Done when:** the cause is known and either fixed or turned into an error message that says what to
do.

### 106. The "No sound" notice has no miniplayer form

Added 2026-10-25 with the notice (`NoSoundNotice` in `player_slates.dart`, shown by `PlayerSlates` on the
watch page and the fullscreen layer). The miniplayer does not mount `PlayerSlates`, so a video whose audio did
not load plays in silence there with nothing said, which is issue #22's symptom again in the one surface the
fix does not reach. `PlaybackState.audioMissing` is already what to read; the form is the open question (an
icon on the miniplayer, a line under the title) and has to follow the Accessibility rules (no overlay under
something that mounts, one name said once).

**Done when:** a miniplayer playing a video with no audio shows it, and the retry (`retryAudio`) is reachable.

### 107. A stream URL that has expired, or a connection that has gone, fails silently

Raised 2026-10-25 while designing the `video-add` quality switch, then measured. Every `videoplayback` URL
carries `expire=`, six hours out (seen on both the video and the audio URL of a fresh `playback.open`), and
nothing in the app refreshes them: `switchQuality` reuses the ladder from the original `playback.open` (no RPC,
§3.5), `_reopenStalled` reopens the same `PlaybackVariant`, `retryAudio` is the only path that resolves again
and it only runs from the "No sound" notice. After the expiry any *new* request for the URL is refused (403),
which affects every new read: a seek to a place not yet buffered, a resume after a long pause if the connection
went, a quality switch, a reopen.

**What happens today, measured with the bundled libmpv against a local server that answers 403 once told to
expire, with the read-ahead kept small (`sidecar/scratch/measure-expiry.ts`, `seek` / `pause` / `pausecut`):**
- **A seek into a region not yet read hangs.** mpv logs `http: HTTP error 403 Forbidden` (warning) and
  `Seek failed (to …)` (error), then `seeking` stays `yes` and `core-idle` stays `yes` for as long as it was left
  (24 s here). Nothing ends and nothing errors: `idle-active` stays `no`, no `eof-reached`. media_kit turns only
  `tcp:`-prefixed ffmpeg errors into its `error` stream, and `Seek failed` is not one, so the app is told nothing.
  The stall watchdog (`_armStallWatchdog`) is armed for 5 s after an open and only looks at position 0, so it
  does not see this. The viewer sees a seek that never lands.
- **A connection that is gone ends the video early, as a normal ending.** With the connections cut while paused
  and resumed 12 s later, playback ran 13 s from the cache and then the file ended (`idle-active=yes`) at 16 s of
  a 60 s video, with **no new request made**. The control, where new requests are still answered (`pausecut`),
  behaves the same: this build of mpv does not reconnect (no `reconnect` option is set), so a dropped connection
  is an EOF whether or not the URL has expired. In the app that EOF is `completed`, so `_onCompleted` reports the
  watch as `ended`, advances the queue and plays the next video. Not measured: whether YouTube drops a paused
  connection after any particular time, so how often this happens in life is unknown; the expiry only adds that
  the retry would be refused.
- **A read that is already in flight carries on** after the expiry (the 'play' arm played to the end): the
  URL is checked when a request is made.

**Done 2026-10-27 (the app-side half):** a file that ends more than 5 s short of its duration is a failed read, and so
is a seek that stays `seeking` for 20 s. Neither reports the watch as ended or advances the queue; both resolve the
video again (`playback.open`, as `retryAudio` does) and reopen at the position, paused if it was paused, with the
clock held through the reload. At most three in a minute, then an error with a retry; a second end in the same place
(within 3 s) is taken as the file's real end, so a stream shorter than its stated duration does not loop. A live stream
has no end to fall short of. Tests in `read_recovery_test.dart`, each half with a mutation. Against the real engine
(`RILL_VIDEO_ADD_PROBE_EXPIRY`, a server that cuts the connections and refuses new requests): `completed` fires 18 s
after the cut with the position 41 s short of the duration, and a seek after the expiry is still seeking after 25 s.

**Still open, directions none chosen:**
- A refresh in the sidecar that returns a fresh ladder for the open session without minting a second one (the
  reason `switchQuality` does no RPC), called when the variants are older than about 5.5 h and on resume after a
  long pause, so the recovery above resolves once instead of reopening on URLs that may be as old as before.
  Needs the sidecar to keep what `playback.open` resolved with.
- `reconnect` options for ffmpeg's http (`stream-lavf-o`): invariant 8 applies, the bundled FFmpeg may not
  have them, and the option has to be proved against the binary's string table before it is believed.

**Done when (107):** a seek, a resume after a long pause and a quality switch on a video whose URLs have expired
each end with the video playing at the right place (or a message that says what to do), and a dropped
connection is not reported as the end of the video. A test with the fake engine for the recovery, and the
scratch harness run against the change.

### 109. A quality switch still stops the picture and the sound for 1 to 3 s

Reported 2026-10-27 after the in-place switch (F60) landed: the old quality plays for about a second, then
the picture and the sound stop until the new quality is in, and then it carries on. What was wanted: keep
playing in the old quality while the new one loads, then swap so that the clock does not change (a stutter
is fine, going back or pausing is not). The clock no longer goes back (fixed, F60 item 9); the pause is what is
left.

**Measured (F60 item 10):** 0.8 to 2.6 s of everything stopped per switch, from mpv's log: the new video
has to be sought to where the clock is, a seek restarts audio and video together, and the restart waits for
the new video's first frame, a network fetch. Inside one mpv nothing avoids it: an unselected track is not
repositioned by a seek (the pre-seek made it worse), `video-add` refuses an EDL source, and a keyframe
seek lands up to a GOP behind the clock.

**The way that is left: a second player as the buffer.** The engine opens the new quality in a second
`Player` (audio as the file, the video added, muted), paused at the clock and then playing in step with
the first, until it has a decoded frame and a few seconds of read-ahead; then the picture and the sound
move to it in one frame and the first is stopped. The cost, so that the decision is an informed one:
- every stream the engine exposes (`positionStream`, `durationStream`, `playingStream`, `bufferingStream`,
  `bufferStream`, `widthStream`, `heightStream`, `volumeStream`, `completedStream`, `videoOutputStream`,
  `audioMissingStream`, the subtitle text) comes from `_player.stream` now and would have to be re-emitted
  from whichever player is active, or every listener goes stale at the swap;
- the surface (`videoSurface`, `videoWidget`, the `LayerLink` the fullscreen move uses, the miniplayer's)
  is built on one `VideoController`, so the controller has to be swappable under a `Video` widget that is
  already mounted, with the texture handed over without a black frame;
- captions (`setSubtitle`, `LibassLayer` draws from `engine.subtitle` and the position), volume, mute and
  the audio-only mode (`vid` and the added tracks) all act on one player today;
- double the bandwidth while it runs (the audio too), only for the seconds it takes;
- the hover preview already runs a second `Player`, so two decoders in one process is known to work.
It is a rewrite of the engine's core rather than a change to it, and wants its own task and its own review;
the in-place switch stays as the fallback when the second player cannot be made ready.

**The cheaper step is done** (PR 29): the old frame stays, the quality button shows busy, and a note on the
picture says `Switching to 1080p…` while the switch runs. It makes the pause look deliberate; it does not meet
"no pause".

**Measured 2026-10-27 for the design (`RILL_VIDEO_ADD_PROBE_DUAL=1`, two real engines, a 2160p60 vp9 video, a debug
build of the app on this machine's Intel GPU, three runs):**
- one player: 0 frames dropped in 12 s, 14.5 to 14.9 CPU seconds per 12 s (1.2 cores), 16 to 17% of the GPU's
  video-decode engine, `d3d11va-copy`;
- **two playing at once: the one on screen drops 122, 365 and 423 of its ~720 frames in 12 s (17 to 59%)**, the
  other 272 to 364, 23 to 29 CPU seconds, 28 to 32% decode. A second player that *plays* is out;
- **a second player paused at a frame with a 20 s read-ahead costs nothing:** the one on screen dropped 1 to 5
  frames, CPU and decode as for one player;
- **ready in 2.5 to 3.1 s** (open plus seek to the clock) for the standby at 2160p60, before its read-ahead fills;
- **the standby's own seek to the clock: 49, 830, 843, 614 and 602 ms inside its read-ahead, 2984 ms beyond it.**
  That is a stall of the standby, not of the viewer, if it is done while the first player plays on (below);
- bandwidth: this rung is 17.2 Mbit/s (`clen` over `dur`), so a 20 s read-ahead is 43 MB and the overlap doubles the
  stream for the seconds it runs (`cache-speed` reads 0 for a network stream here, so the rate is computed).

**Design:** a one-page design went to the orchestrator and the user as a report on 2026-10-27, for review before any
code; its decisions are recorded here once approved.

**Spike, plan step 1 (2026-10-27; `RILL_VIDEO_ADD_PROBE_SWAP=1`, `ui/swap_spike.dart`, a release build, two real engines, six
scenarios, two layouts; branch `feat/second-player`).** The standby opens paused with a 6 s read-ahead, is aimed past
where it will be ready, and is swapped in by starting it, pausing the first player and flipping a visibility together.
- **The surface: both layouts work, and an offstage `Texture` is current.** The standby `Video` as `Offstage` and the
  standby stacked *under* the active one both opened and observed normally, and **0 black frames in 99 to 108 captured
  frames around each of the five swaps**, with the capture proven able to see a texture (mean luma 122 playing, never
  below 124 at the swap; it reads the composited tree with `RepaintBoundary.toImage`). So `Offstage` is enough and is
  cheaper (a hidden surface is not composited); the stacked layout is the fallback if a platform differs.
- **The seam, from the players' own `audio-pts` and `time-pos` events:** silence at the swap **1 to 8 ms** (five swaps), sound
  skipped **0 ms**, the clock steps **forward** 33 to 67 ms (never back; the 1 ms "worst step back" is the events' jitter).
  That needs the trigger to fire about 30 ms before the clock reaches the target: the pause and play commands land in
  7 to 9 ms. With the first guess of 120 ms the two swaps that ran stepped the clock 133 and 134 ms forward.
- **Ready time, and the lead:** with the first aim at clock + 5 s the standby was ready 1.2 to 1.5 s after the start
  (open 0.5 to 0.8 s, first seek 0.45 to 0.76 s) with 4.0 to 4.1 s of lead left, no re-aim needed (five swaps). The earlier
  run, with a 3.5 s lead and a 1.2 s re-aim lead, took 1 to 3 re-aims in every swap and was ready after 4.3 to 8.6 s: its seeks took 0.5 to 1.8 s, so a re-aim lead must be longer
  than the seek. Rule: first aim clock + 5 s,
  re-aim lead = 2 x the last seek + 1 s.
- **Memory (private bytes), standby ready against before it existed:** +48 MB for a 720p60 standby, +132 MB for 1440p60,
  +228 to +268 MB for 2160p60. After the swap and the first player stopped and disposed it comes back to the new rung's
  own level (310 to 324 MB for 720p/1080p, 531 to 633 MB around 1440p/2160p): no leak seen over one swap. The
  baseline before the standby (319 to 524 MB) depends on what is playing, so read the deltas, not the levels.
- **One failure in six standby opens (the tuned run):** `video-add` for the standby did not produce a track (`under`, 2160p60 to
  1440p60, "the video stream would not open"); the other five opened. Not understood: the engine's 2 s wait for the
  `vid` event, a transient refusal, or the layout. The fallback chain covers it, but it is a number to watch.
- **Not measured:** A/V sync of the standby after the swap (`avsync`), the swap while the first player is paused or
  buffering, memory over repeated swaps, other GPUs.

**Built (2026-10-28, `feat/second-player`):** `SwappingEngine` over two `SwapSlot`s, `architecture.md` §2.16;
the shell's engine in `main.dart`, `PlaybackController` untouched (its `switchVideo` is the second player's now, with the
in-place switch as the fallback). Tested with fakes (`swapping_engine_test.dart`); mutation-checked on the re-pointing.
Hand-tested 2026-10-28: it works, and lags a little under load while the standby is made. A switch now logs
`second player: the viewed player dropped N frames while the standby was made` (mpv's decoder and output drop counters,
observed, not polled), so the cost is a number per switch; no CPU or GPU figures from the real app yet.
**Not done:** a switch through the real app measured from mpv's log (silence, clock, black frames) at 1080p60 and 2160p60;
the frame-drop trigger that sends weak hardware to the in-place switch (the ruling is every rung, with that fallback);
the one standby open that failed in six; the A/V sync of the swapped-in player (not measured; none reported); and by
hand: fullscreen, the miniplayer, audio-only, captions and volume across a swap, and Narrator (the surface now holds
two `Video` widgets: re-run `RILL_SEMANTICS_PROBE=1` and `RILL_FOCUS_PROBE=watch`).

**Done when:** a switch at 1080p60 and at 2160p60, started mid-video on a normal connection, never stops the
sound for more than a few hundred milliseconds and never moves the clock, measured from mpv's log or from
the audio clock, not from the property stream (the probe's own "stall" figure under-reported it by a factor
of three).

### 108. Start the audio's first bytes before mpv does

Not started; a line, not a plan (2026-10-25, from the F59 and F60 numbers). An open is the sum of the audio's
first byte and the video's, because mpv opens the second stream only after the first (F59), and since F60 the
audio is the file and the video is added, so that order is fixed: audio, then `video-add`. Measured on a live
ladder the open is 1.5 to 2.0 s (audio 0.3 to 0.7 s) and a switch 1.3 to 4.4 s, most of which is the new
stream's first bytes. Either wait could be hidden by asking for the bytes before mpv does, for example a
request for the video's first bytes made as soon as `playback.open` answers, so the connection and the CDN
are warm when `video-add` asks. Whether googlevideo serves the second request from anything warmer is not
measured, and the URL must not be used in a way that changes what `playback.report` sees.

**Not measured for the in-place switch (F60):** a muxed rung (this ladder had none), a live stream with a
separate audio (kept on the old layout), Narrator's reaction to a switch, and captions across one in the app
(the external track survived in the harness; the app's `LibassLayer` draws from `engine.subtitle`, which a switch
does not touch).

**Done when:** the open or a switch is measurably shorter from it, or the measurement shows it is not worth it.

---

## Triggered — read when one of these fires

### 18. Evaluate freezed 4.0.1

**Triggers:** codegen breaks again, **or** the FVM Flutter pin moves off 3.44.9.
Do not pick this up on a quiet day; it is a major version bump with no current
symptom.

The project sits on `freezed: ^3.2.6-dev.1` — a dev prerelease — which declares
`analyzer >=12.0.0 <13.0.0`. `app/pubspec.yaml`'s override block names that
ceiling as the binding constraint: *"the constraint the solver has to respect is
the one freezed declares."*

**freezed 4.0.1 inverts it:** `analyzer >=13.0.0 <15.0.0`, `source_gen >=3.0.0
<5.0.0`, `build >=3.0.0 <5.0.0`, and `freezed_annotation 3.1.0` — the version
already in use. So the optimistic case retires the prerelease pin in one move.
(The `source_gen`/`build` overrides it would also have made unnecessary are
already gone — tested out 2026-09-16, when the solver picked identical versions
without them.)

**Two things that decide it, neither settled:**

1. What 3→4 actually breaks. Read `CHANGELOG.md` for 4.0.0 first; the migration
   guide published on the package page documents 2→3, not 3→4.
2. Whether a `dart_style` exists that accepts analyzer 13.0.x while staying
   under the SDK's `meta 1.18.0` pin. The original failure was never analyzer 13
   as such — it was that analyzer 13.1 needs `meta ^1.18.3` while `flutter_test`
   from SDK 3.44.9 pins `meta 1.18.0`. Only `pub get` on a branch answers this.

**The analyzer plugin is not a reason to do this.** The 2026-09-16 lint
investigation first suspected the pinned SDK's Dart 3.12.2 (dart.dev dates
analyzer plugins to 3.13) and considered moving the pin, which would have
fired this item's second trigger. It was not the cause — the plugin loads on
3.12.2, and the missing diagnostics were a timing race that happens on 3.13.2
too (`app/tool/rill_lints/README.md`). So the pin has no pressure on it from
that side; only the triggers above apply.

**Change one thing at a time.** Try freezed 4 on its own, not together with a
Flutter pin move or any other dependency change: a failure has to be able to
tell you which change caused it — the exact diagnostic trap the
`animated_vector_gen` note exists to prevent.

**Whichever way it goes, rewrite that comment block rather than renumbering it.**
Its central claim becomes false the moment freezed 4 lands. A stale version
number is harmless; a stale causal explanation sends the next person down the
wrong path.

---

## Far future — ideas, not commitments

### 91. A backdrop material for the app's surfaces

Wanted later, not designed: the app's surface taking a material instead of a
flat colour. Two different things have been called this, and they are built
differently:

- **A translucent title bar the page scrolls under**, blurred. In-app only: the
  page's body laid out behind the bar and a blur in the bar itself. It touches
  the caption layer, which is clipped below the bar on the assumption that the
  bar is opaque (`_BelowTopBarClipper`, `player_shell.dart`), and whether a blur
  samples the video texture has to be measured, not assumed.
- **A window material from the OS** (Mica, Acrylic). Mica is Windows 11 only, and
  the development machine is Windows 10, where Acrylic is the nearest thing. It
  needs the Flutter view itself to be transparent, so every opaque ground in the
  app becomes a decision.

Either could follow **what is playing**. A colour from the video has to come
from something already decoded off the UI isolate (the thumbnail, a storyboard
frame, `nowPlayingBackdropProvider`), never from polling the player (CLAUDE.md
invariant 9).

**Where it plugs in.** Every page paints its title bar, rail and ground from one
shared value, `PageChrome` (`ui/page_wrapper.dart`, `architecture.md` §2.8),
which is a colour today. A material would widen that value rather than add a
second mechanism, and it does not need the title bar moved above the
`Navigator`, which was rejected for the keyboard's sake.

**Done when:** one of the two is chosen and specified as a task, or the idea is
dropped and this item deleted.

### 80. SponsorBlock

Skip sponsor segments using the community SponsorBlock database. A third-party
service, so: **off by default and opt-in** (item 69). Use its privacy-preserving
lookup, which takes a hash prefix of the video id so the server never learns
exactly which video is playing. Skips go through the engine's seek, with a short
"Skipped sponsor" notice and an undo.

### 81. Return YouTube Dislike

Show a dislike count from the Return YouTube Dislike API. Third-party, and it is
sent the video id itself, so **off by default and opt-in**, and the number is
labelled as an estimate.

### 82. Display language

Possible, in two halves. YouTube's own text (shelf titles, chip labels, view
counts, relative dates, "Highlighted comment") follows the request's `hl`
parameter, so the sidecar can ask for another language. The app's own strings
are inline English today and need Flutter localisation (ARB files and
`flutter_localizations`) — a full pass over every screen. Dates and numbers the
app formats itself follow the same locale.

### 83. Keyboard and screen-reader follow-ups from Task 32

What `docs/tasks/32` found and deliberately left, each one small:

- **Check with a screen reader.** Narrator has not read any of this
  (`docs/tasks/32` §6). The AXTree errors are gone from the release log, which
  says the tree is being delivered, not that it reads well.
- **Vertical-video layout.** The two `Slider` fixes (architecture.md F51) were
  applied to the vertical control column too but never driven live — the probe
  has no vertical video. Run `RILL_SEMANTICS_PROBE=1 RILL_SEMANTICS_PROBE_VIDEO=<a
  Short's id>` and count.
- **Other `MenuAnchor` and dialogs.** The tile menu and subscribe menu now move
  focus in and return it; `accent_debug_button.dart`'s `MenuAnchor` has the same
  gap and was not touched (it is a debug control). The delete-comment dialog is
  `showDialog`, the same mechanism as the tested ones, with no test of its own.
- **Not walked in the real app:** the queue (the probe has no queue), the
  subscriptions pages, the search results page and the caption-style page's rows,
  and a video whose description has links. All of it is asserted by test, none of
  it by `RILL_FOCUS_PROBE`.
- **The ring and the tile lift were not seen on screen**, only measured. Whether
  a 2 px primary ring reads well on every surface (over a video, over a scrim, on
  the rail) is a visual question.
- **The vertical-video volume slider** mounts above its speaker button, so a Tab
  onto the speaker opens a slider that sits *before* it in reading order and the
  next Tab does not land on it. Horizontal layout is correct and tested.
- **The queue header's right-click menu** (Task 34) closes on scroll now
  (`architecture.md` §2.8). Whether focus moves into it and returns, and how
  Narrator reads it, were not checked.
- **The watch page's view count and date** show their exact values in an overlay
  `Tooltip` (a `ShortcutTooltip` without `silent`), inside a page that scrolls.
  Seen in a node log on 2026-10-07, added and removed cleanly; `silent: true` is
  the conversion.
- **The artist shelf's left chevron** is a Tab stop that exists only while the
  shelf is scrolled. The tiles are reachable without it, so it may want
  `ExcludeFocus`.
- **The comment box's Escape** does not cancel (Cancel does); the filters dialog
  and the player's submenus close on Escape through their own paths.

### 88. Say "can't reach YouTube" when the connection itself fails

Measured 2026-10-05: with no network, yt-dlp's tier of the playback ladder reports
`Unable to download API page: … Failed to resolve 'www.youtube.com' ([Errno 11001]
getaddrinfo failed)`, and the UI shows that text (or "This video would not open")
instead of saying the connection is the problem.

- **A new RPC error code** for a failure *below HTTP*: DNS (`getaddrinfo`, `ENOTFOUND`),
  `ECONNREFUSED`, `fetch failed`, and yt-dlp's `Failed to resolve`. Raised only when nothing
  got through — not for HTTP 4xx/5xx, timeouts or TLS errors, which can be a proxy, a flaky
  link or a real outage and need their own wording.
- **Wording:** "Can't reach YouTube. Check your internet connection." — true for no network,
  filtered DNS, a VPN or a firewall alike. Not "You're offline", which can be wrong.
  `retry: user`, and keep *Try again* (a single DNS blip is common).
- **In the playback ladder** it sits next to the throttle check in `resolve.ts`, so a video is
  not blamed for the connection; tier 2 (yt-dlp) reports through a string and needs a small
  pattern match.
- **Check the other paths** (`feed.*`, `search.query`, `video.comments`) surface the same
  code rather than only playback.

### 85. The sign-in page is not reachable with a screen reader or by Tab from Flutter

Reported 2026-10-06 while testing with Narrator on: on the login page the embedded WebView2 is
not focusable from the Flutter side.

- **What works:** once the page has focus (click the email field), Tab moves through the page's
  own controls exactly as in a browser.
- **What does not:** Tab from Flutter's controls never enters the page, and Tab inside the page
  never leaves it (it cycles the page's items). Narrator does not see the page's content.
- **Cause (not yet confirmed on a build):** `third_party/flutter_inappwebview_windows` hosts
  WebView2 in *composition* mode (`ICoreWebView2CompositionController`): the page is a texture
  in Flutter's surface, so the page's UIA tree is not part of the window's, and Flutter's focus
  traversal has no way to hand focus across (`MoveFocus`) or take it back.
- **Chosen fix: sign-in in its own native window.** Host WebView2 in a top-level window
  (windowed `ICoreWebView2Controller`), opened by the login page, which waits for the cookie
  result and closes it. A real window is accessible to Narrator and takes keyboard focus on its
  own, so neither direction of Tab needs bridging. Re-verify Task 33's cookie capture, the
  device-trust cookie on sign-out and the account picker, which share this code path.
- **Rejected:** bridging WebView2's UIA tree into Flutter's (answering `WM_GETOBJECT` ourselves —
  fragile); a child HWND inside the Flutter window (unclear that Narrator descends into it, and
  Tab handoff is still manual).
- **A smaller step if wanted first:** keyboard handoff only — `MoveFocus` into the page on Tab
  from the last Flutter control, and back out on Shift+Tab / at the page's ends. Does nothing for
  Narrator reading the page.
- Until then: sign in without Narrator, or seed the session with `YT_COOKIE`.

### 86. Report an accessibility error when it happens

An `AXTree` error silences Narrator for the rest of the session (see CLAUDE.md "Accessibility"),
and today it is only visible to someone reading the log. Wanted: it is noticed, and a report with
enough in it to find the node can be kept or sent — for the developer testing, and for users.

- **Where it can be seen.** The error is the engine's own stderr line
  (`accessibility_bridge.cc(114)`), so only the release launcher
  (`windows/runner/log_capture.cpp`, which already pipes, redacts and timestamps every line) can
  see it; Dart cannot. The launcher can count the lines and tell the app (a file or a named pipe).
- **Report contents (no cookie, no account data):** time, app version, the first error line, how
  many followed, the OS and Flutter versions, whether a screen reader was running, and — if
  `RILL_SEMANTICS_DUMP` is on — the node id's lines from `rill-semantics-changes.txt`. The log
  already redacts cookies; keep that chokepoint.
- **Local first:** append to `%LOCALAPPDATA%\rill\a11y-reports\` (one file per run, newest 10),
  and show a row in the Problems list ("Accessibility errors: N this session — Copy report").
  Sending anything off the machine is a separate, opt-in step; nothing is sent by default.
- **Do not** try to recover the tree automatically (re-sending semantics) without measuring it:
  the bridge rejects every later update, and a rebuild may or may not clear that.

### 87. Remove the default-on semantics dump (due 2026-11-28)

`RILL_SEMANTICS_DUMP` was made **on by default in a dev build** (no `RILL_VERSION`) on 2026-10-06 to
collect node logs for the intermittent `AXTree` error. It used to force semantics on, which broke
Narrator started after the app (2026-10-23); it now follows the platform's semantics and forces them
only for `=1`. It writes a ring of tree dumps once a second to
`%TEMP%` and keeps a 4 MB node-change log.

- **On or after 2026-11-28:** delete `_dumpWanted`'s dev-build default in `ui/semantics_probe.dart`
  (back to `== '1'` only), and the sentences about the default in `docs/configuration.md` and
  CLAUDE.md "Accessibility".
- **Before removing:** if the error was seen in that time, check that it is explained
  (`axtree-error-diagnosis` memory, `architecture.md` F51); if not, extend the date.
  AXTree errors from dev-build sessions between 2026-10-06 and 2026-10-23 with Narrator started after
  the app are explained by this and do not count toward extending the date.
- Released builds were never affected: they carry a version and so need `RILL_SEMANTICS_DUMP=1`.

### 89. Distinct playlist tile

A playlist tile looks like a mix tile (stacked cards) and says far less than
youtube.com's: only the title, the owner's name and the count.

- **Look:** a video-count bar instead of the mix's stacked cards, so the two are
  told apart at a glance.
- **Content the response already has** (search `lockupViewModel`, measured
  2026-10-06): the owner's channel id (row 0's `browseEndpoint`), the type label
  ("Playlist" / "Album" / "Podcast"), and the first two videos as
  `"<title> · <duration>"` rows, each with its own `watchEndpoint`. youtube.com
  also shows "Updated 4 days ago"; that row was absent from the captured search
  fixtures, so find where it appears before promising it. Its search tile also
  ends with a line of the playlist's description (seen 2026-10-14), which has
  not been looked for in a response.
- **Not wanted: youtube.com's "View full playlist" link.** There the tile plays
  the first video and that link is the only way to the playlist's page. Here it
  is the other way round on purpose: the tile opens the page and the thumbnail
  plays (decided 2026-10-14).
- **Contract:** new `PlaylistItem` fields go in all five places
  (`contract-docs.test.ts`), the Dart model and the corpus sanitiser.

**Done when:** a playlist tile cannot be mistaken for a mix, and shows what
YouTube's does where the response carries it.
