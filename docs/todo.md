# Todo

Work that is agreed but not done. Each entry carries enough context to be picked
up cold: what the problem is, where it lives, and what "done" means.

This is not a task spec archive — `docs/tasks/` is that, and those files record
what was asked for at a moment in time. This file is the live backlog, and an
item leaves it when the work lands.

**Ordering is by section, not by line.** Within a section nothing is ranked.

---

## Now

### 1. Merge the build scripts into one `rill.ps1`

`setup.bat`, `build.bat`, `package.bat` and `run.bat` share three copies of the
`.env` `YT_COOKIE` parse and two copies of the sidecar-bundling step. Merge the
last three; leave `setup.bat` alone (it is the bootstrap, and converting the one
script a fresh machine runs before anything is configured is the change you
cannot debug with the tooling it installs).

Shape:

- Bare invocation prints help. **Not** a build — a bare `rill` currently means
  minutes of `bun run build` + `flutter build windows --release` plus
  overwriting the release folder, which is the wrong thing to reach by typing a
  name and pressing enter.
- Subcommands (mutually exclusive): `build`, `run`, `flutter`, `zip`.
  - `run` = build, then launch the exe **attached to this terminal**.
    `probe_task19.dart`'s own header records why: *"`flutter run --release -t …`
    also works but does not always relay the app's stdout back; building and
    launching the exe from the shell does."* This project diagnoses through
    stdout — the `rill: sidecar <path> (built <mtime>)` startup line and
    nineteen `RILL_*` probe variables — so attached is the useful default.
  - `--detach` restores today's `start ""` behaviour.
  - `flutter` = `fvm flutter run --release -d windows`, for when you want the
    Flutter tool driving.
  - `zip` = build, bundle, `Compress-Archive`, open explorer.
- `--target <dart file>` applies to `build`, `run` and `flutter`. This is the
  flag most likely to earn its keep: `rill run --target lib/probe_task19.dart`
  turns an incantation that currently lives only in a source-file header into
  something discoverable.
- `-h` / `--help` prints the detailed version. It must stand alone without
  CLAUDE.md, which means carrying the **hazards**, not just the flag list:
  - that `run`/`zip` imply a build, so nobody ships or measures stale code;
  - that the script copies `sidecar/dist/sidecar.exe` into the release folder
    and why — the app prefers the copy beside its own executable, and
    `flutter build windows` does not refresh an already-populated bundle. This
    is CLAUDE.md's longest hazard and this script is what prevents it;
  - that it uses `fvm flutter` and silently falls back to bare `flutter`, and
    that the fallback costs an unpinned SDK;
  - that it loads `YT_COOKIE` from `.env`, which is why a checkout can come up
    signed in with the variable unset in the environment;
  - one line pointing at `setup.bat` as what a fresh machine runs first.
- One `rill.bat` forwarding `%*`, so cmd works:
  `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rill.ps1" %*`.
  `-ExecutionPolicy Bypass` is not optional — without it the `.ps1` refuses to
  run on a default-configured machine, which is how a repo script works for its
  author and nobody else.

**Fix the exit-code bug while you are in there.** `build.bat` runs
`call bun run build` and `call %FLUTTER_CMD% build windows --release` with no
`errorlevel` test and only checks the copy. So a failed Flutter build proceeds to
bundle the sidecar and launch the *previous* release binary — the app comes up,
looks fine, and is old code. That is CLAUDE.md's "a fix verified this way appears
not to work, with no error and no clue" trap, mechanised. Check `$LASTEXITCODE`
after every stage and abort.

**Carry through unchanged:** the sidecar-bundling step and its comment. A merge
is exactly when a step that looks redundant gets dropped.

**Done when:** one `rill.ps1` + one `rill.bat`, `setup.bat` untouched, every
stage checks its exit code, `rill --help` is self-sufficient, and CLAUDE.md's
Commands block is a short subcommand table ending with "run `rill --help` for
the full surface". One summary, one detail — CLAUDE.md already restates the
contract in five places and two went stale silently; do not create a sixth.

### 2. Test whether `source_gen` and `build` overrides are still needed

`app/pubspec.yaml`'s `dependency_overrides` block carries `source_gen: ^4.1.2`
and `build: ^4.0.4`. Both came from `16b70c7` alongside `animated_vector_gen` and
the `analyzer`/`dart_style` pair; the 2026-09-09 fix removed two of the four and
documented the removal at length, and these two survived with no justification of
their own. `pubspec.lock` confirms both are still `dependency: "direct
overridden"`, and the resolved versions (`source_gen 4.2.4`, `build 4.0.7`) sit
well above the override floors — which hints they are vestigial without proving
it, since an override also removes a package from normal constraint solving.

This matters because CLAUDE.md's own history says this class of failure *"lands
at compile time with messages about someone else's AST"* and *"neither names a
version"*. Two un-justified overrides are a known trap left armed in a project
already bitten by it twice.

**How:** comment both out, `fvm flutter pub get`,
`fvm dart run build_runner build --delete-conflicting-outputs`.

**Done when:** either they are deleted and `pubspec.yaml` records that they were
vestigial from `16b70c7`, or the exact failure is recorded next to the paragraph
explaining why `analyzer` and `dart_style` deliberately are *not* overridden.
Either outcome closes the loop; only one is a doc edit.

### 3. Re-measure the fullscreen round trip (F19) now that bitsdojo owns the frame

`Win32WindowChrome.setFullscreen` does borderless fullscreen via
`GetWindowPlacement` / `SetWindowPos` (`app/lib/ui/player/window_chrome.dart`).
`main.cpp` now also declares `BDW_CUSTOM_FRAME`, so `bitsdojo_window` owns the
window frame too. **Two things own the frame.**

F19's measurement — a fullscreen round trip restoring `rcNormalPosition`
`[10, 10, 1290, 730]` → whole monitor → `[10, 10, 1290, 730]` — predates
bitsdojo entirely, so it no longer describes the shipping configuration.

**How:** `RILL_CONTROLS_PROBE=1` against a release build. Sequence this *after*
the window-controls seam landed (it has), or you measure a build whose tests do
not run.

**Done when:** F19 carries a dated amendment saying whether the round trip still
restores exactly, under the custom frame.

### 4. Decide what `AUTH_DEGRADED` and `RATE_LIMITED` are

`protocol.md` §4 assigns both a `retry` value and a UI contract. Neither is ever
constructed: across all of `sidecar/src`, `new RpcError(...)` is only ever called
with `UPSTREAM_ERROR` (12), `BAD_REQUEST` (12), `STREAM_UNAVAILABLE` (4),
`VIDEO_UPCOMING` (1), `VIDEO_MEMBERS_ONLY` (1), `AUTH_REQUIRED` (1).

Two live consequences:

- `app/lib/ui/feed_controller.dart:529`'s `if (e.code == 'AUTH_DEGRADED')` branch
  is unreachable. Degraded state only ever arrives as a *successful*
  `auth.verify` / `auth.status` result.
- YouTube's throttle — `LOGIN_REQUIRED — Sign in to confirm you're not a bot`,
  which `architecture.md` F20 documents as real and observed — surfaces as
  `STREAM_UNAVAILABLE` / `UPSTREAM_ERROR`, never `RATE_LIMITED`. The documented
  `auto` backoff path is reached only by way of `UPSTREAM_ERROR`.

**Decide, per code:** emit it (and make the app's branch live), or delete it from
the table and remove the dead branch. `RATE_LIMITED` is the more interesting of
the two — F20 already knows how to recognise a throttle, so emitting it is
cheap and would give the app a correct backoff path instead of an accidental
one.

**Done when:** every code in §4's envelope table is either emitted somewhere in
`sidecar/src` or gone from the table, and no client branch tests for a code that
cannot arrive.

### 5. Close the `no-console` gap in the sidecar lint

`sidecar/eslint.config.js` sets `'no-console': ['error', { allow: ['error',
'warn'] }]`. `sidecar/src/log.ts:5` claims *"The eslint config bans the
alternatives so this cannot regress quietly."* That is false for
`console.error` / `console.warn`, and both bypass `redact.ts` — the chokepoint
CLAUDE.md credits with making cookie leaks structurally impossible rather than a
rule per call site. No live call exists today, so this is a gap in the guard
rather than a leak.

**Two halves, and an agent will do the first and stop unless told otherwise:**

1. Drop the `allow` list and route any resulting call sites through `log.ts`.
2. Fix `log.ts:5`'s comment, which currently asserts a ban that is not in force.

**Done when:** `bun run check` is green with no `allow` list, and the comment
describes what the config actually does.

---

## Soon

### 6. Bind the `/player` response cache to the player revision (Task 04 §1)

`docs/tasks/04-player-revision-safety.md` §1 — never implemented, never recorded
as deferred. Task 06 said it would be "scoped separately after this lands"; no
later task took it up.

The defect: `openPlayback` fetches a `/player` response whose
`signatureTimestamp` was built against player revision **P_old**, then each tier
independently calls `getPlayer()` (`resolve.ts:337`, `:757`), which past
`PLAYER_TTL_MS` may install **P_new**. P_old's `n` then gets deciphered with
P_new's script. The task is explicit about the cost: *"a wrong `n` produces a
plausible-looking string that throttles to ~50 KB/s, which reaches the user as
buffering and reaches us as a bug report about their internet."*

**The fix is one line of intent:** include `playerId` in `keyFor`
(`sidecar/src/innertube/player-response.ts:57`), which is currently
`` `${client}:${videoId}` `` plus the playlist id.

**Record this when you write it up, or the next person closes it as
unreproducible:** live exposure today is **zero**, because nothing in the
production ladder deciphers (see item 7). That is two undocumented facts
cancelling out, not a fixed bug.

### 7. Write down that `MWEB` was retired from the resolution ladder

The production ladder in `openPlayback()` (`sidecar/src/playback/resolve.ts:887`)
has **three** rungs: `VISIONOS plain adaptive` → `yt-dlp` → `itag 18
progressive`. There is no `MWEB` tier. `'MWEB'` survives in that file only as a
post-resolution fallback that fetches a second `/player` to recover
`startTimestamp` for a live stream with a null duration (`:922`, and its log
string at `:927`).

This was deliberate — commit `c53fb54`: *"MWEB adaptive retired: F10 has refused
open-ended ranges since the spike, so it was never a playback path. Nothing in
the ladder deciphers now."* It was never written down, and **six** places assert
the opposite:

| Where | Text |
|---|---|
| `protocol.md` §3.5 | "2. `MWEB` plain adaptive URLs — the decipher path, kept as a fallback" |
| `CLAUDE.md` (Notes) | "asking as `VISIONOS` (ladder tier 1) and falling back to `MWEB` (tier 2)" |
| `CLAUDE.md` (Current state) | "Phase 1: plain `MWEB` URLs, no SABR, no media proxy." |
| `architecture.md` §2.3 | client table: "Stream resolution — ladder tier 2 \| `MWEB`" |
| `architecture.md` §2.4 | "`MWEB` stays tier 2 … the only client with a proven decipher path" |
| `architecture.md` §4 | "`MWEB` remains tier 2; F10 constrains consumption, not resolution" |

Plus `resolve.ts`'s own module header (`:4-11`), which still opens *"Five tiers,
tried in order"*.

**The consequence is bigger than a stale row.** `CLIENTS_WITH_N_PARAM`
(`signed-url.ts:55`) is `{WEB, MWEB, WEB_REMIX, WEB_EMBEDDED_PLAYER}`. Neither
`VISIONOS` nor `ANDROID` is in it, so **nothing in the production ladder
deciphers anything.** Hard invariant 2 and Task 02's whole decipher path now
guard a code path no production request reaches. It is still exercised by the
network tests, so it is not rotting silently — but CLAUDE.md reads as though it
constrains the shipping path, and it does not.

**This is not a code task.** Do not delete the decipher path: it is the only
proven decipher implementation, `WEB` is already SABR-only, Phase 2 may need it,
and F3's tripwire still samples `MWEB` for exactly that reason. Do not restore
`MWEB` as a tier either: F10 settled that its URLs refuse the open-ended
`Range: bytes=0-` ffmpeg emits by construction.

**Done when:** `architecture.md` §2.4 carries a dated paragraph saying MWEB was
retired on 2026-08-19, why (F10), what is retained and why, and that nothing in
the production ladder deciphers today; §2.3's table, §4's row, `protocol.md`
§3.5, CLAUDE.md and `resolve.ts`'s header all agree with it.

Note that `contract-docs.test.ts` cannot catch this class: `MWEB` *does* still
appear in `sidecar/src`, so every stale sentence passes the client-token guard.

### 8. Widen `contract-docs.test.ts`

It is doing its job on what it checks, but its reach is narrower than CLAUDE.md's
"one test checks they agree" implies:

- It compares **field names only** — not types, not nullability. `channelId:
  string` versus `string | null` passes, which is the distinction the DTO rule
  cares about most.
- It parses shapes out of **CLAUDE.md only**. `protocol.md`'s own
  `interface SearchFilters` and `interface PlaylistMembership` are never
  compared against code.
- It covers the **five interfaces in CLAUDE.md's block**. `VideoDetail` — 22
  fields, the entire `video.info` result — has **no full shape written down
  anywhere** and is checked by neither the TS nor the Dart auditor. That is
  exactly where the live drift landed that item 0b just fixed.
- `type FeedItem = …` is a type alias, so the regex never matches it and the
  union's membership is never verified.

**Done when:** nullability is compared, `VideoDetail` has a written shape that is
checked, and the union's members are verified. Keep the existing "the check can
actually fail" control and add one per new assertion — an auditor that cannot
fail is worse than no auditor.

### 9. Rename `tierAndroidVr`

`sidecar/src/playback/resolve.ts:529` exports `tierAndroidVr()`, a function that
resolves **`VISIONOS`**. `:18` references it by that name too.

`ANDROID_VR` was replaced at ladder tier 1 on 2026-08-18 (F11), and CLAUDE.md
spends a paragraph on how that rename went stale in thirteen places. The literal
token `ANDROID_VR` appears nowhere in `sidecar/src`, so `contract-docs.test.ts`'s
client guard is intact and still fires — but a camelCase identifier is invisible
to it, and this one teaches the retired client to anyone reading the ladder.

Rename to something that says what it does (`tierVisionOs`, or fold it into
`tierPlainAdaptive`'s call site, since all it does is supply `'VISIONOS'` and a
visitor-id retry). While in the file: `:740`, inside `tierProgressive`, throws
`` `${videoId}: the MWEB /player call did not return` `` — that function is only
ever called with the `ANDROID` response, a leftover from when `c53fb54` renamed
`mwebResponse` to `androidResponse`. And `:617` carries
`// yt-dlp does not give us an itag reliably; 0 signals "unknown".` directly
above `itag: null`.

**Done when:** no identifier or message in `resolve.ts` names a client it does
not use.

### 10. Reconcile `architecture.md` §2.2's renderer vocabulary table

§2.2's table is the 2026-08-01 version. CLAUDE.md's is materially wider —
`playlistVideoRenderer`, `shortsLockupViewModel`, the mix panel, `ChipsShelfView`,
station badges. It is dated, so it is exempt from the doc guard, but it is the
table someone reading `architecture.md` in order finds first.

Not a typo fix: read `sidecar/src/parser/vocabulary.ts` and CLAUDE.md's table
together and merge, keeping the dated original as history where it says something
the current one does not.

### 11. Wire the notifications button, or remove it

`app/lib/ui/widgets/topbar.dart` renders a notifications button with a "9+" badge
and `onTap: () {}, // TODO: open notifications`. A rendered control that does
nothing is exactly what `architecture.md` §2.7 argued against when it chose a
disabled captions button over a live dead one:

> A disabled button says "later"; a live one that did nothing would lie.

The badge makes it worse — it asserts there are nine things to see.

**Done when:** it opens something, or it is disabled, or it is gone.

---

## Low priority

### 12. Caption legibility at small render surfaces

Two related pieces, and neither is a renderer problem — it is a size problem that
exists under mpv and under `LibassLayer` alike.

**Previews** are the cheap half. A hover preview runs on a second
`MediaKitEngine` with no `LibassLayer` mounted, so `_isSubtitleVisible` stays at
its `true` default and `hover_preview.dart:298`'s `engine.setSubtitle(ass)`
renders through mpv's `sub-add`. That means the lever is one mpv property —
`sub-scale` or `sub-font-size` on the preview engine. No pipeline work.

**The general case** is a size floor that scales with the render surface, applied
in whichever renderer is active. Worth measuring rather than assuming, because
the two renderers may need different levers to reach the same result: mpv scales
subtitles relative to the window by default, while `LibassLayer` renders at the
document's `PlayRes` and scales down. That measurement is also a good early test
of whether the two-renderer setting (item 13) can hold parity.

The miniplayer redesign to ~600 px shrinks this problem but does not remove it.

### 13. Suppress caption drag by mount point

The drag-lock predicate in `LibassLayer` is `track.positional != true` — a
property of the **track**, not of where the video is being drawn. There is one
`LibassLayer`, mounted once at `app/lib/ui/player_shell.dart:359` outside all
three mount-point branches and positioned by `CompositedTransformFollower`
against `engine.videoLayerLink`, so it follows whatever the video texture
currently is.

Nothing in that path knows whether the video is in the watch page, the
miniplayer or the fullscreen layer. If dragging is to stay disabled in the
miniplayer — and it should, at any size — that has to enter the predicate.

Settle it before the miniplayer redesign rather than after.

### 14. Consolidate the probe entrypoints

Eight probe files across four directories, each env-gated differently:
`ui/auth_probe.dart`, `ui/audio_delay_probe.dart`,
`ui/player/{captions,controls,launch,libass}_probe.dart`, `ui/debug_player.dart`,
and `lib/probe_task19.dart`.

`lib/probe_task19.dart` is **correctly placed** and should stay at `lib/` root —
it and `main.dart` are the only two files in `app/lib` with a top-level `main()`,
and lib/ root is where Flutter convention puts entrypoints. It only reads as
orphaned because nothing says so.

Churn warning: `architecture.md` references several of these by path inside dated
findings, so moving them costs doc edits for tidiness only. Low priority on
purpose.

### 15. A portable parser corpus

`sidecar/fixtures/` is gitignored and must stay that way — it holds raw InnerTube
responses for the real account's home feed, watch history and subscription list.
Committing it publishes viewing history permanently, and git keeps it after a
later delete.

`corpus/` cannot substitute: it is sanitised **DTO output**, and the parser's job
is raw→DTO, so testing the parser against its own output side proves nothing.

So a fresh clone's green `bun run check` is partly hollow. `parser.test.ts:42`
already says so out loud when fixtures are missing — *"with them skipped, a
parser regression is a green suite"* — but that warning lives only in the test
file.

The real fix is a small hand-authored corpus of **synthetic raw renderer trees**:
a dozen nodes covering each vocabulary entry, written by hand, containing no
account data. Committable, portable, and it makes the offline gate mean
something on a machine that has never run `bun run capture`.

Until then, CLAUDE.md's Commands block should say that `bun test`'s parser half
needs `bun run capture` first.

### 16. Persist the members-only preference

`app/lib/ui/members_only_preference.dart` — every feed surface already reads
`membersOnlyVisibleProvider`, its own comment says *"Not persisted yet"*, and
nothing calls `.set()` / `.toggle()`. There is no settings UI to reach it from.

**Blocked on:** an app settings screen. Listed here rather than nowhere, because
the whole point of this file is that work deferred for good reasons and recorded
nowhere is how Task 04 §1 disappeared for two months.

### 17. Two small UI gaps

- `app/lib/ui/player/settings_menu.dart:749` — `//TODO add fps when it is not 30`
- `app/lib/ui/player/shortcuts.dart:147` — `// TODO add end and home for seeking
  to the start and end of the video`

---

## Triggered — read when one of these fires

### 18. Evaluate freezed 4.0.1

**Triggers:** codegen breaks again, **or** the FVM Flutter pin moves off 3.44.9.
Do not pick this up on a quiet day; it is a major version bump with no current
symptom.

The project sits on `freezed: ^3.2.6-dev.1` — a dev prerelease — which declares
`analyzer >=12.0.0 <13.0.0`. `app/pubspec.yaml`'s override block names that
ceiling as the binding constraint: *"the constraint the solver has to respect is
the one freezed declares."*

**freezed 4.0.1 inverts it:** `analyzer >=13.0.0 <15.0.0`, `source_gen >=3.0.0
<5.0.0`, `build >=3.0.0 <5.0.0`, and `freezed_annotation 3.1.0` — the version
already in use. So the optimistic case retires the prerelease pin *and* both
overrides from item 2 in one move.

**Two things that decide it, neither settled:**

1. What 3→4 actually breaks. Read `CHANGELOG.md` for 4.0.0 first; the migration
   guide published on the package page documents 2→3, not 3→4.
2. Whether a `dart_style` exists that accepts analyzer 13.0.x while staying
   under the SDK's `meta 1.18.0` pin. The original failure was never analyzer 13
   as such — it was that analyzer 13.1 needs `meta ^1.18.3` while `flutter_test`
   from SDK 3.44.9 pins `meta 1.18.0`. Only `pub get` on a branch answers this.

**Do item 2 first, separately.** Folding the override test into a freezed
migration means a failure cannot tell you which change caused it — the exact
diagnostic trap the `animated_vector_gen` note exists to prevent.

**Whichever way it goes, rewrite that comment block rather than renumbering it.**
Its central claim becomes false the moment freezed 4 lands. A stale version
number is harmless; a stale causal explanation sends the next person down the
wrong path.

---

## Documentation backlog

These are edits, not investigations. Grouped because they are one sitting.

### 19. Captions: the docs describe an architecture phase 5 deleted

- `CLAUDE.md:428` — *"Captions render through mpv/libass … Flutter draws none."*
  `LibassLayer` calls `engine.setSubtitleVisible(false)` on mount
  (`libass_layer.dart:170`) and paints glyph bitmaps itself with `RawImage`
  (`:969`) and the background/window with `CustomPaint` (`:938`).
  `player_shell.dart:315` says so outright. The bullet's supporting facts are
  inert too: `sub-add` at 12–36 ms, and `retainSubtitle: true` restoring a track
  mpv is not displaying.
- `architecture.md:902` — the same claim, inside §2.9, contradicting that
  section's own later "What phase 5 deleted" subsection.
- **Record the renderer choice as a decision**, per the plan: mpv and
  `LibassLayer` are both supported, user-selectable on the watch page and
  miniplayer, with mpv as the maintained-upstream fallback. §2.9's rejection of
  option B must be **amended rather than removed** — a user-chosen split is
  genuinely different from an automatic one (the user knows which path is live,
  so there is no silent divergence about which ran), but the risk it named
  survives: *a regression in whichever renderer is not selected is invisible*.
  Say so, and say that previews are always mpv because they run on a separate
  engine rather than a separate mount point.
- **Something must pin both paths.** At minimum a test rendering the same
  document through each and asserting neither is silently empty. Without it the
  project ships the failure mode §2.9 already paid for once.

### 20. `architecture.md` §2.6 and §2.7

- §2.6: *"There is no CC button on a preview. Captions do not exist anywhere in
  this app yet."* Both halves false — `hover_preview.dart:275-308` implements
  `toggleCaptions()` and `media_tile.dart:503-513` renders the button. **Rewrite
  rather than delete**: the paragraph explains *why* there wasn't one, and the
  replacement should record the current decision (previews fetch with
  `allowFallback: false`, so a hover never pays for the fallback's second
  `/player`).
- §2.7: *"Captions are a disabled button, not a reserved gap."*
  `controls.dart:651`'s own comment says the opposite, and the button is live.

### 21. Where the mpv stream options actually live

F15 and §2.4 both name `mpv-options.ts` and say it *"sets only `request_size`"*.
`sidecar/src/playback/mpv-options.ts` is imported by nothing but
`src/probe-playback.ts`. The shipped path reads
`app/lib/ui/debug_constants.dart:22` — `request_size=…,short_seek_size=…`, both
options, from a file named `debug_constants` — applied at `engine.dart:308`.

Harmless in effect (F15 measured `short_seek_size` as present-but-irrelevant in
the bundled artefact), but the doc names the wrong file and the wrong option set.

### 22. Document the build and setup path

None of the four root `.bat` scripts appear in any doc, and each carries
something load-bearing:

- `setup.bat` runs `build_runner build --delete-conflicting-outputs`. `*.g.dart`
  and `*.freezed.dart` are gitignored, so a fresh clone does not compile until
  codegen runs — and CLAUDE.md's Commands block has no codegen step, despite
  devoting ~40 lines to the build_runner failure history.
- Flutter is pinned via FVM to **3.44.9** (`app/.fvmrc`). CLAUDE.md's
  `cd app && flutter run -d windows` bypasses the pin. **Document `fvm flutter`
  as the correct form** — this project has been bitten twice by toolchain
  version drift, and a documented command that silently uses the wrong SDK is
  the same shape of trap.
- `setup.bat` also runs `flutter analyze` and `dart analyze` on
  `app/tool/rill_lints`, a real custom analyzer plugin shipping a
  `no_color_literals` rule scoped to `lib/ui/`. Eight task specs require
  "`flutter analyze` clean"; CLAUDE.md lists no app analyze step at all.

Fold the script surface itself into item 1's output rather than documenting the
`.bat` files that are about to be replaced.

### 23. Document the vendored libass DLLs

`app/windows/libass_bundle/` holds **20 committed MSYS2 MINGW64 DLLs (~11 MB)** —
libass 0.17.5 plus freetype, harfbuzz, fribidi, fontconfig, glib, iconv, brotli,
libstdc++, libwinpthread, zlib — globbed into the build at
`app/windows/CMakeLists.txt:93` and loaded by
`app/lib/ui/player/libass/dll_search.dart`.

§2.9 records adopting "an own FFI binding against libass 0.17" but never that it
means vendoring and shipping a DLL tree.

**Write it as a decision, not an inventory**, because §2.4 rejected vendoring a
newer libmpv on the grounds that it *"would mean owning a binary and an
unexercised API-version surface"* — and the project now owns twenty. That is not
a contradiction, libass is a different bet from libmpv, but the doc should say
why the earlier reasoning does not govern here. Include the fribidi LGPL-2.1
note, which is the one with distribution consequences, and point at
`THIRD_PARTY_LICENSES` (1566 lines, every package, version, licence and MSYS2
recipe — the compliance work was done properly and is referenced from nowhere).

### 24. Document the configuration surface

26 environment variables are read across the two processes; CLAUDE.md documents
one (`YT_COOKIE`).

Sidecar: `SIDECAR_PLAYER_RESPONSE_TTL_MS`, `SIDECAR_PLAYER_TTL_MS`,
`SIDECAR_STORYBOARD_TTL_MS`, `SIDECAR_CAPTIONS_NEGATIVE_TTL_MS`,
`SIDECAR_LOG_LEVEL`, `YT_DLP_PATH`, `YT_DUMP_ASS`, `YT_VIDEO_STANDARD`, plus
`YT_SEARCH_QUERY` / `YT_ARTIST_QUERY` in `capture.ts`.

App: 19 `RILL_*` probe and override variables, including `RILL_STREAM_LAVF_O`,
which replaces the mpv option string for a run.

Four are cache TTL overrides whose caches are themselves partly undocumented —
the `/player` response cache (5 min, 64 entries,
`innertube/player-response.ts:28`) and the player-JS/decipher cache (30 min,
512-entry `n` memo, `innertube/player.ts:44`). The 30 s base-browse cache and the
6 h storyboard cache *are* documented, so this is a specific gap rather than a
blanket one.

### 25. Mark the three specified-but-absent RPC methods

`feed.watchLater` (`protocol.md:171`), `feed.history` (`:172`) and
`video.comments` (`:197`) have no handler in `rpc/server.ts`. They are intended
future surfaces, not phantom methods — Watch Later and history are reachable
today only as writes, and comments are a planned addition.

Mark them the way `playlist.get` already is, in the same voice:

> **`playlist.get` is specified and does not exist.** … The row stays because the
> shape is still the intended one, but it is marked so the table cannot be read
> as a list of things that work.

This also guards against the thing that nearly happened:
`feed_controller.dart:111` already cites `feed.history` as "already specified in
protocol.md §3.2", which is a spec row one step from being treated as an
implementation.

### 26. Document the layer-linked caption mount

§2.8 records "one texture, three mount points". Its counterpart is undocumented
and it is the fact that makes item 13 what it is: **one caption layer, three
mount points, positioned by `CompositedTransformFollower` against
`engine.videoLayerLink`** (`player_shell.dart:345-362`).

That single sentence is what tells the next person why per-mount-point renderer
selection is expensive — it means unmounting or hiding `LibassLayer` and flipping
`engine.setSubtitleVisible` in exact antiphase at every route transition, which
is §2.9's draw-twice / draw-nothing bug on a hot path. Right now the reasoning
lives only in `player_shell.dart`'s comments, which explain the `OverflowBox` and
the clipper in detail but never state the top-level shape.

### 27. Doc-internal errors

Trivial, batch them:

| Where | Problem |
|---|---|
| `protocol.md:723` | §3.9 "Playlists — the save dialog" sits between §3.4 and §3.5 |
| `protocol.md:1059`, `architecture.md:1082` | "Eight numbers per *track*" — `CaptionLayout` has **eleven** fields (`captions/style.ts:150-168`); protocol.md's own example two lines below shows all eleven |
| `architecture.md:1286` | The `yt-dlp not installed` row's Symptom cell is scrambled: *"Ladder is four rungs; the videos tier 4 exists for fail as \"Unavailable\" with nothing naming the cause"* |
| `architecture.md:890` | Cites "§2.10's sample" for the 0/23-styled-tracks measurement; that sample is in the unnumbered "Who draws a caption" section, while §2.10 is "Drag Lock" |
| `protocol.md:201` | `search.query`'s summary row omits `artist`, which §3.3 and `types.ts` both carry |
| `architecture.md:239` | §2.4 says the two URLs merge "via `--audio-file`"; F15 measured `audio-add … select` |

### 28. Add pointers to CLAUDE.md's Deferred list

Two lines, not copies — the detail stays where it was written:

- **Task 19 §14 lists six open caption items**: stale in-flight render flash on
  drag-commit, windowed/theatre one-frame flicker, `probe-task19.ts` unable to
  guard the window-vs-video coordinate regression class, dead
  `PlaybackEngine.subtitleTextStream` (`engine.dart:123,414` — still present,
  still unconsumed), no karaoke-classified track ever rendered end to end, and a
  styled track's authored background colour not painted.
- **`docs/todo.md` is the live backlog.**

### 29. Document the client-side view-count rule

`protocol.md` §3.3 documents the sidecar half thoroughly — `viewCount`, the
`originalViewCount` `"0"`-on-18-of-24 trap, `exactCountFromText` refusing rounded
strings. What is undocumented is the **client** rule: when the exact number is
shown versus the rounded string, and where. That belongs in `architecture.md`'s
watch-page section, not in `protocol.md`.

There is no Task 27 — the `scratch/task27-*.ts` filenames are a naming artefact,
not a missing spec.
