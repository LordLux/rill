/**
 * Drive the real sidecar process over NDJSON, the way the Flutter client does.
 *
 * The end-to-end check the ASS pipeline cannot make on its own: the document has
 * to survive `captions.get`'s envelope and the transport, not merely be rendered.
 *
 *   bun run scratch/rpc-captions.ts <videoId>
 */
const videoId = process.argv[2] ?? 'L-BgxLtMxh0';

const child = Bun.spawn(['bun', 'run', 'src/main.ts'], {
  stdin: 'pipe',
  stdout: 'pipe',
  stderr: 'ignore',
});

child.stdin.write(
  `${JSON.stringify({ id: '1', method: 'captions.list', params: { videoId } })}\n`,
);
await child.stdin.flush();

const decoder = new TextDecoder();
let buffer = '';
let trackId: string | null = null;

for await (const chunk of child.stdout) {
  buffer += decoder.decode(chunk, { stream: true });
  let newline: number;
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (line.trim() === '') continue;
    const message = JSON.parse(line) as {
      id?: string;
      method?: string;
      result?: Record<string, unknown>;
      error?: unknown;
    };

    if (message.method === 'event.ready') {
      console.error('ready:', JSON.stringify(message.params ?? {}));
      continue;
    }
    if (message.error !== undefined) {
      console.error('ERROR', JSON.stringify(message.error));
      process.exit(1);
    }

    if (message.id === '1') {
      const tracks = message.result?.['tracks'] as { id: string; label: string }[];
      console.error(`captions.list -> ${tracks.map((t) => `${t.id} (${t.label})`).join(', ')}`);
      const wanted = process.argv[3];
      trackId = (wanted === undefined ? tracks[0]?.id : tracks.find((t) => t.id === wanted)?.id) ?? null;
      if (trackId === null) process.exit(1);
      child.stdin.write(
        `${JSON.stringify({ id: '2', method: 'captions.get', params: { videoId, trackId } })}\n`,
      );
      await child.stdin.flush();
      continue;
    }

    if (message.id === '2') {
      const content = String(message.result?.['content']);
      const dialogues = content.split('\n').filter((l) => l.startsWith('Dialogue:'));
      const identical = dialogues.length - new Set(dialogues).size;
      console.error(`captions.get -> format=${String(message.result?.['format'])}`);
      console.error(`  cueCount=${String(message.result?.['cueCount'])}, ${content.length} bytes`);
      console.error(`  starts "[Script Info]": ${content.startsWith('[Script Info]')}`);
      console.error(`  Dialogue lines: ${dialogues.length}, byte-identical repeats: ${identical}`);
      console.error(`  styled (has overrides): ${dialogues.filter((l) => l.includes('{')).length}`);
      child.kill();
      process.exit(0);
    }
  }
}
