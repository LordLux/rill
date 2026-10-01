# Task 31: Sign-in and sign-out rough edges (todo 56)

**Read first:** `CLAUDE.md` (hard invariant 5, and the comment DTO's vote-param
note), `docs/todo.md` item 56, `architecture.md` F7 and F33, and
`ui/auth_controller.dart` from top to bottom.

The user found these five by hand on 2026-10-01 while checking Task 30's
sign-in. None of them has been reproduced or read in code yet. Read the code
for each one before you change it; for points 1 and 3, also take the
measurement the section asks for.

**You cannot sign in with Google yourself.** Every check that needs a real
sign-in goes into the hand-off list in §6. Write that list as you go, and say
plainly which checks you ran and which you handed off.

---

## 1. The first sign-in lands on "YouTube returned an empty feed" (56.1)

`login_page.dart` `_checkCookies` reads the WebView2 jar on a 2 s poll. As soon
as `hasSessionCookies` passes, it calls `authProvider.notifier.signIn`, which
runs `auth.setCookie`, which counts home tiles. A `degraded` answer ends the
flow with that message.

The user saw this twice in a row. **Try again** then succeeded without a second
Google login, so Google's session was fine. There are two candidate causes, and
they need different fixes:

- **(a) The jar was incomplete.** The check fires mid-redirect, when Google's
  cookies exist but YouTube's are not set yet.
- **(b) The jar was complete but checked too early,** before YouTube honoured
  the session.

**Do both of these, so that the user's next sign-in both fixes the bug and
tells us which cause it was:**

1. **Make the cause visible in the log.** Log cookie *names* only, never values
   (`describe(jar)` already does this for the not-ready case), plus the time
   since the poll started. Log at every `signIn` attempt.
2. **Handle `degraded` from the first attempt.** Do not end the flow. Wait,
   re-read the jar (a fresh read, not the same header), and call `signIn` again.
   - Make it at most **two** extra attempts, with a short backoff.
   - Only after those does the existing degraded message appear. The comment in
     the `degraded` case explains why retrying forever is wrong; keep that
     reasoning, and bound the retries.
   - Every attempt is still a real `auth.setCookie`. Never treat cookie
     presence as success (invariant 5). The cookie is still stored only on
     `authenticated`.
   - The user sees "Checking with YouTube…" throughout.

**Test:** a fake auth controller that answers `degraded` then
`authenticated` must close the page with `true` and never show the message.
One that answers `degraded` three times must show it. **Mutation:** remove the
retry, and the first case must fail.

## 2. Sign-out leaves the page showing the old account's state (56.3)

**The cause is already visible in the code:**

- `AccountActions` (`account_actions.dart`) drops its entries when the identity
  changes. It then falls back to "what the server said", which is
  `VideoDetail.isSubscribed` / `myRating` from the `/next` fetched **while
  signed in**. Nothing re-fetches the open video on sign-out.
- `authRefreshProvider` is bumped on sign-in and on sign-out, but only
  `feed_controller.dart` watches it.
- `SubscribeButton`'s *subscribed* branch (the `MenuAnchor`'s
  `FilledButton.tonal`) never checks `blocked`. Only the *subscribe* branch
  does. So a degraded session can still open the
  all / personalised / none / unsubscribe menu.

**Requirements:**

1. **While not authenticated, account-derived state reads as none,
   immediately:** not subscribed, no rating. An anonymous viewer has neither,
   so no fetch is needed to know it.
2. **On every identity change (sign-in, sign-out, a different account),
   re-fetch the open video's `VideoDetail`.** Otherwise signing in on an open
   page shows *Subscribe* for a channel that account already follows. Find the
   seam; `authRefreshProvider` probably is it. The re-fetch must not reopen
   playback or move the scroll position.
3. **The subscribed branch respects `blocked`,** like the other branch does.
4. Check the watch page's other account-derived state (the rating, and Watch
   Later if it shows a saved state) against the same two rules.

**Tests:**

- Signed in and subscribed, then sign out: the button reads *Subscribe*, is
  disabled, and has the "Sign in to subscribe" tooltip.
- The same for a liked video: the rating shows as none.
- Degraded and subscribed: the menu cannot be opened.

**Mutations:** drop requirement 1's mask, and drop the `blocked` check from the
subscribed branch. Each must fail a test.

## 3. Comments loaded while signed out ignore votes after sign-in (56.5)

The user says "the buttons respond but nothing happens". Replies expanded and
pages loaded *after* sign-in work, so what is stale is the rows that were
already there. `_rate` (`comments_section.dart`) has three ways to do nothing,
and they mean different things:

- **(a)** The params for that transition are null, so it returns silently.
- **(b)** The RPC fails, so the vote is reverted and a snackbar shows.
- **(c)** The RPC succeeds, but YouTube does not record the vote.

**Find out which one it is.** If `YT_COOKIE` is set to the burner account, use
a sidecar probe:
1. Fetch a comment page anonymously.
2. Call `action.rateComment` with those params in the signed-in session.
3. Re-fetch signed in and read `myRating`.
4. Undo the vote.

Without the cookie, reason from the code and say that you did. **If it is
(c), that is a finding in its own right:** a success that did not land.
Record it as F51 in `architecture.md`.

**The fix, whichever it is:** on identity change, re-fetch the comments from
the first page, through the path a re-sort already uses (`$cancel` plus the
generation guard).
- Thread state (expansions, loaded replies) is dropped. That is correct: it
  belonged to the other identity.
- This also clears the old account's vote state from the rows after sign-out,
  which is the same bug in the other direction.

**Test:** an identity change triggers a fresh first-page fetch, and the old
rows are gone. **Mutation:** remove the trigger, and the test must fail.

## 4. Blocked actions look enabled (56.4)

Signed out, the watch page's like, dislike, save and Watch Later get
`onTap: null` and a "Sign in to …" tooltip. They keep their full colour,
though. The subscribe button already greys out
(`disabledBackgroundColor … alpha 0.38`).

- **Find every account-only action in the app,** not only the watch page:
  tile menus, the hover overlay's Watch Later, the save dialog, the comment
  composer and the comment vote buttons. List each one with its signed-out
  behaviour today.
- **Make them consistent:** disabled, greyed out (Material's 0.38 disabled
  alpha, as the subscribe button uses), and the same `signedInActionBlocker`
  tooltip.
- An action that is *enabled* while signed out and only fails after the call
  (a toast saying "Sign in to …") counts as a bug here too. Gate it up front.

**Test:** for the watch page's four, signed out: the action is disabled and its
foreground is the disabled colour. Signed in: neither is true.

## 5. The login page has no window buttons (56.2)

`showLoginFlow` pushes `LoginPage` on the **root** navigator as a
`fullscreenDialog`. That covers the top bar, which is where the window controls
live (`topbar.dart`, through `windowControlsProvider`). So the login page, and
its error state, has no minimise, maximise or close, and no drag region.

- Give the login page the same controls and drag region, through
  `windowControlsProvider`. In tests that is `NoWindowControls`, and a test can
  override it with a fake. **Reuse what the top bar renders; do not build a
  second set.** The user is working on the titlebar, so keep this change
  small and in one place.
- **Find every other route or dialog that covers the top bar** (pushes with
  `rootNavigator: true`, full-screen dialogs) and list them. Fix the ones that
  hide the controls, the same way.

**Test:** with a fake `WindowControls`, the login page renders its buttons, in
both the normal and the error state.

## 6. Hand-off and verification

Run `.\rill check` and `cd sidecar; bun run check`, one at a time, and paste
the raw output.

**Then hand the user this list,** adjusted to what you built. Mark each item as
run by you or handed off:

1. **Sign out, then sign in fresh.** It should land signed in without the
   empty-feed message. Send back the new `rill auth:` log lines (cookie names
   only) from `%LOCALAPPDATA%\rill\logs\`. Do this twice.
2. **Sign-out.** Open a video from a channel you are subscribed to, and that
   you have liked. Sign out. The button should read *Subscribe*, greyed out,
   and the like should show as none, without reloading the page. Sign back in:
   *Subscribed* and the like should come back.
3. **Comment votes.** Signed out, open a video with comments. Sign in. Like a
   comment that was already on screen, then reload the page and check that the
   like stuck. Undo it.
4. **Greyed-out actions.** Signed out, every account-only action looks
   disabled and shows a "Sign in to …" tooltip on hover.
5. **Window buttons.** The login page and its error state both have working
   minimise, maximise, close and drag.

## 7. Docs

- **todo 56.** Delete it if all five landed and the user's checks pass.
  Otherwise narrow it to what is left, with the reason.
- **`architecture.md`:**
  - F51 if §3 found case (c).
  - A finding for §1 once the user's log says (a) or (b). Until then, add a
    dated note in todo 56 saying the cause is unconfirmed.
- **`CLAUDE.md`.** If the identity-change re-fetch becomes a pattern (§2, §3),
  add one line under "Notes that will bite otherwise": account-derived state
  must be re-read on identity change, not taken from a cached response.

---

## Definition of done

- All five points addressed, each with its test and mutation check
- §1's diagnostic logging in place (names only), with bounded retries
- §3's case (a), (b) or (c) identified, or the reason it could not be
- `.\rill check` and `bun run check` green, raw output pasted
- The §6 hand-off list given to the user
- Docs updated as in §7

## Out of scope

- Redesigning the login page, or touching the titlebar beyond adding its
  existing controls.
- Comments item 39 and nesting item 42.
- Anything in the sidecar's auth beyond a measurement probe.

## Stop conditions

- **§1's retry would need more than two extra attempts to work** in your
  reasoning, or would mean storing the cookie before `authenticated`. Report;
  do not loosen either rule.
- **§2's re-fetch reopens playback, reloads the player, or loses the scroll
  position.** Report what triggers it before working around it.
- **§3 finds the vote params are tied to the session that fetched them in a
  way a re-fetch does not fix.** Report it.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Edit files with your editor tools only. Never use scripts that rewrite source
  files. Delete any helper you create before reporting.
