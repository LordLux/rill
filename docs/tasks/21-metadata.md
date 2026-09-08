# Task 21 — The metadata the UI is missing

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.2 and §3.3,
`docs/architecture.md` §2.2, and the Task 12 and Task 20 reports.

**Sidecar and DTO only.** The UI work is being done separately — this task's job
is to make the data available, not to render it. Do not touch `app/lib/ui/`
beyond what a DTO change forces.

The premise: YouTube's own UI renders things ours cannot, from the *same
responses we already fetch*. A music video shows `♪ 5:00` in its duration badge
on youtube.com and `5:00` in ours. The data is in the payload and the parser is
dropping it.

**Start with the corpus, not the network.** `badges` is on the sanitiser's
`KEEP_REAL` list, so real badge values survive in `corpus/search.json`,
`corpus/home.json` and the rest. Grep those before capturing anything.

---

## 1. Shorts — flag, do not strip

The parser strips Shorts shelves. Task 20's screenshots show Shorts arriving in
**search** as ordinary video items carrying a `SHORTS` badge, so the strip does
not cover them.

This reverses the original "no shorts" requirement, deliberately: to group them
the way youtube.com does, the client needs them **flagged**, not removed.

- Add `isShort: bool` to `VideoItem`
- Stop stripping in the parser; classify instead
- Report what actually distinguishes a Short in each surface — a badge, a
  renderer type, a duration threshold, or several. Say which are reliable and
  which are inference.

The client decides whether to hide, group or show them. The sidecar reports.

## 2. Music classification

Two separate signals, and they may have different sources:

**Per video** — the `♪` in the duration badge. Drives the badge and, per the UI
plan, the like-button animation.

**Per channel** — the artist badge beside a channel name. Distinct from the
verified checkmark, which is its own thing and also currently missing.

Find where each lives. Candidates worth grepping in the corpus:
`ThumbnailBadgeView` and its `icon_name`, `badges`, `ownerBadges`,
`thumbnailOverlayTimeStatusRenderer` and its `style`. **This list is a starting
point, not an answer** — report what is actually there.

Add whatever you find to the DTOs as explicit fields. Do not infer music from a
channel name, a title, or a category.

If a signal genuinely is not in the payload, say so — that is a real answer and
it stops the UI planning for something unreachable.

## 3. The artist panel

An artist search returns a panel above the results: avatar, subscriber count,
video count, description, and action buttons. It is a distinct renderer, not a
video tile.

- Capture a live search for an artist name and report the renderer
- Decide how it reaches the client: a new `FeedItem` kind, or a separate field
  on the search response

**Prefer the separate field.** `FeedItem` is a sealed union the grid switches
over, and a panel is not a grid item. If it becomes a kind, every surface has to
know to skip it.

Whichever you choose, `UnknownItem` means an older client degrades rather than
throws — confirm that still holds.

## 4. Subscriptions channel list

`feed.subscriptions` returns the video feed. The **channel list** — every channel
the user subscribes to, with avatar, handle, subscriber count and description —
is a different browse endpoint.

- Add a method for it; propose the shape against §3.2 and amend `protocol.md`
- It is a list of `ChannelItem`, which Task 20 just fixed twice — protocol-
  relative avatars and `videoCountText` carrying the subscriber count. Confirm
  both fixes hold here.
- Report whether it paginates, and whether sort order is a parameter or fixed

Client-side search over the list is UI work; the sidecar returns the list.

## 5. The contract

`VideoItem` and `ChannelItem` both gain fields. That is the **shared contract**:

- Update the Dart DTOs to match, and the strict-key contract test — a field
  added sidecar-side that Dart does not read is exactly what that test exists
  to catch
- Re-export the sanitised corpus so the new fields are covered, and confirm the
  corpus auditor still passes. Any new field carrying real data must be
  sanitised or justified in `KEEP_REAL`
- `badges` already carries display strings. If a new flag duplicates something
  already in `badges`, say so and pick one — two sources for one fact is how
  they drift

---

## Tests

- Shorts classified, not stripped, on every surface that returns them
- The music signal parses from a real captured response, per video and per
  channel
- A video with no music signal yields `false`, not `null`, and does not throw
- The artist panel parses, and a search without one is not an error
- The channel list parses into `ChannelItem`s with working avatars and real
  subscriber counts
- Strict-key contract test covers every new field
- Existing corpus tests still pass

**Mutation-check the Shorts and music classifiers.** A test asserting "the field
exists" passes with a hardcoded `false`. Assert against a known Short and a known
music video, by id.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- Corpus re-exported, auditor green
- A search for an artist returns the panel, flagged Shorts, and music-marked
  videos, all visible in the RPC response

**Report what each signal actually was**, with the field path — that is the
deliverable the UI work depends on, more than the code.

## Out of scope

All UI. Rendering the panel, grouping Shorts, the music note, the like
animation, the channel-list search box. A setting to hide Shorts — the flag
enables it, the setting is UI.

## Stop conditions

- **A signal is not in the payload.** Say so plainly; do not infer it from the
  title, the channel name or a category.
- **The artist panel needs a new `FeedItem` kind** and the separate-field
  approach does not work. Explain why before widening the union.
- **A new field duplicates `badges`.** Report and pick one rather than shipping
  both.
