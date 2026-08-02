# Spike 03 — Playback client

**This is a spike, not a task.** The deliverable is a finding, not a component.
Throwaway code goes in `spiking/`. **Do not modify `sidecar/src/`.**

**Prerequisite:** `CLAUDE.md`, `docs/architecture.md` (F5, F10, §2.4), and the
Task 02 report.

---

## Why

Task 02 proved deciphering works, then hit F10: `c=MWEB` URLs refuse the
open-ended range request ffmpeg opens every stream with, so a deciphered MWEB
URL cannot be handed to libmpv. Task 02 correctly stopped rather than reviving
rejected alternative A6.

But the same report measured tier 3 resolving through `ANDROID_VR` at
**10.9–23.3 MB/s** — two to five times MWEB's 4.02 — on URLs that *do* accept
open-ended ranges and *do* play in mpv.

So F10 may not need a workaround. It may need the right client. That is what
this spike determines, and everything downstream is blocked on the answer.

Note F5 records `ANDROID_VR` as actively refused. yt-dlp resolves it fine, so
F5 most likely describes **our request construction**, not the client.

---

## Q1 — Can `ANDROID_VR` be made to work?

Capture what yt-dlp actually sends and diff it against ours.

```bash
yt-dlp --print-traffic -f bestvideo --extractor-args "youtube:player_client=android_vr" \
  --simulate <VIDEO_ID> 2> yt-dlp-traffic.log
```

Compare the `/youtubei/v1/player` request body and headers against what
youtubei.js emits for `{ client: 'ANDROID_VR' }`. Likely divergences, in rough
order of probability:

- `clientVersion` — youtubei.js may carry a stale one; yt-dlp updates constantly
- `androidSdkVersion` — required for Android clients, easy to omit
- `deviceMake` / `deviceModel`
- `User-Agent`
- `osName` / `osVersion`

Port the difference into a throwaway script and re-request.

**Pass:** > 0 adaptive formats at ≥ 1080p.

> `ANDROID_VR` URLs legitimately carry no `n` parameter. Absence is expected,
> not a decipher failure. Do not chase it.

## Q2 — Do `ANDROID_VR` URLs survive F10 end to end?

Only meaningful if Q1 passes. Four checks, in order:

1. `Range: bytes=0-` → expect **206**, not 403
2. Bare GET, no headers → record the status (Task 02 measured 403 on MWEB)
3. Sustained throughput, ≥ 12 MB fetched, assert **> 1.5 MB/s**
4. `mpv <videoUrl> --audio-file=<audioUrl>` — plays, audio in sync, **seek
   works** mid-file

Check 4 is the one that matters. Task 02's suite passed while playback was
broken because it only ever issued bounded ranges — the exact path that works.
Do not repeat that shape of test.

**Also record the video codec.** Task 02 saw `ANDROID_VR` return AV1
(itag 401) where MWEB returned VP9 (itag 315). AV1 4K hardware decode needs a
relatively recent GPU; without it, 4K AV1 software-decodes and burns CPU. Note
what this machine does — `mpv --msg-level=vd=v` reports whether decoding is
hardware or software. If AV1 is software-decoded here, that is a finding, and
it may argue for preferring VP9 formats from the same client.

## Q3 — Does `max_request_size` exist in media_kit's libmpv?

Independent of Q1 and Q2, worth ten minutes while you are here.

An upstream FFmpeg patch adds a `max_request_size` option to
`libavformat/http.c`, explicitly motivated by mpv and YouTube. If it merged and
media_kit's bundled libmpv is new enough, MWEB becomes usable with one config
line instead of a proxy.

- Check whether it landed in FFmpeg master, and in which release
- Check media_kit's bundled libmpv/FFmpeg version
- If present, test: `mpv --stream-lavf-o=max_request_size=1048576 <mwebUrl>`

**Do not** pursue `seekable=0`. It suppresses the Range header entirely, but
Task 02 measured a bare GET at 403, so it cannot work.

---

## Deliverable

A report, in the same shape as Task 02's: what was measured, what contradicted
the docs, what it means. Specifically:

- Q1 pass/fail, and if pass, exactly which fields differed
- Q2 results per check, including the codec and hardware-decode finding
- Q3 present/absent, with versions
- A recommendation on the playback client — but **do not implement it**

Amend `docs/architecture.md` only with measured observations: F5's correction
if Q1 passes, and whatever Q2 establishes about `ANDROID_VR` versus F10. Do not
edit §2.4's undecided paragraph; that decision is not made in this session.

## Out of scope

Building the chunking proxy. Modifying the resolution ladder. Promoting a tier.
Any Flutter or media_kit integration work. Touching `sidecar/src/`.

## If Q1 and Q2 both pass

Say so and stop. That outcome removes F10 rather than working around it, and it
changes the ladder's tier ordering — which is a decision to be made outside this
session, not a change to make inside it.
