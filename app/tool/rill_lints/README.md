# rill_lints

Project-local analysis rules, loaded by the analysis server via the `plugins:`
section of `app/analysis_options.yaml`. They run in the IDE and in
`flutter analyze` / `dart analyze` — no separate command.

## `no_color_literals`

Bans colour literals under `lib/ui/`. Same reasoning as the sidecar's stdout
rule (hard invariant 3): a discipline that depends on remembering decays. A
`Color(0xFF…)` that slips into a tile does not re-theme, and nothing says so
until someone changes the accent and that one thing stays put.

Colours are named in two files, both outside the rule's scope:
`lib/theme/accent.dart` (the seed and its presets) and `lib/theme/tokens.dart`
(the few things that are genuinely not roles — the thumbnail scrim, the LIVE
status red).

`Colors.transparent` is allowed: it is not a colour, it means "paint nothing",
and there is no role that says it.

### Scoping

The scope is decided inside the rule, not in analysis options — analyzer plugins
[cannot be configured in a nested `analysis_options.yaml`][nested], so
"only under `lib/ui/`" has to be the rule's own test. Generated files
(`*.g.dart`, `*.freezed.dart`) and `test/` fall outside it for free.

[nested]: https://github.com/dart-lang/sdk/blob/main/pkg/analysis_server_plugin/doc/using_plugins.md

### Verifying the rule still fires

A plugin that fails to load reports nothing and says nothing about it, which
looks exactly like a clean codebase. After a dependency bump, check it still
works: drop this in `app/lib/ui/widgets/_lint_probe.dart`,

```dart
import 'package:flutter/material.dart';

const Color a = Color(0xFF123456);
const Color b = Color.fromARGB(255, 1, 2, 3);
const Color c = Colors.white;
final Color d = Colors.grey[800]!;
final Color e = Colors.grey.shade500;
const Color ok = Colors.transparent;
```

run `dart analyze` from `app/`, and expect five `no_color_literals` diagnostics —
`ok` is not one of them. Then delete the file.

Note that `flutter analyze` reports each plugin diagnostic twice and
`flutter analyze <single-file>` does not load the plugin at all; `dart analyze`
does neither. Both find the same violations over the whole package.
