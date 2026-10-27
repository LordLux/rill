/**
 * Todo 107: what happens today when a stream URL has expired and mpv reads from it again?
 *
 * Playing a video-only file with its audio in `audio-files`, both from a local server
 * (`measure-expiry-server.ts`, its own process) that answers 403 to everything once `/__expire`
 * is requested, which is what googlevideo does after `expire=`. The read-ahead is kept small
 * (`demuxer-max-bytes`, `demuxer-readahead-secs`) so the cache runs out within seconds and mpv has
 * to read again. Three arms:
 *
 *   play    expire at 4 s and let it play on
 *   seek    expire at 4 s, seek to 40 s at 6 s (a position nothing has read)
 *   pause   pause at 3 s, expire and cut the open connections, resume at 15 s (a long pause)
 *   pausecut  the same, but new requests are still answered: the control for "the connection went"
 *
 * Every change of `time-pos`, `core-idle`, `idle-active`, `eof-reached`, `paused-for-cache` and
 * `seeking` is printed with its time, then the errors from mpv's log. Through the *bundled*
 * libmpv (hard invariant 8). What the app makes of these is read from media_kit's source: it
 * maps `eof-reached` to `completed`, which the playback controller treats as the video ending.
 *
 *   VIDEO=v.webm AUDIO=a.webm bun run scratch/measure-expiry.ts play|seek|pause
 */
import { CString, dlopen, FFIType, ptr } from 'bun:ffi';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const DLL = 'C:/Projects/NativeYouTube/app/build/windows/x64/runner/Release/libmpv-2.dll';
const SECONDS = Number(process.env['SECONDS'] ?? 40);
const arm = process.argv[2] ?? 'play';
if (!process.env['VIDEO'] || !process.env['AUDIO']) throw new Error('set VIDEO and AUDIO');

const server = Bun.spawn(['bun', path.join(import.meta.dir, 'measure-expiry-server.ts')], {
  env: { ...process.env },
  stdout: 'pipe',
  stderr: 'inherit',
});
let resolvePort: (port: number) => void = () => {};
const portReady = new Promise<number>((resolve) => (resolvePort = resolve));
void (async () => {
  const decoder = new TextDecoder();
  let buffered = '';
  for await (const chunk of server.stdout) {
    buffered += decoder.decode(chunk);
    for (const line of buffered.split('\n').slice(0, -1)) if (line.startsWith('PORT ')) resolvePort(Number(line.slice(5)));
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
const logFile = path.join(os.tmpdir(), 'rill-expiry-mpv.log');
fs.rmSync(logFile, { force: true });

opt('terminal', 'no');
opt('msg-level', 'all=v');
opt('log-file', logFile);
opt('vo', 'null');
opt('ao', 'null');
opt('hwdec', 'no');
opt('keep-open', 'no');
// Small read-ahead: the cache has to run out for the expiry to matter.
opt('cache', 'yes');
opt('demuxer-max-bytes', '64KiB');
opt('demuxer-max-back-bytes', '0');
opt('demuxer-readahead-secs', '1');
opt('audio-files', `${base}/a.webm`);
if (lib.symbols.mpv_initialize(h) < 0) throw new Error('mpv_initialize failed');

const t0 = Date.now();
const stamp = () => String(Date.now() - t0).padStart(6) + ' ms';
console.log(`arm=${arm}`);
cmd(`loadfile "${base}/v.webm"`);

let expired = false;
let sought = false;
let paused = false;
let resumed = false;
let last = '';
while (Date.now() - t0 < SECONDS * 1000) {
  lib.symbols.mpv_wait_event(h, 0);
  const elapsed = Date.now() - t0;
  if (arm.startsWith('pause') && !paused && elapsed > 3000) {
    paused = true;
    cmd('set pause yes');
    console.log(`${stamp()}  PAUSED`);
  }
  if (!expired && elapsed > (arm.startsWith('pause') ? 3500 : 4000)) {
    expired = true;
    // `pause` also cuts the connections already open: a long pause lets them go.
    // `pausecut` is the control: the connections go, new requests are still answered.
    await fetch(`${base}/__expire${arm === 'pause' ? '?cut=1' : arm === 'pausecut' ? '?cut=1&refuse=0' : ''}`);
    console.log(`${stamp()}  URL EXPIRED (server answers 403 from here)`);
  }
  if (arm === 'seek' && expired && !sought && elapsed > 6000) {
    sought = true;
    cmd('seek 40 absolute');
    console.log(`${stamp()}  SEEK to 40`);
  }
  if (arm.startsWith('pause') && !resumed && elapsed > 15000) {
    resumed = true;
    cmd('set pause no');
    console.log(`${stamp()}  RESUMED`);
  }
  const pos = prop('time-pos');
  const line =
    `time-pos=${pos === null ? '-' : Math.floor(Number(pos))} idle-active=${prop('idle-active')} eof=${prop('eof-reached') ?? '-'} ` +
    `core-idle=${prop('core-idle')} cache-pause=${prop('paused-for-cache')} seeking=${prop('seeking')} pause=${prop('pause')}`;
  if (line !== last) {
    console.log(`${stamp()}  ${line}`);
    last = line;
  }
  await Bun.sleep(100);
}
const afterExpiry = await fetch(`${base}/__count`).then((r) => r.text());
console.log(`requests the server refused after expiry: ${afterExpiry}`);
lib.symbols.mpv_terminate_destroy(h);
server.kill();
const log = fs.readFileSync(logFile, 'utf8').split('\n');
console.log('--- mpv log, errors and the end of the file:');
for (const line of log) if (/\b(error|fatal|Failed|403|Forbidden|End of file|EOF|end-file|Exiting|abort)\b/i.test(line)) console.log(line.slice(0, 200));
