# Task 25 — Actions

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.1 and §3.4,
`docs/architecture.md` §2.3 and F6, and the Task 22 report.

The first task that **writes to the user's real account.** Read §1 before
writing code.

Login shipped and only reads are verified. Whether the authenticated session can
write is untested: `action.addToWatchLater` was written in Task 14 and has never
been exercised, and `playback.report` landing in real history is still an open
item from Task 22's definition of done. This task establishes both.

---

## 1. This writes to a real account

Every method here changes something visible on youtube.com, and some are
annoying to undo.

- **Use a throwaway account if you have one.** If not, be correspondingly
  careful: prefer testing subscribe on a channel the user already follows,
  playlist operations on a playlist created for the purpose, likes on a video
  where a stray like does not matter.
- **Create and delete your own test playlist** rather than mutating an existing
  one.
- **Never bulk-test.** A loop that likes twenty videos to measure a rate is a
  loop that polluted a real account.
- **Report exactly what you changed** on the account, so it can be undone.

## 2. What already exists — verify, do not assume

`protocol.md` §3.4 lists `action.addToWatchLater`, `action.addToPlaylist`,
`action.like` / `action.dislike`, `action.subscribe`. Some are implemented; at
least one has never run.

For each: does it exist, does it execute against the authenticated `WEB`
session, and does it actually work? Report the three separately — Task 14's
`_ChannelTile` existed, compiled, and was wrong in two ways the first time it
ran.

**All actions go over the authenticated `WEB` session** (§2.3, F6). Stream
resolution stays anonymous `VISIONOS`. Do not send cookies on the resolution
path.

## 3. Current state is the hard part

A like button needs to know the video is already liked; a subscribe button needs
to know the channel is already subscribed. Otherwise the first render is wrong
and the first click toggles the wrong way.

Establish where that lives in the watch-page response and surface it on the DTOs.
Likely candidates in `/next`: the like/dislike toggle buttons carry a state, and
the subscribe button carries `subscribed`. **Verify against a captured
response** rather than assuming field names.

If a state is genuinely not available, say so — a button that cannot know its
own state is a design problem, not an implementation one.

## 4. Optimistic UI, honestly

A like should feel instant. It should also not lie.

- Update immediately, revert on failure, and tell the user it failed
- A failure that silently reverts looks like the click did not register
- Do not queue retries — an action the user did not see succeed should not
  happen later without them

Say what you chose for each action and why.

## 5. Playlists

Beyond `action.addToPlaylist`, the save-to-playlist dialog needs:

- **The user's playlists** — a method to list them. Propose the shape against
  §3.2, and note whether it paginates
- **Which playlists already contain this video**, so checkboxes render correctly
- **Remove from playlist**, since the dialog's checkboxes toggle both ways
- **Create a new playlist**, with a privacy setting if the API exposes one

The tile's 3-dot menu and the watch page both open this. One dialog, one
controller.

## 6. `playback.report` — close the open item

Task 22's definition of done included "a watch lands in real YouTube history"
and it was never confirmed.

Confirm it now: play a distinctive video signed in, then check youtube.com. This
is the thing the whole two-client design exists to protect — F6 established
reporting works from the authenticated session, and nothing has verified it end
to end since.

If it does not land, that is a finding and probably outranks the rest of this
task.

## 7. Watch Later

`action.addToWatchLater` exists, has never run, and the tile's hover button
already calls something.

- Verify it works
- The button needs a state — already saved, or not
- Removing from Watch Later is the same playlist mechanism as §5; Watch Later is
  a playlist with a fixed id

---

## Tests

- Each action executes against the authenticated session and returns success
- Each action against an anonymous session fails cleanly — an error the UI can
  show, not a crash
- Current state parses from a real captured watch-page response: liked,
  disliked, neither; subscribed, not subscribed
- Optimistic update reverts on failure, and the failure surfaces
- The playlist dialog renders existing membership correctly
- Creating and deleting a playlist round-trips

**Mutation-check the state parsing and the optimistic revert.** A test asserting
"the button shows liked after clicking" passes if it always shows liked. Assert
the not-liked case, and assert the revert on a forced failure.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- Like, dislike and un-like a video; the state survives a reload
- Subscribe and unsubscribe; the subscriptions surface reflects it
- Add and remove a video from a playlist via the dialog
- Create a playlist, add to it, delete it
- Watch Later add and remove, from the tile and the watch page
- **A watch lands in real YouTube history**

**Run the app and say what you saw**, and list every change made to the real
account.

## Out of scope

Comments. Mixes. The custom title bar. Playlist reordering. Sharing.
Not-interested and don't-recommend. Notification settings.

## Stop conditions

- **An action's current state is not in the response.** Report where you looked;
  do not infer it from another field.
- **`playback.report` does not land in history.** Report and stop — that
  outranks the rest of this task.
- **An action needs a client other than `WEB`.** Report before building; the
  two-client model is load-bearing.
- **You changed something on the account you cannot undo.** Say so immediately.
