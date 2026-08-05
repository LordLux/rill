# rill

The Flutter half of the client. Windows only.

Right now it is **not an app** — it is task 07's media_kit harness: one window, a
`Video` widget, four seek buttons and a property readout, existing to answer
whether `media_kit` behaves like the libmpv it wraps (see `docs/tasks/07`).

```bash
bun run spiking/07-resolve.ts      # resolve a stream; URLs last ~6 h
cd app && flutter run -d windows
```

The harness reads its mode from environment variables rather than
`--dart-define`, so one build serves every measurement — see the header comment
in `lib/main.dart`. `spiking/07-run.ps1` drives it and tallies the verdicts.

`media_kit_libs_windows_video` is pinned **exactly**, not with a caret. A bump
lands a modern FFmpeg and reintroduces the F13 seek freeze. See
`docs/architecture.md` §2.4.
