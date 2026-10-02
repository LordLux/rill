# Task 32: The broken accessibility tree, and real focus order (todo 37 + 38)

**Read first:** `CLAUDE.md`, `docs/todo.md` items 37 and 38,
`architecture.md` §2.8 (including its 2026-09-18 note about `TabBarView` and
`!semantics.parentDataDirty`), and `ui/player/controls_probe.dart`, which shows
how this repo measures things that are only visible in the real app.

Two halves of the same surface: what the app exposes to assistive technology.

- **Item 37.** One release session logged 2 146 copies of
  `Failed to update ui::AXTree, error: Nodes left pending by the update: 1312`.
  The engine rejects each update, so Narrator, or anything else using UI
  Automation, reads a stale tree.
- **Item 38.** `FocusTraversalGroup` appears nowhere in `app/lib`, so Tab order
  is whatever the widget tree happens to be.

Do 37 first. A traversal group is also a semantics boundary, so 38 is easier to
judge once the tree is stable.

---

## 1. Measure the AXTree error before changing anything

The error comes from the engine's Windows accessibility bridge. **`flutter test`
cannot show it**, so it has to be measured in the real app with semantics on.

1. **Add a probe in the existing family:** `RILL_SEMANTICS_PROBE=1`, beside
   `controls_probe.dart`. It must:
   - call `SemanticsBinding.instance.ensureSemantics()` at startup;
   - drive a fixed script: feed → open a video → toggle theatre → scroll to the
     comments and expand a thread → open the queue → back to the feed;
   - wait a few seconds after each step, so the error bursts land between steps;
   - log a marker line per step.

   Unset, it costs one environment lookup, like the others.
2. **Baseline.** Run the release build with the probe three times. Count
   `Failed to update ui::AXTree` lines per step from the release log
   (`%LOCALAPPDATA%\rill\logs\`). Report the counts per step, not just the total.
3. **Find the surface responsible.** Bisect by step. Then, within the worst
   step, bisect by widget: remove or `ExcludeSemantics` one subtree at a time,
   **in the probe build only**, and re-measure. Candidates worth trying first:
   - the watch page's tab / column switch (the §2.8 `TabBarView` note);
   - the libass caption overlay, which follows the video through
     `CompositedTransformFollower`;
   - the video texture itself;
   - the comments sliver's lazy rows;
   - the hover preview's second engine.

   Search the Flutter issue tracker for the exact error text too. If it is a
   known engine bug, say which issue.

## 2. Fix it, or record it

- **If an app-side cause is found,** fix it at the source. Do not hide it by
  wrapping large subtrees in `ExcludeSemantics`, since that only trades a stale
  tree for an empty one.
- **If it is an engine bug with no app-side fix,** record it as an
  `architecture.md` finding with the issue link and the measured counts. Keep
  the probe so the next Flutter pin bump can be re-checked. Then stop the 37
  half there.

**After the fix:** the same three probe runs log **zero** AXTree errors.

## 3. Focus traversal (item 38)

1. **Groups, one per surface, in a stated order:** title bar, rail, top bar
   (search), page content (feed or watch page), queue panel, player controls.
   - Decide whether the window buttons belong in the Tab walk. Windows apps
     usually leave them out; if you do, give a reason in a comment.
   - Order *inside* a group is reading order. If the tree order does not give
     that, use `OrderedTraversalPolicy` or `FocusTraversalOrder`.
2. **Hidden things are not focusable.** The player controls overlay is
   focusable while hidden (item 38). Wrap it in `ExcludeFocus` while it is not
   shown, and check anything else that is hidden but still mounted.
3. **Overlays trap and restore focus:** the account menu, search suggestions,
   the save dialog, the share dialog, tile menus, the login page. For each one:
   focus moves into it when it opens, Tab stays inside it, Escape closes it, and
   focus returns to whatever opened it. Material menus and `showDialog` do some
   of this already. **Verify each one; do not assume.**
4. **Shortcuts and focus agree.** Space, `k` and the rest go through
   `shortcuts.dart`, which checks `textEntryHasFocus()`. With real focus groups,
   check that a focused button does not swallow a shortcut, and that a shortcut
   never fires while a text field has focus.
5. **Fullscreen and the miniplayer** change which surface should own focus.
   Entering fullscreen puts focus in the player; leaving it puts focus back
   where it was.

## 4. Labels: a cheap guard while you are here

The app has almost no explicit semantics. Add Flutter's
`labeledTapTargetGuideline` check (`expect(tester, meetsGuideline(…))`) to a
widget test of the feed and the watch page.

- **Fix what fails if it is a handful.** Most fixes are a `tooltip` or a
  `Semantics(label:)` on an icon-only control.
- **If it is dozens,** list them in a new todo item instead. This task is not a
  full accessibility audit.

## 5. Tests

- **Item 37:** the probe is the test. There is no widget test for an engine
  bridge error. Put the before and after counts in the report.
- **Item 38:** a widget test that sends Tab repeatedly through the feed and
  through the watch page, and asserts the order of
  `FocusManager.instance.primaryFocus`. Also one test per overlay: it traps
  focus, and focus is restored on close.
- **Mutations:**
  - remove one `FocusTraversalGroup`, and the order test must fail;
  - remove the `ExcludeFocus` on the hidden controls, and a test must fail;
  - make one overlay not restore focus, and its test must fail.
- **The label guideline test,** passing.

## 6. Hand-off to the user

The user checks with Narrator (Win + Ctrl + Enter), on a release build:

1. Tab through the feed and a watch page. The order matches what the report
   states, and nothing invisible gets focus.
2. Narrator reads sensible names for the main buttons.
3. Open and close each overlay with the keyboard. Focus goes in, stays in, and
   comes back.
4. Send the release log from that session. It should contain no
   `Failed to update ui::AXTree` lines.

## 7. Docs

- **todo 37 and 38.** Delete them if done; otherwise narrow them, with the
  reason.
- **`architecture.md`.** Add a finding for the AXTree cause (app-side or
  engine), with the counts.
- **`CLAUDE.md`.** If focus groups become a rule (for example, "a new surface
  gets its own `FocusTraversalGroup`"), add one line under "Notes that will bite
  otherwise".

---

## Definition of done

- AXTree errors measured per step, with the cause found and either fixed (zero
  after) or recorded as an engine bug with an issue link
- Focus groups, hidden-control exclusion, and overlay trap/restore in place,
  each tested and mutation-checked
- Label guideline test passing, or failures listed as a new todo item
- `.\rill check` and `cd sidecar; bun run check` green, raw output pasted
- §6 hand-off given to the user

## Out of scope

- A full accessibility audit: contrast, text scaling, screen-reader wording
  everywhere.
- Redesigning any surface.
- Item 57 and the other new todo items (58–82).

## Stop conditions

- **The AXTree error does not reproduce under the probe** in three runs. Report
  what the probe did, and stop before building fixes for it.
- **The only fix found is excluding a large subtree from semantics.** Report,
  and do not ship it.
- **A focus change breaks a keyboard shortcut,** or a shortcut starts firing
  while a text field has focus, and the fix is not obvious. Report.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Edit files with your editor tools only, never with scripts that rewrite source
  files. Delete any helper scripts before reporting.
- Say plainly what you ran and what you handed to the user.
