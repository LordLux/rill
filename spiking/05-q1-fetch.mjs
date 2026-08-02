// Spike 05 Q1/Q2 — fetch the libmpv artefacts under test.
// Throwaway. Binaries land in the scratchpad, never in the repo.
import { createHash } from 'node:crypto';
import { writeFileSync, readFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';

const OUT = process.argv[2];
mkdirSync(OUT, { recursive: true });

const TARGETS = [
  {
    id: 'shipped',
    note: 'pinned by media_kit_libs_windows_video 1.0.11 (pub.dev latest)',
    url: 'https://github.com/media-kit/libmpv-win32-video-build/releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z',
    md5: 'a832ef24b3a6ff97cd2560b5b9d04cd8', // from the package's own CMakeLists
  },
  {
    id: 'main-branch',
    note: 'pinned by media-kit/media-kit main branch (unpublished)',
    url: 'https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/mpv-dev-x86_64-20241021-git-0f78584.7z',
    md5: '6ecf18e85b093c3f7edb16f3ee6603f3',
  },
  {
    id: 'candidate',
    note: 'shinchiro/mpv-winbuild-cmake latest release',
    url: 'https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20260610/mpv-dev-x86_64-20260610-git-304426c.7z',
    md5: null,
  },
];

const results = [];
for (const t of TARGETS) {
  const name = t.url.split('/').pop();
  const path = join(OUT, name);
  if (!existsSync(path)) {
    process.stderr.write(`downloading ${name}\n`);
    const r = await fetch(t.url, { redirect: 'follow' });
    if (!r.ok) throw new Error(`${t.id}: HTTP ${r.status}`);
    writeFileSync(path, Buffer.from(await r.arrayBuffer()));
  }
  const md5 = createHash('md5').update(readFileSync(path)).digest('hex');
  results.push({
    id: t.id,
    note: t.note,
    url: t.url,
    file: path,
    bytes: statSync(path).size,
    md5,
    md5Expected: t.md5,
    md5Match: t.md5 === null ? null : md5 === t.md5,
  });
}

console.log(JSON.stringify(results, null, 2));
