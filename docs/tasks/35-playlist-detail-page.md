# Task 35: Playlist detail page (todo 59)

**Read first:** `CLAUDE.md` (hard invariants 1, 4, 6 and 10; the DTO block; the
whole "Accessibility" section), `docs/protocol.md` §3.3 (`playlist.get`),
`architecture.md` F54 and §2.8, `docs/todo.md` items 59 and 89,
`sidecar/src/parser/playlist.ts`, and `app/lib/ui/open_video.dart`
(`startPlaylistFromTile`, `tapHandlerFor`).

**The gap.** A playlist can be played (Task 34) but not looked at. There is no
page that shows what is in it, and a playlist tile can only start it.

**The goal.** The page youtube.com opens at `/playlist?list=<id>`: a header
panel (cover, title, owner, counts, description, actions) beside the list of
every video, loading further pages as the user scrolls.

**Decisions already made by the user (2026-10-06).** Do not reopen them:

1. On a playlist tile, **the thumbnail plays the playlist; the rest of the tile
   opens the page.**
2. **Right-clicking the queue panel's header** opens a menu: *Open playlist
   page* and *Copy link*. A normal click still collapses and expands the panel.
3. **Clicking a video on the page plays the playlist from that video**, not the
   video alone.
4. Header actions: **Play all and Share work now. Save and Shuffle are stub
   buttons**, visible and inert.
5. **Layout is YouTube's:** header panel on the left, list on the right; the
   header moves on top when the window is narrow.
6. **The viewer's own playlists are read-only here.** The owner's extra buttons
   (add videos, edit) are stubs too.

---

## 1. Measure first

Raw responses only (`parse: false`). `fixtures/playlist.json` is a public
playlist's first page; capture more as needed, declared in
`sidecar/src/fixtures.ts` or kept out of `fixtures/`.

1. **The header,** in `header.pageHeaderRenderer.content.pageHeaderViewModel`
   and, where it is easier, `sidebar.playlistSidebarRenderer` and
   `metadata.playlistMetadataRenderer`. Find, and record the path of:
   - the cover image (`heroImage`);
   - the owner's name, channel id and avatar (metadata row 0, an avatar stack);
   - the type label, the video count and the view count (metadata row 1);
   - the visibility ("Private", "Unlisted"), which youtube.com shows in that
     same row for the viewer's own playlists;
   - the description;
   - the "last updated" text, if it is there at all;
   - a colour for the header's tint, if the response carries one. The artist
     panel's does (`ThemedColor`, `artist_panel_card.dart`); look for the same
     here before assuming it has to be computed from the cover.
2. **Which of those survive** for: a public playlist, an unlisted one, a private
   one of the viewer's own, `WL` and `LL`. Signed in and anonymous where both
   make sense. Record what is absent, not only what is present.
3. **Whether the viewer owns it.** Find a signal that is not a localised label
   (an edit endpoint, a flag), since stub owner buttons depend on it.
4. **A language-independent visibility signal,** if one exists. If the only
   source is the label, say so and ship the label as display text.

**Report the measurements before building**, as Task 34 did. They go into the
`architecture.md` finding (§6).

## 2. The sidecar: a header on `playlist.get`

- **Add the header to `PlaylistResult`** as one nullable object, present on the
  first page and `null` on a continuation:

  ```ts
  interface PlaylistHeader {
    title: string;
    thumbnailUrl: string | null;
    ownerName: string | null;
    ownerChannelId: string | null;
    ownerAvatarUrl: string | null;
    videoCount: number | null;
    viewCountText: string | null;     // display string, not parsed
    visibilityText: string | null;    // null for a public playlist
    updatedText: string | null;
    description: string | null;
    isOwnedByViewer: boolean;
  }
  ```

  That is a proposal; §1 decides the real fields. **If §1 finds a
  language-independent visibility signal, ship that instead of the label:**
  `visibility: 'public' | 'unlisted' | 'private' | null`, with the client
  writing the word. `visibilityText` is only for the case where the label is
  all there is. Every field is a value or `null`, never omitted. `PlaylistResult.title` and `.videoCount` exist already
  and the queue reads them: keep them, or move them into the header and update
  the queue, but do not ship the same fact twice.
- **Restate the shape in all five places** (`CLAUDE.md` on
  `contract-docs.test.ts`), the Dart model, and the corpus sanitiser. A playlist
  title, description and owner are real data: the sanitiser replaces them.
- **Tolerant parsing.** A missing header field is `null`; a missing header is a
  `null` header with the list still shipped.
- **`isOwnedByViewer` is account state.** It follows the Task 31 rule: re-read
  on an identity change, never taken from a response cached under the other
  identity.

## 3. The app

### 3.1 The page

- **A new route and page** (`ui/pages/playlist.dart`), with its own controller
  holding `{header, items, continuation, loading, error}`. Any `copyWith` over
  the nullable fields uses the sentinel (invariant 10).
- **Layout:** header panel left, list right; header on top below a width you
  choose and name as a constant. The header's tinted background on youtube.com
  comes from the cover.
- **The tint must not pop in.** Use a colour from the response if §1 found one
  (as the artist panel does: no decode, no first frame in the wrong colour).
  The app has no palette extraction today (`theme/tokens.dart` says so). If the
  colour has to be computed from the cover, do it off the UI isolate, cache it
  by playlist id, draw the header on the plain surface colour first and animate
  to the tint when it arrives. Text and buttons must stay readable on both, in
  light and dark themes. A new dependency for this is a decision to report, not
  to take silently.
- **Header content:** cover, title, owner (avatar, "by <name>", opening nothing
  yet unless a channel page exists), `Playlist · <visibility> · N videos · views`,
  description, and the action row.
- **Actions:**
  - *Play all*: `startPlaylistFromTile`'s path, from the first video.
  - *Share*: `share_dialog.dart`, with the playlist URL.
  - *Save*, *Shuffle*, and for an owned playlist *Add videos* and *Edit*: stub
    buttons. Enabled-looking but inert is a trap; show them disabled, each with
    a `ShortcutTooltip(silent: true)` saying it is not available yet. A disabled
    control cannot hold focus, which is correct here.
- **Rows:** index, thumbnail with duration, title, channel, views and age. A row
  uses the existing tile pieces where they fit; do not fork `MediaTile`.
- **Loading, empty and error states:** a skeleton while the first page is out;
  the `UPSTREAM_ERROR` text ("The playlist does not exist.") with no retry; a
  retry for a network failure.

### 3.2 Paging on the page

- **Load the next page when the user nears the bottom** of what is loaded, the
  way `feed_view.dart` does. Not all at once: this page is for looking, and an
  883-video playlist is nine requests nobody asked for.
- **One request at a time; a null continuation ends it; a failed page offers a
  retry at the foot of the list** and does not lose what is loaded.
- This is **separate from the queue's paging.** The queue loads every page in
  the background because it has to play them (`QueueController._maybeExtend`).
  The two may fetch the same pages; do not couple them to avoid that. This is
  duplicated work, not a race: each controller holds its own list and its own
  continuation, the requests are read-only, and neither reads the other's
  result. No de-duplication in the client or the sidecar.

### 3.3 Playing from the page

- **Clicking row N plays the playlist from video N.** Add a start position to
  `QueueController.startPlaylist` (the page hands over the items it has loaded
  and its continuation, so the queue does not refetch page one and can start on
  a video from page three immediately). The queue then carries on paging from
  that continuation as it does today.
- The undo snackbar and the rollback on failure behave as for a tile.
- **Test the case where the clicked row is on a later page** than the first.

### 3.4 Ways in

- **Tile:** thumbnail plays, the rest opens the page (`tapHandlerFor`,
  `media_tile.dart`). Two tap targets, each with its own name for a screen
  reader ("Play <title>", "Open playlist <title>"), each reachable by Tab.
  Mix tiles are unchanged: a mix has no page.
- **Queue panel header:** right-click opens a menu with *Open playlist page* and
  *Copy link*. Only for a playlist, not a mix or a hand-built queue.
  - The menu must also open from the keyboard (the context-menu key and
    Shift+F10 on the focused header); a mouse-only menu is not done. The
    header is already a Tab stop (its `InkWell` collapses the panel), so this
    adds a key handler, not a new focus node.
  - Read the Accessibility section before choosing the widget: an overlay menu
    anchored under something that unmounts is the AXTree fault. The header does
    not unmount while the panel is shown, but check with the semantics probe.
  - *Copy link* copies `https://www.youtube.com/playlist?list=<id>` and says so
    in a snackbar.

### 3.5 Accessibility and focus

- The page is a new surface: declare its Tab order in `ui/focus_surface.dart`
  (header actions, then the list).
- Every control has one name; durations are spoken through `ui/spoken.dart`.
- Run `RILL_SEMANTICS_PROBE=1` with a focus probe over the new page, and walk it
  with Tab, before calling it done.

## 4. Tests

**Sidecar:** the header against the fixture (`hasFixture`) and against a
synthetic tree with fields missing; a continuation page has a `null` header;
Guard 2 (`contract-docs.test.ts`) green; the corpus auditor green after
`bun run export-contract-corpus`.

**App:**
- the page shows the header and the first page, and asks for the next page only
  when scrolled near the end;
- a null continuation stops it; a failed page keeps the list and offers a retry;
- clicking row N starts the playlist at N, including N beyond the first page;
- the tile's thumbnail plays and its body opens the page;
- the queue header's menu appears for a playlist only, from the mouse and from
  the keyboard, and both entries do what they say;
- stub buttons are present, disabled and named;
- the labelled-tap-target and focus-traversal guideline tests pass with the new
  page in them.

**Mutations,** each must fail a test, output pasted:
1. load every page on open instead of on scroll;
2. clicking a row plays that video alone;
3. the tile body plays instead of opening the page;
4. show the header menu for a mix.

## 5. Hand-off to the user

1. Open a public playlist's page from a tile; check the header against
   youtube.com.
2. Scroll a playlist of more than 200 videos to the bottom; it should load in
   steps without a visible stall.
3. Click a video far down the list; the playlist plays from there and the queue
   shows the right position.
4. Open one of your own private playlists; visibility shows and nothing is
   editable.
5. Right-click the queue header during a playlist; try both entries. Do the same
   with the keyboard.
6. Tab through the page with Narrator on.

## 6. Docs

- **`protocol.md`:** `PlaylistResult` and the header shape.
- **`architecture.md`:** a finding with §1's measurements (next free F number;
  read the table, do not count), and §2.8 if the page adds a sharp edge.
- **`CLAUDE.md`:** the DTO block if a shape listed there changed.
- **`todo.md`:** delete item 59; add items for Save, Shuffle and playlist
  editing if none exists. Take each number from the "Next number" line as it is
  on disk at that moment, and bump it in the same edit. Item 89 (the tile's own
  look and extra content) stays open unless this task finishes it.

---

## Definition of done

- §1's measurements in the report and in an `architecture.md` finding
- The page opens from a tile and from the queue header, shows the header and
  the list, and pages on scroll
- Row N plays the playlist from N
- Play all and Share work; the stubs are disabled and say why
- Keyboard and Narrator can reach and use everything on the page
- Tests and the four mutations
- `.\rill check` and `cd sidecar; bun run check` green, raw output pasted
- The §5 hand-off given to the user

## Out of scope

- Save to library, Shuffle, loop.
- Editing a playlist: title, visibility, reordering, removing, adding.
- A channel page for the owner link.
- Watch Later and history as their own feeds.
- The playlist tile's redesign (item 89), beyond the two tap targets.

## Stop conditions

- **The header is not in the `/browse VL<id>` response** in a usable form for
  some playlist type. Report which.
- **Ownership or visibility can only be read from a localised label.** Report
  it before shipping a label match.
- **Starting the queue from a later page would change how a mix or an ordinary
  playlist start behaves.** Report it; do not bend Task 34's paging to fit.
- **The right-click menu cannot be made keyboard-reachable or trips the AXTree
  fault.** Report it rather than shipping it mouse-only.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Edit files with your editor tools only, never with scripts that rewrite source
  files. Delete any helper scripts before reporting.
- Say plainly what you ran and what you handed to the user.
