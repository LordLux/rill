/**
 * Todo 103, `video-add` as the quality switch: three questions the in-app probe could not ask.
 *
 *   keeps    after `video-add <v2> select` and a seek to the current position, does the original
 *            video track (deselected, and not removable) keep downloading? A server that
 *            trickles at `RATE` bytes/s counts what each path puts on the wire; if `/v.webm`'s
 *            count goes on climbing after the switch, a switch at 2160p costs double bandwidth.
 *   paused   a switch while paused: the clock never moves, so "position passed target + 0.4 s"
 *            cannot be the done signal. Which properties change, and when?
 *   remove   what `video-remove` says about the file's own track, and about the added one.
 *
 * Through the *bundled* libmpv (hard invariant 8), `vo=null ao=null`. The server is
 * `measure-expiry-server.ts` (its own process) with `VIDEO2` set.
 *
 *   VIDEO=v1.webm VIDEO2=v2.webm AUDIO=a.webm bun run scratch/measure-deselected.ts keeps|paused|remove
 */
import { CString, dlopen, FFIType, ptr } from 'bun:ffi';
import * as path from 'path';

const DLL = 'C:/Projects/NativeYouTube/app/build/windows/x64/runner/Release/libmpv-2.dll';
const arm = process.argv[2] ?? 'keeps';
const SECONDS = Number(process.env['SECONDS'] ?? 40);
if (!process.env['VIDEO'] || !process.env['VIDEO2'] || !process.env['AUDIO']) throw new Error('set VIDEO, VIDEO2 and AUDIO');

const server = Bun.spawn(['bun', path.join(import.meta.dir, 'measure-expiry-server.ts')], {
  env: { ...process.env, RATE: process.env['RATE'] ?? '40000' },
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

opt('terminal', 'no');
opt('msg-level', 'all=error');
opt('vo', 'null');
opt('ao', 'null');
opt('hwdec', 'no');
opt('keep-open', 'yes');
// `audiomain`: the audio is the file mpv opens and every video is added to it, so none of them is
// the file's own, undeselectable track.
if (arm !== 'audiomain') opt('audio-files', `${base}/a.webm`);
if (lib.symbols.mpv_initialize(h) < 0) throw new Error('mpv_initialize failed');

const t0 = Date.now();
const stamp = () => String(Date.now() - t0).padStart(6) + ' ms';
const bytes = async () => (await (await fetch(`${base}/__bytes`)).json()) as Record<string, number>;
const tracks = () => {
  const count = Number(prop('track-list/count') ?? 0);
  const out: string[] = [];
  for (let i = 0; i < count; i++) {
    out.push(`${prop(`track-list/${i}/type`)}#${prop(`track-list/${i}/id`)}${prop(`track-list/${i}/selected`) === 'yes' ? '*' : ''}${prop(`track-list/${i}/external`) === 'yes' ? 'e' : ''}`);
  }
  return out.join(' ');
};

console.log(`arm=${arm}`);
cmd(`loadfile "${base}/${arm === 'audiomain' ? 'a' : 'v'}.webm"`);

let firstAdded = false;
let switched = false;
let removed = false;
let last = '';
let lastBytes = 0;
let nextBytes = 0;
const switchAt = arm === 'paused' ? 4500 : 6000;
while (Date.now() - t0 < SECONDS * 1000) {
  lib.symbols.mpv_wait_event(h, 0);
  const elapsed = Date.now() - t0;
  if (arm === 'audiomain' && !firstAdded && elapsed > 600) {
    firstAdded = true;
    const rc = cmd(`video-add "${base}/v.webm" select`);
    console.log(`${stamp()}  video-add v1 (the first quality) rc=${rc}, tracks: ${tracks()}`);
  }
  if (arm === 'paused' && elapsed > 3500 && prop('pause') !== 'yes') {
    cmd('set pause yes');
    console.log(`${stamp()}  PAUSED at ${prop('time-pos')}`);
  }
  if (!switched && elapsed > switchAt) {
    switched = true;
    const pos = Number(prop('time-pos') ?? 0);
    console.log(`${stamp()}  video-add v2 select (clock at ${pos}), tracks: ${tracks()}`);
    const rc = cmd(`video-add "${base}/v2.webm" select`);
    console.log(`${stamp()}  video-add returned rc=${rc}, tracks: ${tracks()}`);
    cmd(`seek ${pos} absolute`);
    console.log(`${stamp()}  seek ${pos} issued`);
  }
  if (arm === 'audiomain' && switched && !removed && elapsed > switchAt + 4000) {
    removed = true;
    const rc = cmd('video-remove 1');
    console.log(`${stamp()}  video-remove 1 (the first quality, added) rc=${rc}, tracks: ${tracks()}, vid=${prop('vid')}`);
  }
  if (arm === 'remove' && switched && !removed && elapsed > switchAt + 4000) {
    // Once, four seconds on.
    removed = true;
    const rcOriginal = cmd('video-remove 1');
    console.log(`${stamp()}  video-remove 1 (the file's own track) rc=${rcOriginal}, tracks: ${tracks()}`);
    const rcAdded = cmd('video-remove 2');
    console.log(`${stamp()}  video-remove 2 (the added one, selected) rc=${rcAdded}, tracks: ${tracks()}, vid=${prop('vid')}`);
  }
  const line =
    `time-pos=${prop('time-pos') === null ? '-' : Math.floor(Number(prop('time-pos')) * 10) / 10} seeking=${prop('seeking')} pause=${prop('pause')} ` +
    `core-idle=${prop('core-idle')} vid=${prop('vid')} w=${prop('video-params/w') ?? '-'} frame=${prop('estimated-frame-number')}`;
  if (arm === 'paused' && switched && line !== last) {
    console.log(`${stamp()}  ${line}`);
    last = line;
  }
  if (elapsed >= nextBytes) {
    nextBytes = elapsed + 2000;
    const sent = await bytes();
    const total = Object.values(sent).reduce((a, b) => a + b, 0);
    if (arm !== 'paused') {
      console.log(`${stamp()}  served: v1=${sent['/v.webm'] ?? 0} v2=${sent['/v2.webm'] ?? 0} audio=${sent['/a.webm'] ?? 0}  (+${total - lastBytes})${switched ? '' : '  [before switch]'}`);
    }
    lastBytes = total;
  }
  await Bun.sleep(40);
}
lib.symbols.mpv_terminate_destroy(h);
server.kill();
