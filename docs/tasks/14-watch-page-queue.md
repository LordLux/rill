# Task 14 — Watch page, player shell, and queue

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.3, §3.4, §3.5,
`docs/architecture.md` §2.3 and F15/F16, and the Task 07 report.

The feed renders and nothing is clickable. This makes it work end to end: tap a
tile, watch the video, queue the next one.

Large, so the cuts are deliberate. **Out of scope:** hover previews, comments,
search, mixes auto-extending, the quality stepper, login. Each is its own task.

---

## 1. The player shell — decide this first

**The player lives above the `Navigator`, not inside the watch route.**

A player inside the route is destroyed on pop, which makes a mini-player and
background playback impossible. Structure:

```
ProviderScope
  └─ PlayerShell            ← owns the media_kit Player, survives all routes
       ├─ Navigator          ← feed, watch, future pages
       └─ MiniPlayer         ← visible when playing and not on the watch page
```

- One `Player` instance for the whole app, in a Riverpod provider
- The watch page renders the video into the shell's player rather than creating
  one
- Leaving the watch page collapses to a mini-player; returning expands it
- **Playback does not stop on route change or window blur.** Background audio is
  requirement #6 and is nearly free here — verify it rather than build it

### Hard invariant 9 applies throughout

Never poll `NativePlayer.getProperty` from the UI isolate — F15 measured a
1.2–1.3 s frame-loop stall during a seek. Position, duration and buffering come
from `player.stream.*`. Direct property reads are diagnostics only.

## 2. Sidecar methods

Per `protocol.md` §3.3 and §3.4. The parser already produces the DTOs.

| Method | Notes |
|---|---|
| `video.info` | Composes `/next` and `/player` — `/next` carries no duration. **One player response shared with `playback.open`**, not two round trips |
| `video.related` | Related tiles flatten to the same `FeedItem` DTOs the feed uses |
| `action.addToWatchLater` | Authenticated `WEB` session |
| `action.addToPlaylist` | Same |
| `playback.report` | See §4 |

Validate params with the existing `requireString`; `BAD_REQUEST` for anything
malformed.

## 3. Watch page

Route pushed on tile tap. `maintainState` default, so the feed's scroll survives.

- Video in the shell player, from `variants[0]`
- Title, channel name and avatar, view count, published text
- Description, collapsed with a show-more
- Watch Later and Add to Queue actions
- Related videos from `video.related`, reusing `MediaTile`
- Loading, error and `STREAM_UNAVAILABLE` states — the last is `retry: "user"`
  per §4, so offer a retry rather than declaring the video dead

Tapping a related tile replaces the current video without pushing a second watch
route.

## 4. `playback.report` — load-bearing

Flagged since the architecture doc: **if watch events stop landing, the
recommender stops training and the homepage drifts from the real one**, which
defeats the product's premise.

- Reported from the authenticated `WEB` session, per F6 and §2.3 — streams
  resolve via `ANDROID_VR`, reporting goes over `WEB`. Two independent calls; do
  not attempt to bridge the CPN
- Real cadence: every 10–30 s plus state changes, not once at completion
- Position comes from `player.stream.position`

**Verify it lands.** Watch a distinctive video through the app, then open
youtube.com and check your history. That is the only proof, and it is the check
Task 02's design could never make.

## 5. Queue

Client-side state in a Riverpod provider.

- Ordered list plus a current index
- **Add to Queue** from the tile's existing button and from the watch page
- **Play next** as a distinct action — inserts after current rather than
  appending
- Reorder and remove
- A panel showing the queue, reachable from the mini-player and the watch page
- **Autoplay:** on completion, advance to the next item. When the queue empties,
  stop — pulling from related or a mix is a later task
- Queue survives navigation; it lives above the router like the player

Adding to an empty queue while nothing plays starts playback. Adding while
something plays does not interrupt it.

### Preload the next item

`playback.open {preload: true}` resolves without opening a session. Preload the
next queue item so transitions are instant.

## 6. Tile `onTap`

`MediaTile` has `cursor: SystemMouseCursors.click` and no tap handler.

- `VideoItem` → watch page
- `MixItem` → watch its first video, with the mix as context (`mix.start` is a
  later task; opening the first video is enough here)
- `PlaylistItem` → out of scope, leave inert
- The two action buttons stop propagating so they do not also navigate

---

## Tests

- `video.info` composes both responses with exactly one `/player` call
- Related tiles parse into the same DTOs as feed tiles, against the corpus
- Queue: append, play-next ordering, remove, reorder, autoplay advance, empty
  stop
- Adding to an empty queue starts playback; adding to a playing queue does not
- The player survives a route push and pop and keeps its position
- `playback.report` fires on cadence, not only on completion
- A `STREAM_UNAVAILABLE` on open surfaces a retry rather than a dead end

**Mutation-check anything that guards against a regression** — three tests this
session passed against deliberately broken code on the first attempt.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean including
  the colour-literal rule
- Tap a tile, video plays, seek works, audio in sync
- Navigate back mid-video: audio continues, mini-player appears, tapping it
  returns to the watch page with position intact
- Queue three videos, let one finish, next starts
- **Watch history lands on youtube.com** — checked manually

**Run the app and say what you saw**, including the history check.

## Stop conditions

- **The player cannot be hoisted above the `Navigator`** without media_kit
  fighting it. Report before restructuring around it.
- **`playback.report` does not land in history.** That is a finding, not a bug to
  work around — say so and stop.
- **A DTO cannot represent something the watch page needs.** Report; do not widen
  the shared contract unilaterally.
