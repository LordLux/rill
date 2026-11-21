# Task 39: Audio tracks: play the original by default, and let the viewer choose (todo 84, points 1 and 2)

**Read first:**
- `CLAUDE.md`: the hard invariants, and the DTO block.
- `docs/todo.md` item 84. It is this task's spec, together with what follows.
- `sidecar/src/playback/resolve.ts`: `rankAudio`.
- `sidecar/src/parser/player.ts`: how adaptive formats become `PlayerFormat`.
- `docs/protocol.md`: `playback.open`, `PlaybackSource`, and `preload`.
- `docs/architecture.md`:
  - F59 and F60, because since #29 the audio is the file mpv plays and the picture is added to it;
  - the second player's design, §2.16.
- `app/lib/data/playback/swapping_engine.dart`.

**The problem.** A video with several audio tracks (often dozens of YouTube's automatic AI dubs) can open in a foreign language. There is no way to change the track. `rankAudio` ranks by DRC, then channels, then bitrate. It knows nothing about languages, so the dub with the highest bitrate wins.

---

## 1. Measure first

Report this before building anything. No sign-in is needed, and you can run it yourself.

1. **Choose four videos:**
   - `MLgrNktS67c` (item 84's report);
   - a video with official multi-language tracks uploaded by the creator;
   - a video with only automatic dubs;
   - a single-track video.
2. **For each video, on every ladder tier** (the InnerTube clients, yt-dlp, the itag 18 floor), record:
   - which track fields each adaptive audio format carries: `audioTrack` (display name, id, the default flag), the URL's `xtags` (original, dubbed or auto-dubbed, and the language), and anything else;
   - how many audio tracks there are;
   - whether every track's URL needs its own signing (the `n` parameter, decipher), and what that costs.
3. **What YouTube marks as the default.** Record what it marks anonymously, and whether that changes with the request's language (`hl`). If the default can be a dub in the requester's language, rank the **original** structurally, not by the default flag.

## 2. The original by default

Rank the original track first, then YouTube's default, then today's order. Use the structural marker §1 found; never match a display name.

- **Tests:** a fixture with several tracks, in which a dub has a higher bitrate than the original. The original is ranked first.
- **Mutation:** rank by bitrate alone, and the test fails.

Do this on every tier that carries tracks. Say plainly which tiers carry none.

## 3. The track list, and switching

1. **Contract.** `PlaybackSource` gains the list of audio tracks:
   - an id;
   - YouTube's display name;
   - the original, dubbed and auto-dubbed markers;
   - which track is playing.

   Choosing a track either adds a parameter to `playback.open` (say `audioTrackId`) or needs a new method. **Sign on demand:** signing dozens of URLs up front is wasteful. Specify it in `protocol.md` first.
2. **Restate the DTO everywhere it lives:**
   - `protocol.md`;
   - `types.ts`;
   - `CLAUDE.md`'s DTO block;
   - the Dart model;
   - the corpus sanitiser.

   `contract-docs.test.ts` checks the first three. Add a sanitised corpus entry with several tracks.
3. **Switching in the app.** Since F60 the audio is the main file, so a track change replaces the file mpv plays.
   - **Carry it with the second player's swap,** like a quality switch: the same video with new audio, opened in the standby at the clock, then swapped.
   - **The fallback** is a reopen at the position.
   - **Resolve with `preload: true`,** so no second session is registered and the watch history is not doubled.
   - **Rules:**
     - the clock never goes back;
     - a paused video stays paused;
     - captions continue;
     - the volume is unchanged.
4. **The choice sticks** for that video, across quality switches, recovery reopens, the audio-only toggle and the session restore. Add the track to the snapshot.
5. **The menu.** The *Audio track* placeholder in `settings_menu.dart` becomes a real page.
   - It appears only when there is more than one track.
   - Rows use YouTube's display names, the original is marked, and the current track is ticked.
   - Narrator reads each row's name and its state.

## 4. Tests

- the ranking, with its mutation (§2);
- the contract and corpus entry for the new fields;
- choosing a track in the menu asks for that track, and the swap carries it, with the position kept;
- the choice survives a quality switch and the audio-only toggle;
- on one track, no *Audio track* entry appears.

**Mutations,** each must fail a test, with the output pasted:
1. drop the chosen track on a quality switch;
2. let the swap restart the clock at 0.

## 5. Hand-off to the user

On a release build:
1. `MLgrNktS67c` plays its original English audio.
2. On a video with several tracks, switch to another language mid-video, then back. Each time:
   - the position holds;
   - the sound changes within a few seconds;
   - nothing restarts.
3. Switch quality after choosing a track: the track stays.
4. Turn audio-only on and off: the track stays.
5. With Narrator on, open the *Audio track* page: each row is read with its name and whether it is selected. The `AXTree` count in the log is 0.

## 6. Docs

- **`architecture.md`:** a finding with §1's measurements.
- **`protocol.md`:** the new fields and how to choose a track.
- **`todo.md`:** narrow item 84 to point 3 (the language preferences), which waits for the settings page (item 69). Take any new number from the **"Next number" line as it is on disk at that moment**, and bump it in the same edit.

---

## Definition of done

- §1's measurements are in the report and in an `architecture.md` finding
- The original is ranked first on every tier that carries tracks, with a test and the mutation
- The track list is in the contract, specified, guarded, with a corpus entry
- The menu switches tracks through the swap, with the reopen as the fallback, and the choice sticks
- `.\rill check` and `cd sidecar; bun run check` green, raw output pasted
- The §5 hand-off given to the user

## Out of scope

- Item 84 point 3: the preferred-languages setting and reading the account's own setting.
- Audio channels (mono, stereo, surround) and any audio filters.

## Stop conditions

- **A tier carries no track information**, and is the tier that usually wins. Report before working around it.
- **Signing a single chosen track needs something unusual,** such as a second `/player` call per track with a cost you cannot bound. Report it.
- **The swap cannot carry an audio change without changing F60's or the second player's semantics.** Report it; use the reopen meanwhile.

## Report rules

- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Say plainly what you ran and what you handed to the user.
- No raw `/player` response in commits, tests or docs; the commit hook refuses them. Use sanitised fixtures only.
- No AI attribution in commits, issues or PRs.
- Open a PR. Whether it gets the release label is the user's call.
