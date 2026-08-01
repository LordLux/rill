# Task 01 — Fixture capture + renderer parser

**Prerequisite:** read `docs/architecture.md`, `docs/protocol.md`, and
`CLAUDE.md` first.

**No UI in this task. No RPC transport. No Flutter.** This builds the one
component everything else depends on, in isolation, where it can be tested
offline against real data.

---

## Why this first

The parser is the highest-risk component in the project. YouTube ships two
renderer generations simultaneously and mutates them via A/B tests. If the
parser is wrong, every screen is wrong, and the failure is silent — items just
go missing. It is also the only component that can be tested exhaustively
without a network, which makes it the right thing to nail before anything is
built on top of it.

---

## Deliverables

### 1. `sidecar/src/innertube/session.ts`

Session creation with cookie auth via youtubei.js.

- `createSession(cookie: string): Promise<Session>`
- `execute(endpoint, params)` — always `parse: false`, always returns raw JSON
- `verifyAuth(session)` → `{ state: 'authenticated' | 'degraded' | 'anonymous', tileCount: number }`

`verifyAuth` fetches the home feed and counts video tiles in the raw response.
Zero tiles with cookies present means `degraded`. Do not use youtubei.js's
`logged_in`.

### 2. `sidecar/src/capture.ts`

CLI that captures raw fixtures. `bun run capture`.

- Clears the fixture directory first — never mix runs
- Captures: home feed, home continuation, subscriptions, history, a search, a
  playlist, a Mix (`RD*`), a watch page, and `player` responses for `MWEB` and
  `WEB`
- Writes raw unparsed JSON, one file per capture, plus a `manifest.json`
  recording timestamp and which endpoint produced each file
- Requires `YT_COOKIE`; fails loudly if `verifyAuth` returns `degraded`

Reference: `spike.mjs` in the repo root already does auth, the `node:vm`
interpreter shim, and `parse: false` execution correctly. Reuse that, don't
rediscover it.

### 3. `sidecar/src/parser/`

The tolerant renderer walker.

- `parseFeed(raw): { chips: Chip[], items: FeedItem[], continuation: string | null }`
- `parseVideoDetail(raw): VideoDetail`
- `parsePlayer(raw): { formats, storyboards, cpn }`

Requirements:

- Walks the raw tree; recognises known renderers; **silently skips unknown
  ones**. Never throws on an unrecognised node.
- Handles both generations (see the vocabulary table in `CLAUDE.md`).
- Emits only the flat DTOs defined in `CLAUDE.md`. No renderer fragments, no
  `undefined`, no omitted fields.
- Missing optional field → `null`, item still ships.
- Strips Shorts.
- Logs unknown renderer types once per type per run, to **stderr**, with a
  count. This log is how we find out YouTube changed something.

### 4. `sidecar/test/parser.test.ts`

Tests run offline against `fixtures/`. No network in tests.

Must cover:

- Home feed yields > 0 items and > 0 chips
- Both `videoRenderer` and `lockupViewModel` produce identical `VideoItem`
  shapes
- Mix tiles parse as `kind: 'mix'` with an `RD*` id
- Continuation token extracted from both `continuationItemRenderer` and
  `ContinuationItem`
- Shorts are absent from output
- **An injected unknown renderer type does not throw and does not drop sibling
  items** — this is the single most important test in the suite
- Every emitted item validates against the DTO shape (no `undefined`, `kind`
  always present)

---

## Definition of done

- `bun test` passes with no network access
- `bun run capture` produces a fresh fixture set from a live session
- Parser handles a fixture with an unknown renderer injected into the middle of
  the item list without losing the surrounding items
- Unknown-renderer log output is visible and useful on a real capture

---

## Explicitly out of scope

Do not build: the RPC transport, `playback.open` or the resolution ladder, any
Flutter code, the SABR bridge, yt-dlp integration.

---

## If you get stuck

If a fixture cannot be parsed into the DTOs without either throwing or
inventing a field, **stop and report it** rather than widening the DTO. The DTO
shape is a contract with the Flutter side; changing it unilaterally breaks the
other half of the app. Describe what the renderer contains and what field it
would need.
