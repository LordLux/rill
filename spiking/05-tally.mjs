// Spike 05 — consolidate every run into one tally.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const OUT = new URL('./05-out/', import.meta.url).pathname.replace(/^\//, '');
const rows = [];
for (const f of readdirSync(OUT)) {
  if (!f.startsWith('q3') || !f.endsWith('.json') || f === 'q3-matrix.json') continue;
  const v = JSON.parse(readFileSync(join(OUT, f), 'utf8'));
  if (v.seeks_ok === undefined) continue;
  rows.push({
    run: f.replace(/\.json$/, ''),
    mpv: v.mpv_version, ffmpeg: v.ffmpeg_version,
    itag: v.itag, mode: v.mode,
    seeks: `${v.seeks_ok}/${v.seeks_total}`,
    played: v.played, hwdec: v.hwdec_current,
    audioLoaded: v.track_count === '2' || v.track_count === 2 || !!v.audio_codec,
    cpu: v.cpu_seconds,
    positions: Object.values(v.seeks ?? {}).map((s) => Number(s.pos.toFixed(1))),
  });
}
rows.sort((a, b) => a.run.localeCompare(b.run));

const byBuild = {};
for (const r of rows) {
  const k = `${r.mpv} / ${r.ffmpeg}`;
  byBuild[k] ??= { baseline: [], request_size: [] };
  byBuild[k][r.mode].push(r.seeks);
}

writeFileSync(join(OUT, 'q3-tally.json'), JSON.stringify({ rows, byBuild }, null, 2));
console.log(JSON.stringify(byBuild, null, 2));
console.table(rows.map(({ run, mpv, mode, itag, seeks, hwdec, audioLoaded, cpu }) =>
  ({ run, mpv, mode, itag, seeks, hwdec, audioLoaded, cpu })));
