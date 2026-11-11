# Task 37: The home feed's members shelf and the missing members badge

**Read first:**
- `CLAUDE.md`: hard invariants 1, 4 and 6, and the badge rules;
- `docs/protocol.md`: `VideoItem.isMembersOnly`, and the `VIDEO_MEMBERS_ONLY` section;
- the header comment of `sidecar/src/parser/feed.ts`;
- `CONTAINERS` in `sidecar/src/parser/vocabulary.ts`;
- `scanBadges` in `sidecar/src/parser/text.ts`;
- `app/lib/ui/widgets/tile_badges.dart`.

## The reports

The user reported these on 2026-11-10, on v0.26.0, signed in in the app with his own account. That account has several channel memberships.

1. **No members pill.** Members-only videos no longer show the green "Members only" pill on their tiles. Example: JerryRigEverything's "Our Newest Employee is not even Human - (MEMBERS ONLY)" sits on the home page with no pill.
2. **One channel crowds the home page.** For weeks, every load of the home grid has shown 5 to 9 tiles from Linus Tech Tips. youtube.com's home page, for the same account, shows far fewer.
3. **The members content is gone.** "The members shelf doesn't show members-only stuff anymore."

## The orchestrator's hypothesis (unverified, from a screenshot)

All three may have **one cause**.

**What the screenshot shows.** Twelve of the first fifteen tiles have **no view count** and are **old** (three weeks to a year):
- two from MIMI, one of them titled 「メンバーさんへ」 ("to members");
- three from CGP Grey;
- two of Markiplier's "MMMMM";
- four from LTT ("Extras", "Why is WAN Late", "Tech Roulette");
- the JerryRigEverything members video.

That looks like YouTube's **members-only shelf**. youtube.com shows it as a single row.

**What the parser does with it.**
- **It flattens the shelf into the grid.** `richShelf` and `richSection` are containers, so their tiles become ordinary grid items with no sign of the shelf they came from.
- **It no longer reads the members marker.** `scanBadges` reads `thumbnailBadgeViewModel`, `metadataBadgeRenderer` and the time-status overlay. A tile that now marks members-only some other way would be missed: a `badgeViewModel` in a lockup's metadata rows, for example.

**Confirm or refute this before building anything.**

---

## 1. Measure, without any raw response leaving the machine

The account with the memberships is the user's own, signed in in the app. Captures made with `YT_COOKIE` use the burner account, which has no memberships, so they cannot show this.

1. **Add a names-only shape dump.** It works like `RILL_COOKIE_DUMP`: a switch (say `SIDECAR_FEED_SHAPE=1`) makes the sidecar, which is the only place renderer trees live (invariant 6), write a file for the home page's first page and each continuation.
   - Never write it to stdout; stdout is protocol only.
   - Write it to `%TEMP%` or the release log.
2. **What the dump contains:**
   - the tree of renderer names, from the page down to each tile;
   - every shelf or section header: its renderer and its title text;
   - for each tile:
     - its renderer;
     - the parser's verdict (mapped, stripped or unknown);
     - whether it has a view count;
     - every badge-like node under it, as renderer name, style, icon name and label text.
3. **What it never contains:** video titles, video or channel ids, URLs, thumbnails, avatars, or anything from `response-context`. Document the switch in `docs/configuration.md`.
4. **Hand the user exact steps** for a release build:
   - open the home page;
   - scroll through two continuations;
   - do this on three launches;
   - send back the dump files.
5. **Report from the dumps:**
   - where the tiles with no view count sit: in which shelf, with what title and renderer;
   - how a members-only tile marks itself now (renderer, style, icon);
   - which other shelves the home page carries, and how many tiles each one adds to the flattened grid;
   - for the top channels, how many of their tiles come from shelves and how many from the main grid.

**Stop and report if the hypothesis is wrong.** Do not fix anything until the measurement explains all three reports, or says which of them it does not explain.

## 2. The members pill

Once §1 has shown the marker:

- **Read the new marker** without breaking the old ones. Members-only stays a **flag** (`isMembersOnly`), never a `"Members only"` string in `badges[]`. That is the existing rule; keep it.
- **Check the other surfaces.** The same tile parser feeds them, so check one members-only video in search results, in the subscriptions feed, and on the watch page (the members slate, `VideoDetail.isMembersOnly`).
- **Tests:**
  - a synthetic tile built from the measured shape (renderer names and styles only, no real titles or ids);
  - the existing badge tests still pass;
  - **mutation:** removing the new branch fails a test.

## 3. The shelves: report the options, do not build

Flattening the shelves is what lets one channel crowd the grid.

**Report the options.** For each, say what it costs, using what §1 found:

- **A. Titled rows.** Shelves become titled rows inside the grid, as on youtube.com. This changes the `FeedPage` DTO, so it touches:
  - `protocol.md`;
  - `types.ts`;
  - `CLAUDE.md`'s DTO block;
  - the Dart model;
  - the corpus;
  - the feed UI.
- **B. A members chip.** The members shelf stays off the main grid, and its tiles go to a "Members" chip or page instead.
- **C. Flatten, with a shelf label.** Keep flattening, but tag each tile with the shelf it came from, so the UI can at least mark it.
- **Anything §1 suggests** that is better than these.

**The user decides.** Build only after he has picked one; that is a separate step.

## 4. Docs

- **`architecture.md`:** a finding with what §1 measured. Use the next free F number; read the table, do not count.
- **`docs/configuration.md`:** the dump switch.
- **`todo.md`:** an item for the §3 decision, if it is not built in this task.

**Todo numbering.** If you add an item, take its number from the **"Next number" line of the file as it is on disk at that moment**, and bump that line in the same edit.

---

## Definition of done

- The §1 dumps taken by the user, and the report answers all four questions
- The members pill shows again on home, search, subscriptions, and the watch page's slate, with tests and the mutation in place
- §3's options reported for the user's decision
- `.\rill check` and `cd sidecar; bun run check` green, raw output pasted

## Out of scope

- Building §3's shelf change, until the user has chosen.
- The subscriptions feed's own layout.
- Anything about the recommendations themselves. The goal is to show what YouTube sends faithfully, not to re-rank it.

## Stop conditions

- **§1 refutes the hypothesis**, or explains only part of it. Report what the dump shows.
- **The members marker is not in the structure at all,** only in title text. Report it; do not match on title text.
- **The dump would need anything from the stop list in §1.3** to be useful. Report why, before adding it.

## Report rules

- **No raw response anywhere:** not in commits, tests, docs or the report. The commit hook refuses raw responses.
- **No real titles, ids or channel names** from the user's account in tests or docs; use synthetic ones.
- Raw command output, never summarised.
- Every file:line you cite must be one you opened in this session.
- Say plainly what you ran and what you handed to the user.
- No AI attribution in commits, issues or PRs.
