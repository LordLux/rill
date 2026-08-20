/**
 * Task 19, question 2: is "pixels per character" a usable calibration for a
 * proportional font, and does measuring a representative string beat it?
 *
 * The nudge in §4.3 of the brief needs the rendered width of cues Flutter never
 * sees. Flutter measures *something* and the sidecar applies it to a character
 * count. This asks what that something should be, by measuring what libass — the
 * thing that actually draws the caption — does to real strings.
 *
 * Method: one row per string, every row `\pos`-ed so libass's collision
 * avoidance stays out of it (measured in task 18). Render through the *bundled*
 * libmpv (hard invariant 8) and read each row's ink extent out of the TGA.
 * Widths are differenced against a single-glyph row, so the outline's constant
 * contribution cancels. Rows are rendered in frame-sized batches — a very tall
 * rawvideo frame is silently dropped rather than decoded.
 *
 *   bun run scratch/measure-advances.ts
 */
import { dlopen, FFIType, ptr, toArrayBuffer } from 'bun:ffi';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const DLL = 'C:/Projects/NativeYouTube/app/build/windows/x64/runner/Release/libmpv-2.dll';

/** Must match `ass.ts` — the document the app actually generates. */
const FONT = 'Arial';
const FONT_SIZE = 48;
const OUTLINE = 2.5;

const WIDTH = 1920;
const HEIGHT = 1080;
/** Row pitch. Comfortably over the glyph box at 48 px, so bands never overlap. */
const PITCH = 70;
const ROWS_PER_FRAME = Math.floor((HEIGHT - 20) / PITCH);
const REPEATS = 20;

const lib = dlopen(DLL, {
  mpv_create: { args: [], returns: FFIType.ptr },
  mpv_initialize: { args: [FFIType.ptr], returns: FFIType.int },
  mpv_set_option_string: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.int },
  mpv_command_string: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.int },
  mpv_wait_event: { args: [FFIType.ptr, FFIType.double], returns: FFIType.ptr },
  mpv_terminate_destroy: { args: [FFIType.ptr], returns: FFIType.void },
});

const BS = String.fromCharCode(92); // never type a backslash into a template here
const fwd = (value: string) => value.split(BS).join('/');

/** Rendered ink width of each string, in pixels, at the style above. */
function measureAll(texts: string[]): number[] {
  const out: number[] = [];
  for (let start = 0; start < texts.length; start += ROWS_PER_FRAME) {
    out.push(...measureBatch(texts.slice(start, start + ROWS_PER_FRAME)));
  }
  return out;
}

function measureBatch(texts: string[]): number[] {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rill-adv-'));
  const assPath = path.join(dir, 'm.ass');
  const rawPath = path.join(dir, 'bg.raw');

  const events = texts.map(
    (text, i) =>
      `Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,` +
      `{${BS}an7${BS}pos(20,${10 + i * PITCH})}${text}`,
  );
  fs.writeFileSync(
    assPath,
    [
      '[Script Info]',
      'ScriptType: v4.00+',
      'WrapStyle: 2',
      'ScaledBorderAndShadow: yes',
      'YCbCr Matrix: None',
      `PlayResX: ${WIDTH}`,
      `PlayResY: ${HEIGHT}`,
      '',
      '[V4+ Styles]',
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, ' +
        'BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, ' +
        'BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
      `Style: Default,${FONT},${FONT_SIZE},&H00FFFFFF,&H000000FF,&H00000000,` +
        `&H80000000,0,0,0,0,100,100,0,0,1,${OUTLINE},0,7,0,0,0,1`,
      '',
      '[Events]',
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
      ...events,
    ].join('\n'),
    'utf8',
  );
  fs.writeFileSync(rawPath, Buffer.alloc(WIDTH * HEIGHT * 3, 0));

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
  opt('msg-level', process.env['MSG'] ?? 'all=error');
  opt('vo', 'image');
  opt('vo-image-format', 'jpg');
  opt('vo-image-outdir', fwd(dir));
  opt('sub-files', fwd(assPath));
  opt('sid', '1');
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

  if (lib.symbols.mpv_initialize(h) < 0) throw new Error('mpv_initialize failed');
  lib.symbols.mpv_command_string(h, cstr(`loadfile "${fwd(rawPath)}"`));

  const started = Date.now();
  while (Date.now() - started < 60_000) {
    const event = lib.symbols.mpv_wait_event(h, 0.5);
    if (!event) continue;
    const id = new DataView(toArrayBuffer(event, 0, 8)).getInt32(0, true);
    if (id === 7 || id === 1) break;
  }
  lib.symbols.mpv_terminate_destroy(h);

  const frame = fs.readdirSync(dir).find((name) => /[.](jpg|jpeg)$/.test(name));
  if (frame === undefined) throw new Error(`no frame written in ${dir}`);

  // The image VO only accepts png/jpg/webp in this build — `tga` and `ppm` are
  // rejected outright (rc -7) and it silently falls back to jpg — and its FFmpeg
  // has no PNG encoder, which CLAUDE.md already records. So the frame is JPEG,
  // and the decoder is Windows itself: System.Drawing writes a 24-bit BMP, which
  // is a header and a pixel array. Ringing around the glyphs is symmetric and
  // constant, and the advances are differences, so it cancels.
  const bmpPath = path.join(dir, 'frame.bmp');
  const convert = Bun.spawnSync([
    'powershell',
    '-NoProfile',
    '-Command',
    `Add-Type -AssemblyName System.Drawing; ` +
      `$i = [System.Drawing.Image]::FromFile('${path.join(dir, frame)}'); ` +
      `$i.Save('${bmpPath}', [System.Drawing.Imaging.ImageFormat]::Bmp); $i.Dispose()`,
  ]);
  if (!fs.existsSync(bmpPath)) {
    throw new Error(`bmp conversion failed: ${convert.stderr.toString()}`);
  }

  const bmp = fs.readFileSync(bmpPath);
  const offset = bmp.readUInt32LE(10);
  const bmpWidth = bmp.readInt32LE(18);
  const bmpHeight = bmp.readInt32LE(22);
  const bpp = bmp.readUInt16LE(28) / 8;
  const stride = Math.ceil((bmpWidth * bpp) / 4) * 4;

  // JPEG at quality 90 rings a few units around a hard white-on-black edge; 80
  // is comfortably above that and far below the glyph body.
  const INK = 80;
  const widths = texts.map((_, i) => {
    const top = 10 + i * PITCH;
    let min = Infinity;
    let max = -Infinity;
    for (let y = top; y < Math.min(bmpHeight, top + PITCH); y++) {
      const base = offset + (bmpHeight - 1 - y) * stride; // BMP rows run bottom-up
      for (let x = 0; x < bmpWidth; x++) {
        const at = base + x * bpp;
        if (bmp[at]! > INK || bmp[at + 1]! > INK || bmp[at + 2]! > INK) {
          if (x < min) min = x;
          if (x > max) max = x;
        }
      }
    }
    return max < min ? 0 : max - min + 1;
  });

  fs.rmSync(dir, { recursive: true, force: true });
  return widths;
}

// ---------------------------------------------------------------------------

const ALPHABET = [
  ...'abcdefghijklmnopqrstuvwxyz',
  ...'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
  ...'0123456789',
  ...' .,!?\'"-:;()',
];

/** Real caption lines, plus the shapes that break an average. */
const SENTENCES = [
  'Hello!',
  'hey there! how are you doing my friend?',
  'WHY WOULD ANYONE SHOUT AN ENTIRE CAPTION LINE',
  'illillillillillillilli',
  'MMMMMMMMMMMMMMMMMMMMMM',
  'the quick brown fox jumps over the lazy dog',
  'THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG',
  'so anyway, that is basically the whole idea behind it',
  'A',
  'W',
  'i',
];

const probes: string[] = [];
for (const glyph of ALPHABET) {
  probes.push(glyph === ' ' ? `x${' '.repeat(REPEATS)}x` : glyph.repeat(REPEATS));
  probes.push(glyph === ' ' ? 'xx' : glyph);
}
const sentenceStart = probes.length;
probes.push(...SENTENCES);

console.error(`${probes.length} rows in ${Math.ceil(probes.length / ROWS_PER_FRAME)} frame(s)`);
const measured = measureAll(probes);

const advance = new Map<string, number>();
ALPHABET.forEach((glyph, i) => {
  advance.set(glyph, (measured[i * 2]! - measured[i * 2 + 1]!) / (REPEATS - 1));
});
const strWidth = new Map<string, number>();
SENTENCES.forEach((sentence, i) => strWidth.set(sentence, measured[sentenceStart + i]!));

const sorted = [...advance.entries()].sort((a, b) => a[1] - b[1]);
const values = [...advance.values()];
const mean = values.reduce((a, b) => a + b, 0) / values.length;
console.error('\nadvance widths, Arial 48 px, through the bundled libass:');
console.error(`  narrowest ${sorted.slice(0, 6).map(([c, w]) => `'${c}'=${w.toFixed(1)}`).join(' ')}`);
console.error(`  widest    ${sorted.slice(-6).map(([c, w]) => `'${c}'=${w.toFixed(1)}`).join(' ')}`);
console.error(
  `  mean ${mean.toFixed(2)}  min ${Math.min(...values).toFixed(2)}  max ${Math.max(...values).toFixed(2)}  ` +
    `max/min ${(Math.max(...values) / Math.min(...values)).toFixed(1)}x`,
);

const REFERENCE = 'the quick brown fox jumps over the lazy dog';
const perCharFromReference = strWidth.get(REFERENCE)! / REFERENCE.length;

function sumAdvances(text: string): number {
  const fallback = Math.max(...values);
  let total = 0;
  for (const ch of text) total += advance.get(ch) ?? fallback;
  return total;
}

console.error(`\nper-char from the reference string: ${perCharFromReference.toFixed(2)} px`);
console.error(`per-char from the alphabet mean:    ${mean.toFixed(2)} px\n`);

const header = ['string', 'real', 'ref*n', 'err', 'mean*n', 'err', 'sum(adv)', 'err'];
const table: string[][] = [header];
const errors = { ref: [] as number[], mean: [] as number[], sum: [] as number[] };

for (const sentence of SENTENCES) {
  const real = strWidth.get(sentence)!;
  const pct = (estimate: number) => ((estimate - real) / real) * 100;
  const byRef = perCharFromReference * sentence.length;
  const byMean = mean * sentence.length;
  const bySum = sumAdvances(sentence);
  errors.ref.push(pct(byRef));
  errors.mean.push(pct(byMean));
  errors.sum.push(pct(bySum));
  const sign = (v: number) => `${v >= 0 ? '+' : ''}${v.toFixed(0)}%`;
  table.push([
    sentence.length > 30 ? sentence.slice(0, 27) + '...' : sentence,
    real.toFixed(0),
    byRef.toFixed(0),
    sign(pct(byRef)),
    byMean.toFixed(0),
    sign(pct(byMean)),
    bySum.toFixed(0),
    sign(pct(bySum)),
  ]);
}

const columns = header.map((_, i) => Math.max(...table.map((row) => row[i]!.length)));
for (const row of table) console.error(row.map((cell, i) => cell.padEnd(columns[i]!)).join('  '));

const span = (list: number[]) =>
  `${Math.min(...list).toFixed(0)}% .. ${Math.max(...list) >= 0 ? '+' : ''}${Math.max(...list).toFixed(0)}%`;
console.error(
  `\nerror span — reference*n ${span(errors.ref)}   alphabet*n ${span(errors.mean)}   sum(advances) ${span(errors.sum)}`,
);
console.error(`payload if the advances are sent: ${ALPHABET.length} numbers`);

// The table itself, for the Flutter side to be compared against — the whole
// estimate rests on TextPainter agreeing with libass about this font.
const dump = process.env['ADVANCES_OUT'];
if (dump !== undefined) {
  fs.writeFileSync(
    dump,
    JSON.stringify(
      {
        font: FONT,
        assFontSize: FONT_SIZE,
        advances: Object.fromEntries([...advance].map(([c, w]) => [c, Number(w.toFixed(2))])),
        strings: Object.fromEntries([...strWidth]),
      },
      null,
      2,
    ),
  );
  console.error(`wrote ${dump}`);
}
