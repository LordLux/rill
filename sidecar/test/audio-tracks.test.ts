/**
 * Audio tracks — Task 39, `architecture.md` F65, `protocol.md` §3.5. Offline.
 *
 * The parse (track fields and `xtags`, from the URL or the format's own protobuf field), the
 * list and its names. The ranking and the choice run end to end through `openPlayback` in
 * `playback.test.ts`, against the same fixture.
 */

import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { decodeXtagsField, parseXtagsText } from '../src/parser/audio-track.ts';
import { parsePlayer } from '../src/parser/index.ts';
import { listAudioTracks, trackDisplayName } from '../src/playback/audio-tracks.ts';
import { sourceFromYtDlpDump, type YtDlpDump } from '../src/playback/resolve.ts';
import type { PlayerAudioTrack } from '../src/types.ts';

const DATA = join(dirname(fileURLToPath(import.meta.url)), 'data');
interface FixtureBody {
  streamingData: { adaptiveFormats: Array<Record<string, unknown>> };
}
const body = (): FixtureBody => JSON.parse(readFileSync(join(DATA, 'player-audio-tracks.json'), 'utf8')) as FixtureBody;

describe('the track fields of a format', () => {
  test('xtags as text, and as the base64 protobuf field, read the same', () => {
    expect(parseXtagsText('acont=dubbed-auto:lang=pt-BR')).toEqual({ acont: 'dubbed-auto', lang: 'pt-BR' });
    // A field copied from a measured VISIONOS response (MLgrNktS67c's Arabic AI dub).
    expect(decodeXtagsField('ChQKBWFjb250EgtkdWJiZWQtYXV0bwoKCgRsYW5nEgJhcg')).toEqual({ acont: 'dubbed-auto', lang: 'ar' });
  });

  test('a malformed field is no xtags, never a throw (invariant 4)', () => {
    for (const junk of ['', '!!!', 'AAAA', 'Cg', 'ChQKBWFjb250']) expect(decodeXtagsField(junk)).toBeNull();
    expect(parseXtagsText('nothing-here')).toBeNull();
  });

  test('every audio format of the fixture carries its track, and the field stands in for a URL without xtags', () => {
    const formats = parsePlayer(body()).formats;
    const audio = formats.filter((f) => f.hasAudio);
    expect(audio.every((f) => f.audioTrack !== null)).toBe(true);
    expect(formats.filter((f) => f.hasVideo).every((f) => f.audioTrack === null)).toBe(true);
    // de-DE's URLs carry no `xtags` (ANDROID's carry no URL at all): the field is the only copy.
    const german = audio.find((f) => f.audioTrack?.id === 'de-DE.10')!;
    expect(new URL(german.rawUrl!).searchParams.has('xtags')).toBe(false);
    expect(german.audioTrack).toMatchObject({ content: 'dubbed-auto', language: 'de-DE', isDefault: false });
    expect(audio.find((f) => f.audioTrack?.id === 'en-US.4')!.audioTrack).toMatchObject({ content: 'original', isDefault: true });
  });

  test('a single-track video names no track, so there is nothing to list', () => {
    const single = body();
    for (const format of single.streamingData.adaptiveFormats) {
      delete format['audioTrack'];
      delete format['xtags'];
      format['url'] = String(format['url']).replace(/&xtags=[^&]*/, '');
    }
    const formats = parsePlayer(single).formats;
    expect(formats.every((f) => f.audioTrack === null)).toBe(true);
    expect(listAudioTracks(formats)).toEqual([]);
  });
});

describe('the list', () => {
  test('the original first, then by name; one entry per track; the markers from acont', () => {
    const tracks = listAudioTracks(parsePlayer(body()).formats);
    expect(tracks.map((t) => t.id)).toEqual(['en-US.4', 'de-DE.10', 'hi.10', 'es.3']);
    expect(tracks[0]).toEqual({ id: 'en-US.4', displayName: 'English (US)', isOriginal: true, isDubbed: false, isAutoDubbed: false });
    expect(tracks.find((t) => t.id === 'es.3')).toMatchObject({ isDubbed: true, isAutoDubbed: false, isOriginal: false });
    expect(tracks.find((t) => t.id === 'hi.10')).toMatchObject({ isDubbed: false, isAutoDubbed: true });
  });
});

describe("the original's name loses YouTube's own 'original' wording", () => {
  const original = (displayName: string): PlayerAudioTrack => ({ id: 'x.4', displayName, isDefault: true, content: 'original', language: 'en-US' });

  // Every wording measured on 2026-11-22 (F65), one per `hl`.
  const measured: Array<[string, string]> = [
    ['English (US) original', 'English (US)'],
    ['Englisch (US) (Original)', 'Englisch (US)'],
    ['Inglés (US) original', 'Inglés (US)'],
    ['Anglais (US) original', 'Anglais (US)'],
    ['英語 (US)（オリジナル）', '英語 (US)'],
    ['मूल भाषा अंग्रेज़ी (US)', 'अंग्रेज़ी (US)'],
    ['الإنجليزية (US): أصلي', 'الإنجليزية (US)'],
    ['মূল ভাষা ইংরেজি (US)', 'ইংরেজি (US)'],
    ['English original', 'English'],
  ];
  for (const [youtube, shown] of measured) {
    test(`${JSON.stringify(youtube)} → ${JSON.stringify(shown)}`, () => expect(trackDisplayName(original(youtube))).toBe(shown));
  }

  test('a wording it does not know is left alone, and a dub is never touched', () => {
    expect(trackDisplayName(original('Inglese (US) originale'))).toBe('Inglese (US) originale');
    expect(trackDisplayName({ ...original('Something original'), content: 'dubbed' })).toBe('Something original');
  });

  test('a track with no name falls back to its language, then its id', () => {
    expect(trackDisplayName({ ...original(''), displayName: null })).toBe('en-US');
    expect(trackDisplayName({ ...original(''), displayName: null, language: null })).toBe('x.4');
  });
});

describe('the yt-dlp tier (no track id of its own)', () => {
  // The ANDROID response's shape: every track's fields, and no URL on an adaptive format.
  const android = (() => {
    const raw = body();
    for (const format of raw.streamingData.adaptiveFormats) delete format['url'];
    return parsePlayer(raw);
  })();

  const xtagsUrl = (id: string, lang: string, acont: string) =>
    `https://rr1---sn-sanitised.googlevideo.com/videoplayback?expire=1&c=VISIONOS&id=${id}&xtags=${encodeURIComponent(`acont=${acont}:lang=${lang}`)}`;
  const dump: YtDlpDump = {
    duration: 634,
    formats: [
      { url: xtagsUrl('en140', 'en-US', 'original'), vcodec: 'none', acodec: 'mp4a.40.2', abr: 129, protocol: 'https' },
      { url: xtagsUrl('en251', 'en-US', 'original'), vcodec: 'none', acodec: 'opus', abr: 139, protocol: 'https' },
      { url: xtagsUrl('hi140', 'hi', 'dubbed-auto'), vcodec: 'none', acodec: 'mp4a.40.2', abr: 129, protocol: 'https' },
      { url: xtagsUrl('hi251', 'hi', 'dubbed-auto'), vcodec: 'none', acodec: 'opus', abr: 145, protocol: 'https' },
      { url: xtagsUrl('hiHls', 'hi', 'dubbed-auto'), vcodec: 'none', acodec: 'opus', abr: 999, protocol: 'm3u8_native' },
    ],
    requested_formats: [
      { url: 'https://rr1---sn-sanitised.googlevideo.com/videoplayback?expire=1&c=VISIONOS&id=v399', vcodec: 'av01', acodec: 'none', height: 1080 },
      { url: xtagsUrl('en251', 'en-US', 'original'), vcodec: 'none', acodec: 'opus' },
    ],
  };

  test("yt-dlp's own pick is the original, and the list is ANDROID's", () => {
    const source = sourceFromYtDlpDump(dump, 'yt-dlp', android);
    expect(source.audioTrackId).toBe('en-US.4');
    expect(source.audioTracks.map((t) => t.id)).toEqual(['en-US.4', 'de-DE.10', 'hi.10', 'es.3']);
    expect(source.variants[0]!.audioUrl).toContain('id=en251');
  });

  test('a requested track is matched by language and kind, best bitrate, plain https only', () => {
    const source = sourceFromYtDlpDump(dump, 'yt-dlp', android, 'hi.10');
    expect(source.audioTrackId).toBe('hi.10');
    expect(source.variants[0]!.audioUrl).toContain('id=hi251');
  });

  test('a track yt-dlp has no format for keeps its pick, and says so', () => {
    const source = sourceFromYtDlpDump(dump, 'yt-dlp', android, 'es.3');
    expect(source.audioTrackId).toBe('en-US.4');
  });

  test('with no ANDROID response there is nothing to match against: no list, no id', () => {
    const source = sourceFromYtDlpDump(dump, 'yt-dlp', null);
    expect(source.audioTracks).toEqual([]);
    expect(source.audioTrackId).toBeNull();
  });
});
