/**
 * The release signer refuses to ship a manifest no installed app could trust.
 *
 * `release/make-manifest.ts` signs `update.json` with the private key held in the
 * `UPDATE_SIGNING_KEY` Actions secret, and the app embeds the matching *public* key
 * and rejects anything that does not verify. The failure this guards against is
 * silent and only arrives after the fact: a secret that is not the committed key's
 * pair produces a perfectly well-formed release whose update every installed copy
 * quietly declines. So the script verifies its own output against the committed
 * public key before writing anything, and these tests hold it to that.
 *
 * Every key here is generated for the test and thrown away. The real private key
 * is never read, which is also why the script takes `--public-key`.
 */

import { afterAll, describe, expect, test } from 'bun:test';
import { createHash, createPublicKey, generateKeyPairSync, verify } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const RELEASE_DIR = join(import.meta.dir, '..', '..', 'release');
const SCRIPT = join(RELEASE_DIR, 'make-manifest.ts');

const work = mkdtempSync(join(tmpdir(), 'rill-manifest-'));
afterAll(() => rmSync(work, { recursive: true, force: true }));

interface Pair {
  pem: string;
  rawBase64: string;
}

function keyPair(): Pair {
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const x = publicKey.export({ format: 'jwk' }).x;
  if (!x) throw new Error('no public key material');
  return {
    pem: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
    rawBase64: Buffer.from(x, 'base64url').toString('base64'),
  };
}

const INSTALLER_BYTES = Buffer.from('not really an installer, but it has a definite hash');
const installer = join(work, 'Rill-Setup-x64.exe');
writeFileSync(installer, INSTALLER_BYTES);
const notes = join(work, 'notes.txt');
writeFileSync(notes, 'Round the outer ends of the progress bar\n\nOpen a pasted video link directly\n');

let runs = 0;

/** Runs the script for real, in a child process, the way the workflow does. */
async function run(opts: { key: string | undefined; publicKeyBase64: string; version?: string }) {
  const out = join(work, `out-${++runs}`);
  const publicKeyFile = join(work, `public-${runs}.b64`);
  writeFileSync(publicKeyFile, `${opts.publicKeyBase64}\n`);

  const env: Record<string, string> = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (value !== undefined && name !== 'UPDATE_SIGNING_KEY') env[name] = value;
  }
  if (opts.key !== undefined) env['UPDATE_SIGNING_KEY'] = opts.key;

  const child = Bun.spawn(
    [
      process.execPath, SCRIPT,
      '--version', opts.version ?? '0.1.412',
      '--tag', 'v0.1.412',
      '--repo', 'LordLux/rill',
      '--installer', installer,
      '--notes', notes,
      '--out', out,
      '--public-key', publicKeyFile,
    ],
    { env, stdout: 'pipe', stderr: 'pipe' },
  );
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  return { out, stdout, stderr, exitCode };
}

function publicKeyOf(rawBase64: string) {
  return createPublicKey({
    key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(rawBase64, 'base64').toString('base64url') },
    format: 'jwk',
  });
}

describe('make-manifest', () => {
  test('a manifest is written whose signature verifies and whose hash is the installer\'s', async () => {
    const pair = keyPair();
    const { out, exitCode, stderr } = await run({ key: pair.pem, publicKeyBase64: pair.rawBase64 });
    expect(stderr).toBe('');
    expect(exitCode).toBe(0);

    const body = readFileSync(join(out, 'update.json'));
    const signature = Buffer.from(readFileSync(join(out, 'update.json.sig'), 'utf8').trim(), 'base64');
    expect(signature.length).toBe(64);
    expect(verify(null, body, publicKeyOf(pair.rawBase64), signature)).toBe(true);

    const manifest = JSON.parse(body.toString('utf8'));
    expect(manifest.schema).toBe(1);
    expect(manifest.version).toBe('0.1.412');
    expect(manifest.notes).toEqual(['Round the outer ends of the progress bar', 'Open a pasted video link directly']);
    expect(manifest.assets['windows-x64']).toEqual({
      name: 'Rill-Setup-x64.exe',
      url: 'https://github.com/LordLux/rill/releases/download/v0.1.412/Rill-Setup-x64.exe',
      sha256: createHash('sha256').update(INSTALLER_BYTES).digest('hex'),
      size: INSTALLER_BYTES.length,
    });
  });

  test('the signature covers the exact bytes: one appended byte no longer verifies', async () => {
    const pair = keyPair();
    const { out } = await run({ key: pair.pem, publicKeyBase64: pair.rawBase64 });
    const body = readFileSync(join(out, 'update.json'));
    const signature = Buffer.from(readFileSync(join(out, 'update.json.sig'), 'utf8').trim(), 'base64');
    const tampered = Buffer.concat([body, Buffer.from(' ')]);
    expect(verify(null, tampered, publicKeyOf(pair.rawBase64), signature)).toBe(false);
  });

  test('a secret that is not the public key\'s pair fails the release and writes nothing', async () => {
    const secret = keyPair();
    const committed = keyPair();
    const { out, exitCode, stderr } = await run({ key: secret.pem, publicKeyBase64: committed.rawBase64 });
    expect(exitCode).toBe(1);
    expect(stderr).toContain('different pair');
    expect(existsSync(join(out, 'update.json'))).toBe(false);
    expect(existsSync(join(out, 'update.json.sig'))).toBe(false);
  });

  test('a missing key fails and says which variable to set', async () => {
    const pair = keyPair();
    const { exitCode, stderr } = await run({ key: undefined, publicKeyBase64: pair.rawBase64 });
    expect(exitCode).toBe(1);
    expect(stderr).toContain('UPDATE_SIGNING_KEY');
  });

  test('an unreadable key fails without echoing what it was given', async () => {
    const pair = keyPair();
    const garbage = 'definitely-not-a-key-0123456789';
    const { exitCode, stderr, stdout } = await run({ key: garbage, publicKeyBase64: pair.rawBase64 });
    expect(exitCode).toBe(1);
    expect(stderr).not.toContain(garbage);
    expect(stdout).not.toContain(garbage);
  });

  test('a version that is not major.minor.patch is refused', async () => {
    const pair = keyPair();
    const { exitCode, stderr } = await run({ key: pair.pem, publicKeyBase64: pair.rawBase64, version: '0.1' });
    expect(exitCode).toBe(1);
    expect(stderr).toContain('major.minor.patch');
  });
});

describe('the committed public key', () => {
  // The app will embed this exact key. If this file is ever mangled the signer
  // would refuse every release, and the app would refuse every update.
  test('is a base64 32-byte Ed25519 key that Node accepts', () => {
    const raw = Buffer.from(readFileSync(join(RELEASE_DIR, 'update-signing.pub'), 'utf8').trim(), 'base64');
    expect(raw.length).toBe(32);
    expect(() => publicKeyOf(raw.toString('base64'))).not.toThrow();
  });
});
