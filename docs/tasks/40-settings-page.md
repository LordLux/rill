# Task 40: The app settings page (todo 69, and todo 16)

**Read first:**
- `CLAUDE.md`, especially the focus-group and accessibility notes.
- `docs/todo.md` items 69 and 16.
- `app/lib/ui/widgets/account_button.dart`:
  - the *Settings* entry, a placeholder today;
  - the *Home feed* panel;
  - the *Updates* panel, with "Reopen where I left off".
- `app/lib/ui/widgets/accent_debug_button.dart`, still mounted on the feed page.
- `app/lib/ui/player/settings_menu.dart`: *More options* and the caption style pages.
- Every preference that is stored today:
  - `captions_controller.dart`;
  - `update_controller.dart`;
  - `ytdlp_controller.dart`;
  - `promoted_preference.dart`;
  - `shelf_visibility.dart`;
  - `members_only_preference.dart`;
  - `audio_mode_controller.dart`;
  - `hide_queue_controller.dart`;
  - `page_wrapper.dart`;
  - `theme/accent.dart`.

**Why now.** The next task, the ultrawide zoom (Task 41), has too many options for the player's menu. Two other items are already waiting on a settings page: todo 16 (the members-only preference) and todo 84 point 3 (audio languages). Rill has no settings page: the account menu's *Settings* entry does nothing.

---

## 1. Propose before building

**Report this to the user and wait for his answer.**

1. **A table of every user-facing setting that exists today.** For each one, give:
   - where it is set now;
   - where it is stored;
   - what you propose: **move** to the page, **stay** where it is, or **both**.

   *Both* is allowed only when it is the same provider shown in two places, never two copies of the value.

   **The rule from item 69:** what belongs to the video playing now stays with the video (quality, this video's captions, audio-only for this video). What is app-wide moves (defaults, caption style, updates, feed options, the accent colour).
2. **New entries:** the members-only preference (todo 16), wired to `membersOnlyVisibleProvider` and persisted.
3. **The page's sections and their order.** For example: General, Home feed, Player, Captions, Updates. Leave a place for the later sections, *Zoom* (Task 41) and *Audio languages* (todo 84 point 3).
4. **A sketch of the layout,** in words or ASCII, using the app's existing look: the account menu's panels, the player menu's rows and the design tokens.

## 2. Build, after the user's answer

- **Opening it.** The account menu's *Settings* entry opens the page.
  - It is a page in the content navigator, like the playlist page, so Back returns to where you were.
  - The top bar and the window buttons stay visible. Remember the login page, which once hid them.
- **Adding a section later is one new file.** A later task registers a section in one place, and the page builds from that list.
- **Each setting has one provider and one stored value.** After a move, the old place shows nothing, or shows the same provider. A setting is never set in two places.
- **Persistence** with `SharedPreferences`, as now. Moved settings keep their stored keys, so nobody loses a value.
- **The accent colour picker** moves from the debug button to the page, and the debug button goes.
- **The account menu's placeholders** (theme, language, restricted mode) stay where they are, as placeholders. Do not build them.
- **Keyboard and screen readers:**
  - the page is one `FocusTraversalGroup`, in reading order;
  - every control has a label Narrator reads, with its state;
  - Escape and Back leave the page;
  - nothing on the page fires a player shortcut while a field has focus.

## 3. Tests

- **The page opens** from the account menu, and Back returns.
- **Moved settings:** each one's new control writes the same provider the app already reads, and its old control is gone, or shows the same provider.
- **Persistence:** a value set on the page survives a restart (round trip through the store).
- **The members-only switch** changes what the feeds show, and persists.
- **Narrator:** the label guideline test (`meetsGuideline(labeledTapTargetGuideline)`) passes on the page.
- **Focus:** Tab order through the page is reading order.

**Mutations,** each must fail a test, with the output pasted:
1. write a moved setting to a new key;
2. leave its old control in place with its own copy of the value;
3. drop the members-only persistence.

## 4. Hand-off to the user

On a release build:
1. Open Settings from the account menu, change one setting in each section, and go back.
2. Restart Rill: every change is still there.
3. Check that the old places no longer carry a duplicate:
   - the player menu's *More options*;
   - the account menu's panels;
   - the feed page's debug button.
4. Tab through the page with Narrator on (Narrator started after Rill): sensible names, reading order, and 0 `AXTree` lines in the log.

## 5. Docs

- **`todo.md`:**
  - delete items 69 and 16 if done, otherwise narrow them;
  - in item 84, say that point 3 now has a home.
- **`CLAUDE.md`, "Notes that will bite otherwise":** one line, "An app-wide setting lives on the settings page, registered as a section; never a second copy elsewhere."
- **Any new number** comes from the **"Next number" line as it is on disk at that moment**, bumped in the same edit.

---

## Definition of done

- The §1 table approved by the user, and the page built as approved
- Todo 16 done: the members-only preference set and persisted
- Tests and mutations in place
- `.\rill check` and `cd sidecar; bun run check` green, raw output pasted
- The §4 hand-off given to the user

## Out of scope

- The zoom settings (Task 41), audio languages (todo 84 point 3), theme switching, display language, restricted mode.
- Redesigning the account menu beyond removing what moved.

## Stop conditions

- **A setting cannot move without changing its stored key** (a type change, say). Report the migration needed before doing it.
- **The page needs the root navigator** to show at all. Report it; do not hide the window controls.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Say plainly what you ran and what you handed to the user.
- No AI attribution in commits, issues or PRs.
- Open a PR. Whether it gets the release label is the user's call.
