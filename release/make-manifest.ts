// Builds and signs update.json for a release. Run by the publish job, and by hand
// to test the signing path:
//
//   UPDATE_SIGNING_KEY="$(cat ~/.rill-update-key/private.pem)" \
//     bun release/make-manifest.ts --version 0.1.412 --tag v0.1.412 \
//       --repo LordLux/rill --installer Rill-Setup-x64.exe --notes notes.txt --out dist
//
// Writes update.json and update.json.sig (base64 Ed25519 over the exact bytes of
// update.json). The app embeds the matching public key and refuses a manifest whose
// signature does not verify, so a hijacked release account cannot push code to
// installed copies. The hash of the installer lives inside the signed manifest,
// which is what binds the binary to the signature.
//
// stdout is quiet on purpose and the key is never printed.

import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

function fail(message: string): never {
  process.stderr.write(`make-manifest: ${message}\n`);
  process.exit(1);
}

const { values } = parseArgs({
  options: {
    version: { type: 'string' },
    tag: { type: 'string' },
    repo: { type: 'string' },
    installer: { type: 'string' },
    notes: { type: 'string' },
    out: { type: 'string' },
    published: { type: 'string' },
    // Tests only: verify against a throwaway key pair instead of the committed one.
    'public-key': { type: 'string' },
  },
});

const version = values.version ?? fail('--version is required');
const tag = values.tag ?? fail('--tag is required');
const repo = values.repo ?? fail('--repo is required (owner/name)');
const installer = values.installer ?? fail('--installer is required');
const out = values.out ?? fail('--out is required');

if (!/^\d+\.\d+\.\d+$/.test(version)) fail(`version "${version}" is not major.minor.patch`);
if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) fail(`repo "${repo}" is not owner/name`);

const pem = process.env['UPDATE_SIGNING_KEY']?.trim();
if (!pem) fail('UPDATE_SIGNING_KEY is not set (repository secret holding the private key PEM)');

const installerBytes = readFileSync(installer);
const name = basename(installer);

const notes = values.notes
  ? readFileSync(values.notes, 'utf8')
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)
  : [];

const manifest = {
  schema: 1,
  version,
  tag,
  publishedAt: values.published ?? new Date().toISOString(),
  notes,
  // A floor a client below it must update past. Null unless a release needs it.
  minimumVersion: null,
  assets: {
    'windows-x64': {
      name,
      url: `https://github.com/${repo}/releases/download/${tag}/${name}`,
      sha256: createHash('sha256').update(installerBytes).digest('hex'),
      size: statSync(installer).size,
    },
  },
};

const body = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`, 'utf8');

let signature: Buffer;
try {
  signature = sign(null, body, createPrivateKey(pem));
} catch {
  // Deliberately not echoing the error: a parser failure can quote the input.
  fail('UPDATE_SIGNING_KEY is not a valid PKCS#8 Ed25519 private key PEM');
}

// The committed public key is the one the app embeds. Verifying against it here
// turns a wrong secret into a failed release rather than into updates that every
// installed copy silently rejects.
const here = dirname(fileURLToPath(import.meta.url));
const publicKeyFile = values['public-key'] ?? join(here, 'update-signing.pub');
const publicRaw = Buffer.from(readFileSync(publicKeyFile, 'utf8').trim(), 'base64');
if (publicRaw.length !== 32) fail(`${publicKeyFile} is not a base64 32-byte Ed25519 key`);
const publicKey = createPublicKey({
  key: { kty: 'OKP', crv: 'Ed25519', x: publicRaw.toString('base64url') },
  format: 'jwk',
});
if (!verify(null, body, publicKey, signature)) {
  fail('the signature does not verify against release/update-signing.pub: the secret and the committed public key are a different pair');
}

mkdirSync(out, { recursive: true });
writeFileSync(join(out, 'update.json'), body);
writeFileSync(join(out, 'update.json.sig'), `${signature.toString('base64')}\n`);
process.stdout.write(`make-manifest: wrote ${join(out, 'update.json')} (${version}, ${name}, ${manifest.assets['windows-x64'].size} bytes)\n`);
