import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    rules: {
      // Hard invariant 3: stdout is protocol only. One stray console.log corrupts
      // the NDJSON stream, and the failure is silent on the Flutter side — it just
      // sees a malformed frame and drops it. Logging goes to stderr, via src/log.ts.
      // No `allow` list: console.error and console.warn write to stderr directly,
      // bypassing redact.ts, the chokepoint that keeps cookie values out of stderr
      // (CLAUDE.md, "No cookie value goes to stderr…") — so every console.* call
      // is banned, not just the stdout ones.
      'no-console': 'error',
      'no-restricted-properties': [
        'error',
        {
          object: 'process',
          property: 'stdout',
          message:
            'process.stdout is the RPC channel. Write logs with src/log.ts (stderr). ' +
            'Only the NDJSON transport in src/rpc may write to stdout.',
        },
      ],
    },
  },
  {
    // The transport owns stdout; that is the whole point of the module.
    files: ['src/rpc/**/*.ts'],
    rules: { 'no-restricted-properties': 'off' },
  },
  {
    // `scratch/` is ad-hoc probes against the live API — not shipped, not
    // imported, and console output is the whole point of one.
    //
    // The files below are the same kind of throwaway probe/measurement
    // harness — standalone scripts run directly with `bun run <file>.ts`,
    // never imported by src/ or loaded into the sidecar process — they just
    // predate the scratch/ convention and live at the package root instead.
    // Exempting them by exact filename (never a directory-wide or extension
    // glob at the root) is what keeps this narrow: hard invariant 3's
    // no-console rule, and every other rule here, still guards all of src/
    // at full strength, and a new file added under src/ can never land in
    // this list by accident. Confirmed by `bun run lint` at the time this
    // was written: these four names are exactly the files with violations.
    ignores: [
      'node_modules/**',
      'fixtures/**',
      'scratch/**',
      'compare-captions.ts',
      'dump-player.ts',
      'feed-test.ts',
      'session-test.ts',
    ],
  },
);
