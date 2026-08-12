# Task 15 — Hover previews

> **Superseded on 2026-08-11, after this task shipped.** §1 below ("Storyboards,
> not video") was reversed by a decision recorded in `architecture.md` §2.6:
> hover previews now play the real video, muted, and sprite sheets are kept only
> as the scrubber's future input (`protocol.md` §3.7). The brief is left intact
> as the record of what was asked for; where it and §2.6 disagree, §2.6 wins.

**Prerequisite:** `CLAUDE.md` (hard invariants 8 and 9), `docs/architecture.md`
F8 and F16, `docs/protocol.md` §3.5 and §5, and the Task 07 report.

The last piece of the tile, and the requirement that started the project:

> when the user hovers over the video, the preview of the video starts playing

The action buttons are already drawn. This makes the thumbnail move.

---

## 1. Storyboards, not video

F8 measured it: **feed responses carry no preview media at all** — zero mp4 or
webm URLs across nine captures. YouTube's hover clips are not in the payload.
What is available is `PlayerStoryboardSpec`, a sprite sheet of frames, present
with a resolved template URL.

So a preview is a **sprite sheet animated on hover**, not a video.

This is cheaper than it sounds and better suited to a grid: one image request,
no player instance, no session, no PO token, no decipher.

**Do not instantiate a player per tile.** Task 07 measured ANGLE surface
creation and F16 measured 16–29% dropped frames at 2160p60 on this machine with
*one* player. A grid of them is not a slow version of this design; it is a
different and unworkable one.

## 2. Getting the storyboard URL

`playback.open` already returns `storyboardTemplate`, but calling it per tile is
wrong — it resolves streams, opens a session, and costs a round trip.

Add a lightweight method. Suggested shape, but check §3.5 and propose better if
this does not fit:

```
video.storyboard  {videoId}  →  {template, columns, rows, interval, frameCount, width, height}
```

Requirements:

- **No session, no stream resolution.** A storyboard needs the player response's
  storyboard spec and nothing else
- **Batchable or cheap enough not to need batching.** A feed page is ~22 tiles;
  22 sequential round trips on hover is fine, 22 on page load is not
- **Cache in the sidecar.** Storyboard specs do not change; the URLs are signed
  and expire, so cache the spec and re-sign rather than re-resolving
- Amend `protocol.md` with whatever shape you land on

**The template URL needs parameter substitution.** YouTube's storyboard URLs
carry `$L` (level), `$N` (name) and `$M` (sheet index) placeholders plus a
`sigh` signature per level. Work out the substitution against a real response
rather than assuming a format — and if the spec cannot be parsed reliably,
**that is a stop condition**, not something to approximate.

## 3. Hover behaviour

- **~400 ms delay before starting.** Sweeping the mouse across a grid must not
  fire twenty requests. The delay is also what makes the effect feel deliberate
  rather than twitchy
- Cancel on exit, including during the delay
- Animate through frames at the spec's interval, looping
- Fall back silently to the static thumbnail on any failure — a missing preview
  is not an error state, and a broken-image box is worse than no preview

### Rendering

Sprite animation is an image offset changing, not twenty images. `CustomPainter`
drawing a source rect from one decoded sheet, or a `Stack` with a clipped
`Positioned`. Decode the sheet once and hold it.

**Cache decoded sheets in memory with a bounded LRU.** A sheet is a few hundred
KB decoded; an unbounded cache across a long scroll is a leak. Bound it, and say
what the bound is and why.

### Hard invariant 9

Nothing here polls `NativePlayer.getProperty`, but the same reasoning applies:
decoding an image is CPU work and must not land on the frame loop. Use Flutter's
async image decoding rather than a synchronous decode in a build method.

## 4. What must not regress

- The two action buttons still work, and hovering one does not stop the preview
- `IgnorePointer` still keeps faded buttons from swallowing clicks
- Tile tap still navigates
- Scrolling stays smooth **while previews are running** — this is the one most
  likely to break, and it is why the LRU bound matters

---

## Tests

- The storyboard method returns a usable spec for a real video, with no session
  opened and no stream resolved
- Template substitution produces a fetchable URL — assert the fetch returns an
  image, not that the string looks right
- Hover after the delay starts the animation; hover-and-leave inside the delay
  starts nothing
- A failed storyboard fetch leaves the static thumbnail and logs, with no error
  UI
- The decoded-sheet cache evicts at its bound
- Existing tile tests stay green

**Mutation-check the delay and the cancel.** Both are the kind of guard that
passes against deleted code — a test that hovers, waits 500 ms and asserts an
animation started will pass with no delay implemented at all.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean including
  the colour-literal rule
- Hovering a tile animates its thumbnail; leaving stops it
- Sweeping across the grid fires no requests
- Scrolling with previews active stays smooth

**Run the app and say what you saw** — including a fast sweep across several
rows, and a scroll while a preview is playing.

## Out of scope

Video previews, the quality stepper, mixes auto-extending, search, login,
comments.

## Stop conditions

- **The storyboard spec cannot be parsed or substituted reliably.** Report the
  actual shape rather than approximating a URL format.
- **Scrolling degrades with previews active** and bounding the cache does not
  fix it. Report before redesigning the tile.
- **A tile-level method does not fit `protocol.md`'s method surface** without
  contorting it. Say so and propose the shape rather than bending an existing
  method.
