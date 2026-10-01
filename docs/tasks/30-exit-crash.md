# Task 30: The exit crash, and the plugin behind it

**Todo items:** 30 (the exit-time `0xC0000602`), and the half of 51 that
concerns the same plugin. **Read first:** `architecture.md` F27 and §2.11 (the
release log), `todo.md` items 30, 32 and 51, and `CLAUDE.md`.

The app crashes on most closes. F27 found the cause from one dump.
`flutter_inappwebview_windows` 0.6.0 holds a `Compositor` in an `inline static`
(`InAppWebViewManager::compositor_`). The static is created when the plugin
registers, which happens **on every launch**, even though the WebView is only
ever used for sign-in. It is released by a static destructor at DLL unload,
when CoreMessaging can no longer serve it, and the process fails fast.

Nothing is lost, because the app has already shut down. But every release
user collects crash events, and on this machine each crash also writes a
**full dump containing the session cookie** (item 32: the `LocalDumps` key is
kept deliberately). The same plugin is one of the two that do not build on
Visual Studio 2026 (item 51).

---

## 1. Baseline: measure before changing anything

The rate today is anecdotal: 2 of 2 window closes, 5 of 5 probe exits, and four
Application-log events. A fix needs a number to beat.

- Build release (`.\rill build`). Script **20 launch-and-close cycles** in
  PowerShell. For each cycle:
  1. Start the release exe.
  2. Wait until the app's window exists, plus about 10 s.
  3. Close it the way a user does: `CloseMainWindow()` on the `rill` process
     that has a main window (WM_CLOSE). Not `exit(0)` and not `Stop-Process`,
     because those are different exit paths.
  4. Wait for both processes to exit.
  5. Record the exit code from that run's release log
     (`%LOCALAPPDATA%\rill\logs\rill-*.log`; the launcher's last line reads
     `CRASHED with code 0xC0000602` on a crash).
- **Dumps.** Each crash writes a full dump to `%LOCALAPPDATA%\CrashDumps`, and
  it holds the cookie.
  - Delete every `rill.exe.*.dmp` the runs create, immediately.
  - The one exception: if `cdb.exe` (Debugging Tools for Windows) is
    installed, read the stack of **two** fresh dumps first and confirm they
    fault in the same place F27 names. This settles item 30's open question of
    whether the other crashes are the same one. Report frame names only.
  - Never copy, attach or paste dump memory.
- Report: the 20 exit codes, the crash rate, and the two stacks if read.

## 2. Pick the fix

Three candidates, in order of preference. Read the source; do not guess from
changelogs.

**A. Upgrade the plugin.** `flutter_inappwebview_windows` has
`0.7.0-beta.3` (published 2026-02-04). Stable is still 0.6.0. In its source,
check two things:
1. Is the compositor still a static destroyed at DLL unload, or is it now
   released at plugin teardown?
2. Does it still compile with `/await` and `<experimental/coroutine>` (item
   51), or has it moved to C++20 `<coroutine>`?

Take A only if all three of these hold:
- it fixes (1);
- it is a drop-in: an override of the Windows implementation alone, with no
  change to `flutter_inappwebview` itself and none to our Dart code
  (`login_page.dart`, `web_session_cookies.dart`, `auth_probe.dart`);
- it builds.

**B. Vendor 0.6.0 and patch it.** There is precedent: `third_party/media_kit_video`
(F28). Release the compositor at plugin or manager teardown, while the
engine is still alive. Patch only that. If B is taken:
- Add the vendoring comment in `pubspec.yaml`, matching the media_kit one.
- Add the licence entry in `THIRD_PARTY_LICENSES` (Apache-2.0).
- Draft an upstream issue in the same shape as
  `third_party/media_kit_video.upstream-issue.md`.

**C. `TerminateProcess` after engine shutdown** in `runner/main.cpp`. This
skips every DLL's exit cleanup, not just the plugin's. Do **not** take C
without asking. If A and B both fail, stop and report why.

## 3. Verify

1. **The same 20-cycle script, after the fix: zero `0xC0000602`.** Report every
   exit code, not just the count. Delete any dumps exactly as in §1.
2. **Sign-in still works.** You cannot do this one yourself: it needs the
   user's Google account. When you get here, stop and hand the user this check:
   - sign in through the login page;
   - confirm the account shows and the home feed is personalised
     (`auth.verify` tiles > 0);
   - sign out;
   - sign in again.

   State in the report that this was handed off, not done.
3. `.\rill check` and `cd sidecar; bun run check`, run one at a time, raw
   output.

## 4. Item 51, the part that touches this

- **`flutter_inappwebview_windows`.** Say whether the chosen fix also removes
  its `/await` dependency. If A was taken and it does, verify with a
  Visual Studio 2026 build if this machine has one (generator
  `Visual Studio 18 2026`). Otherwise say it is unverified.
- **`flutter_media_session`.** Item 51 says to check first whether it is ours.
  Answer that from pub.dev (publisher, repository), and whether a published
  version drops `/await`. Fix it only if that is a plain version bump.
  Otherwise record the finding in item 51 and stop there.

## 5. Docs

- **F27.** Add the fix and both measurements (before and after, n = 20). Keep
  the finding's history; rewrite rather than delete.
- **todo 30.** Delete it if §3.1 passed.
- **todo 51.** Update it with what §4 found.
- **todo 32.** Leave it. The dump policy is unchanged, but add one sentence:
  exits no longer produce dumps.
- **Three stale spots in `todo.md`, unrelated to this task, found in review:**
  - Item 42 still opens with "Blocked on real nesting" although its own update
    says the depth landed. Its list now starts at "2.". Rewrite the
    paragraph to say what is left: the drawing.
  - Item 12 refers to "the two-renderer setting (item 13)". There is no such
    setting any more (`architecture.md` §2.9: LibassLayer on the main player,
    mpv on previews), and item 13 is about drag. Rewrite that sentence.
  - The "Documentation backlog" heading at the end is empty. Remove it.

---

## Definition of done

- Baseline and after-fix measurements reported, n = 20 each, with zero
  `0xC0000602` after the fix
- Fix A or B in place; C only with approval
- Sign-in check handed to the user, with exact steps
- `.\rill check` and `bun run check` green, raw output pasted
- No dump left on disk from these runs
- F27, todo 30, 51 and 32 updated, and the three stale spots fixed

## Out of scope

- Crashpad (the rest of item 32).
- Any other plugin upgrade.
- The release workflow's `windows-2022` pin. GitHub has announced no
  retirement date for that image yet, so it stays.

## Stop conditions

- **The baseline shows fewer than 5 crashes in 20.** A fix cannot be shown at
  that rate. Report, and stop before changing anything.
- **A needs anything beyond overriding the Windows implementation.** Go to B;
  do not move `flutter_inappwebview` to a beta.
- **B's patch turns out to need more than releasing the compositor earlier.**
  Report what else it needs and stop.
- **Neither A nor B works.** Stop. C is a decision for the user, not for you.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Say plainly which checks you ran and which you handed to the user.
