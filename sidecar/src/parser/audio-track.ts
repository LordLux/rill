/**
 * What an adaptive audio format says about its track — Task 39, `architecture.md` F65.
 *
 * Two sources, read together. `audioTrack` (`id`, `displayName`, `audioIsDefault`, and
 * `isAutoDubbed` on an AI dub) names the track; `xtags` says what kind it is (`acont`:
 * `original`, `dubbed`, `dubbed-auto`) and its language (`lang`). `xtags` arrives twice and
 * the two agreed on every format measured: as plain text in the URL (`acont=original:lang=en-US`)
 * and as a base64url protobuf field on the format, which is the only copy on an `ANDROID`
 * response, whose adaptive formats carry no URL at all. The URL is read first, the field after.
 *
 * Hard invariant 4 in miniature: nothing here throws. A malformed `xtags` is no `xtags`.
 */

import type { PlayerAudioTrack } from '../types.ts';
import { isObject, str, type JsonObject } from './tree.ts';

/** `acont=original:lang=en-US` → `{acont: 'original', lang: 'en-US'}`. */
export function parseXtagsText(text: string | null): Record<string, string> | null {
  if (!text) return null;
  const out: Record<string, string> = {};
  for (const part of text.split(':')) {
    const equals = part.indexOf('=');
    if (equals <= 0) continue;
    out[part.slice(0, equals)] = part.slice(equals + 1);
  }
  return Object.keys(out).length > 0 ? out : null;
}

/** The `xtags` query parameter of a format's address: a plain URL, or a `signatureCipher`'s `url`. */
function xtagsFromAddress(address: string | null): Record<string, string> | null {
  if (!address) return null;
  try {
    const url = /^https?:\/\//i.test(address) ? new URL(address) : new URL(new URLSearchParams(address).get('url') ?? '');
    return parseXtagsText(url.searchParams.get('xtags'));
  } catch {
    return null;
  }
}

/**
 * The format's own `xtags` field: base64url protobuf, a repeated message (field 1) of
 * `{1: key, 2: value}` strings. Decoded by hand because it is that small; anything that does not
 * read as exactly that answers null.
 */
export function decodeXtagsField(encoded: string | null): Record<string, string> | null {
  if (!encoded) return null;
  try {
    const bytes = Buffer.from(encoded.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
    const out: Record<string, string> = {};
    for (const entry of readMessage(bytes)) {
      if (entry.field !== 1) continue;
      let key: string | null = null;
      let value: string | null = null;
      for (const part of readMessage(entry.bytes)) {
        if (part.field === 1) key = part.bytes.toString('utf8');
        if (part.field === 2) value = part.bytes.toString('utf8');
      }
      if (key) out[key] = value ?? '';
    }
    return Object.keys(out).length > 0 ? out : null;
  } catch {
    return null;
  }
}

/** Length-delimited fields only (wire type 2), which is all `xtags` holds; anything else throws. */
function readMessage(buffer: Buffer): Array<{ field: number; bytes: Buffer }> {
  const fields: Array<{ field: number; bytes: Buffer }> = [];
  let i = 0;
  const varint = (): number => {
    let value = 0;
    let shift = 0;
    for (;;) {
      if (i >= buffer.length || shift > 28) throw new Error('bad varint');
      const byte = buffer[i++]!;
      value |= (byte & 0x7f) << shift;
      if ((byte & 0x80) === 0) return value;
      shift += 7;
    }
  };
  while (i < buffer.length) {
    const tag = varint();
    if ((tag & 7) !== 2) throw new Error('not a length-delimited field');
    const length = varint();
    if (i + length > buffer.length) throw new Error('field overruns the message');
    fields.push({ field: tag >> 3, bytes: buffer.subarray(i, i + length) });
    i += length;
  }
  return fields;
}

/**
 * The track an adaptive audio format belongs to, or null when it names none (a single-track
 * video's formats carry no `audioTrack` at all, measured on `dQw4w9WgXcQ`).
 */
export function parseAudioTrack(entry: JsonObject, address: string | null): PlayerAudioTrack | null {
  const track = entry['audioTrack'];
  if (!isObject(track)) return null;
  const id = str(track['id']);
  if (!id) return null;

  const xtags = xtagsFromAddress(address) ?? decodeXtagsField(str(entry['xtags']));
  // `isAutoDubbed` is on the AI dubs and on nothing else; it stands in for a missing `xtags`.
  const content = xtags?.['acont'] ?? (track['isAutoDubbed'] === true ? 'dubbed-auto' : null);

  return {
    id,
    displayName: str(track['displayName']),
    isDefault: track['audioIsDefault'] === true,
    content,
    language: xtags?.['lang'] ?? null,
  };
}
