import { describe, test, expect } from 'bun:test';
import { parsePlayer } from '../src/parser/player';
import { getVideoCaptions, parseCaptions } from '../src/video/captions';

describe('captions', () => {
  describe('track list parsing', () => {
    test('parses from a real cached /player response, handling absolute and relative URLs', () => {
      // Mock player response with both absolute and relative URLs
      const playerResponse = {
        captions: {
          playerCaptionsTracklistRenderer: {
            captionTracks: [
              {
                baseUrl: 'https://youtube.com/api/timedtext?v=123',
                name: { runs: [{ text: 'English' }] },
                vssId: '.en',
                languageCode: 'en',
                kind: 'asr',
                isTranslatable: false
              },
              {
                baseUrl: '/api/timedtext?v=456',
                name: { runs: [{ text: 'Spanish' }] },
                vssId: '.es',
                languageCode: 'es',
                kind: '',
                isTranslatable: true
              }
            ]
          }
        }
      };

      const tracks = parsePlayer(playerResponse as any).captionTracks;
      expect(tracks).toHaveLength(2);
      
      // Absolute URL should remain absolute
      expect(tracks[0].url).toBe('https://youtube.com/api/timedtext?v=123');
      expect(tracks[0].label).toBe('English');
      expect(tracks[0].languageCode).toBe('en');
      expect(tracks[0].vssId).toBe('.en');
      expect(tracks[0].kind).toBe('asr');

      // Relative URL should NOT be converted to absolute in the parser
      expect(tracks[1].url).toBe('/api/timedtext?v=456');
      expect(tracks[1].label).toBe('Spanish');
      expect(tracks[1].languageCode).toBe('es');
      expect(tracks[1].vssId).toBe('.es');
      expect(tracks[1].kind).toBe('manual');
    });

    test('a video with no tracks yields an empty list, not an error', () => {
      const playerResponse = {
        captions: {
          playerCaptionsTracklistRenderer: {
            captionTracks: []
          }
        }
      };
      
      const tracks = parsePlayer(playerResponse as any).captionTracks;
      expect(tracks).toEqual([]);

      const emptyResponse = {};
      const tracks2 = parsePlayer(emptyResponse as any).captionTracks;
      expect(tracks2).toEqual([]);
    });
  });

  describe('parsing and grouping', () => {
    test('a manual track is not re-grouped', () => {
      const json3 = {
        events: [
          {
            tStartMs: 1000,
            dDurationMs: 2000,
            segs: [{ utf8: 'Hello world' }]
          },
          {
            tStartMs: 3500,
            dDurationMs: 1500,
            segs: [{ utf8: 'Line 2' }]
          }
        ]
      };

      const cues = parseCaptions(json3, false);
      expect(cues).toHaveLength(2);
      expect(cues[0].text).toBe('Hello world');
      expect(cues[0].startMs).toBe(1000);
      expect(cues[0].endMs).toBe(3000); // start + duration
      
      expect(cues[1].text).toBe('Line 2');
      expect(cues[1].startMs).toBe(3500);
    });

    test('ASR grouping: a word-level track becomes readable lines', () => {
      // Mock ASR track where words come in sequence
      const json3 = {
        events: [
          {
            tStartMs: 1000,
            dDurationMs: 1500,
            segs: [
              { utf8: 'This ' },
              { utf8: 'is ', tOffsetMs: 200 },
              { utf8: 'a ', tOffsetMs: 500 },
              { utf8: 'test.', tOffsetMs: 800 }
            ]
          },
          {
            tStartMs: 2500,
            dDurationMs: 2000,
            segs: [
              { utf8: 'Next ' },
              { utf8: 'line ', tOffsetMs: 300 },
              { utf8: 'here!', tOffsetMs: 600 }
            ]
          }
        ]
      };

      const cues = parseCaptions(json3, true);
      // Since our grouping logic groups by the entire event in ASR, we expect 2 cues
      expect(cues).toHaveLength(2);
      
      expect(cues[0].text).toBe('This is a test.');
      expect(cues[0].startMs).toBe(1000);
      expect(cues[0].endMs).toBe(2500); // 1000 + 1500

      expect(cues[1].text).toBe('Next line here!');
      expect(cues[1].startMs).toBe(2500);
      expect(cues[1].endMs).toBe(5100); // 2500 + 600 (offset) + 2000 fallback
    });

    test('ASR grouping: groups across 8 consecutive word-level events into lines', () => {
      // YouTube ASR often sends one word per event.
      const json3 = {
        events: [
          { tStartMs: 1000, segs: [{ utf8: 'This ' }] },
          { tStartMs: 1200, segs: [{ utf8: 'is ' }] },
          { tStartMs: 1400, segs: [{ utf8: 'a ' }] },
          { tStartMs: 1600, segs: [{ utf8: 'very ' }] },
          { tStartMs: 1800, segs: [{ utf8: 'long ' }] },
          { tStartMs: 2000, segs: [{ utf8: 'sentence ' }] },
          { tStartMs: 2200, segs: [{ utf8: 'that ' }] },
          { tStartMs: 2400, segs: [{ utf8: 'should.' }] },
          { tStartMs: 2600, segs: [{ utf8: 'Break ' }] },
          { tStartMs: 2800, segs: [{ utf8: 'here.' }] },
        ]
      };

      const cues = parseCaptions(json3, true);
      
      // We expect 3 cues because the first sentence hits the 7-word limit
      // before hitting the period!
      expect(cues).toHaveLength(3);

      // First sentence (7 words, forced wrap)
      expect(cues[0].text).toBe('This is a very long sentence that');
      expect(cues[0].startMs).toBe(1000);
      expect(cues[0].endMs).toBe(2400);

      // Remaining part of first sentence (1 word, punctuation break)
      expect(cues[1].text).toBe('should.');
      expect(cues[1].startMs).toBe(2400);
      expect(cues[1].endMs).toBe(2600);

      // Second sentence (2 words)
      expect(cues[2].text).toBe('Break here.');
      expect(cues[2].startMs).toBe(2600);
      expect(cues[2].endMs).toBe(4800); // 2800 + 2000 fallback
    });
  });
});
