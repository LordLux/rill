# Todo

Work that is agreed but not done. Each entry carries enough context to be picked
up cold: what the problem is, where it lives, and what "done" means.

This is not a task spec archive — `docs/tasks/` is that, and those files record
what was asked for at a moment in time. This file is the live backlog, and an
item leaves it when the work lands.

**Ordering is by section, not by line.** Within a section nothing is ranked.

**Numbers are permanent.** Other files cite items by number, so a finished item
is deleted and its number is not reused; gaps are expected.

**Next number: 36.** A new item takes it, and the same edit bumps this line.
The highest number still in the file is not a substitute — once that item is
finished and deleted, it would hand the same number out twice.

---

## Now

Nothing here right now.

---

## Soon

### 33. Playback opens paused while media_kit says it is playing

Seen 2026-09-17 in a release build that had been running for a while, and
once under a debugger; not reproduced in a fresh launch. A video opened from a
tile shows its first frame with the clock at 0:00 while the controls show
*pause* — media_kit's `playing` is `true` — and hover previews do not start
(they are suppressed while the shell reports playing). One play/pause press
starts the video and flips the button to *play*; a second pair resyncs them,
until the next video. Previews that do start show one frame and stop.

The inversion is mechanical once mpv is really paused: `Player.playOrPause()`
flips media_kit's own `state.playing` and sends `cycle pause` to mpv, so if
the two already disagree, each press keeps them disagreeing. So the question is
what leaves mpv paused (or stalled) after `open()` set `pause=no` — media_kit
ignores mpv's `pause` events while `isPlayingStateChangeAllowed` is false,
which is one way a change can go unseen.

A lead, not a cause: this machine's audio devices hotplug every ~15 minutes
(WASAPI `OnDeviceStateChanged`, seen in both engines' logs), and a freshly
launched app, which has not been through any, behaved. A stalled audio output
would hold an external-audio stream at 0:00, but would not by itself explain
the inverted button.

Next time: run with `RILL_MPV_LOG=<path>` and note the time it happens. The log
has the app's calls, media_kit's belief and mpv's real `pause` side by side.

**Done when:** the cause is known and fixed, or recorded if it is outside the
app.

---

## Low priority

### 35. Check the other `media_kit_video` bugs a blind review reported

While confirming F28, a Gemini 3.1 Pro agent reviewed the unmodified 1.3.1
Windows code with no context and did not find F28 — it reported these four
instead. None is verified; the plugin is vendored now
(`third_party/media_kit_video`), so any that hold can be fixed in place.

1. `video_output_manager.cc` — `Create`/`SetSize`/`Dispose` run on detached
   threads capturing `this`; a plugin destroyed first (hot restart, shutdown)
   is used after free.
2. `video_output.cc`, `~VideoOutput` — the promise it waits on is only
   fulfilled inside `if (texture_id_)`, so a `VideoOutput` disposed while
   `texture_id_` is 0 waits forever. **Read and looks real.** `Resize` leaves
   `texture_id_` at 0 from the unregister until the new texture is published —
   upstream's window, which the F28 patch extends only by the insert.
3. `~VideoOutput` posts `mpv_render_context_free` and returns; an update
   callback firing in between calls `NotifyRender` on a freed object.
4. `Resize`'s unregister callback captures `this` by reference and may run
   after the object is gone (it checks `destroyed_` only after locking a member
   mutex).

Each touches disposal, which the app does on every preview hover-out, so the
cheap test is the same one F28 used: a delay that widens the window, and a
probe that exercises it.

**Done when:** each is confirmed and fixed in the vendored copy, or ruled out
with the reason written here.

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

### 30. Decide what to do about the exit-time `0xC0000602`

The cause is known and recorded as `architecture.md` F27: at DLL unload,
`flutter_inappwebview_windows` releases a static `Compositor` that CoreMessaging
can no longer serve, and the process fails fast. It happens on some exits, not
all, after the app has finished shutting down, so nothing is lost — the cost is
an Application-log crash event. Low priority for that reason.

Two ways out, neither tried:

- **Upgrade the plugin.** The app is on `flutter_inappwebview_windows` 0.6.0
  (via `flutter_inappwebview` 6.1.5). Check whether a later release destroys the
  compositor at plugin teardown instead of in a static destructor.
- **End the process without DLL teardown.** After the engine has shut down, the
  runner (`app/windows/runner/main.cpp`) would call
  `TerminateProcess(GetCurrentProcess(), exitCode)`. That skips *every* DLL's
  exit-time cleanup, not just the plugin's — confirm nothing (mpv, the sidecar
  pipe, settings writes) relies on it first.

Before choosing, confirm the other three logged crashes (2026-09-09 04:01 and 04:17,
2026-09-10 18:40) are the same one as 17:41 — only one dump was read. If a dump
is taken for that, it holds the session cookie: read it, delete it, never
attach it.

The release log now records it: the launcher's last line reads
`CRASHED with code 0xC0000602`. On 2026-09-17 two of two ordinary window
closes of a scratch release build ended that way, as did the user's own close
of a long-running release app and 5 of 5 `RILL_CONTROLS_PROBE` exits
(`exit(0)`) — more often than the Application log's four events suggested,
so "some exits" is closer to "most".

**Done when:** one of the two is done and a stretch of closes leaves no
`0xC0000602` event, or the crash is accepted and F27 says so.

### 32. Local crash capture with Crashpad

Nothing inside the process can catch the crashes seen so far. A fast fail
(`0xC0000409`, `0xC0000602`) skips every in-process handler, and the engine's
`abort()` is its own statically linked copy, so neither
`SetUnhandledExceptionFilter` nor a `SIGABRT` handler in the runner sees it.
The release log (`architecture.md` §2.11) now records *that* a crash
happened and its code, and whatever was printed before it — but not the stack,
which is what named the cause of F28.

Found 2026-09-17: `HKCU\Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\rill.exe`
exists with `DumpType = 2`, so every rill crash — the exit-time one of item 30
included — currently writes a **full** dump, with the session cookie, to
`%LOCALAPPDATA%\CrashDumps`. That dump is how F28 was solved, and it is also a
cookie on disk after every close. **Kept deliberately (decided 2026-09-17)**
until this item lands: the stack is worth more than the risk, and the rule
stands — read a dump, then delete it, never attach it.

Crashpad — directly, or through `sentry-native` with uploading disabled — runs
an out-of-process handler and registers a WER runtime exception module
(`WerRegisterRuntimeExceptionModule`), which *is* called for fast fails. It
writes a minidump to a folder the app chooses.

**The dump is the problem to design around.** A minidump can carry the session
cookie (see item 30). So: symbolise it into a text stack as soon as it exists —
`flutter_windows.dll.pdb` ships in the FVM engine artefacts, and the runner's
PDB comes from the build — then delete the dump, and keep only the text. The
symbolising step needs those PDBs at hand, which a user's machine does not
have; decide whether that happens on the next launch against bundled PDBs, or
the dump is kept briefly and handed over deliberately.

Also decide the native build: Crashpad's handler is a separate executable that
ships beside `rill.exe`.

**Done when:** a forced fast fail in a release build leaves a symbolised stack
in the app's data directory and no dump on disk.

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
already in use. So the optimistic case retires the prerelease pin in one move.
(The `source_gen`/`build` overrides it would also have made unnecessary are
already gone — tested out 2026-09-16, when the solver picked identical versions
without them.)

**Two things that decide it, neither settled:**

1. What 3→4 actually breaks. Read `CHANGELOG.md` for 4.0.0 first; the migration
   guide published on the package page documents 2→3, not 3→4.
2. Whether a `dart_style` exists that accepts analyzer 13.0.x while staying
   under the SDK's `meta 1.18.0` pin. The original failure was never analyzer 13
   as such — it was that analyzer 13.1 needs `meta ^1.18.3` while `flutter_test`
   from SDK 3.44.9 pins `meta 1.18.0`. Only `pub get` on a branch answers this.

**The analyzer plugin is not a reason to do this.** The 2026-09-16 lint
investigation first suspected the pinned SDK's Dart 3.12.2 (dart.dev dates
analyzer plugins to 3.13) and considered moving the pin, which would have
fired this item's second trigger. It was not the cause — the plugin loads on
3.12.2, and the missing diagnostics were a timing race that happens on 3.13.2
too (`app/tool/rill_lints/README.md`). So the pin has no pressure on it from
that side; only the triggers above apply.

**Change one thing at a time.** Try freezed 4 on its own, not together with a
Flutter pin move or any other dependency change: a failure has to be able to
tell you which change caused it — the exact diagnostic trap the
`animated_vector_gen` note exists to prevent.

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

30 environment variables are read across the two processes; CLAUDE.md documents
one (`YT_COOKIE`).

Sidecar: `SIDECAR_PLAYER_RESPONSE_TTL_MS`, `SIDECAR_PLAYER_TTL_MS`,
`SIDECAR_STORYBOARD_TTL_MS`, `SIDECAR_CAPTIONS_NEGATIVE_TTL_MS`,
`SIDECAR_LOG_LEVEL`, `YT_DLP_PATH`, `YT_DUMP_ASS`, `YT_VIDEO_STANDARD`, plus
`YT_SEARCH_QUERY` / `YT_ARTIST_QUERY` in `capture.ts`.

App: 23 `RILL_*` probe and override variables, including `RILL_STREAM_LAVF_O`,
which replaces the mpv option string for a run, and `RILL_MPV_LOG=<path>`
(added 2026-09-17, `data/playback/mpv_log.dart`), which writes both players'
calls, media_kit's state, mpv's real state and mpv's `v` log to one file.
`RILL_LOG_CAPTURE=0`, `RILL_LOG_FILE` and `RILL_LOG_TEST` belong to the
release log (`architecture.md` §2.11).

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
