/**
 * Task 19 end to end: real caption tracks, real documents, real libass.
 *
 * **Needs a release build of this checkout (`.\rill build`) and network
 * access.** It loads the bundled `libmpv-2.dll` from
 * `app/build/windows/x64/runner/Release/` and fetches real tracks. Position is
 * checked on rendered pixels; colour is checked in the document (inline `\c&H`
 * tags), not on pixels.
 *
 * Everything the feature does to a caption happens between `captions.get` and
 * the pixels libass draws, and both ends of that are reachable offline-ish from
 * here — the sidecar fetches a genuine YouTube track, and the *bundled*
 * `libmpv-2.dll` renders what comes back (hard invariant 8). So each claim below
 * is checked against a frame rather than against the document that was supposed
 * to produce one.
 *
 * What it covers: a drag on a plain track, a drag on a styled one, and three
 * style changes. What it does not: the gesture itself, `CaptionsState`'s
 * reset-on-track-change rules, and — since phase 5 — **the clamp**, which is no
 * longer the document's job at all. `LibassLayer` clamps against the boxes
 * `ass_render_frame` returns; what is asserted here is the property that makes
 * that trustworthy, namely that the document applies the delta and nothing else.
 * The Flutter side is `app/test/caption_style_test.dart` and
 * `app/test/probe_drag_lag.dart`.
 *
 *   bun run scratch/probe-task19.ts [outdir]
 */
import { dlopen, FFIType, ptr, toArrayBuffer } from 'bun:ffi';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { createSession } from '../src/innertube/session.ts';
import { getCaptionTrack, listCaptionTracks } from '../src/captions/service.ts';
import type { CaptionStyle } from '../src/captions/style.ts';

const DLL = path.join(import.meta.dir, '..', '..', 'app', 'build', 'windows', 'x64', 'runner', 'Release', 'libmpv-2.dll');
if (!fs.existsSync(DLL)) {
  console.error(`no release build at ${DLL}: run .\\rill build first`);
  process.exit(1);
}
const WIDTH = 1920;
const HEIGHT = 1080;

/** A plain manual/ASR track, and a document that carries real per-cue styling. */
const PLAIN = 'dQw4w9WgXcQ';
const STYLED = 'L-BgxLtMxh0';

const NO_STYLE: CaptionStyle = {
  fontFamily: null,
  fontSizePercent: null,
  textColor: null,
  background: null,
  window: null,
  edgeStyle: null,
};

const lib = dlopen(DLL, {
  mpv_create: { args: [], returns: FFIType.ptr },
  mpv_initialize: { args: [FFIType.ptr], returns: FFIType.int },
  mpv_set_option_string: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.int },
  mpv_command_string: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.int },
  mpv_wait_event: { args: [FFIType.ptr, FFIType.double], returns: FFIType.ptr },
  mpv_terminate_destroy: { args: [FFIType.ptr], returns: FFIType.void },
});

const BS = String.fromCharCode(92);
const fwd = (value: string) => value.split(BS).join('/');
const keep = process.argv[2];

interface Ink {
  left: number;
  right: number;
  top: number;
  bottom: number;
  pixels: number;
}

/**
 * Where the caption actually lands, in frame pixels, at [atSeconds].
 *
 * The ink extent of everything that is not the flat background — glyphs, box and
 * window together, which is exactly what "the caption" means to someone dragging
 * it.
 */
function renderInk(document: string, atSeconds: number, label: string): Ink | null {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rill-t19-'));
  const assPath = path.join(dir, 'm.ass');
  const rawPath = path.join(dir, 'bg.raw');
  fs.writeFileSync(assPath, document, 'utf8');
  // One frame per second of the clip, mid grey so a 75% black box reads clearly.
  const frames = atSeconds + 1;
  fs.writeFileSync(rawPath, Buffer.alloc(WIDTH * HEIGHT * 3 * frames, 128));

  const held: Buffer[] = [];
  const cstr = (value: string) => {
    const buffer = Buffer.from(value + '\0', 'utf8');
    held.push(buffer);
    return ptr(buffer);
  };
  const h = lib.symbols.mpv_create();
  const opt = (name: string, value: string) =>
    lib.symbols.mpv_set_option_string(h, cstr(name), cstr(value));

  opt('terminal', 'yes');
  opt('msg-level', 'all=error');
  opt('vo', 'image');
  opt('vo-image-format', 'jpg');
  opt('vo-image-outdir', fwd(dir));
  opt('sub-files', fwd(assPath));
  opt('sid', '1');
  // Exactly what media_kit sets with `libass: true` — the shipping configuration.
  opt('sub-ass', 'yes');
  opt('sub-visibility', 'yes');
  opt('audio', 'no');
  opt('untimed', 'yes');
  opt('hwdec', 'no');
  opt('keep-open', 'no');
  opt('demuxer', 'rawvideo');
  opt('demuxer-rawvideo-w', String(WIDTH));
  opt('demuxer-rawvideo-h', String(HEIGHT));
  opt('demuxer-rawvideo-mp-format', 'bgr24');
  opt('demuxer-rawvideo-fps', '1');

  lib.symbols.mpv_initialize(h);
  lib.symbols.mpv_command_string(h, cstr(`loadfile "${fwd(rawPath)}"`));
  const started = Date.now();
  while (Date.now() - started < 60_000) {
    const event = lib.symbols.mpv_wait_event(h, 0.5);
    if (!event) continue;
    const id = new DataView(toArrayBuffer(event, 0, 8)).getInt32(0, true);
    if (id === 7 || id === 1) break;
  }
  lib.symbols.mpv_terminate_destroy(h);

  const frame = fs
    .readdirSync(dir)
    .filter((name) => /[.]jpg$/.test(name))
    .sort()[atSeconds];
  if (frame === undefined) {
    fs.rmSync(dir, { recursive: true, force: true });
    return null;
  }
  const bmpPath = path.join(dir, 'frame.bmp');
  Bun.spawnSync([
    'powershell',
    '-NoProfile',
    '-Command',
    `Add-Type -AssemblyName System.Drawing; $i = [System.Drawing.Image]::FromFile(` +
      `'${path.join(dir, frame)}'); $i.Save('${bmpPath}', ` +
      `[System.Drawing.Imaging.ImageFormat]::Bmp); $i.Dispose()`,
  ]);
  const bmp = fs.readFileSync(bmpPath);
  const offset = bmp.readUInt32LE(10);
  const bpp = bmp.readUInt16LE(28) / 8;
  const stride = Math.ceil((bmp.readInt32LE(18) * bpp) / 4) * 4;

  let left = WIDTH;
  let right = -1;
  let top = HEIGHT;
  let bottom = -1;
  let pixels = 0;
  for (let y = 0; y < HEIGHT; y++) {
    const base = offset + (HEIGHT - 1 - y) * stride;
    for (let x = 0; x < WIDTH; x++) {
      const at = base + x * bpp;
      const b = bmp[at]!;
      const g = bmp[at + 1]!;
      const r = bmp[at + 2]!;
      if (Math.abs(r - 128) < 20 && Math.abs(g - 128) < 20 && Math.abs(b - 128) < 20) continue;
      pixels++;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  if (keep !== undefined && pixels > 0) {
    fs.mkdirSync(keep, { recursive: true });
    fs.copyFileSync(path.join(dir, frame), path.join(keep, `${label}.jpg`));
  }
  fs.rmSync(dir, { recursive: true, force: true });
  return pixels === 0 ? null : { left, right, top, bottom, pixels };
}

let failures = 0;
function check(claim: string, ok: boolean, detail: string): void {
  if (!ok) failures++;
  console.error(`  ${ok ? 'OK  ' : 'FAIL'} ${claim.padEnd(52)} ${detail}`);
}

/**
 * A whole second that lies strictly inside some cue, so the frame has ink.
 *
 * Not "the first cue's start second": a cue that begins at 0.32 s and ends at
 * 0.90 s is over before the second frame, and a document whose opening line is
 * short then reports as rendering nothing at all. The first cue wide enough to
 * contain an integer second is the one worth rendering.
 */
function frameSecondWithCue(document: string): number {
  for (const line of document.split(String.fromCharCode(10))) {
    const match =
      /^Dialogue: (\d+),(\d):(\d\d):(\d\d)[.](\d\d),(\d):(\d\d):(\d\d)[.](\d\d),([^,]+),(?:[^,]*,){5}(.*)$/.exec(
        line,
      );
    if (match === null) continue;
    if (match[10] !== 'Default') continue;
    // Strip the override block and YouTube's zero-width separators: a styled
    // track opens with an invisible spacer cue, and rendering the frame it is on
    // reports the whole document as drawing nothing.
    const text = match[11]!.replace(/\{[^}]*\}/g, '').split('​').join('').trim();
    if (text === '') continue;

    const at = (h: string, m: string, sec: string, cs: string) =>
      Number(h) * 3600 + Number(m) * 60 + Number(sec) + Number(cs) / 100;
    const start = at(match[2]!, match[3]!, match[4]!, match[5]!);
    const end = at(match[6]!, match[7]!, match[8]!, match[9]!);
    const second = Math.ceil(start);
    if (second < end && second <= 90) return second;
  }
  return 1;
}

async function main(): Promise<void> {
  const session = await createSession({ clientType: 'MWEB' });

  for (const [kind, videoId] of [
    ['plain', PLAIN],
    ['styled', STYLED],
  ] as const) {
    const { sources } = await listCaptionTracks(session, videoId);
    const source = sources.find((candidate) => candidate.track.languageCode.startsWith('en'));
    if (source === undefined) {
      console.error(`\n${kind} (${videoId}): no English track — skipped`);
      continue;
    }
    const trackId = source.track.id;
    console.error(`\n${kind} (${videoId} / ${trackId})`);

    const home = await getCaptionTrack(session, videoId, trackId, {});
    const second = frameSecondWithCue(home.content);
    const at = renderInk(home.content, second, `${kind}-home`);
    if (at === null) {
      check('a caption renders at all', false, `nothing on frame ${second}`);
      continue;
    }
    check(
      'a caption renders at all',
      true,
      `ink ${at.right - at.left + 1}x${at.bottom - at.top + 1} at (${at.left},${at.top})`,
    );
    check(
      'the layout descriptor rides along',
      home.layout?.playResX === 1920 && home.layout?.fontSize === 48,
      `font ${home.layout?.fontFamily} ${home.layout?.fontSize}, anchor ` +
        `(${home.layout?.defaultX},${home.layout?.defaultY})`,
    );
    check(
      'classification resolves positional flag',
      home.positional !== null &&
        (kind === 'styled' ? home.positional === true : home.positional === false),
      `positional: ${home.positional}`,
    );

    // --- the drag -----------------------------------------------------------
    const dragged = await getCaptionTrack(session, videoId, trackId, {
      offset: { dx: -0.2, dy: -0.3 },
    });
    const movedTo = renderInk(dragged.content, second, `${kind}-dragged`);
    check(
      'a drag moves the caption on screen',
      movedTo !== null && movedTo.left < at.left && movedTo.top < at.top,
      movedTo === null
        ? 'nothing rendered'
        : `(${at.left},${at.top}) -> (${movedTo.left},${movedTo.top}), ` +
          `wanted about (${at.left - 384},${at.top - 324})`,
    );
    check(
      'the same request is byte-identical (the cache key carries the delta)',
      (await getCaptionTrack(session, videoId, trackId, { offset: { dx: -0.2, dy: -0.3 } }))
        .content === dragged.content,
      'second fetch matched',
    );
    check(
      'a zero delta is the untouched document',
      (await getCaptionTrack(session, videoId, trackId, { offset: { dx: 0, dy: 0 } })).content ===
        home.content,
      'byte-identical',
    );

    // --- no clamp -----------------------------------------------------------
    // Phase 5 retired the server-side clamp with the mpv pipeline it was built
    // for. It existed because nothing could see where libass put a line, so the
    // sidecar estimated a width from a client-supplied advance table and pulled
    // an over-far drag back inside the frame. `LibassLayer` reads the rendered
    // boxes out of `ass_render_frame` and clamps against those, every frame, so
    // the document now carries the position it was asked for and the client is
    // the only thing that decides where a caption may sit.
    //
    // The two claims here used to be "nothing leaves the frame" and "a longer
    // cue is pushed further in". Both are now false of the *document* on
    // purpose, and asserting them again is what re-introduces a second, worse
    // clamp. What replaces them is the property that makes the client's clamp
    // trustworthy: the document is a pure function of the anchor and the delta.
    const corner = await getCaptionTrack(session, videoId, trackId, {
      offset: { dx: 0.5, dy: 0.5 },
    });
    const cornerX = [...corner.content.matchAll(/\\pos\((-?\d+),(-?\d+)\)/g)].map((m) => ({
      x: Number(m[1]),
      y: Number(m[2]),
    }));
    const homeX = [...dragged.content.matchAll(/\\pos\((-?\d+),(-?\d+)\)/g)].map((m) => ({
      x: Number(m[1]),
      y: Number(m[2]),
    }));
    // Every cue moved by exactly the difference between the two deltas, whatever
    // its text and wherever it started. Under the old clamp the long lines and
    // the short ones landed on different pixels.
    const stepX = Math.round((0.5 - -0.2) * 1920);
    const stepY = Math.round((0.5 - -0.3) * 1080);
    const uniform =
      cornerX.length === homeX.length &&
      cornerX.length > 0 &&
      cornerX.every((p, i) => p.x - homeX[i]!.x === stepX && p.y - homeX[i]!.y === stepY);
    check(
      'the position is the anchor plus the delta, unclamped and text-independent',
      uniform,
      `${cornerX.length} cues, all shifted by (${stepX},${stepY})`,
    );
    // And the frame is no longer a boundary the document respects: dragged half
    // the frame past the corner, the text is meant to be off-screen. Rendering
    // nothing is the correct outcome, and is what the client's own clamp exists
    // to prevent ever reaching a user.
    check(
      'the document does not stop a drag at the frame edge',
      renderInk(corner.content, second, `${kind}-corner`) === null,
      'off-frame as asked',
    );

    // --- three style changes ------------------------------------------------
    const changes: [string, CaptionStyle, (doc: string) => boolean][] = [
      [
        'font colour',
        { ...NO_STYLE, textColor: { r: 255, g: 0, b: 0, a: 1 } },
        (doc) => doc.includes('Style: Default,Arial,48,&H000000FF,'),
      ],
      // The two backdrop controls are **client-side now** — `LibassLayer` paints
      // the per-line box and the window over the boxes it measured, so the
      // document must not carry them or libass draws them a second time. Both
      // therefore assert *absence*: the style menu's backdrop half changes what
      // the user sees without changing a byte of what the sidecar produces.
      [
        'background off',
        { ...NO_STYLE, background: { r: 0, g: 0, b: 0, a: 0 } },
        (doc) => !doc.includes('Style: Box,') && !doc.includes(',Box,,'),
      ],
      [
        'window on',
        { ...NO_STYLE, window: { r: 0, g: 0, b: 255, a: 0.6 } },
        (doc) => !doc.includes('Style: Window,') && !doc.includes(',Window,,'),
      ],
    ];
    for (const [name, style, expected] of changes) {
      const changed = await getCaptionTrack(session, videoId, trackId, { style });
      const ink = renderInk(changed.content, second, `${kind}-${name.replace(/ /g, '-')}`);
      check(
        `style change: ${name}`,
        expected(changed.content) && ink !== null,
        ink === null ? 'nothing rendered' : `${ink.pixels} px of ink`,
      );
    }

    // A styled track's own colours have to survive a *position* change, which is
    // the property that keeps `styled` cosmetic rather than load-bearing.
    if (kind === 'styled') {
      const authored = (home.content.match(/\\c&H/g) ?? []).length;
      const afterDrag = (dragged.content.match(/\\c&H/g) ?? []).length;
      check(
        'dragging a styled track keeps every authored colour',
        authored > 0 && authored === afterDrag,
        `${authored} inline colours before, ${afterDrag} after`,
      );
    }
  }

  console.error(`\n${failures === 0 ? 'all claims held' : `${failures} claim(s) FAILED`}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
