# Task 17 — Captions

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.3 and §3.5,
`docs/architecture.md` §2.6–§2.8, and the Task 15 and 16 reports.

The CC button was deliberately left as a gap in Task 16 rather than shipped
dead. This fills it — for the watch page first, which is where captions matter
most, and for the hover preview second.

---

## 1. Tracks come from the response already fetched

Measured during Task 15: caption tracks arrive on the **same `ANDROID_VR`
`/player` response** the ladder and `video.info` already fetch and cache.
`dQw4w9WgXcQ` returns 6 tracks (manual plus ASR) anonymously.

So this costs no extra request to YouTube. Read from the cached response.

**One gotcha, already measured:** `ANDROID_VR` returns absolute `timedtext`
URLs; `WEB`/`MWEB` return relative ones. Handle whichever the cached response
carries rather than assuming.

**Videos with no tracks are ordinary**, not an error. Big Buck Bunny has none.
An empty list means hide the control, the same way a missing storyboard means no
scrubber preview.

## 2. Format — measure before choosing

YouTube serves timedtext in several formats, selected by a query parameter:
`json3`, `srv1`, `srv2`, `srv3`, `ttml`, `vtt`. **Do not assume which are
available or what each contains** — fetch a real track in each and report what
comes back, including whether the parameter is honoured at all.

Two things to establish empirically:

- **Which format carries clean cue-level timing.** Some carry word-level
  timing, some cue-level, and the difference decides everything downstream.
- **Whether positioning and styling data survive** — YouTube captions can carry
  position, alignment and colour, and a format that drops them is a different
  product decision than one that keeps them.

Pick one, and say in the report what the others gave you. If mpv can consume a
format directly, that is worth knowing before writing a parser.

## 3. Auto-generated tracks are the hard part

ASR tracks carry **word-level timing**. Fed through unchanged they render as a
word-by-word stutter — each word appearing alone as it is spoken — which is
unreadable and is not what youtube.com shows.

The site groups words into rolling lines. Whatever you do here, do it
deliberately and say what rule you used: word count, duration, punctuation, or
some combination. Show a before/after of the same passage in the report.

**A track that is `kind: "asr"` is the signal.** Manual tracks are already cue-
level and need none of this.

## 4. Getting them into mpv

media_kit exposes mpv's subtitle handling. Establish what it supports before
designing around it:

- Can a subtitle track be added from a URL, or does it need a local file?
- Does adding one mid-playback work, or does it need a reopen?
- What formats does the bundled libmpv accept? F12 established that the pinned
  build is from 2023 — **do not assume a format is supported because current mpv
  supports it.** Check the artefact, as invariant 8 requires.

**If a track must be written to disk**, keep it in a temp directory, clean it up
on close, and say where it lives.

**A caption change must not rebuild the video texture.** F19 measured what a
quality switch costs (0.55–12 s, texture rebuilt) precisely because it reopens
the media. If enabling a caption track forces a reopen, that is the finding —
report it before working around it, because it changes whether captions can be
toggled freely or are a per-open choice.

## 5. Protocol

Add a method for the track list, or extend `video.info` — whichever fits §3.3
better. Propose the shape and amend `protocol.md`.

The sidecar should hand Flutter something **fetchable and parsed**, not a
template the client has to construct. Hard invariant 6's reasoning: the client
building URLs against a format that changes without notice is the thing that
rule exists to prevent. Task 15 landed on the same conclusion for storyboards.

Cache parsed tracks — a language switch should not refetch.

## 6. The control

**Watch page.** The CC button goes in the gap Task 16 left, between quality and
theatre. It opens the settings panel's caption page — a track list with the
current one marked, and Off.

- Remember the choice for the session
- If a preferred language was used last time and this video has it, select it
- **C** toggles captions on and off, subject to the same text-field focus guard
  as every other shortcut

**Hover preview.** The preview gets a CC toggle alongside its mute toggle, per
the design you settled on: while previewing, the tile's watch-later and queue
buttons are replaced by mute and CC.

The preview and the watch page share the parsed track cache. A preview that has
already fetched a track means opening the video costs nothing extra.

## 7. Rendering

Whether mpv renders them or Flutter does is your call — but say which and why.

If mpv renders: styling is limited to what libmpv exposes and positioning data
may be lost. If Flutter renders: full control, but you own timing against
`player.stream.position`, and hard invariant 9 applies — position comes from the
stream, never from polling `getProperty`.

Either way: legible over arbitrary video, not clipped by the controls overlay,
and repositioned when the controls are visible so they do not sit under the
scrubber.

---

## Tests

- Track list parses from a real cached `/player` response, absolute and relative
  URL forms both handled
- A video with no tracks yields an empty list, not an error
- The chosen format parses to cues with correct timing, against a fixture
- **ASR grouping**: a word-level track becomes readable lines, asserted against
  a known passage. Assert the grouping, not that something was produced
- A manual track is not re-grouped
- Toggling captions does not reopen the media (or, if it must, the test pins
  that it does and the report says so)
- Track choice persists across videos within a session
- **C** toggles captions and does not fire while a text field has focus

**Mutation-check the ASR grouping and the focus guard.** Both are the shape that
passes against deleted code — a test asserting "cues exist" passes with no
grouping at all.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean including
  the colour-literal rule
- Captions display on the watch page, correctly timed, in a chosen language
- An auto-generated track is readable, not a word-by-word stutter
- Toggling and switching language works without losing position
- Hover preview CC toggle works
- A video with no captions shows no control

**Run the app and say what you saw** — a manual track, an ASR track, a language
switch, and a video with none. Screenshots described, since caption legibility
is not testable.

## Out of scope

Caption search, transcripts, translation (`tlang`), user-adjustable caption
styling, the settings page, login.

## Stop conditions

- **The bundled libmpv cannot consume the chosen format** and Flutter rendering
  is not viable either. Report both attempts.
- **Enabling a track forces a media reopen.** Report the cost before designing
  around it — it decides whether captions toggle freely.
- **ASR grouping cannot be made readable** without heuristics that misfire on
  ordinary speech. Report what you tried and what broke.
