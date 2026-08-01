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
      'no-console': ['error', { allow: ['error', 'warn'] }],
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
    ignores: ['node_modules/**', 'fixtures/**'],
  },
);
