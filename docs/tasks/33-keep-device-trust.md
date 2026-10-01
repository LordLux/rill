# Task 33: Sign-out without making Google forget the device (todo 57)

**Read first:** `CLAUDE.md` (hard invariant 5, and everything about cookies and
logging), `docs/todo.md` item 57, `ui/auth_controller.dart` (`signOut`), and
`data/auth/web_session_cookies.dart` and `data/auth/youtube_cookies.dart`.

**The problem.** After a sign-out, the next sign-in asks for 2-step verification
again, even when "Don't ask again on this device" was ticked minutes earlier.

**The cause** is by design. `signOut` ends with
`CookieManager.instance().deleteAllCookies()`
(`web_session_cookies.dart`, `clear()`), which wipes the whole WebView2 jar.
That includes Google's trusted-device mark, so every sign-in after a sign-out
looks like a new device.

**The full wipe exists for a reason**, and the reason must survive: "leaving it
means the next sign-in shows no account picker and silently reuses this
account" (`auth_controller.dart`).

**The goal:** sign-out removes every cookie that signs anyone in, and keeps the
cookies that only describe the device.

**Cookies are credentials.** Log cookie *names* and *domains* only, never values,
anywhere: logs, reports, tests, fixtures. `describe(jar)` already follows this
rule. Every log line you add must follow it too.

---

## 1. Measure; do not guess the names

You cannot sign in with Google, so this section is a script you build and the
user runs.

1. **Add a names-only dump.** Through the same DevTools-protocol access
   `web_session_cookies.dart` already uses, list every cookie in the WebView2
   jar as `name @ domain (session|persistent, httpOnly, secure)`.
   - Use `Network.getAllCookies` if it is available, so that `google.com`,
     `accounts.google.com` and `youtube.com` all appear.
   - Gate it behind an environment variable, like the other probes, and write
     it to the release log.
2. **The user runs four dumps:**
   - **A:** right after a sign-out (today's full wipe);
   - **B:** after signing in **without** ticking "Don't ask again";
   - **C:** after signing out and signing in again, ticking it this time;
   - **D:** after one more sign-out.
3. **From the diffs, name:**
   - **The session set:** every cookie whose presence keeps someone signed in.
     That means everything `hasSessionCookies` and `cookieHeader` read, plus
     Google's login cookies on `accounts.google.com`.
   - **The device-trust cookie(s):** what C has that B does not.
   - **Everything else.**

**Report the three lists, names and domains only.**

## 2. Change sign-out

Replace `deleteAllCookies()` with deleting the session set from §1. The list is
explicit, by name *and* domain, and comes from the measurement. Keep the
device-trust cookies, and keep anything that is neither.

**Then the deciding check, which the user runs.** It goes in the §4 hand-off:

1. Sign in, ticking "Don't ask again".
2. Sign out.
3. Sign in again with the same account.

**It must ask for the account and the password**, an account chooser is fine,
**and skip the second step.** A sign-in that needs no password at all means a
login cookie survived. That is a failure: put the cookie in the session set and
re-check.

## 3. Tests

- **The deletion list covers the reader.** Every cookie name that
  `hasSessionCookies` or `cookieHeader` depends on is in the session set.
  **Mutation:** drop one name from the set, and the test fails.
- **Sign-out deletes the set and only the set.** Use a fake cookie store: after
  `signOut`, no session cookie remains, and a non-session cookie (the
  device-trust one) does.
- **The other three stores are still cleared:** credential store, sidecar
  session, cached feed. Task 22 §5's ordering stays as it is.

## 4. Hand-off to the user

1. Run the four dumps from §1 (instructions with the exact environment variable)
   and send back the names-only output.
2. After the change: the §2 check, done twice.
3. One more dump right after a sign-out. It must show **no** cookie from the
   session set.

## 5. Docs

- **todo 57.** Delete it if §2's check passes; otherwise narrow it, with what
  was learned.
- **`architecture.md`.** Add a finding: which cookie carries Google's device
  trust, which cookies make up the session, and the decision to keep the first
  on sign-out. Names only.
- **The `signOut` comment** in `auth_controller.dart`. Rewrite it rather than
  delete it: the reason for the old full wipe stays, plus why the new partial
  wipe still meets it.

---

## Definition of done

- The three cookie lists from the user's dumps, in the report, names and domains
  only
- Sign-out deletes exactly the session set; tests and mutation in place
- The user's check passes: password required, second step skipped, no session
  cookie left after sign-out
- `.\rill check` and `cd sidecar; bun run check` green, raw output pasted
- No cookie value anywhere in the diff, the logs or the report

## Out of scope

- A "forget this device" option. If the user wants one, it goes into the
  settings page (item 69).
- Switch account (item 75).
- Anything in the sidecar.

## Stop conditions

- **A device-trust cookie is also needed for being signed in,** or the two
  cannot be told apart from the dumps. Report it, and keep the full wipe.
- **Keeping any cookie lets a sign-in skip the password.** Revert to the full
  wipe and report.
- **The DevTools protocol cannot list all domains' cookies.** Report what it
  can list before working around it.

## Report rules

- Raw command output, never summarised, except cookie values, which never
  appear at all.
- Every file:line you cite must be one you opened in this session.
- Edit files with your editor tools only, never with scripts that rewrite source
  files. Delete any helper scripts before reporting.
