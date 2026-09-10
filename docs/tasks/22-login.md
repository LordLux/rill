# Task 22 — Login

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.1, `docs/architecture.md`
§2.5, and F7.

The last piece where the app is not yet the user's own. `feed.subscriptions` and
`subscriptions.channels` both shipped and are both anonymous-empty; history and
watch later wait behind the same thing.

**This task handles credentials.** Read §5 before writing any code — the failure
modes here are worse than a broken feature.

---

## 1. What already exists

- `auth.setCookie`, `auth.verify`, `auth.status`, `auth.signOut` are specified in
  `protocol.md` §3.1. Some are implemented; check which.
- The sidecar accepts a cookie today via `YT_COOKIE` — that is the development
  path and stays working.
- `auth.verify` has reported `authenticated | degraded | anonymous` since the
  first spike. **Nothing has ever rendered `degraded`.**
- `isAnonymous` drives the feed's "browsing anonymously" state, with a Log In
  button that currently shows a snackbar.

## 2. Why cookies, and why a WebView

Established at the spike and unchanged: OAuth device-code no longer works
against YouTube, and a `TV`-context session does not return the web chip bar. So
cookies are the only path, and a cookie means a real Google login page.

**WebView2 for the login flow only.** It renders no app UI, and it exists solely
so Google's login — including 2FA, passkeys and whatever Google adds next —
happens in a real browser engine rather than something we reimplement.

Confirm early that WebView2 is reachable from Flutter Windows and can hand back
cookies for `.youtube.com` and `.google.com`. If the available package cannot
read cookies out of the session, that is a **stop condition** — the whole task
depends on it.

## 3. F7 is the constraint that shapes the UI

A degraded session returns **HTTP 200 with an empty feed and no error**. The
client's `logged_in` flag reflects cookie presence, not server acceptance. That
is why `auth.verify` fetches the home feed and counts tiles.

So:

- Run `auth.verify` on startup and after any empty feed
- `degraded` shows a re-authentication prompt, never an empty feed
- `anonymous` shows the existing state, with a Log In button that now works
- **Never report signed-in from cookie presence alone**

The distinction between `degraded` and `anonymous` matters to the user: one
means "your session expired, sign in again", the other means "you were never
signed in". They are different messages.

## 4. Cookie lifetime

Cookies rotate. F7 records a session degrading mid-work because a browser tab
touched the same account.

The WebView flow avoids that — the app owns its session and nothing else touches
it — but re-login will still be needed periodically. Handle it as an ordinary
state, not an error: detect, prompt, restore, and **do not lose the user's place**
in whatever they were doing.

Report what you learn about lifetime if anything is measurable. Do not guess a
TTL.

## 5. Credential handling — read before coding

**Store cookies in the OS credential store**, not `SharedPreferences`, not a
file, not the repo. `flutter_secure_storage` maps to DPAPI on Windows. If you
use something else, say what and why.

**Never log a cookie value.** Not at debug level, not truncated, not in an error
message, not in a probe. The sidecar logs to stderr and stderr goes to the
console — a cookie in a log is a leaked session. Grep your own output before
reporting.

**Never write a cookie to disk outside the credential store.** No temp file, no
fixture, no capture. `auth.txt` was deleted once already for this reason and
`.gitignore` still covers it — do not reintroduce the pattern under a new name.

**Sign-out must actually clear** — credential store, sidecar session, WebView2's
own cookie jar, and any cached feed. A sign-out that leaves the WebView logged in
means the next sign-in silently reuses the old account.

**Test with a throwaway account if you can.** If you cannot, be correspondingly
careful; a mistake here costs a real session.

## 6. The flow

1. Log In opens a WebView2 window at Google's YouTube sign-in
2. User signs in — including 2FA, passkeys, whatever
3. Detect completion by the presence of the session cookies, not by URL
   matching. Report what you keyed on.
4. Extract cookies for `.youtube.com` and `.google.com`
5. `auth.setCookie` to the sidecar; sidecar creates the browse session
6. `auth.verify` confirms — **tiles greater than zero**, not a 200
7. Persist to the credential store; close the WebView
8. Refresh whatever surface the user was on

On restart: restore from the credential store, `auth.verify`, and land in
`authenticated`, `degraded` or `anonymous` accordingly.

**Cancellation at any point leaves the app exactly as it was.**

## 7. The account surface

Minimal. The full settings page is a later task.

- Avatar and display name in the top bar when signed in — where the placeholder
  person icon sits now
- A menu with the account name and Sign Out
- The anonymous state keeps the person icon and offers Log In

Where the name and avatar come from is a question: `auth.verify` returns
`{state, tileCount}` today. Extending it, or adding `auth.status`, is a protocol
decision — propose it.

## 8. What must not regress

- `YT_COOKIE` still works for development, and takes precedence or does not —
  say which, and make it deliberate
- Anonymous browsing still works completely: feed, search, playback, captions
- The sidecar's two-client model is untouched — browse is `WEB` with cookies,
  stream resolution stays anonymous `VISIONOS` (F11). **Do not send cookies on
  the resolution path.**
- `playback.report` lands in real watch history once signed in — that is the
  point of being signed in, and it has been verified working before

---

## Tests

- `auth.setCookie` with a valid cookie yields `authenticated` and tiles > 0
- A degraded cookie yields `degraded`, not `anonymous` and not an error
- No cookie yields `anonymous`
- Sign-out clears the credential store, the sidecar session and the WebView jar,
  and a subsequent `auth.verify` returns `anonymous`
- Restart with a stored cookie restores the session without a WebView
- Cancelling the login flow leaves state unchanged
- **No cookie value appears in any log at any level** — assert this, do not
  eyeball it
- Anonymous playback and captions still work

**Mutation-check the degraded path and the sign-out clear.** A test asserting
"sign-out sets state to anonymous" passes while leaving cookies on disk. Assert
the store is empty, not that the flag flipped.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- Sign in with a real account; the home feed becomes personalised
- Subscriptions and the channel list populate
- Restart stays signed in
- Sign out returns to anonymous, and signing in again offers the account picker
  rather than reusing the old session
- **A watch lands in real YouTube history** — check youtube.com

**Run the app and say what you saw**, including sign-out then sign-in-as-someone-
else if you have a second account.

## Out of scope

The settings page. History, watch later and playlist pages. Multiple accounts.
The custom title bar.

## Stop conditions

- **WebView2 cannot return cookies** from the login session with the packages
  available. Report what you tried; the task depends on it.
- **Sign-out cannot clear the WebView2 cookie jar.** Report — the alternative is
  a disposable WebView profile per login, which is a design change.
- **A cookie appears anywhere it should not** — a log, a file, a fixture. Stop,
  say where, and confirm it never reached git.
