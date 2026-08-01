# Task 02 — Decipher + playback resolution

**Prerequisite:** `CLAUDE.md`, `docs/architecture.md`, `docs/protocol.md`,
and a passing Task 01 suite.

Task 01 discharged the parser risk. It now sits here: **nothing in the codebase
has ever signed a URL.** `SignedUrl` has no constructor, so it is currently
impossible to play anything. F4's throughput half — 4.0 MB/s with `n`
deciphered — was measured by the throwaway spike, never by our code.

Until this task proves decipher end-to-end, the ~50 KB/s throttle is the
largest unknown in the build.

---

## Deliverables

### 1. `sidecar/src/innertube/player.ts`

Player JS retrieval and deciphering.

- `getPlayer(session)` → `{ playerId, signatureTimestamp, decipherSignature, decipherN }`
- Cache the deciphered functions **keyed by `playerId`**, never indefinitely.
  YouTube ships new player revisions; a stale cache silently reintroduces the
  throttle.
- The `node:vm` interpreter shim is required. `spike.mjs` has a working
  IIFE-wrapped version — reuse it.

**`signatureTimestamp` is mandatory on every raw `/player` call.** Omitting it
returns `UNPLAYABLE — "The page needs to be reloaded."`, which reads like a
dead or region-locked video and is not.

### 2. `sidecar/src/innertube/signed-url.ts`

The `SignedUrl` branded type and its **only** constructor.

```ts
declare const brand: unique symbol;
export type SignedUrl = string & { readonly [brand]: 'SignedUrl' };

// The only function in the codebase that may produce a SignedUrl.
export function sign(rawUrl: string, player: Player): SignedUrl;
```

`sign` applies the signature cipher and the `n` transform, then asserts the
result carries `n=` when the client expects one. Everything downstream accepts
`SignedUrl`, never `string`. This is the type-level guard that makes the
throttle unrepresentable rather than merely unlikely.

Note: `ANDROID_VR` and `TV` URLs legitimately carry no `n` parameter. `MWEB`
and `WEB` do. Gate the assertion on client, or a valid URL fails validation.

### 3. `sidecar/src/playback/resolve.ts`

`playback.open` and the resolution ladder from `protocol.md` §3.5.

Tiers, in order:

1. `MWEB` plain adaptive — the Phase 1 path
2. SABR → DASH — **not implemented**; throw `STREAM_REQUIRES_SABR` so the
   ladder falls through. Leave the seam, build nothing.
3. `yt-dlp` subprocess — age-restricted, Vevo, edge cases
4. itag 18 progressive, 360p — sets `qualityDegraded: true`

Returns the `PlaybackSource` shape from `protocol.md`. Flutter must not be able
to tell which tier served it; `transport` is telemetry only.

**Share the player response.** `video.info` needs `/player` for duration
(`/next` does not carry it) and `playback.open` needs it for formats. One call,
one cache entry, both consumers — not two round trips per video open.

### 4. `sidecar/src/playback/sabr-detect.ts`

`isSabrOnly(playerResponse): boolean`

Defined **over adaptive formats only**. A SABR-only `WEB` response still
carries a working itag 18 progressive stream; defining this over all formats
returns `false` and silently serves 360p forever.

This function is the Phase 2 trigger. Test asserts `MWEB → false` and
`WEB → true`. The capture that flips `MWEB` to `true` fails the suite loudly,
which is how we learn Phase 2 became mandatory — not from a user complaint.

### 5. `sidecar/src/playback/po-token.ts`

Interface only, no implementation.

```ts
export interface PoTokenProvider {
  mint(videoId: string): Promise<string | null>;
}
```

Anonymous `MWEB` needs no token today. That may not last. Build the seam so
adding a provider later is a plug-in rather than a refactor; wire a null
provider for now.

### 6. Storyboards

Extract `storyboardTemplate` from the player response into `PlaybackSource`.
Hover previews depend on it and it costs nothing here.

---

## Tests

Offline against fixtures where possible. Two must hit the network.

**Offline:**
- `isSabrOnly` — `MWEB` false, `WEB` true, on captured player responses
- `sign()` output carries `n=` for `MWEB`, and is accepted without one for
  `ANDROID_VR`
- Ladder falls through tiers correctly when a tier throws
- `PlaybackSource` shape validates; `transport` and `qualityDegraded` populated

**Network — these are the point of the task:**
- **Sustained throughput.** Resolve a video via `MWEB`, fetch ≥ 12 MB with a
  range request, assert **> 1.5 MB/s**. Asserting the `n` parameter merely
  exists is not sufficient — a wrongly-deciphered `n` is present and still
  throttles. This test is the only thing that proves decipher works.
- A raw `/player` call **without** `signatureTimestamp` returns `UNPLAYABLE`,
  and **with** it returns streaming data. Pins N2 so nobody re-learns it.

---

## Definition of done

- A real video resolves to two `SignedUrl`s and streams at > 1.5 MB/s
- `mpv <videoUrl> --audio-file=<audioUrl>` plays it with audio in sync
  (manual check — media_kit integration is Task 03)
- `isSabrOnly` correct on both clients, with the Phase 2 tripwire in place
- No path exists by which an unsigned URL can reach `PlaybackSource`

---

## Out of scope

Flutter, media_kit, the RPC transport, the SABR bridge, a real PO token
provider, watch-history reporting.

---

## If you get stuck

If throughput sits near 50 KB/s, the `n` transform is wrong — not the network.
Check the player cache is keyed by `playerId` and that the shim is executing
the current player JS, before suspecting anything else.
