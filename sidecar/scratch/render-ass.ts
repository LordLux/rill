// Render an ASS file over a solid colour through the *bundled* libmpv (libass).
// Hard invariant 8: measure the artefact the app actually loads, not a version number.
import { dlopen, FFIType, ptr, toArrayBuffer } from 'bun:ffi';
import * as fs from 'fs';

const DLL = 'C:/Projects/NativeYouTube/app/build/windows/x64/runner/Release/libmpv-2.dll';

const lib = dlopen(DLL, {
  mpv_create: { args: [], returns: FFIType.ptr },
  mpv_initialize: { args: [FFIType.ptr], returns: FFIType.int },
  mpv_set_option_string: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.int },
  mpv_command_string: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.int },
  mpv_wait_event: { args: [FFIType.ptr, FFIType.double], returns: FFIType.ptr },
  mpv_terminate_destroy: { args: [FFIType.ptr], returns: FFIType.void },
  mpv_error_string: { args: [FFIType.int], returns: FFIType.ptr },
});

const held: Buffer[] = [];
const cstr = (s: string) => {
  const b = Buffer.from(s + '\0', 'utf8');
  held.push(b);
  return ptr(b);
};

const assFile = process.argv[2]!;
const outDir = process.argv[3]!;
const seconds = Number(process.argv[4] ?? '1');
const fwd = (p: string) => p.split('\\').join('/');

fs.mkdirSync(outDir, { recursive: true });
for (const f of fs.readdirSync(outDir)) fs.unlinkSync(`${outDir}/${f}`);

const h = lib.symbols.mpv_create();
if (!h) throw new Error('mpv_create failed');

function opt(name: string, value: string) {
  const rc = lib.symbols.mpv_set_option_string(h, cstr(name), cstr(value));
  if (rc < 0) console.error(`  ! set ${name}=${value} -> rc ${rc}`);
}

opt('terminal', 'yes');
opt('msg-level', 'all=error');
opt('vo', 'image');
opt('vo-image-format', process.env['IMGFMT'] ?? 'tga');
opt('vo-image-outdir', fwd(outDir));
opt('sub-files', fwd(assFile));
opt('sid', '1');
opt('audio', 'no');
opt('untimed', 'yes');
opt('hwdec', 'no');
opt('keep-open', 'no');
opt('demuxer', 'rawvideo');
opt('demuxer-rawvideo-w', '1920');
opt('demuxer-rawvideo-h', '1080');
opt('demuxer-rawvideo-mp-format', 'bgr24');
opt('demuxer-rawvideo-fps', '2');

const rc = lib.symbols.mpv_initialize(h);
if (rc < 0) throw new Error('mpv_initialize failed: ' + rc);

const src = process.env['BG'] ?? 'bg.raw';
void seconds;
lib.symbols.mpv_command_string(h, cstr(`loadfile "${src}"`));

const start = Date.now();
while (Date.now() - start < 60_000) {
  const ev = lib.symbols.mpv_wait_event(h, 0.5);
  if (!ev) continue;
  const eventId = new DataView(toArrayBuffer(ev, 0, 8)).getInt32(0, true);
  if (eventId === 7) { console.log('end-file'); break; }
  if (eventId === 1) { console.log('shutdown'); break; }
}
lib.symbols.mpv_terminate_destroy(h);
console.log('frames written:', fs.readdirSync(outDir).join(', ') || '(none)');
