/**
 * Cookie redaction — the one function every outbound string passes through.
 *
 * Task 22 §5: **never log a cookie value.** Not at debug level, not truncated,
 * not in an error message, not in a probe. The sidecar logs to stderr and
 * stderr goes to the console, so a cookie in a log is a leaked session.
 *
 * "Just don't log it" is not enough on its own, and that is the whole reason
 * this file exists. The sidecar's own code never interpolates a cookie — but
 * the cookie is a request header on every authenticated call, and the failure
 * mode is a *third party* putting it in a string we then log: youtubei.js
 * raising an error that quotes the request, a `fetch` rejection that carries
 * headers, a stack frame with a captured argument. None of those are reachable
 * by reading this repo, and each one would be silent.
 *
 * So redaction happens at the two chokepoints instead of at the call sites:
 * `logger()` (stderr) and `emitError` (the RPC error envelope, which is stdout
 * and is rendered in the app). Two independent rules, because each covers the
 * other's gap:
 *
 *  - **Registered secrets.** Every cookie the process is handed is registered
 *    the moment it arrives, and matched literally. Covers a value in any shape,
 *    including a fragment of a header we never parsed.
 *  - **Cookie-shaped pairs.** `NAME=VALUE` for the auth-bearing names YouTube
 *    uses. Covers a value that never reached `registerSecret` — a cookie read
 *    off an environment we did not set, or one embedded in a response.
 *
 * Neither is sufficient alone. The registry cannot see a cookie it was never
 * given; the pattern cannot see a bare value with no `NAME=` in front of it.
 */

/** What a redacted value is replaced by. Deliberately unmistakable in a log. */
export const REDACTED = '«redacted»';

/**
 * Exact values to strike from any outbound string.
 *
 * A `Set` of raw strings rather than hashes: this never leaves the process, and
 * comparing against the real value is what makes a partially-quoted header —
 * the case a hash would miss — still match through the pattern rule below.
 */
const secrets = new Set<string>();

/**
 * Register a value that must never appear in a log or an error envelope.
 *
 * Called with every cookie the sidecar accepts, from every route it can arrive
 * on: `YT_COOKIE` at startup and `auth.setCookie` at runtime. Short strings are
 * ignored — a one- or two-character "secret" would redact ordinary prose and
 * make every log unreadable, and nothing that short is a session.
 */
export function registerSecret(value: string | undefined | null): void {
  if (typeof value !== 'string') return;
  const trimmed = value.trim();
  if (trimmed.length < 8) return;
  secrets.add(trimmed);

  // Also register the individual cookie values inside a header. A logged
  // message is far more likely to quote one pair than the whole header, and an
  // exact match on the header alone would sail straight past that.
  //
  // Group 3, not group 2. Group 2 is the cookie *name*, and registering those
  // strikes `VISITOR_INFO1_LIVE` — a diagnostic this project logs on purpose —
  // out of every line while leaving the value it was supposed to hide in place.
  // Caught by `redact.test.ts`; it is the sort of off-by-one that reads
  // correct.
  for (const [, , , cookieValue] of trimmed.matchAll(/(^|[;,\s])([^=;,\s]+)=([^;,\s]+)/g)) {
    if (cookieValue && cookieValue.length >= 8) secrets.add(cookieValue);
  }
}

/** Test seam. Nothing in `src/` calls this; the process holds secrets for life. */
export function clearSecrets(): void {
  secrets.clear();
}

/**
 * The cookie names that actually carry a session.
 *
 * A closed list rather than "anything shaped like `k=v`", because the second
 * would redact `videoId=…`, `itag=…` and every other diagnostic this project
 * logs on purpose. These are Google's auth cookies: the `SID` family, the
 * `APISID` family youtubei.js derives `SAPISIDHASH` from, YouTube's own
 * `LOGIN_INFO`, and the `__Secure-`/`__Host-` prefixed variants of all of them.
 */
const COOKIE_NAME = String.raw`(?:__Secure-|__Host-)?(?:\d+P)?(?:S?APISID|SID|HSID|SSID|SIDCC|PSIDTS|PSIDCC|LOGIN_INFO|SAPISIDHASH)`;

const COOKIE_PAIR = new RegExp(String.raw`\b(${COOKIE_NAME})=([^;,\s"']+)`, 'g');

/**
 * Strike every known secret and every cookie-shaped pair out of `text`.
 *
 * Never throws and never returns `undefined`: it sits on the error path, and a
 * redactor that can fail is a redactor that fails exactly when something has
 * already gone wrong.
 */
export function redact(text: string): string {
  let out = text;
  for (const secret of secrets) {
    if (out.includes(secret)) out = out.split(secret).join(REDACTED);
  }
  return out.replace(COOKIE_PAIR, (_match, name: string) => `${name}=${REDACTED}`);
}
