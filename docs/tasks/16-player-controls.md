# Task 16 — Player controls

**Prerequisite:** `CLAUDE.md` (hard invariants 8 and 9), `docs/architecture.md`
F13, F15, F16, `docs/protocol.md` §3.5, and the Task 14 and 15 reports.

Playback works and is barely controllable. This makes the player usable: pause,
seek, fullscreen, quality.

**Captions are out of scope** — their own task, next. Leave a gap where the CC
button goes rather than shipping a dead one.

---

## 1. Controls

An overlay on the shell player. Auto-hides after ~3 s of no pointer movement
while playing, reappears on movement, stays up while paused.

**Bottom Left cluster:** play/pause, previous, next, volume with a mute toggle and a
slider.

**Bottom Right cluster:** quality, theatre, fullscreen. Leave space for CC between
quality and theatre.

**Scrubber:** position, buffered range, duration. Dragging seeks on release,
not continuously — F15 measured a 1.2–1.3 s stall per seek, so a continuous
drag would fire dozens.

### Keyboard

| Key | Action |
| --- | --- |
| Space, K | Play/pause |
| ←, → | Seek ∓5 s |
| J, L | Seek ∓10 s |
| ↑, ↓ | Volume |
| M | Mute |
| F | Fullscreen |
| T | Theatre |
| Esc | Exit fullscreen, then theatre |
| 0–9 | Seek to that decile |
| comma, period | Seek ∓1 frame |
| Shift + comma, period | Seek ∓1 second |

Shortcuts must not fire while a text field has focus — the search box exists and
typing "f" in it must not go fullscreen.

### Pointer

Click anywhere on the video toggles play/pause. Double-click toggles fullscreen.

**These conflict**, and the naive fix — waiting ~250 ms on every click to see
whether a second follows — makes every pause feel broken. Toggle immediately on
the first click and undo it if a double arrives. Say in the code why.

### Keyboard + Mouse

| Shortcut | Action |
| --- | --- |
| Shift + scroll | Volume |

## 2. Fullscreen and theatre

Both, as YouTube has them, and they are different things.

**Theatre** — player expands to fill the app's content area horizontally. The right side recommendations slide downwards/upwards to accommodate the expanded/normal player. Chrome stays. App window unchanged. Cheap: a layout change.

**Fullscreen** — the OS window goes borderless fullscreen, all app chrome
hidden, player fills the display. Restores the previous window bounds on exit.

The player already lives above the `Navigator` (Task 14 §1), so neither should
need to move or rebuild the surface.

**Do not destroy and recreate the video output on a mode change.** Task 15
measured what that costs, and F13 pins libmpv exactly. If the texture is torn
down on either transition, that is the finding — report it rather than working
around it with a rebuild.

State is app-level, not route-level: entering fullscreen from the watch page and
navigating must not leave the app stuck fullscreen with no player.

## 3. Quality picker

`variants[]` has shipped ranked and client-chosen since Task 09 and **nothing
has ever consumed it.** Every video plays `variants[0]` — 2160p60 on a typical
VOD, which F16 measured dropping 16–29% of frames on this machine while 1080p60
dropped none.

- Menu listing available heights and fps, current one marked
- Switching preserves position and play state
- Remember the choice for the session; persisting it is a later decision
- Show the actual playing height, not the requested one

**Automatic stepping on frame drops is out of scope.** It needs a threshold over
a window, hysteresis, and a way to tell a decode limit from a momentary stall.
The picker first — it will also tell you what this machine actually does.
Just add an entry to the menu for "Auto" that is always present but for now is a no-op and disabled.

Report what a quality switch costs in wall-clock time. If it is slow enough to
feel like a stall, say so; that shapes whether the stepper is worth building.

## 4. Constraints that will bite

**Hard invariant 9.** Position, duration and buffering come from
`player.stream.*`. A scrubber polling `getProperty` at 60 Hz would stall the
frame loop for over a second on every seek — F15 measured exactly this, and the
harness that did it manufactured a false reading.

**Hover previews must keep working.** The preview engine is deliberately
separate from the shell player (Task 15). Controls belong to the shell only —
the preview keeps its mute toggle and nothing else. Suppression still holds:
nothing previews while the shell plays.

**The queue.** Previous and next drive the existing queue controller. At the
ends they disable rather than wrap — Task 14 verified the queue stops rather
than wrapping, and the buttons must agree.

---

## Tests

- Each shortcut fires its action, and none fires while a text field has focus
- Single click toggles play/pause with no delay; double-click reaches fullscreen
  and leaves play state as it started
- Scrubber drag seeks once, on release
- Shift + scroll changes volume
- Controls auto-hide while playing, stay while paused, return on movement
- Theatre and fullscreen enter and exit, and exit restores the previous window
  bounds
- Fullscreen survives a route change without stranding the app
- Quality switch preserves position and play state
- Previous/next at the queue's ends are disabled, not wrapping

**Mutation-check the auto-hide timer, the text-field focus guard, and the
single-vs-double click resolution.** All three are the shape that passes against
deleted code.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean including
  the colour-literal rule
- Space pauses, F goes fullscreen, T goes theatre, Esc unwinds both
- Scrubbing works and does not stutter
- Quality switches without losing position
- Hover previews still work and are still suppressed during playback

**Run the app and say what you saw** — including a quality switch, both modes,
and typing in the search box without triggering a shortcut.

## Out of scope

Captions. Automatic quality stepping. The watch page redesign. The Hero
transition. Any new page. Downloads.

## Stop conditions

- **A mode change tears down the video texture.** Report; do not rebuild around
  it.
- **A quality switch cannot preserve position** without a visible reload. Report
  what it costs before deciding.
- **Shortcuts cannot be scoped away from text fields** with Flutter's focus
  system as the app is structured. Report rather than special-casing widgets.
