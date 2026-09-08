# Task 17 — Captions (revised)

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.3, §3.5, §3.7,
`docs/architecture.md` §2.6–§2.8, F12, F16, F19, F20.

The CC button was deliberately left as a gap in Task 16 rather than shipped
dead. This fills it.

**A previous attempt at this task was rolled back.** It worked, but broke
playback and other behaviour along the way. What it *learned* is preserved
below — §1 is measured fact, not speculation, and re-deriving it would waste a
day. What it *built* is not a model to follow: it rendered captions in Flutter,
which this brief replaces for reasons given in §2.

---

## 1. What is already known

Established by the rolled-back attempt. Treat as measured; re-verify only if
something contradicts it.

| | Finding |
|---|---|
| **Source** | Caption tracks arrive on the **`/player` response already fetched and cached** for stream resolution. No extra request to YouTube in the normal case. |
| **URL form** | `ANDROID_VR` returns **absolute** `timedtext` `baseUrl`s; `WEB`/`MWEB` return **relative** ones. Handle whichever the cached response carries. |
| **ANDROID_VR gap** | For a minority of videos `ANDROID_VR` returns **zero** tracks where `WEB` returns them. All-or-nothing, not partial. Verified stable across 10 fresh sessions — not a per-session bucket like F20. |
| **Genuinely captionless** | ~3.4% of a real feed sample (1/29) has no captions at all. Any "fetch `WEB` when empty" fallback fires on these too, so it must cache the negative. |
| **`translationLanguages`** | A video may carry **1 real track plus ~156 `translationLanguages`**. Those are machine translations of the one track, fetched by appending `&tlang=<code>` to the same `baseUrl`. **They are not missing tracks.** A track list far shorter than youtube.com's picker is expected and correct. |
| **`json3`** | Carries word-level timing for ASR, grouped under parent events. Clean structured JSON, cheapest to parse. |
| **ASR** | `kind: "asr"` tracks are word-level and render as a word-by-word stutter unless grouped. Manual tracks are already cue-level. |
| **`build_runner` is broken** | See §6. This blocks **all** codegen in this project, not just `freezed`. |

## 2. Architecture — ASS through libass, not Flutter

**Captions render through mpv/libass, from ASS. The sidecar converts every
format to ASS; Flutter draws nothing.**

The rolled-back attempt rendered in Flutter. That works for plain text and
cannot ever work for **YTT** — YouTube's own format, carrying per-word timing,
positioning, colours, fonts, edge effects and karaoke. Full YTT support is the
end state, and libass renders exactly that class of styling natively while a
Flutter overlay would mean reimplementing a subtitle layout engine.

Choosing Flutter now means ripping it out later. Choosing ASS now makes YTT an
additional converter behind an interface that already exists.

### Pipeline

```
/player  →  track list
   ↓
fetch track (format chosen per §3)
   ↓
parse → intermediate cue model     ← format-specific
   ↓
ASR grouping (if kind == "asr")    ← operates on cues, not on ASS
   ↓
render to ASS                      ← one renderer, all formats
   ↓
hand to mpv                        ← §4
```

The intermediate model carries **optional** styling — position, alignment,
colour, per-word timing. `json3` populates text and timing only; YTT will
populate the rest. Design the model for that now; do not build the YTT parser.

### Scope for this iteration

- **Build:** `json3` → cues → ASS, with ASR grouping. This covers the
  overwhelming majority of videos.
- **Design for, do not build:** YTT. The converter interface, the intermediate
  model's optional styling fields, and the ASS renderer's ability to emit
  positioning and inline overrides must all accommodate it. Say in the report
  what a YTT parser would have to fill in and what it would not have to change.

## 3. Format selection

`json3` is the working assumption from §1, and it is probably right. **Verify
rather than assume**: fetch one real track in each of `json3`, `srv3`, `ttml`,
`vtt` and `ytt`, and report what each returns — including whether the `fmt`
parameter is honoured at all.

Two things worth knowing before committing:

- **Does `ytt` return something distinguishable from `srv3`?** If YTT arrives
  as `srv3` with extra elements, the future parser is an extension rather than a
  new one.
- **Does any format already produce something libass consumes directly?** If so,
  a passthrough may beat a converter for that case, and that is worth knowing
  even if it is not what you build.

## 4. Getting ASS into mpv

Establish what media_kit exposes **before** designing around it. F12 pins the
bundled libmpv at a 2023 build — invariant 8 applies: check the artefact, do not
assume current mpv's capabilities.

Three delivery mechanisms, cheapest first:

1. **Subtitle data passed directly**, if media_kit supports it. No file, no
   server, no cleanup. Try this first.
2. **A temp file** plus a file URI. Clean up on close; say where it lives.
3. **Loopback HTTP from the sidecar.** `protocol.md` §1 already reserves a
   loopback media channel for Phase 2, so there is precedent — but do not build
   a server if (1) or (2) works.

### Two integration constraints

**A caption change must not rebuild the video texture.** F19 measured a quality
switch at 0.55–12 s precisely because it reopens the media. `sub-add` should be
a separate track and cost nothing — **verify it**. If enabling a track forces a
reopen, that is a stop condition: it decides whether captions toggle freely or
are a per-open choice.

**Captions must survive a quality switch.** A quality switch reopens the media
(F19), which will drop an attached subtitle track. Reattach after the switch, or
say why it is not needed.

## 5. The `ANDROID_VR` fallback

When `ANDROID_VR` returns zero tracks, fetch `/player` once as `WEB` — anonymous
resolve session, no cookies — and take the track list from there.

- **Cache the negative per video, with a TTL** (an hour is fine). A video can
  gain captions after upload, so a permanent negative would never notice.
- **Log each fallback at INFO with the video id.** If `ANDROID_VR`'s behaviour
  changes, the fire rate moving is how we find out.
- **Do not add a user-facing toggle.** A setting whose correct value is always
  "on" is a way to break the app.

Report the observed fire rate once it runs.

## 6. `build_runner` is broken — this will bite immediately

Diagnosed during the rolled-back attempt:

```
Generating AOT kernel dill failed!
type 'InvalidType' is not a subtype of type 'FunctionType' in type cast
  _FfiUseSiteTransformer._verifyAndReplaceNativeCallable
  (package:vm/modular/transformations/ffi/use_sites.dart:1317)
```

`build_runner` bootstraps itself as an AOT binary, and the AOT kernel generator
crashes on FFI use sites — `media_kit`'s and the app's own. **This blocks every
code generator in the project**, not just `freezed`.

`VideoDetail` needs a new field for caption tracks, so you will hit this on the
first regeneration.

**Try for an escape hatch before converting anything.** JIT mode, a flag that
skips the AOT bootstrap, a version pin, an upstream issue with a workaround. A
one-line escape is worth far more than a permanent hand-written-DTO policy, and
nobody has looked yet.

If there is none, convert only what must change, and then:

- **Add `VideoDetail` to `contract_test.dart`** against the corpus. It is
  currently uncovered, and a hand-written `fromJson` is where a field added
  sidecar-side gets silently dropped client-side.
- The assertion must be **strict-key**: every key in the corpus payload maps to
  a field, or the test fails naming the unknown key. The expected key set is
  **hand-written per model** — deriving it from the corpus makes the test
  unfailable.
- **Mutation-check it**: add an unknown key to a corpus payload and confirm it
  fails.

Record whatever you find in `CLAUDE.md`, including that it blocks all
generators.

## 7. ASR grouping

Word-level cues fed through unchanged are unreadable and are not what
youtube.com shows. Group into rolling lines.

Say what rule you used — word count, duration, punctuation, or a combination —
and show a **before/after of 8–10 consecutive events**. The previous attempt
demonstrated this with a single event containing four segments, which proves
nothing: the parser groups by parent event, so one cue comes out whether or not
grouping logic exists.

Report the raw cue count in and the line count out.

**Mutation-check the grouping** against the multi-event fixture.

## 8. The control

**Watch page.** CC button in the gap Task 16 left, between quality and theatre.
Opens the settings panel's caption page: track list with the current one marked,
plus Off.

- Remember the choice for the session; prefer the same language on the next
  video if it has it
- **C** toggles captions, subject to the same text-field focus guard as every
  other shortcut
- **Hide the control entirely when the track list is empty** — after the §5
  fallback, not before it

**Hover preview.** A CC toggle alongside mute, replacing watch-later and queue
while previewing. The preview engine is a **separate `Player`** (Task 15), so it
needs its own attach — say what that costs. If it is expensive, report and leave
it for a follow-up rather than slowing the preview path.

## 9. What must not regress

The previous attempt broke playback. Before reporting done, verify by hand:

- A video plays, seeks, and switches quality
- Hover previews still work and are still suppressed during playback
- The queue advances on completion
- Fullscreen and theatre still work
- **The player still works with captions off** — the default path must be
  untouched

---

## Tests

- Track list parses from a real cached `/player` response, absolute and relative
  URL forms both handled
- A video with no tracks yields an empty list, not an error
- The `ANDROID_VR` fallback fires on an empty list, caches the negative, and
  does not fire twice for the same video inside the TTL
- `json3` parses to cues with correct timing, against a fixture
- **ASR grouping** across 8–10 events produces readable lines; a manual track is
  not re-grouped
- ASS output is well-formed and its timings match the cues
- Toggling captions does not reopen the media (or pins that it does)
- Captions survive a quality switch
- Track choice persists across videos in a session
- **C** toggles and does not fire while a text field has focus
- Strict-key contract test on `VideoDetail`

**Mutation-check** the ASR grouping, the focus guard, the negative cache and the
strict-key test. All four are the shape that passes against deleted code — this
project has caught five such tests.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean including
  the colour-literal rule
- Captions display, correctly timed, in a chosen language
- An auto-generated track is readable, not a word-by-word stutter
- Toggling and switching language works without losing position
- A video with no captions shows no control
- **Everything in §9 still works**

**Run the app and say what you saw** — a manual track, an ASR track, a language
switch, a video with none, and a quality switch with captions on. Report the
test counts, not "passed flawlessly".

## Out of scope

The YTT parser itself. Translations (`&tlang=`) — §1 explains why a short track
list is correct. Caption search, transcripts, user-adjustable caption styling,
the settings page, login.

## Stop conditions

- **Enabling a track forces a media reopen.** Report the cost before designing
  around it.
- **media_kit exposes no way to attach a subtitle** without a reopen or a
  server. Report all three mechanisms from §4 and what each did.
- **libass in the bundled libmpv cannot render the ASS you generate.** Report
  what it rejected — that decides whether YTT is reachable at all on this pin.
- **The `build_runner` escape hatch exists but changes behaviour elsewhere.**
  Report rather than adopting it silently.
