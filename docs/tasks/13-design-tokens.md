# Task 13 — Design tokens and foundation cleanup

**Prerequisite:** `CLAUDE.md` (hard invariants 9 and 10), `docs/protocol.md` §2.

No new features. This is the foundation the watch page will be built on, done
before it rather than retrofitted after. **Do not add navigation, a watch page,
playback wiring, or any RPC method.** Those are Task 14.

Behaviour must not change except where stated. If a colour swap alters layout or
hover behaviour, that is a bug in the swap.

---

## 1. Naming

`main.dart` declares `NativeYouTubeApp` with `title: 'Native YouTube'`, while
`feed.dart` renders "Rill" and the repo is `rill`. Settle on **Rill**: class
name, window title, and any other stray reference.

The Windows executable name in `app/windows/runner/` should follow, so the built
binary is not `native_youtube.exe`. Note that `build.bat` launches it by path —
update that too, or the build script silently launches a stale binary.

## 2. The Shorts drawer entry

`page_wrapper.dart` has a Shorts item. Shorts are stripped by the parser by
design — it is the product's first requirement — so this entry can never do
anything. Remove it.

Leave the other drawer entries as non-functional placeholders; they become real
in later tasks.

## 3. Design tokens — the substance of this task

### 3.1 A derived scheme, not a raw colour

The accent is a **seed**, not a value used directly. A user picking something
very light or very saturated must not produce unreadable text.

```dart
ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark)
```

Widgets reference **roles** — `primary`, `onPrimary`, `surface`,
`onSurfaceVariant`, `surfaceContainerHighest` — never the seed and never a
literal.

Default accent: **purple**. Deliberately not red; red is the single strongest
signal of YouTube's brand and we are not using it.

### 3.2 The accent is user-changeable and persisted

- A Riverpod provider holding the accent, with the purple default
- Persisted to disk (`shared_preferences` is fine) so it survives a restart —
  an accent that resets each launch reads as broken
- **A temporary debug control** to change it: a colour swatch row behind the
  existing debug action in the top bar is enough. Without a way to change it,
  "user-changeable" is untested. The real settings surface is a later task;
  say clearly in the code that this control is temporary.

### 3.3 Where the accent belongs

**Yes:** selected chip, focus rings, primary buttons, the watched-progress bar
on tiles, selected drawer item.

**No:** thumbnails, grid background, body text, surfaces, badges.

Accent everywhere is the standard failure of themeable apps and the one thing
that would make this look amateur beside the real site.

### 3.4 Replace every literal

Currently hardcoded, non-exhaustive:

| File | Literals |
|---|---|
| `topbar.dart` | `Color(0xFFCC0000)` (**YouTube red**), `Color(0xFF0F0F0F)`, `Color(0xFF404040)`, `Color(0xFF303030)`, `Color.fromARGB(66,0,0,0)`, `Color.fromARGB(109,105,105,105)`, `Color.fromARGB(100,51,51,51)`, several `Colors.white` |
| `media_tile.dart` | `Colors.white`, `Colors.white70`, `Colors.grey[800]`, `Colors.grey[850]`, `Color.fromARGB(180,0,0,0)`, `Colors.black`, `Colors.red` (progress bar → accent) |
| `feed.dart` | `Colors.red`, `Colors.white54`, `Colors.white70` |
| `main.dart` | `Colors.white` in the title style |

Grep for `Color(`, `Colors.`, and `withValues(alpha:` when you think you are
done. Two exceptions may stay, with a comment saying why: the LIVE badge red,
which is a status colour rather than branding, and the black scrim behind the
tile's hover buttons, which exists for contrast over an arbitrary thumbnail.

**Add a lint rule** banning colour literals in `lib/ui/`, same reasoning as the
stdout rule. A token discipline that depends on remembering is a token
discipline that decays.

### 3.5 `TextThemeMod`

It takes `themeMode` and `onThemeModeChanged` and ignores both, applying only a
font-size delta. Either wire them or delete them. Dead parameters that look
load-bearing are worse than no parameters.

## 4. The RPC decode bug

`client.dart:_handleLine` runs `await Isolate.run(() => jsonDecode(line))` on
**every** line, and `listen` does not await the handler. Two consequences:

- **Ordering.** Concurrent decodes can complete out of order. Responses are
  keyed by `id` so it mostly does not matter, but `event.ready` arriving after a
  response would break the ready gate.
- **Cost.** An isolate spawn per message costs far more than parsing a 200-byte
  response. Hard invariant 9's concern was a *large payload* on the frame loop,
  not every message.

Fix both. A size threshold — parse inline below it, offload above — is the
simplest thing that works; one persistent worker isolate is also fine. Either
way, **processing must stay ordered**.

Add a test: a large payload and several small ones arriving together are all
delivered, in order, with the large one not blocking the main isolate. The
existing invariant-9 test should still pass unchanged.

---

## Definition of done

- `flutter analyze` clean, including the new lint rule
- `flutter test` green, `bun test` green, `bunx tsc --noEmit` clean
- Changing the accent visibly re-themes the app and survives a restart
- No colour literal remains in `lib/ui/` except the two documented exceptions
- The built binary is named for Rill and `build.bat` launches it

**Run the app and say what you saw** — the feed with the default purple, and
with one other accent. Confirm the tile hover, chip selection and drawer still
behave exactly as before.

## Out of scope

The watch page, tile `onTap`, any `action.*` or `video.*` method, the queue, the
settings UI, login. Task 14.

## Stop conditions

- **A literal cannot be expressed as a role** without inventing a token that is
  really a one-off. Say which and leave it with a comment rather than forcing a
  role that does not fit.
- **The lint rule cannot be scoped to `lib/ui/`** and would fire on generated or
  test code. Report rather than weakening it to a warning.
