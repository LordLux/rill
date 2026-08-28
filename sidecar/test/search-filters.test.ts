/**
 * `buildSearchParams` — pure, offline. The byte sequences asserted here are the
 * ones measured live against `/search` on 2026-08-27 (see the module comment in
 * `src/parser/search-filters.ts`), not re-derived from a spec: this test pins
 * the encoding, it does not re-verify the encoding is correct.
 */
import { describe, expect, test } from 'bun:test';
import { buildSearchParams } from '../src/parser/search-filters.ts';

function decode(token: string): number[] {
  return Array.from(Buffer.from(token, 'base64url'));
}

describe('buildSearchParams', () => {
  test('no filters is unfiltered', () => {
    expect(buildSearchParams(null)).toBeNull();
    expect(buildSearchParams(undefined)).toBeNull();
  });

  test('an empty object is the same as no filters', () => {
    expect(buildSearchParams({})).toBeNull();
  });

  test('each single dimension encodes to its measured bytes', () => {
    expect(decode(buildSearchParams({ uploadDate: 'week' })!)).toEqual([0x12, 0x02, 0x08, 0x03]);
    expect(decode(buildSearchParams({ type: 'playlist' })!)).toEqual([0x12, 0x02, 0x10, 0x03]);
    expect(decode(buildSearchParams({ type: 'channel' })!)).toEqual([0x12, 0x02, 0x10, 0x02]);
    // Deliberately not 1,2,3 in short/medium/long order — measured against real
    // durations (short 66–186s, long 1466–12202s, medium 254–1170s).
    expect(decode(buildSearchParams({ duration: 'short' })!)).toEqual([0x12, 0x02, 0x18, 0x01]);
    expect(decode(buildSearchParams({ duration: 'long' })!)).toEqual([0x12, 0x02, 0x18, 0x02]);
    expect(decode(buildSearchParams({ duration: 'medium' })!)).toEqual([0x12, 0x02, 0x18, 0x03]);
    expect(decode(buildSearchParams({ sortBy: 'viewCount' })!)).toEqual([0x08, 0x03]);
  });

  test('multiple dimensions concatenate, sortBy first', () => {
    expect(decode(buildSearchParams({ type: 'playlist', sortBy: 'viewCount' })!)).toEqual([
      0x08, 0x03, 0x12, 0x02, 0x10, 0x03,
    ]);
    expect(decode(buildSearchParams({ duration: 'long', uploadDate: 'year' })!)).toEqual([
      0x12, 0x02, 0x08, 0x05, 0x12, 0x02, 0x18, 0x02,
    ]);
  });

  test('the token is URL-safe base64, unpadded', () => {
    const token = buildSearchParams({ type: 'playlist', sortBy: 'viewCount' })!;
    expect(token).not.toMatch(/[+/=]/);
  });
});
