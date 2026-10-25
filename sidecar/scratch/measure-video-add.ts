/**
 * Spike: can a quality switch be a track switch on the playing file instead of a reopen?
 *
 * The audio is already a separate stream, so a switch only needs the video to change.
 * On a file that is playing (video 1 at load, the audio in `audio-files`), this issues
 * `video-add <video 2> select` and then `video-remove` on the old track, against a local
 * server that holds video 2's first byte for `DELAY_V2_MS` (default 3000). It reports:
 *
 *   - whether the playback clock (`time-pos`, which the audio drives) kept running while the
 *     command waited, and whether it ever stepped backwards;
 *   - how long the command took, and when `video-params/w` changed (the picture switched);
 *   - how many frames the image VO wrote per 250 ms around the switch (a frozen picture
 *     is a run of zeros), and the frame size of the first frame written after it;
 *   - whether an external subtitle track survived (`sub-add` before, `track-list` after);
 *   - where `time-pos` is after a seek straight after the switch.
 *
 * Through the *bundled* libmpv (hard invariant 8), `ao=null`, `vo=image` into a temp
 * folder: no window, nothing heard. Report only: nothing here is wired into the app.
 *
 * Media: `v1.webm` (320x240), `v2.webm` (336x252, close in size on purpose: the image VO
 * encodes a JPEG per frame and runs well under real time at 640x480), `a.webm`, each 60 s, in `MEDIA`. The
 * installed standalone mpv makes them with its encoder (see `measure-audio-hold.ts`).
 *
 *   MEDIA=<dir> bun run scratch/measure-video-add.ts
 */
import { CString, dlopen, FFIType, ptr } from 'bun:ffi';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const DLL = 'C:/Projects/NativeYouTube/app/build/windows/x64/runner/Release/libmpv-2.dll';
const MEDIA = process.env['MEDIA'];
if (!MEDIA) throw new Error('set MEDIA to the folder holding v1.webm, v2.webm and a.webm');
const DELAY_V2_MS = Number(process.env['DELAY_V2_MS'] ?? 3000);

const server = Bun.spawn(['bun', path.join(import.meta.dir, 'measure-video-add-server.ts')], {
  env: { ...process.env, MEDIA, DELAY_V2_MS: String(DELAY_V2_MS) },
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

const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'rill-video-add-'));
const subPath = path.join(outDir, 'captions.ass').split(path.sep).join('/');
fs.writeFileSync(
  subPath,
  [
    '[Script Info]',
    'ScriptType: v4.00+',
    'PlayResX: 640',
    'PlayResY: 480',
    '',
    '[V4+ Styles]',
    'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
    'Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1',
    '',
    '[Events]',
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
    'Dialogue: 0,0:00:00.00,0:01:00.00,Default,,0,0,0,,caption survives',
  ].join('\n'),
);

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
const num = (name: string) => Number(prop(name) ?? NaN);

opt('terminal', 'no');
opt('msg-level', 'all=error');
if (process.env['LOG_FILE']) opt('log-file', process.env['LOG_FILE']);
opt('ao', 'null');
opt('vo', 'image');
opt('vo-image-format', 'jpg');
opt('vo-image-outdir', outDir.split(path.sep).join('/'));
opt('hwdec', 'no');
opt('keep-open', 'yes');
opt('audio-files', `${base}/a.webm`);
if (lib.symbols.mpv_initialize(h) < 0) throw new Error('mpv_initialize failed');

const frames = () => fs.readdirSync(outDir).filter((name) => name.endsWith('.jpg')).length;
const jpgWidth = (file: string): number => {
  // The SOF0/SOF2 marker holds height then width; enough to tell 320 from 336.
  const bytes = fs.readFileSync(path.join(outDir, file));
  for (let i = 2; i + 9 < bytes.length; ) {
    if (bytes[i] !== 0xff) return -1;
    const marker = bytes[i + 1]!;
    if (marker === 0xc0 || marker === 0xc2) return (bytes[i + 7]! << 8) | bytes[i + 8]!;
    i += 2 + ((bytes[i + 2]! << 8) | bytes[i + 3]!);
  }
  return -1;
};
const sleep = (ms: number) => Bun.sleep(ms);
const t0 = Date.now();
const stamp = () => `${String(Date.now() - t0).padStart(6)} ms`;

// BASELINE=1: play video 2 from the start and never switch, to see what its own frame rate is
// on this machine through this VO, so the rate after a switch is not blamed on the switch.
const baseline = process.env['BASELINE'] === '1';
console.log(`video 2's first byte held ${DELAY_V2_MS} ms${baseline ? ' (baseline: no switch, video 2 from the start)' : ''}`);
cmd(`loadfile "${base}/${baseline ? 'v2' : 'v1'}.webm"`);
while (!(num('time-pos') >= 4) && Date.now() - t0 < 30000) {
  lib.symbols.mpv_wait_event(h, 0);
  await sleep(20);
}
console.log(`${stamp()}  playing: time-pos=${num('time-pos').toFixed(2)} w=${prop('video-params/w')} vid=${prop('vid')}`);
cmd(`sub-add "${subPath}" select`);
await sleep(300);
const tracksBefore = prop('track-list/count');
console.log(`${stamp()}  tracks before: ${tracksBefore}, sid=${prop('sid')}, oldVid=${prop('vid')}`);

// Frames written per 250 ms window, with the playback clock, to see a stall as a run of zeros.
const timeline: string[] = [];
let lastFrames = frames();
let lastSample = Date.now();
const sample = (label: string) => {
  const now = Date.now();
  if (now - lastSample >= 250) {
    const written = frames();
    timeline.push(`${stamp()}  ${label} +${written - lastFrames} frames  time-pos=${num('time-pos').toFixed(2)} w=${prop('video-params/w')}`);
    lastFrames = written;
    lastSample = now;
  }
};

const oldVid = prop('vid');
const posBefore = num('time-pos');
const framesBefore = frames();
const issued = Date.now();
console.log(`${stamp()}  video-add issued at time-pos=${posBefore.toFixed(2)}`);
if (!baseline) cmd(`video-add "${base}/v2.webm" select`);
const tookMs = Date.now() - issued;
const posAfter = num('time-pos');
console.log(
  `${stamp()}  video-add returned after ${tookMs} ms; time-pos ${posBefore.toFixed(2)} -> ${posAfter.toFixed(2)} ` +
    `(clock advanced ${(posAfter - posBefore).toFixed(2)} s in ${(tookMs / 1000).toFixed(2)} s of wall time), ` +
    `${frames() - framesBefore} frames written meanwhile, w=${prop('video-params/w')}, vid=${prop('vid')}`,
);

let widthChangedAt = -1;
let backwards = 0;
let prev = posAfter;
const switchedFrames = frames();
for (const until = Date.now() + 4000; Date.now() < until; ) {
  lib.symbols.mpv_wait_event(h, 0);
  const pos = num('time-pos');
  if (pos < prev - 0.05) backwards++;
  prev = pos;
  if (widthChangedAt < 0 && prop('video-params/w') === '336') widthChangedAt = Date.now() - issued;
  sample('after');
  await sleep(20);
}
console.log(`video-params/w became 336 ${widthChangedAt < 0 ? 'never' : `${widthChangedAt} ms after the command was issued`}; time-pos stepped backwards ${backwards} time(s)`);
const firstAfter = fs.readdirSync(outDir).filter((n) => n.endsWith('.jpg')).sort().slice(switchedFrames)[0];
console.log(`first frame written after the switch is ${firstAfter ? jpgWidth(firstAfter) : 'none'} px wide`);

console.log(`${stamp()}  video-remove ${oldVid}: ${cmd(`video-remove ${oldVid}`)}`);
await sleep(300);
const subs = JSON.parse(prop('track-list') ?? '[]') as { type: string; selected: boolean; external: boolean }[];
console.log(
  `tracks now: ${subs.map((t) => `${t.type}${t.external ? '(ext)' : ''}${t.selected ? '*' : ''}`).join(' ')}; sid=${prop('sid')} vid=${prop('vid')} aid=${prop('aid')}`,
);

cmd('seek 30 absolute');
await sleep(1200);
console.log(`after seek 30: time-pos=${num('time-pos').toFixed(2)} w=${prop('video-params/w')} frames still arriving: ${frames() > lastFrames}`);

// The audio-only toggle is `vid=no` and back (`vid=auto`): which video comes back after a switch?
cmd('set vid no');
await sleep(500);
const vidOff = `vid=${prop('vid')}`;
cmd('set vid auto');
await sleep(1500);
console.log(`audio-only round trip: ${vidOff}, then vid=auto gives vid=${prop('vid')} w=${prop('video-params/w')} (336 is the added track, 320 the file's own)`);

// A second switch, back to the first quality's URL, removing the track the last one added.
const second = prop('vid');
const secondIssued = Date.now();
cmd(`video-add "${base}/v1.webm" select`);
console.log(`second video-add returned after ${Date.now() - secondIssued} ms: w=${prop('video-params/w')} vid=${prop('vid')}; remove ${second}: ${cmd(`video-remove ${second}`)}`);
await sleep(500);
const after2 = JSON.parse(prop('track-list') ?? '[]') as { type: string; selected: boolean; external: boolean }[];
console.log(`tracks after the second switch: ${after2.map((t) => `${t.type}${t.external ? '(ext)' : ''}${t.selected ? '*' : ''}`).join(' ')}`);

console.log('--- frames written per ~250 ms after the command returned ---');
console.log(timeline.slice(0, 16).join('\n'));
lib.symbols.mpv_terminate_destroy(h);
server.kill();
fs.rmSync(outDir, { recursive: true, force: true });
