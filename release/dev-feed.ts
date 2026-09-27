// A local update feed for working on the updater with a debug or profile build.
// Never used by a release: those ignore every RILL_UPDATE_* define
// (architecture.md §2.14).
//
//   bun release/dev-feed.ts [--version 0.0.2] [--port 8765] [--size-mb 20]
//                           [--ms-per-chunk 40] [--mandatory]
//                           [--fail signature|hash|missing] [--notes "a|b"]
//
// Pair it with a build defining RILL_VERSION below --version and the three
// overrides this prints on start.
//
// The signing key is derived from a fixed, public seed, so the public key is
// stable and can live in a launch configuration. That is only safe because it
// is only ever trusted by a build that is not a release build.
//
// The "installer" is Windows' own whoami.exe padded with zeros to --size-mb, so
// a download takes long enough to watch. Restart to update closes the app and
// runs it; it prints an error about the Inno flags and exits, installing nothing.
import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    version: { type: 'string', default: '0.0.2' },
    port: { type: 'string', default: '8765' },
    'size-mb': { type: 'string', default: '20' },
    'ms-per-chunk': { type: 'string', default: '40' },
    mandatory: { type: 'boolean', default: false },
    fail: { type: 'string' },
    notes: { type: 'string', default: 'Player: a note about the player.|Comments: a longer note, long enough to wrap onto a second line in the card.' },
  },
});

const version = values.version!;
const port = Number(values.port);
const fail = values.fail;
if (fail !== undefined && !['signature', 'hash', 'missing'].includes(fail)) {
  throw new Error(`--fail must be signature, hash or missing, not ${fail}`);
}

// PKCS#8 wrapper for a raw 32-byte Ed25519 seed.
const seed = createHash('sha256').update('rill dev update feed — never trusted by a release build').digest();
const privateKey = createPrivateKey({
  key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]),
  format: 'der',
  type: 'pkcs8',
});
// The public half, computed once with Node. Bun 1.1.42 derives a wrong public
// key from this private one (measured 2026-09-27), so it is written down, and
// the startup check below fails loudly if the pair ever disagrees.
const publicKeyBase64 = 'rp9v+tBqqBbp4ld1peNBiiPmi3AtOgjQO+N2iYTFrE0=';
const publicKey = createPublicKey({
  key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(publicKeyBase64, 'base64').toString('base64url') },
  format: 'jwk',
});

const stub = readFileSync(join(process.env['SystemRoot'] ?? 'C:\\Windows', 'System32', 'whoami.exe'));
const installer = Buffer.alloc(Math.max(stub.length, Math.round(Number(values['size-mb']) * 1024 * 1024)));
stub.copy(installer);

const name = 'Rill-Setup-x64.exe';
const manifest = {
  schema: 1,
  version,
  tag: `v${version}`,
  publishedAt: new Date().toISOString(),
  notes: values.notes!.split('|').map((note) => note.trim()).filter(Boolean),
  minimumVersion: values.mandatory ? version : null,
  assets: {
    'windows-x64': {
      name,
      url: `http://127.0.0.1:${port}/download/v${version}/${name}`,
      sha256: fail === 'hash' ? '0'.repeat(64) : createHash('sha256').update(installer).digest('hex'),
      size: installer.length,
    },
  },
};
// Same bytes-then-sign as make-manifest.ts.
const body = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
const signature = sign(null, body, privateKey);
if (!verify(null, body, publicKey, signature)) throw new Error('dev-feed: the manifest does not verify against its own key');
if (fail === 'signature') signature[0] = signature[0]! ^ 1;

const msPerChunk = Number(values['ms-per-chunk']);
const chunk = 256 * 1024;

Bun.serve({
  port,
  hostname: '127.0.0.1',
  fetch(request) {
    const path = new URL(request.url).pathname;
    console.log(`dev-feed: GET ${path}`);
    if (fail === 'missing') return new Response('not found', { status: 404 });
    if (path === '/update.json') return new Response(body);
    if (path === '/update.json.sig') return new Response(`${signature.toString('base64')}\n`);
    if (path === `/download/v${version}/${name}`) {
      const stream = new ReadableStream({
        async start(controller) {
          for (let at = 0; at < installer.length; at += chunk) {
            controller.enqueue(installer.subarray(at, at + chunk));
            await Bun.sleep(msPerChunk);
          }
          controller.close();
        },
      });
      return new Response(stream, { headers: { 'content-length': String(installer.length) } });
    }
    return new Response('not found', { status: 404 });
  },
});

console.log(`dev-feed: offering ${version}${values.mandatory ? ' (required)' : ''}${fail ? `, failing: ${fail}` : ''}`);
console.log('dev-feed: build defines —');
console.log(`  --dart-define=RILL_UPDATE_FEED=http://127.0.0.1:${port}/update.json`);
console.log(`  --dart-define=RILL_UPDATE_PUBKEY=${publicKeyBase64}`);
console.log(`  --dart-define=RILL_UPDATE_ASSET_PREFIX=http://127.0.0.1:${port}/download/`);
console.log(`dev-feed: serving on http://127.0.0.1:${port}`);
