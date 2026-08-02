# Task 04 — Player revision safety + the yt-dlp pipe deadlock

**Prerequisite:** `CLAUDE.md`, `docs/architecture.md` (hard invariant 2, F5, N2),
and the Task 02 report.

Two defects found while running spike 03. Neither was touched there — that spike
was scoped to `spiking/` and explicitly forbidden from modifying `sidecar/src/`.
Both are recorded here with the diagnosis intact so this task starts from
evidence rather than a re-derivation.

They are unrelated to each other except in origin. The first is the dangerous one.

---

## 1. The player response and the deciphering script can come from different revisions

### What happens

`openPlayback` fetches the `/player` response once for the whole ladder:

```ts
// resolve.ts
response = await getPlayerResponse(deps.session, videoId, 'MWEB');
```

`playerPayload` builds that request's `signatureTimestamp` by reading
`session.innertube.session.player` at call time — call that revision **P_old**.

Each tier then resolves its own deciphering player:

```ts
// tierMwebAdaptive
const player = await getPlayer(deps.session);
```

Past `PLAYER_TTL_MS`, `getPlayer` checks `/iframe_api`, and if YouTube has rolled
a new revision it rebuilds and installs it on the session:

```ts
// player.ts, in build()
session.innertube.session.player = source;   // now P_new
```

The response in hand was minted against **P_old**. Its `s` and `n` values are
P_old's cipher output. They are now deciphered with **P_new**'s script.

### Why it matters more than it looks

The failure is silent, and it is the exact failure hard invariant 2 exists to
prevent:

- a wrong `s` produces a URL that 403s — loud, findable
- a wrong `n` produces a **plausible-looking string that throttles to ~50 KB/s**,
  which reaches the user as buffering and reaches us as a bug report about their
  internet

`player.ts` already documents this hazard and guards the *opposite* ordering —
`build()` installs the new player on the session precisely so a later
`signatureTimestamp` cannot describe a different script than the one we decipher
with. The direction where the response was already fetched is unguarded.

### The window is wider than one call

`getPlayerResponse` caches for five minutes and keys on client and video only:

```ts
// player-response.ts
function keyFor(videoId: string, client: PlayerClient): string {
  return `${client}:${videoId}`;
}
```

So a response minted under P_old can be served from cache and deciphered under
P_new up to five minutes later. Reordering the calls alone does not close this.

### What to build

Make the response and the script travel together, rather than each being
resolved independently from a session that can change underneath them.

- Resolve the player **first**, and thread that one handle through the ladder
  instead of having each tier call `getPlayer` again.
- Take `signatureTimestamp` for the payload from that handle, not from a fresh
  read of `session.innertube.session.player`.
- Include `playerId` in the response cache key, so a cached response can never
  be paired with a different revision's script.

If a mismatch is still reachable by some path, it must **fail loudly** rather
than decipher — a thrown error costs one video, a wrong `n` costs a silent
throttle nobody attributes correctly.

### Tests

- Offline: a response minted under player A, with `getPlayer` then returning
  player B, must not produce a deciphered URL from B's transforms. Assert the
  behaviour chosen above (re-fetch, or throw) — not merely that something happens.
- Offline: two entries for the same video and client under different `playerId`s
  are distinct cache entries.
- The existing network throughput test still passes: > 1.5 MB/s, which remains
  the only observation that proves the transform landed at all.

### Note

This is invisible to the current suite, and for the same reason Task 02's mpv
failure was: it needs a player rollout to coincide with a TTL expiry, and its
symptom is throughput rather than an error. Do not treat a green suite as
evidence the ordering is safe.

---

## 2. `tierYtDlp` can deadlock on the stderr pipe

### What happens

```ts
// resolve.ts
const child = Bun.spawn([binary, ...args], { stdout: 'pipe', stderr: 'pipe', timeout: ... });
stdout = await new Response(child.stdout).text();
const exitCode = await child.exited;
if (exitCode !== 0) {
  const stderr = (await new Response(child.stderr).text())...
}
```

stdout is drained to completion while nothing reads stderr. A child that writes
more than the OS pipe buffer (~64 KB) blocks on `write`, so it never finishes
stdout and never exits.

### Severity

Bounded, not fatal. Two things cap it: `--no-warnings` is passed, which removes
the ordinary source of stderr volume, and `timeout: YT_DLP_TIMEOUT_MS` is set. So
the symptom is **tier 3 burning its entire timeout before declining** rather than
hanging forever — a slow path to the right answer on exactly the videos tier 3
exists to serve, which are the ones most likely to be noisy on stderr.

### What to build

Drain both pipes concurrently:

```ts
const [stdoutText, stderrText] = await Promise.all([
  new Response(child.stdout).text(),
  new Response(child.stderr).text(),
]);
const exitCode = await child.exited;
```

### Test

A stub binary that writes well over 64 KB to stderr and then valid JSON to
stdout must resolve normally and promptly. Asserting only that stderr appears in
the error message does not exercise the deadlock — the buffer has to be
overflowed for the test to mean anything.

---

## Out of scope

The playback-client decision (spike 03's recommendation), the resolution
ladder's tier ordering, media_kit's libmpv pin, and anything in `spiking/`.
