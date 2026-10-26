/**
 * The server half of `measure-expiry.ts`, in its own process.
 *
 * Serves `/v.webm` and `/a.webm` from the files in `VIDEO` and `AUDIO` with Range support, with
 * the body trickled at `RATE` bytes per second so a connection stays open for as long as
 * playback runs. Once `/__expire` has been requested every *new* request (any path) is answered
 * 403, which is what googlevideo does with a URL whose `expire=` has passed; with `?cut=1` the
 * responses already in flight are cut as well, as an idle connection torn down while a video is
 * paused would be. Prints `PORT <n>`, then `EXPIRED <ms>`. `/__count` answers how many requests
 * were refused.
 */
import * as fs from 'fs';

const files: Record<string, Buffer> = {
  '/v.webm': fs.readFileSync(process.env['VIDEO']!),
  '/a.webm': fs.readFileSync(process.env['AUDIO']!),
};
// `VIDEO2`: a second quality, for `measure-deselected.ts`. `/__bytes` answers how many bytes each
// path has put on the wire so far, as JSON.
if (process.env['VIDEO2']) files['/v2.webm'] = fs.readFileSync(process.env['VIDEO2']);
const sent: Record<string, number> = {};
const rate = Number(process.env['RATE'] ?? 60000);
const t0 = Date.now();
let expired = false;
let cutInFlight = false;
let cuts = 0;
let refuseNew = true;
let refused = 0;
const log: string[] = [];

function trickle(body: Buffer, pathname: string): ReadableStream<Uint8Array> {
  let offset = 0;
  const chunk = 4096;
  const opened = cuts;
  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      // Only the responses that were open when the cut was made: a new one is a new connection.
      if (cuts !== opened) {
        controller.error(new Error('cut'));
        return;
      }
      if (offset >= body.length) {
        controller.close();
        return;
      }
      await Bun.sleep((chunk / rate) * 1000);
      const piece = body.subarray(offset, offset + chunk);
      controller.enqueue(piece);
      sent[pathname] = (sent[pathname] ?? 0) + piece.length;
      offset += chunk;
    },
  });
}

function serve(request: Request, body: Buffer, pathname: string): Response {
  const range = /bytes=(\d+)-(\d*)/.exec(request.headers.get('range') ?? '');
  const headers = { 'Content-Type': 'video/webm', 'Accept-Ranges': 'bytes' };
  if (!range) return new Response(trickle(body, pathname), { headers: { ...headers, 'Content-Length': String(body.length) } });
  const start = Number(range[1]);
  const end = range[2] === '' ? body.length - 1 : Math.min(Number(range[2]), body.length - 1);
  const part = body.subarray(start, end + 1);
  return new Response(trickle(part, pathname), {
    status: 206,
    headers: { ...headers, 'Content-Range': `bytes ${start}-${end}/${body.length}`, 'Content-Length': String(part.length) },
  });
}

const server = Bun.serve({
  port: 0,
  idleTimeout: 0,
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === '/__expire') {
      expired = true;
      cutInFlight = url.searchParams.get('cut') === '1';
      if (cutInFlight) cuts++;
      // `refuse=0`: cut the connections but keep answering new requests, the control that
      // separates "the connection went" from "the URL expired".
      refuseNew = url.searchParams.get('refuse') !== '0';
      console.log(`EXPIRED ${Date.now() - t0} cut=${cutInFlight} refuse=${refuseNew}`);
      return new Response('ok');
    }
    if (url.pathname === '/__bytes') return new Response(JSON.stringify(sent));
    if (url.pathname === '/__count') return new Response(`${refused} refused: ${log.join(', ')}`);
    if (expired && refuseNew) {
      refused++;
      log.push(`${Date.now() - t0}ms ${url.pathname} ${request.headers.get('range') ?? ''}`);
      return new Response('Forbidden', { status: 403 });
    }
    const body = files[url.pathname];
    if (!body) return new Response('not found', { status: 404 });
    return serve(request, body, url.pathname);
  },
});
console.log(`PORT ${server.port}`);
