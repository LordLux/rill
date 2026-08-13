/**
 * Does the **compiled** sidecar land in the poisoned bucket, where `bun run`
 * never does?
 *
 * F20's open edge: `fexp=51946838` is assigned per session, 5/12 of the app's
 * sessions carry it, and a standalone script has never once landed in it —
 * 0/32 — on the same code, client type, machine and IP. The difference nobody
 * had named is the **binary**: the app runs `dist/sidecar.exe`, every probe so
 * far ran `bun run src/…`. A compiled binary can differ in TLS fingerprint or
 * header ordering, and a bucketing decision is exactly the sort of thing that
 * keys on those.
 *
 * So this drives the real `dist/sidecar.exe` over its NDJSON RPC, exactly as the
 * app does, and does **not** import the sidecar's own modules — importing them
 * would be `bun run` again wearing a different hat.
 *
 * One process is one resolve session (`getResolveSession` mints once and
 * reuses), so N launches sample N sessions.
 *
 * With `--escape`, every flagged session is immediately followed by a
 * replacement, which is the deciding measurement for a detect-and-re-mint fix:
 * given a session in the bucket, how often does a fresh one clear it?
 *
 * Results to stderr (hard invariant 3).
 *
 *   bun run exe-bucket-probe.ts [sessions] [--escape]
 */

const FLAG = '51946838';
const EXE = 'dist/sidecar.exe';
const VIDEO = process.env.PROBE_VIDEO ?? 'aqz-KE-bpKQ';

const sessions = Number(process.argv[2] ?? '20');
const wantEscape = process.argv.includes('--escape');

/** One sidecar process, one resolve session, one `playback.open`. */
async function mintAndResolve(): Promise<{ flagged: boolean | null; remints?: number; note?: string }> {
  const proc = Bun.spawn([EXE], {
    stdin: 'pipe',
    stdout: 'pipe',
    // Captured, not ignored: since the retry landed, the sidecar's own re-mint
    // log is the only remaining view of the **base** rate. The flag on the
    // returned URL is now the *residual* rate, post-retry — a distinction that
    // silently changed what this probe measures the day the fix shipped.
    stderr: 'pipe',
    // Deliberately not set: the sidecar's parent-PID watch (F17) would poll a
    // pid that is this script rather than a Flutter app. Nothing here outlives
    // the loop anyway, and every process is killed explicitly below.
  });

  const timer = setTimeout(() => proc.kill(), 30_000);
  let remints = 0;
  const watchStderr = (async () => {
    const dec = new TextDecoder();
    for await (const chunk of proc.stderr as ReadableStream<Uint8Array>) {
      const text = dec.decode(chunk, { stream: true });
      remints += (text.match(/re-minting the resolve session/g) ?? []).length;
    }
  })().catch(() => {});
  try {
    proc.stdin.write(JSON.stringify({ id: 1, method: 'playback.open', params: { videoId: VIDEO } }) + '\n');
    proc.stdin.flush();

    const decoder = new TextDecoder();
    let buffer = '';
    for await (const chunk of proc.stdout) {
      buffer += decoder.decode(chunk, { stream: true });
      let nl: number;
      while ((nl = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        let msg: Record<string, unknown>;
        try {
          msg = JSON.parse(line);
        } catch {
          continue;
        }
        if (msg['id'] !== 1) continue; // event.ready and anything else
        if (msg['error']) return { flagged: null, note: JSON.stringify(msg['error']).slice(0, 90) };
        const result = msg['result'] as { variants?: Array<{ videoUrl: string }> };
        const url = result?.variants?.[0]?.videoUrl;
        if (!url) return { flagged: null, note: 'no variants' };
        const fexp = new URL(url).searchParams.get('fexp') ?? '';
        // A beat for the stderr reader to catch up with lines written before the
        // response — the re-mint logs precede it, so this is not a race in
        // practice, but reading zero because the pipe had not drained would look
        // exactly like a healthy mint.
        await Bun.sleep(30);
        return { flagged: fexp.split(',').includes(FLAG), remints };
      }
    }
    return { flagged: null, note: 'stdout closed with no answer' };
  } finally {
    clearTimeout(timer);
    proc.kill();
    await proc.exited;
    await watchStderr;
  }
}

let flagged = 0;
let usable = 0;
let baseFlagged = 0;
let escapes = 0;
let escapeTrials = 0;

for (let i = 1; i <= sessions; i++) {
  const first = await mintAndResolve();
  if (first.flagged === null) {
    process.stderr.write(JSON.stringify({ i, skipped: first.note }) + '\n');
    continue;
  }
  usable += 1;
  if (first.flagged) flagged += 1;
  // A re-mint means the *first* mint was flagged, which is the base rate the
  // retry now hides.
  if ((first.remints ?? 0) > 0 || first.flagged) baseFlagged += 1;

  let escaped: boolean | null = null;
  if (wantEscape && first.flagged) {
    // The replacement a detect-and-re-mint fix would make: a brand new session,
    // immediately, for the same video.
    const replacement = await mintAndResolve();
    if (replacement.flagged !== null) {
      escapeTrials += 1;
      escaped = !replacement.flagged;
      if (escaped) escapes += 1;
    }
  }

  process.stderr.write(
    JSON.stringify({ i, flagged: first.flagged, remints: first.remints ?? 0, escaped }) + '\n',
  );
}

process.stderr.write(
  `\nbase rate (first mint flagged): ${baseFlagged}/${usable}` +
    `\nresidual after the retry:       ${flagged}/${usable}` +
    (wantEscape ? `\nre-mint escaped: ${escapes}/${escapeTrials} flagged sessions\n` : '\n'),
);
process.exit(0);
