/**
 * The server half of `measure-video-add.ts`, in its own process (mpv's commands block the
 * thread that issues them, so a server on that thread would deadlock).
 *
 * Serves `/v1.webm`, `/v2.webm` and `/a.webm` from the directory in `MEDIA`, with Range support.
 * `DELAY_V2_MS` holds the first response for `/v2.webm`: a new quality's first byte being slow.
 * Prints `PORT <n>`, then `V2-FIRST-BYTE <ms since start>` once that response is released.
 */
import * as fs from 'fs';
import * as path from 'path';

const dir = process.env['MEDIA']!;
const read = (name: string) => fs.readFileSync(path.join(dir, name));
const files: Record<string, Buffer> = { '/v1.webm': read('v1.webm'), '/v2.webm': read('v2.webm'), '/a.webm': read('a.webm') };
const delayV2 = Number(process.env['DELAY_V2_MS'] ?? 3000);
const t0 = Date.now();
let v2Requests = 0;

function serve(request: Request, body: Buffer): Response {
  const range = /bytes=(\d+)-(\d*)/.exec(request.headers.get('range') ?? '');
  const headers = { 'Content-Type': 'video/webm', 'Accept-Ranges': 'bytes' };
  if (!range) return new Response(body, { headers });
  const start = Number(range[1]);
  const end = range[2] === '' ? body.length - 1 : Math.min(Number(range[2]), body.length - 1);
  return new Response(body.subarray(start, end + 1), {
    status: 206,
    headers: { ...headers, 'Content-Range': `bytes ${start}-${end}/${body.length}` },
  });
}

const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const pathname = new URL(request.url).pathname;
    const body = files[pathname];
    if (!body) return new Response('not found', { status: 404 });
    if (pathname === '/v2.webm') {
      v2Requests++;
      // Only the first request: that is the new quality being asked for.
      if (v2Requests === 1) {
        await Bun.sleep(delayV2);
        console.log(`V2-FIRST-BYTE ${Date.now() - t0}`);
      }
    }
    return serve(request, body);
  },
});
console.log(`PORT ${server.port}`);
