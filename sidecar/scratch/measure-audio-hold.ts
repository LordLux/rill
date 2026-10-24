/**
 * Todo 102: does the picture wait for the audio when the audio is slow?
 *
 * Two ways of giving mpv a video-only URL and a separate audio URL, against a local
 * server (`measure-audio-hold-server.ts`, its own process) that holds the audio's first
 * byte back for `DELAY_MS`, default 3000:
 *
 *   atload   the audio goes in `audio-files` before `loadfile`, as the engine does now
 *   after    `loadfile` first, then `audio-add … select` once the duration is known,
 *            which is what the engine did before and why a video could play silent
 *
 * Each one prints a line whenever `time-pos`, the audio decoder's sample rate, `aid` or
 * `core-idle` changes, until `SECONDS`. The question is whether `time-pos` moves before
 * the audio is there. Run through the *bundled* libmpv (hard invariant 8), `vo=null`
 * and `ao=null`: the clock still runs, nothing is drawn or heard.
 *
 * Media: any video-only and any audio-only file. The installed standalone mpv can make
 * them with its encoder, no ffmpeg needed:
 *
 *   mpv "av://lavfi:testsrc=size=320x240:rate=25" --length=20 --no-audio --ovc=libvpx --of=webm --o=v.webm
 *   mpv "av://lavfi:sine=frequency=440:sample_rate=48000" --length=20 --no-video --oac=libopus --of=webm --o=a.webm
 *
 *   VIDEO=v.webm AUDIO=a.webm bun run scratch/measure-audio-hold.ts [atload|after]
 */
import { CString, dlopen, FFIType, ptr } from 'bun:ffi';
import * as path from 'path';

const DLL = 'C:/Projects/NativeYouTube/app/build/windows/x64/runner/Release/libmpv-2.dll';
const DELAY_MS = Number(process.env['DELAY_MS'] ?? 3000);
const SECONDS = Number(process.env['SECONDS'] ?? 9);
const mode = process.argv[2] ?? 'atload';
if (!process.env['VIDEO'] || !process.env['AUDIO']) {
  throw new Error('set VIDEO and AUDIO to a video-only and an audio-only file');
}

const server = Bun.spawn(['bun', path.join(import.meta.dir, 'measure-audio-hold-server.ts')], {
  env: { ...process.env, DELAY_MS: String(DELAY_MS) },
  stdout: 'pipe',
  stderr: 'inherit',
});

let t0 = Date.now();
let audioFirstByteAt = -1;
let resolvePort: (port: number) => void = () => {};
const portReady = new Promise<number>((resolve) => (resolvePort = resolve));
void (async () => {
  const decoder = new TextDecoder();
  let buffered = '';
  for await (const chunk of server.stdout) {
    buffered += decoder.decode(chunk);
    for (const line of buffered.split('\n').slice(0, -1)) {
      if (line.startsWith('PORT ')) resolvePort(Number(line.slice(5)));
      if (line.startsWith('AUDIO-FIRST-BYTE')) audioFirstByteAt = Date.now() - t0;
    }
    buffered = buffered.slice(buffered.lastIndexOf('\n') + 1);
  }
})();
const base = `http://127.0.0.1:${await portReady}`;

const lib = dlopen(DLL, {
  mpv_create: { args: [], returns: FFIType.ptr },
  mpv_initialize: { args: [FFIType.ptr], returns: FFIType.int },
  mpv_set_option_string: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.int },
  mpv_command_string: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.int },
  mpv_get_property_string: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
  mpv_free: { args: [FFIType.ptr], returns: FFIType.void },
  mpv_wait_event: { args: [FFIType.ptr, FFIType.double], returns: FFIType.ptr },
  mpv_terminate_destroy: { args: [FFIType.ptr], returns: FFIType.void },
});

const held: Buffer[] = [];
const cstr = (value: string) => {
  const buffer = Buffer.from(value + '\0', 'utf8');
  held.push(buffer);
  return ptr(buffer);
};

const h = lib.symbols.mpv_create();
const opt = (name: string, value: string) => lib.symbols.mpv_set_option_string(h, cstr(name), cstr(value));
const prop = (name: string): string | null => {
  const raw = lib.symbols.mpv_get_property_string(h, cstr(name));
  if (!raw) return null;
  const value = new CString(raw).toString();
  lib.symbols.mpv_free(raw);
  return value;
};
const cmd = (line: string) => lib.symbols.mpv_command_string(h, cstr(line));
const stamp = () => String(Date.now() - t0).padStart(5) + ' ms';

opt('terminal', 'no');
opt('msg-level', 'all=error');
if (process.env['LOG_FILE']) opt('log-file', process.env['LOG_FILE']);
opt('vo', 'null');
opt('ao', 'null');
opt('hwdec', 'no');
opt('keep-open', 'yes');
opt('pause', 'no');
// The bundled build's own defaults otherwise: nothing here is tuned towards an answer.
if (mode === 'atload') opt('audio-files', `${base}/a.webm`);
if (lib.symbols.mpv_initialize(h) < 0) throw new Error('mpv_initialize failed');

console.log(`mode=${mode}, audio first byte held ${DELAY_MS} ms`);
t0 = Date.now();
cmd(`loadfile "${base}/v.webm"`);

let attached = false;
let last = '';
while (Date.now() - t0 < SECONDS * 1000) {
  lib.symbols.mpv_wait_event(h, 0);

  if (mode === 'after' && !attached && Number(prop('duration') ?? 0) > 0) {
    attached = true;
    console.log(`${stamp()}  duration known, audio-add (blocks until the audio has opened)`);
    cmd(`audio-add "${base}/a.webm" select`);
    console.log(`${stamp()}  audio-add returned`);
  }

  const pos = prop('time-pos');
  const line =
    `time-pos=${pos === null ? '-' : Math.floor(Number(pos) * 10) / 10} ` +
    `audio=${prop('audio-params/samplerate') ?? 'none'} aid=${prop('aid') ?? '-'} idle=${prop('core-idle') ?? '-'}`;
  if (line !== last) {
    console.log(`${stamp()}  ${line}`);
    last = line;
  }
  await Bun.sleep(20);
}
console.log(`audio first byte left the server at about ${audioFirstByteAt} ms`);
lib.symbols.mpv_terminate_destroy(h);
server.kill();
