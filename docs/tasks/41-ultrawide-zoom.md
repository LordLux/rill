# Task 41: Ultrawide zoom and automatic black-bar removal

**Read first:**
- `CLAUDE.md`, especially the hard invariants. Note invariant 9: never poll `NativePlayer.getProperty` from the UI isolate.
- `app/lib/data/playback/engine.dart` and `swapping_engine.dart`:
  - the surface widgets (`videoSurface()`, `videoWidget()`);
  - how the second player's two `Video` widgets are stacked.
- `app/lib/ui/player/libass_layer.dart` and `caption_geometry.dart`: how captions find the video's rectangle.
- `app/lib/ui/player/shortcuts.dart`, for three reasons:
  - the key table;
  - why Alt is excluded;
  - `textEntryHasFocus` and the Space rule.
- The settings page from Task 40, and how a section is registered there.
- media_kit's `Player.screenshot`, and mpv's `screenshot-raw`.
- `PlaybackSource.storyboardTemplate` (F8).

**The feature.** The user watches on wide screens. Many videos carry solid black bars: a film letterboxed in 16:9, a 4:3 video pillarboxed, or both at once. The player should find those bars and zoom the picture until they are gone. That removes all four bars when the content's shape matches the player, or the two it can when it doesn't. There are also fixed zoom modes, each with keyboard shortcuts.

**Decisions already made by the user:**
- **The zoom is done in Flutter, not in mpv,** so captions are left completely untouched.
- **Detection scans live frames** while the video plays, at a frequency the user sets, from twice a second to once a minute. Storyboard images are measured for data only, since they are low resolution and compressed.
- **Every new video starts back at the default,** even a video watched before. Nothing is remembered per video.
- **Keys:** `A` auto, `R` reset, `X` cover, `S` 32:9, `W` 21:9, `Z` zoom in 10%, `Shift+Z` zoom out 10%. `C` stays captions. Alt stays excluded: on Windows, Alt+letter belongs to menus. Shortcuts and aspect ratios are both customisable.
- **The settings page comes first** (Task 40). The zoom's configuration lives there, and the player menu gets the quick controls.

---

## 1. Measure first

Report this before building anything.

### a. Grabbing frames while playing

Grab the active player's current frame: raw, without captions (`screenshot-raw video`, or media_kit's `screenshot` with no format). Analyse it in a background isolate. Measure on this machine, on a release build, with videos at 1080p60 and 2160p60 HDR, scanning every 0.5 s, 1 s and 5 s:
- the longest UI-isolate gap while a grab is in flight;
- CPU use;
- the playing player's dropped frames (the engine's drop count), with and without scanning;
- the time from grab to answer.

Say whether a downscale before analysis is possible or needed.

### b. Storyboards, for data only

On the same videos, run the same detection on the storyboard frames, and compare its bars with the live scan's. Report the numbers. The user decided storyboards are not the method; this is so the decision has data.

### c. The videos

Pick public examples of each. The agent chooses them; list their ids in the report.
- a 2.39:1 film letterboxed in 16:9;
- 4:3 content pillarboxed in 16:9;
- windowboxed content (all four bars);
- burned-in subtitles inside the bottom bar;
- long dark scenes and fades to black;
- a video whose aspect changes, such as IMAX sequences;
- a normal 16:9 video;
- an HDR video.

### d. The noise in "black"

How dark are real bars, after compression? Measure the brightest pixel inside true bars, and the darkest real content next to them. Use the numbers to set the default threshold.

## 2. The detection rules

- **A side counts as a bar only if every row or column in it is solid black,** within the measured threshold. A bar with subtitles or a logo in it is not a bar, so it is never cropped.
- **No decision from frames that are mostly black,** such as fades or dark scenes.
- **Zoom in only when several scans in a row agree;** three is a starting point, so state the number you choose. **Zoom out on the first scan** that finds content in a cropped area. It must never hide real content for long.
- **The crop only removes bars.** It never cuts into content.
- **Scan only while it can matter:** while the video is playing and on screen, on the active player only, pausing while the video is paused.
- **The frequency** is the user's setting, from 0.5 s to 60 s. Choose the default from §1.

## 3. The modes, done in Flutter

The zoom is a transform and a clip **inside the engine's own surface widget.** Both of the second player's surfaces sit inside it, so the watch page, fullscreen, theatre and the miniplayer all follow, and no consumer changes.

| Mode | Default key | What it does |
|---|---|---|
| Original | `R` | No zoom (today's fit) |
| Auto | `A` | Crop to the detected content, then fit it in the player |
| Cover | `X` | Fill the player, cropping the overflow, centred |
| 32:9 | `S` | Crop the frame to 32:9, centred, then fit |
| 21:9 | `W` | Crop the frame to 21:9, centred, then fit |
| Custom ratios | user-set | Each is a ratio crop, like the two above |
| Zoom in / out | `Z` / `Shift+Z` | 10% steps on top of the current mode, centred |

- **Captions are untouched.** Captions, and anything else that follows the video's rectangle, keep exactly the position they have without zoom. Test it.
- **Change zoom smoothly** (about 200 ms), with no flash or jump of the surrounding layout.
- **The default for each new video** is *Auto* when the automatic-detection setting is on, and *Original* when it is off. A key or a menu pick changes the mode for this video only, and the next video starts from the default again.
- **Same video, same zoom.** Quality switches, second-player swaps, recovery reopens and the audio-only toggle keep the current mode.

## 4. The keys

- **The defaults** are as in the table. They obey the same rules as every other player key: no Ctrl, Alt or Win, and nothing while a text field has focus.
- **A setting turns all the zoom keys on or off.**
- **Rebinding in the settings page:**
  - a key already used by the player is refused, with a message naming what uses it: `C`, `K`, `J`, `L`, `M`, `F`, `T`, `I`, `Shift+N`, `Shift+P`, digits, `,` and `.`, Space and the arrows;
  - so is a key another zoom binding already uses.

## 5. Settings and the menu

- **A *Zoom* section on the settings page** (Task 40), with:
  - the feature on or off (the master switch);
  - automatic detection on new videos, on or off;
  - the scan frequency, 0.5 s to 60 s;
  - the black threshold, under "Advanced";
  - the zoom keys on or off, and the key bindings;
  - the custom aspect ratios: add, name and remove them, each with an optional key.
- **A *Zoom* page in the player's settings menu,** for quick changes:
  - the modes, with the current one ticked;
  - the custom ratios;
  - the current zoom-in percentage, with a way back to 100%.

  It appears only while the feature is on.

## 6. Tests

- **The geometry,** as unit tests: crop, fit, cover, ratio crops and zoom steps, for wide and narrow players.
- **Detection on synthetic frames:**
  - clean bars are found;
  - bars with noise below the threshold are found;
  - a bar holding subtitles is not a bar;
  - an all-black frame changes nothing;
  - zooming in waits for the agreeing scans, and zooming out happens at once.
- **Resets and continuity:**
  - a new video resets the mode, including a return to a video seen before;
  - a quality switch and a second-player swap keep it.
- **Captions:** the caption layer's rectangle is the same with and without zoom.
- **Keys:** each default works; a conflicting rebinding is refused; nothing fires while a text field has focus.
- **Settings:** the master switch off removes the menu page, stops all scanning and resets the picture.

**Mutations,** each must fail a test, with the output pasted:
1. zoom in on a single scan;
2. let an all-black frame trigger a zoom;
3. keep the zoom across a video change;
4. apply the transform to the caption layer too.

## 7. Hand-off to the user

On a release build, with the videos from §1:
1. Turn on automatic detection. The letterboxed film loses its bars within a few scans, and the windowboxed one loses all four where the shape allows. The dark scenes don't make it jump, and the subtitles in the bar stay visible.
2. Try every key, a custom ratio with its own key, and a refused rebinding.
3. Open the next video: it starts at the default.
4. Do a quality switch while zoomed: the zoom stays.
5. Play the 2160p60 HDR video with scanning every 0.5 s: no visible stutter.
6. With Narrator started after Rill, open the *Zoom* menu page and change mode: 0 `AXTree` lines in the log.

## 8. Docs

- **`architecture.md`:** a finding with §1's measurements, and the zoom's design (where the transform lives, and why captions are unaffected).
- **`docs/configuration.md`:** any switch added for the probes.
- **`todo.md`:** any new number comes from the **"Next number" line as it is on disk at that moment**, bumped in the same edit.

---

## Definition of done

- §1's measurements are in the report and in a finding
- Detection, the modes, the keys, the settings section and the menu page are built as specified, with tests and the four mutations
- `.\rill check` and `cd sidecar; bun run check` green, raw output pasted
- The §7 hand-off given to the user

## Out of scope

- Zoom done in mpv (`video-zoom`, `panscan`, `video-crop`).
- Remembering a zoom per video.
- Hover previews.

## Stop conditions

- **Frame grabbing drops frames, or stalls the UI isolate,** at the default frequency on this machine. Report the numbers before choosing a workaround.
- **The Flutter transform breaks the second player's swap or the video surface hand-over.** Report it.
- **Captions move with the zoom,** and keeping them still needs a change to the caption layer's geometry. Report it before changing that.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Say plainly what you ran and what you handed to the user.
- No raw responses or frame dumps in commits.
- No AI attribution in commits, issues or PRs.
- Open a PR. Whether it gets the release label is the user's call.
