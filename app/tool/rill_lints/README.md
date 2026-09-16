# rill_lints

Project-local analysis rules, loaded by the analysis server via the `plugins:`
section of `app/analysis_options.yaml`. They show up in the IDE on their own.
**On the command line, check them with the lint gate — not with
`flutter analyze` or `dart analyze`:**

```
cd app && fvm dart run tool/lint_gate.dart                # canary + app, the real check
cd app && fvm dart run tool/lint_gate.dart --canary-only  # "does the plugin load at all"
```

## `no_color_literals`

Bans colour literals under `lib/ui/`. Same reasoning as the sidecar's stdout
rule (hard invariant 3): a discipline that depends on remembering decays. A
`Color(0xFF…)` that slips into a tile does not re-theme, and nothing says so
until someone changes the accent and that one thing stays put.

Colours are named outside the rule's scope, in `lib/theme/`:

- `accent.dart` — the seed and its presets.
- `tokens.dart` — `RillTokens`, the things that are genuinely not roles: the
  scrim and what is legible on it, the LIVE red, the membership green, the
  title bar's close red. Its class doc says why each one resists a role.
- `app_theme.dart` — the tooltip bubble, which is fixed dark whatever the
  theme, and the two colours drawn inside it.

`Colors.transparent` is allowed: it is not a colour, it means "paint nothing",
and there is no role that says it.

### When to ignore it instead

Rarely, and always with the reason on the line above:

```dart
// The artist's own palette, an ARGB int from the payload — data, not a
// literal the app chose.
// ignore: rill_lints/no_color_literals
: Color(isDark ? themed.dark : themed.light);
```

The plugin name has to prefix the rule — `rill_lints/no_color_literals`, not
`no_color_literals`. Confirmed on the pinned SDK (Dart 3.12.2), where each
added ignore dropped the gate's count by one. The cases that have earned one
so far: a colour built from data (a server-sent ARGB, the user's own channel
picks), gradients used as alpha masks under `BlendMode.dstIn` (their RGB never
reaches the screen), and a debug-only outline that is hard-coded off.

### Scoping

The scope is decided inside the rule, not in analysis options — analyzer plugins
[cannot be configured in a nested `analysis_options.yaml`][nested], so
"only under `lib/ui/`" has to be the rule's own test. Generated files
(`*.g.dart`, `*.freezed.dart`) and `test/` fall outside it for free.

[nested]: https://github.com/dart-lang/sdk/blob/main/pkg/analysis_server_plugin/doc/using_plugins.md

## Why `flutter analyze` and `dart analyze` are not the check

Investigated 2026-09-16. Both commands can report **"No issues found!" on a
codebase with real violations**, and do so often: on the same code,
`fvm dart analyze` returned 0, then all of them, then 0 again.

**The plugin was loading every time.** Logging from inside it showed
`register()` succeeding on runs that reported nothing. What varies is timing:
the plugin's diagnostics arrive **6–16 s after** the analysis server first
reports itself idle, and a one-shot command stops listening at that first idle
signal. How often it misses them depends only on how fast the rest of the run
happened to be.

**It is not the SDK version.** dart.dev says analyzer plugins arrived in Dart
3.13 and the pinned Flutter ships 3.12.2, which made a version bump the obvious
suspect. It is not the cause: the plugin loads on 3.12.2, and on Dart 3.13.2
`dart analyze` still dropped every diagnostic on 2 of 5 runs. 3.13's server
does announce a second busy phase for the plugin, but only after a brief false
idle — exactly where a one-shot command stops. So nothing about this argues
for moving the Flutter pin (`docs/todo.md` item 18 has the reasons that do).

**When they do report, they can report each diagnostic more than once** —
`fvm dart analyze` listed the same 27 twice each, and `flutter analyze` has
done the same. Count unique diagnostics, never lines.

`tool/lint_gate.dart` avoids all of it by talking to a persistent analysis
server directly and not trusting the first idle signal. Its header explains the
two-phase wait, why the canary exists, and what a pass does and does not prove.

## The canary

`canary/` is a tiny package with exactly one `no_color_literals` violation and
its own `analysis_options.yaml` enabling this plugin by relative path. A plugin
that fails to load reports nothing, which looks exactly like a clean codebase;
the canary is what tells them apart. The gate fails unless the canary reports
exactly one diagnostic, and a broken plugin fails after the 5-minute timeout
rather than passing. Measured 2026-09-16 by renaming the top-level `plugin`
variable: the gate failed with "the canary diagnostic never arrived".

Your IDE will show the canary's one violation in its problems panel. That is
the canary working.

## Checking the rule still detects every form

The canary proves the plugin loads; it does not prove the rule still catches
every way of spelling a colour. After changing the rule, drop this in
`app/lib/ui/widgets/_lint_probe.dart`:

```dart
import 'package:flutter/material.dart';

const Color a = Color(0xFF123456);
const Color b = Color.fromARGB(255, 1, 2, 3);
const Color c = Colors.white;
final Color d = Colors.grey[800]!;
final Color e = Colors.grey.shade500;
const Color ok = Colors.transparent;
```

run the gate, and expect `app — 5 diagnostic(s)`, all in that file — `ok` is
not one of them. Then delete the file.

## Use the pinned SDK, always

Run everything here through `fvm` (the gate launches the SDK behind
`app/.fvm/flutter_sdk` itself). Mixing in the global SDK breaks things that do
not look related:

- bare `flutter`/`dart` in `app/` re-resolves `pubspec.lock` against the global
  SDK's pins (`meta`, `matcher`, `test_api`, `vector_math` all move);
- the two SDKs compile `app/.dart_tool/hooks_runner` in incompatible formats,
  so after an `fvm` run a bare `dart run tool/test_suite_guard.dart` fails before
  running a single test with *"Invalid kernel binary format version (expected
  138, found 130)"* (measured 2026-09-16; only that direction was observed).
