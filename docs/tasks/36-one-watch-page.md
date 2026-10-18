# Task 36: One watch page at a time (todo 90)

**Read first:** `CLAUDE.md`, `docs/todo.md` item 90, and `app/lib/ui/player_shell.dart`
from `currentRouteProvider` down to `showWatchPageIn` (`RouteTracker` sits in
between). Also read `isTopWatchPage` in `pages/watch.dart`, and the route listener
in `player/view_mode.dart`.

**The bug.** "Go to Playlist" in the queue header pushes the playlist's page over
the watch page. Playing a row from there pushes a second watch page over that,
because `showWatchPageIn` pushes whenever the top route is not `watch`. A search
started from the watch page does the same. Each round trip adds two routes, all
kept mounted, and Back has to walk through every one of them.

**The decision is made: one watch route, and the buried one goes.** Opening a
video from a page that sits over a watch page removes that buried watch route and
pushes a fresh one on top. Back then goes to the page you came from (the playlist
page or the search results), and then to whatever was under the old watch page.
At no time is there more than one watch route.

The alternative was rejected: popping back to the existing watch page would throw
away the page the user came from. That is the page Back is most likely meant to
reach, and it is what a browser does on YouTube itself.

---

## 1. Read before building

1. **Finding the buried route.** `Navigator` has no public list of its routes.
   Say how you will find the buried watch route. One way: if `showWatchPageIn` is
   the only place that pushes a watch route (check that with a grep for
   `watchRouteName` and `WatchPage(`), it can keep a reference to the route it
   pushed, and clear it when that route is popped or removed.
2. **`RouteTracker.didRemove` reports the wrong route for this case.** It reports
   `previousRoute`. For a route that is not on top, that is the route *below* the
   removed one, not the route on top. Nothing removes a buried page route today,
   so this has never mattered, but this task does it.

   **Example.** Removing watch₁ from `[feed, watch₁, playlist, watch₂]` reports
   `feed` as the current route while watch₂ is on screen. Three consumers then
   act on a navigation that never happened:
   - `miniPlayerShownProvider` floats the miniplayer over the watch page;
   - `sectionRouteProvider` lights the wrong rail entry;
   - `PlayerViewController` resets the view mode.

   Say whether one order (remove, then push) happens to hide this. **Fix it in
   the tracker either way:** removing a route that is not on top must change
   neither `currentRouteProvider` nor `sectionRouteProvider`.

## 2. Build

1. **`showWatchPageIn`.**
   - If the top route is already the watch page, nothing changes.
   - Otherwise, push a new watch route. If a watch route is buried in the stack,
     remove it with `removeRoute`.
   - The removed route needs no animation. The push animates as it does today.
2. **The tracker.** Fix it as §1.2 describes. The simplest robust shape is
   probably a tracker that keeps its own stack of reportable page routes and
   always reports the top of it, but the shape is your call.
   - `didRemove` does not close tooltips; the other three callbacks do. Add the
     call too, unless you find a reason not to (F51 is the reason the others
     have it).
3. **Playback is not touched.** The player lives above the `Navigator`.
   Removing a watch route must not reopen, reload or pause playback, and must
   not send a second `playback.open`. The video surface passes to the new top
   page through `isTopWatchPage`, as it does today.
4. **Tapping the row that is already playing.** Whatever the queue does with it
   today stays as it is. For the route: say what happens, and keep it sensible.
   Popping back to the existing watch page is fine for this one case.
5. **Other pages still stack,** for example playlist → search → playlist, as
   they would in a browser. That is not this task. If you see a cheap bound,
   mention it in the report; do not build it.

## 3. Tests

1. **Through "Go to Playlist":** watch page → "Go to Playlist" → play a row.
   - Exactly one watch route remains.
   - Back reaches the playlist page.
   - Back again reaches the page that was under the original watch page.
2. **Through search:** the same, starting a search from the watch page.
3. **Back without playing anything:** watch page → playlist page → Back returns
   to the original watch page, and nothing was removed.
4. **The providers, after the removal:**
   - `currentRouteProvider` is `watch`;
   - `sectionRouteProvider` is what it was on the playlist page;
   - the miniplayer is not shown;
   - the view mode was not reset by the removal.
5. **Playback:** the removal adds no `playback.open`.

**Mutations,** each must fail a test, with the output pasted:
1. Skip the removal.
2. Put back the old `didRemove`.
3. Remove the top route instead of the buried one.

## 4. Hand-off to the user

On a release build:

1. Open a video, then the queue header's "Go to Playlist", then play a row.
   Back goes to the playlist page. Back again goes to where you started.
2. From the watch page, search, then play a result. Back behaves the same way.
3. While doing 1 and 2, check four things:
   - the miniplayer never flashes;
   - the rail highlights the right section;
   - playback does not stutter or restart when the old page is removed;
   - theatre mode behaves as it did before.
4. With Narrator on, do step 1 once more. Send the release log from that
   session. It should contain no `Failed to update ui::AXTree` lines.

## 5. Docs

- **todo 90:** delete it when the work is done.
- **`RouteTracker`'s doc comment:** add a paragraph on `didRemove`, saying why
  removing a route that is not on top must not report a navigation.
- **`CLAUDE.md`, "Notes that will bite otherwise":** add one line, but only if
  it is true after the change: "At most one watch route exists.
  `showWatchPageIn` is the only place that pushes one."
- **`architecture.md`:** no finding is needed, unless §1 turns up something
  that was not known.

**Todo numbering.** If you add an item, take its number from the **"Next
number" line of the file as it is on disk at that moment**, and bump that line in
the same edit.

---

## Definition of done

- At most one watch route. Back goes watch → the page you came from → what was
  under the old watch page.
- A route removed from under the top changes no route provider.
- Playback is untouched by the removal.
- Tests and the three mutations are in place.
- `.\rill check` and `cd sidecar; bun run check` are green, with the raw output
  pasted.
- The §4 hand-off has been given to the user.

## Out of scope

- Bounding the stack of pages other than the watch page.
- Keeping the old watch page's scroll position or comments when a different
  video opens.
- The miniplayer, fullscreen, and the queue's own behaviour.

## Stop conditions

- **Removing the buried route reloads the player,** sends `playback.open`, or
  breaks the video surface hand-off. Report what triggers it before working
  around it.
- **A second place pushes watch routes** and cannot be routed through
  `showWatchPageIn`. Report it.
- **The tracker fix changes what any consumer sees on an ordinary push or
  pop.** Report it.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Edit files with your editor tools only, never with scripts that rewrite source
  files. Delete any helper scripts before reporting.
- Say plainly what you ran and what you handed to the user.
