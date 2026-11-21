# Task 38: A sleep timer, and right-click + scroll for volume

**Read first:**
- `CLAUDE.md`.
- `app/lib/ui/player/settings_menu.dart`:
  - `SettingsPage`;
  - `_rootPlaceholders`, whose *Sleep timer* row is a placeholder today;
  - `_QualityPage`, as the model for a real page.
- `app/lib/ui/playback_controller.dart`: `_onCompleted` and `_endedShort`. Together they separate a real ending from a dropped connection.
- `app/lib/ui/player/controls.dart`: `_onPointerSignal`, today's Shift + scroll.
- `app/lib/ui/player/shortcuts.dart`: `textEntryHasFocus`, and the Space rule.
- `VideoDetail.chapters` in `sidecar/src/types.ts` and its Dart model.
- `app/windows/runner/main.cpp`: how the app ends, for the Close Rill action.

Two independent features in one task, because both are small and live in the player. The user has decided every point marked **(decided)**; do not change those without asking.

---

## 1. Sleep timer

### The menu

The *Sleep timer* placeholder becomes a real entry.
- **The root row shows the state:**
  - `Off`;
  - for a countdown, the time left (`12:34`);
  - for the other kinds, what it waits for (`End of chapter`, `End of video`, `After 3 videos`);
  - and, when the end action is not *Do nothing*, the action after it (`12:34 · then Sleep`).
- **The timer page lists, in this order:**
  - `Off`;
  - `1`, `2`, `5`, `10`, `15`, `30`, `45` and `60` minutes;
  - `End of chapter`, only when the video has chapters;
  - `End of video`, not for a live stream;
  - `Custom…`;
  - `When it ends: <action>`, which opens the action page (below).
- **The current choice is ticked,** as on the quality page.
- **To stop a timer, the user picks `Off` or another value (decided).** There is no warning before it fires and no *+10 min* or *Cancel* note.

### Custom…

`Custom…` opens a sub-page with three things:
- **A duration:** minutes and seconds fields and a *Start* button. Accept 0:01 up to 23:59:59.
- **After N chapters:** only when the video has chapters. N is from 1 to 99, with a stepper.
- **After N videos:** N is from 1 to 99.

**Keyboard:**
- The fields take focus, and no player shortcut fires while one has it (`textEntryHasFocus`).
- Enter starts, Escape goes back a page.

**Remember the last custom values** (`SharedPreferences`, like the other preferences), so the next *Custom…* opens on them.

### What each kind means

These rules are part of the spec.

- **A duration** counts real time from the moment it is set, monotonically, whether playback is running or paused. If playback is already paused when it runs out, it still runs its end action (below).
- **End of chapter** ends at the end of the chapter the playhead is in, which is the next chapter's start, or the video's end.
  - A seek into another chapter moves the target to that chapter's end.
  - A seek within the same chapter changes nothing.
- **End of video** uses the controller's **real** ending: the point where autoplay would advance.
  - A dropped connection (`_endedShort`) or a recovery reopen must never fire it.
  - When it fires it pauses at the end, and autoplay does **not** move on.
- **After N videos:** the current video counts as the first, and it pauses when the Nth video ends. With N = 1 it is the same as *End of video*.
  - Each new video that starts counts as one, whether autoplay started it or the user did (Next, a click, the queue).
  - Say in the report what you did about a video that is skipped before it ends, and test it.
- **After N chapters:** the current chapter counts as the first.
  - The count carries on across autoplayed videos.
  - A video without chapters counts as one chapter.

### The fade (decided)

For the kinds whose end is known in advance (a duration, *End of chapter*, *End of video*), the volume fades out over the last 10 s.
- **It fades the output, not the setting.** The user's volume setting is not changed while it fades.
- **Restore the volume the moment playback pauses,** so it is never silent when the user next presses play.
- **Any input from the user during the fade stops it at once:** a key press, a click, a scroll or a volume change in Rill's window. Mouse movement alone does not count.
  - The volume goes straight back.
  - The timer turns off.
  - Nothing pauses, and no end action runs.

  The user is awake, so control goes back to them. (*The orchestrator's reading of "gives control back to the user". Check with the user if you read it differently.*)
- **If the second player swaps in during a fade,** the fade continues on the new player.

### When it fires

1. Pause, with the fade above.
2. Restore the volume.
3. Turn the timer off.
4. Show a short note on the player ("Sleep timer: paused").
5. Run the end action.

### The end action (decided)

The *When it ends* page offers, with **Do nothing** as the default:
- **Do nothing.**
- **Close Rill:** the normal window close, the same path as the window's close button, so the session snapshot and the exit work as for any close.
- **Sleep:** offered only when the system allows it (`IsPwrSuspendAllowed`).
- **Hibernate:** offered only when hibernation is enabled (`IsPwrHibernateAllowed`).
- **Shut down.**
- **Restart.**

**How to run them:**
- Sleep and Hibernate through `SetSuspendState`.
- Shut down and Restart through `ExitWindowsEx`, after enabling `SE_SHUTDOWN_NAME` for the process.
- **Never pass `EWX_FORCE` or `EWX_FORCEIFHUNG`.** An app holding unsaved work must still be able to stop a shutdown, and Windows shows its own "apps are preventing shutdown" screen.
- Put the calls behind one small interface, so tests use a fake. Use FFI or a method channel to the runner, whichever this repo already does for Win32 calls.

**The orchestrator's safety suggestions.** The user may strike them before handing over this brief.
- **A 30 s countdown before a system action.** Before Sleep, Hibernate, Shut down or Restart, show "Shutting down in 30 s" with a *Cancel* button and run the action when it ends. This is separate from the timer, which has no warning: it exists because a mistaken shutdown can lose work in other apps.
- **The action is not remembered across a restart of Rill.** It goes back to *Do nothing*, so a shutdown chosen weeks ago does not surprise anyone. While Rill runs, the choice stays until changed.

### While it runs

- **A small moon icon with the time left** in the controls bar and in the miniplayer (decided). For the kinds without a time, the icon shows alone and its tooltip says what it waits for and the end action.
- **It survives everything that is not a decision about it:** quality switches, second-player swaps, recovery reopens, the audio-only toggle, the miniplayer and fullscreen.
- **It is never restored** by the session restore (todo 101).

### Tests

- **A duration:** fires after its time on a fake clock, whether the video is playing or paused.
- **End of chapter:** fires at the chapter's end, and moves after a seek into another chapter.
- **End of video:** pauses at the real ending, and nothing autoplays.
- **A dropped read** (`_endedShort`) does not fire *End of video*.
- **After N videos:** counts the starts as defined above.
- **The fade:**
  - the volume is restored the moment playback pauses;
  - a key press, a click and a volume change during the fade each stop it, restore the volume and turn the timer off, and nothing pauses;
  - mouse movement alone does not.
- **End actions:**
  - each one calls the fake with the right action;
  - *Do nothing* calls nothing;
  - Sleep and Hibernate are hidden when the system disallows them;
  - the countdown's *Cancel* stops the action (if the countdown is kept).

**Mutations,** each must fail a test, with the output pasted:
1. fire on `_endedShort`;
2. let autoplay advance after *End of video*;
3. skip restoring the volume on pause;
4. let input during the fade leave the timer running.

## 2. Right-click + scroll for volume (decided: it replaces Shift + scroll)

- **The gesture:** holding the right mouse button over the player and scrolling changes the volume, with the same step and feedback as Shift + scroll has today.
- **Remove Shift + scroll,** and update its doc comment to say why.
- **Track the right button yourself.** Use the player's own `Listener` (pointer down and up, `kSecondaryMouseButton`). Check whether `PointerScrollEvent.buttons` reports the button on Windows; do not rely on it unless measured.
- **Only a press that started over the player counts.** Claim the scroll through the `pointerSignalResolver` as today, so the page never scrolls under it.
- **No right-click menu exists on the player today.** Leave a comment where a future one would go: a right press that scrolled must not open it on release.
- **Every surface that had Shift + scroll gets this instead:** the watch page, fullscreen, and the miniplayer if it had it.

**Tests:**
- right button down, then scroll up, raises the volume;
- Shift + scroll no longer changes the volume;
- a plain scroll does neither (no change, no claim);
- after the button is released, a scroll no longer changes the volume.

**Mutation:** ignore the button state, and a test fails.

## 3. Hand-off to the user

On a release build:
1. **A 1-minute timer:** the moon counts down, the sound fades, it pauses, and the volume is back before you press play.
2. **The fade, interrupted:** set another 1-minute timer and press a key during the fade. The fade stops, the volume returns, playback goes on, and the timer is off.
3. **End of video** on a short video: it pauses at the end, and nothing autoplays.
4. **End of chapter** on a video with chapters, then seek into a later chapter: it pauses at that chapter's end.
5. **Custom…**:
   - a time of 0:30;
   - *After 2 videos* in a queue.
6. **End actions:**
   - *Close Rill* with a short timer;
   - *Sleep* with a short timer (cancel the countdown once, let it run once).

   Shut down and Restart only if you choose to.
7. **Surviving changes:** set a timer, then switch quality and go to the miniplayer. The timer keeps running.
8. **Right-click + scroll:**
   - hold the right button over the player and scroll: the volume changes and the page does not scroll;
   - Shift + scroll does nothing to the volume;
   - over the page, without the button, scrolling scrolls the page.

## 4. Docs

- **`architecture.md`:** a short section with the timer's rules (§1, "What each kind means", the fade and the end actions).
- **`todo.md`:** an item for anything left over. Take its number from the **"Next number" line as it is on disk at that moment**, and bump that line in the same edit.

---

## Definition of done

- The timer, the fade and the end actions work as specified, with tests and the four mutations
- Right-click + scroll has replaced Shift + scroll, with tests and the mutation
- `.\rill check` and `cd sidecar; bun run check` green, raw output pasted
- The §3 hand-off given to the user

## Out of scope

- Playback speed (the engine has no rate control) and the other placeholder rows.
- A right-click menu on the player.

## Stop conditions

- **A real ending cannot be told from a dropped read** at the point the timer needs it. Report; do not guess from the position.
- **The fade would need a second volume path** that the second player's swap does not follow. Report first.
- **A system action needs elevation or a forced flag** to work for a normal user. Report; never add a force flag.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Say plainly what you ran and what you handed to the user.
- No AI attribution in commits, issues or PRs.
- Open a PR. Whether it gets the release label is the user's call.
