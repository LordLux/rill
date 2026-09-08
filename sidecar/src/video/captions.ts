import { getPlayerResponse } from '../innertube/player-response.ts';
import type { Session } from '../innertube/session.ts';
import type { CaptionCue, VideoCaptionsResult } from '../types.ts';

export interface CaptionsDeps {
  resolve: Session;
}

export async function getVideoCaptions(
  deps: CaptionsDeps,
  params: { videoId: string; vssId: string },
): Promise<VideoCaptionsResult> {
  const { videoId, vssId } = params;
  const player = await getPlayerResponse(deps.resolve, videoId, 'ANDROID_VR');
  const track = player.captionTracks.find((t) => t.vssId === vssId);
  if (!track) {
    throw new Error(`Caption track ${vssId} not found for video ${videoId}`);
  }

  const url = new URL(track.url, 'https://www.youtube.com');
  url.searchParams.set('fmt', 'json3');
  
  const res = await fetch(url.toString());
  if (!res.ok) {
    throw new Error(`Failed to fetch captions: ${res.status} ${res.statusText}`);
  }
  const data = (await res.json()) as { events?: { tStartMs?: number, dDurationMs?: number, segs?: { utf8: string, tOffsetMs?: number }[] }[] };

  const cues = parseCaptions(data, track.kind !== 'manual');

  return { cues };
}

export function parseCaptions(
  data: { events?: { tStartMs?: number, dDurationMs?: number, segs?: { utf8: string, tOffsetMs?: number }[] }[] },
  isAsr: boolean
): CaptionCue[] {
  const cues: CaptionCue[] = [];

  if (!isAsr) {
    for (const event of data.events || []) {
      if (!event.segs || event.segs.length === 0) continue;
      const text = event.segs.map((s) => s.utf8).join('');
      if (!text.trim()) continue;
      cues.push({
        startMs: event.tStartMs || 0,
        endMs: (event.tStartMs || 0) + (event.dDurationMs || 0),
        text,
      });
    }
  } else {
    // ASR: Flatten all segments into a continuous stream of words
    interface Word {
      text: string;
      startMs: number;
    }
    const words: Word[] = [];
    for (const event of data.events || []) {
      if (!event.segs) continue;
      const baseTime = event.tStartMs || 0;
      for (const seg of event.segs) {
        if (!seg.utf8 || seg.utf8 === '\n') continue;
        const text = seg.utf8.replace(/\n/g, ' ');
        const startMs = baseTime + (seg.tOffsetMs || 0);
        words.push({ text, startMs });
      }
    }

    // Grouping rule: chunk into rolling lines. 
    // We break on punctuation (.!?) or if the line has 7 words.
    // This turns a word-by-word stutter into readable lines of text.
    let currentLine: string[] = [];
    let startMs = -1;

    for (let i = 0; i < words.length; i++) {
      const word = words[i]!;
      if (currentLine.length === 0) {
        startMs = word.startMs;
      }
      currentLine.push(word.text);
      
      const text = word.text.trim();
      const hasPunctuation = text.endsWith('.') || text.endsWith('?') || text.endsWith('!');
      
      if (hasPunctuation || currentLine.length >= 7 || i === words.length - 1) {
        const nextWord = i + 1 < words.length ? words[i + 1]! : null;
        const endMs = nextWord ? nextWord.startMs : word.startMs + 2000;
        
        cues.push({
          startMs,
          endMs,
          text: currentLine.join('').trim(),
        });
        currentLine = [];
      }
    }
  }

  return cues;
}
