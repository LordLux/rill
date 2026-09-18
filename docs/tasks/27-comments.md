# Task 27 — Comments

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.3 and §3.4,
`docs/architecture.md` §2.2, and the Task 25 report.

`video.comments` is specified in §3.3 and — like `mix.start` and `playlist.get`
before it — **may not exist.** Check first; several specified methods have turned
out to be fiction.

This is the largest read surface left, and the first one with **two levels of
pagination**: threads page, and each thread's replies page independently.

---

## 1. Verify the spec before building against it

§3.3 says `video.comments {videoId, continuation?}` → `{items[], continuation?}`.

That shape has no room for replies, for a sort order, for the comment count, or
for the "comments are disabled" case. Measure what the endpoint actually returns
and amend §3.3 to match — do not build against a spec that predates any
measurement.

Establish:

- **Whether the method exists at all**, and whether the parser handles comment
  renderers
- **How comments are fetched.** They are not in the initial `/next`; the watch
  page carries a continuation token that must be followed. Confirm.
- **How replies are fetched** — a second continuation per thread, or inline
- **Sort options** — Top and Newest exist on youtube.com. Are they tokens the
  server hands you, or constructed like search filters (Task 20)?
- **What a disabled-comments video returns.** An empty list, an error, or a
  distinct marker. This is common and must not read as a failure.
- **What a members-only or age-restricted video returns**

Report all six before writing code.

## 2. The DTO

Comments are not `FeedItem`s and should not join that union — the grid switches
over it and a comment is not a tile.

A new DTO. At minimum: id, author name, author avatar, author channel id,
whether the author is the video's uploader, whether they are verified, text,
like count, published text, reply count, whether the viewer liked or hearted it,
and whether it is pinned.

Two things to get right, because both have bitten before:

- **Comment text is rich.** Links, timestamps that seek the video, `@mentions`,
  and newlines. Establish how it arrives — runs with navigation endpoints,
  probably — and carry the structure rather than flattening to a string. A
  flattened string cannot be made clickable later without reparsing.
- **Author verified and artist badges** were solved in Task 21
  (`metadataBadgeRenderer.style`). Reuse that, do not re-derive it.

Add to the DTO contract in `CLAUDE.md`, `types.ts`, the strict-key contract test
and the corpus exporter — `contract-docs.test.ts` will fail otherwise, which is
the point.

## 3. Two levels of pagination

Threads paginate. Each thread's replies paginate **independently**, and a thread
can have thousands.

- Threads load as the user scrolls the watch page
- Replies load on demand per thread, and "show more replies" within an already-
  expanded thread is its own continuation
- Two threads expanding at once must not interfere — this is the surface-keyed
  lesson from the chip bar, one level deeper
- `$cancel` and the generation guard apply. A sort change while threads are
  loading must not merge the old sort's page into the new one

**This is where the bugs will be.** The feed has one continuation; this has one
plus N.

## 4. Sorting

Top and Newest. Changing sort discards and refetches — it is a different list,
not a reordering.

If sort tokens come from the server, treat them like chips. If they are
constructed, treat them like Task 20's search filters and say which.

## 5. Posting — decide, then scope

Posting a comment, replying, liking a comment and hearting are `action.*`
methods, and **they write to a real account** — §1 of Task 25 applies in full.

**Default: read-only in this task.** Rendering comments well is a substantial
surface on its own, and posting is the kind of thing that wants its own
verification pass.

If you disagree — if posting falls out cheaply once the DTOs exist — say so with
the cost and stop. Do not build it unasked.

**Liking a comment is the borderline case**: it needs viewer state on the DTO
either way, since a like button has to render its own state. Carry the state,
leave the action.

## 6. The UI

Below the description on the watch page. Not a separate route.

- Thread list with author, avatar, text, likes, timestamp, reply count
- Expand and collapse replies
- Sort control
- Pinned comments first; uploader replies marked
- Timestamps in comment text seek the player
- Loading, empty, **disabled**, and error states — disabled is not an error
- A comment count near the header

**Comments are heavy.** Hundreds of threads with avatars, in a page that already
hosts a player and a related rail. Virtualise, and do not hold every avatar
decoded. Report what a long thread list costs in frame times — F15's reasoning
applies even though no FFI is involved.

## 7. What must not regress

- The watch page: player, captions, queue, related rail, the actions row
- Hover previews on related tiles
- Scroll position on the watch page when a thread expands — expanding a thread
  above the viewport must not move what the user is reading

---

## Tests

- Comments parse from a real captured response into the new DTO
- A disabled-comments video yields the disabled state, not an error
- Rich text keeps its structure — a link, a timestamp and a mention survive
- Reply pagination is independent per thread; two expanded threads do not
  interfere
- A sort change discards the previous list and does not merge pages
- Viewer like state renders correctly for liked and not-liked
- Uploader, verified, pinned and hearted all render distinctly

**Mutation-check the disabled-comments path and the per-thread pagination
isolation.** A test asserting "thread A loaded replies" passes if replies from
thread B were merged in. Assert both threads' contents.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- Comments load on the watch page and paginate
- Replies expand per thread and paginate independently
- Sorting works and does not mix pages
- A video with comments disabled says so
- A comment timestamp seeks the player
- Scrolling a long comment list stays smooth

**Run the app and say what you saw** — a video with thousands of comments, a
thread with many replies, a sort change mid-load, and a disabled-comments video.
Report frame times for a long list.

## Out of scope

Posting, replying, liking or hearting — see §5. Comment search. Moderation.
Community posts. The custom title bar.

## Stop conditions

- **`video.comments` does not exist or returns something other than §3.3.**
  Report the real shape before building.
- **Rich text cannot be carried structurally** without a DTO shape the contract
  cannot express. Report; do not flatten to a string as a workaround.
- **A long comment list drops frames** and virtualising does not fix it. Report
  the measurement before redesigning.
