# Task 20 — Search, and the second surface

**Prerequisite:** `CLAUDE.md`, `docs/protocol.md` §3.2 and §3.3,
`docs/architecture.md` §2.2, and the Task 12 report.

The first surface beyond the home feed. `FeedController` was built with
`chipBars` as a **surface-keyed map** specifically so adding one would be a key
rather than a refactor — this is where that claim gets tested.

If it turns out not to hold, that is the finding, and it is worth more than the
feature.

---

## 1. The surface abstraction comes first

Do this before the search UI, not after.

`FeedController` has `static const String surface = 'home'` and calls
`feed.home` directly. Generalise it so a surface is a parameter, not a constant:
which RPC method, whether it has chips, what an empty result means.

Then prove it by adding **three** surfaces, not one:

| Surface | Method | Chips | Notes |
|---|---|---|---|
| `home` | `feed.home` | yes | unchanged behaviour |
| `search` | `search.query` | see §3 | new |
| `subscriptions` | `feed.subscriptions` | no | already in §3.2, needs auth |

Subscriptions is in for a reason: it is the cheapest possible second surface, so
if the abstraction only fits `search`, subscriptions is what exposes it. It will
be empty without login — that is fine and is itself a case worth handling.

**Home's behaviour must not change.** Its tests pass untouched, and the chip bar,
infinite scroll, `$cancel` on supersede and the generation guard all still work.
If generalising requires changing home's tests, say why before doing it.

## 2. Sidecar

`search.query` and `search.suggest` are specified in §3.3. The parser already
handles search responses — `corpus/search.json` exists and passes.

**Task 12 measured that search interleaves generations**: videos arrive as
classic `videoRenderer`, playlists and mixes as `lockupViewModel`, in one
response. That is exactly the case the tolerant parser was built for, so it
should need no new parsing — confirm rather than assume.

`search.suggest` returns the autocomplete list. It is a different endpoint from
`/search`; establish what it is and what it returns rather than guessing at a
shape.

## 3. Filters are not chips

Search filters — upload date, type, duration, sort by — are `params` tokens on
the search request. They resemble chips and are not the same thing:

- A chip is a token the server hands you in the response
- A filter is a token **you construct** from a known set

**Decide the shape now, not later.** Options: reuse the `chips[]` field with a
different `scope`, add a distinct `filters[]`, or keep them entirely client-side
and send an opaque `params` string. Say which and why, and amend `protocol.md`.

Getting this wrong is cheap to fix today and expensive once subscriptions and
history have their own variants.

## 4. Suggestions — the first real test of `$cancel`

Debounced per-keystroke requests, each superseding the last. `$cancel` and the
generation guard were built in Tasks 10 and 12 and have **never been exercised
under real typing load** — a fake sidecar race is not the same as someone typing
at 8 characters a second.

- Debounce (~150–250ms; pick one and say why)
- Every superseded request cancelled, and its response dropped if it lands anyway
- Results for the query the user is actually looking at, never a stale one
- Escape and blur close the dropdown; Enter searches

**Test it under sustained typing**, not one keystroke at a time. Report how many
requests a 20-character query issues and how many were cancelled.

## 5. The results page

Reuse `MediaTile` and the feed's grid. Search results are the same DTOs.

- The topbar's search field currently has **no controller** — wire it
- Enter navigates to results; the query is in the route
- Infinite scroll via continuation, same path as the feed
- Channel results render as channels — `_ChannelTile` exists in `feed.dart` and
  has never been exercised, because the home feed does not return channels.
  Search does. Expect it to be wrong.
- Empty results, error and loading states

Navigation from a result to the watch page uses the existing route. **The feed's
scroll position must survive** search-and-back, the same way it survives the
watch page.

## 6. What must not regress

- Home feed: chips, infinite scroll, hover previews, tile actions
- The player, queue and captions are untouched by this task
- Hover previews still suppressed while something plays — and now on the search
  page too, which is a new surface for that rule

---

## Tests

- The three surfaces each load, with home's existing tests unmodified
- A surface with no chips does not render an empty chip bar
- Search results parse both renderer generations from `corpus/search.json`
- Channel results render as channels
- Suggestions: sustained typing issues one request per debounce window, and a
  superseded response never reaches the UI
- Filters produce the right request shape, whatever §3 decided
- Subscriptions with no auth shows the anonymous state, not an error
- Feed scroll survives search-and-back

**Mutation-check the supersede guard and the debounce.** Both are the shape that
passes against deleted code — a test that types, awaits, then asserts will pass
with no debounce at all, because the await lets everything settle.

## Definition of done

- `bun run check` green, `flutter test` green, `flutter analyze` clean
- Type a query, get results, scroll them, open one, come back to a feed that
  kept its place
- Suggestions appear while typing and match what is in the box
- Filters change the results
- Subscriptions renders (empty, anonymously)

**Run the app and say what you saw** — including typing fast enough to outrun the
debounce, and a search returning channels.

## Out of scope

Login. History, watch later, playlist and channel pages. Search within a channel.
Voice search. Any player, queue or caption work.

## Stop conditions

- **The surface abstraction does not fit all three** without special-casing.
  Report where it breaks rather than adding a branch — that is a finding about a
  design decision made in Task 12.
- **`search.suggest` is not what §3.3 assumes.** Report the real shape.
- **Channel results need a DTO field that does not exist.** Report; do not widen
  the shared contract unilaterally.
