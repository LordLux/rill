/**
 * The server half of `measure-audio-hold.ts`, in its own process: mpv's `audio-add`
 * blocks the thread that issues it until the audio opens, so a server on that thread
 * can never answer and the two deadlock.
 *
 * Prints `PORT <n>` and then `AUDIO-FIRST-BYTE <ms since start>` when the held
 * response is released (`VIDEO-FIRST-BYTE` likewise for the video when `VIDEO_DELAY_MS` is set).
 * `VIDEO`, `AUDIO`, `DELAY_MS` and `AUDIO_STATUS` come from the environment.
 */
import * as fs from 'fs';

const videoBytes = fs.readFileSync(process.env['VIDEO']!);
const audioBytes = fs.readFileSync(process.env['AUDIO']!);
const delayMs = Number(process.env['DELAY_MS'] ?? 3000);
const videoDelayMs = Number(process.env['VIDEO_DELAY_MS'] ?? 0);
const t0 = Date.now();
let audioRequests = 0;
let videoRequests = 0;

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
    const url = new URL(request.url);
    if (url.pathname === '/v.webm') {
      videoRequests++;
      // `VIDEO_DELAY_MS`: the video's first byte held too. Only the first request, as for the audio.
      if (videoRequests === 1 && videoDelayMs > 0) {
        await Bun.sleep(videoDelayMs);
        console.log(`VIDEO-FIRST-BYTE ${Date.now() - t0}`);
      }
      return serve(request, videoBytes);
    }
    if (url.pathname === '/a.webm') {
      audioRequests++;
      // `AUDIO_STATUS=404`: an audio URL that is dead, to see what mpv does with it.
      if (process.env['AUDIO_STATUS'] === '404') {
        console.log(`AUDIO-FIRST-BYTE ${Date.now() - t0}`);
        return new Response('gone', { status: 404 });
      }
      // Only the first request is held: that is the one a slow audio start is.
      if (audioRequests === 1) {
        await Bun.sleep(delayMs);
        console.log(`AUDIO-FIRST-BYTE ${Date.now() - t0}`);
      }
      return serve(request, audioBytes);
    }
    return new Response('not found', { status: 404 });
  },
});
console.log(`PORT ${server.port}`);
