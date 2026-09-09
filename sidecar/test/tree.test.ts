/**
 * `get` — path walking, including through arrays.
 *
 * The array case is here because it did not work, silently, from the initial
 * commit until 2026-09-09. `get` guarded every hop with `isObject`, which
 * excludes arrays deliberately, so a path that stepped onto a list answered
 * `null` for every remaining segment. The one caller that depended on it —
 * `parsePlayer`'s `playabilityStatus.messages[0]` fallback — was dead the whole
 * time: written, documented, and never once firing, with nothing thrown and
 * nothing logged.
 *
 * The audit that followed found no other caller doing it, so these tests exist
 * less to protect existing behaviour than to make the trap unsettable: the next
 * person who writes `get(x, 'runs', '0', 'text')` gets the value rather than a
 * null they will spend an afternoon on.
 */

import { describe, expect, test } from 'bun:test';
import { get, isObject } from '../src/parser/tree.ts';

describe('get through objects', () => {
  const node = { a: { b: { c: 'leaf' } } };

  test('walks a nested path', () => {
    expect(get(node, 'a', 'b', 'c')).toBe('leaf');
  });

  test('a missing hop is null, not a throw', () => {
    expect(get(node, 'a', 'nope', 'c')).toBeNull();
    expect(get(null, 'a')).toBeNull();
    expect(get('a string', 'a')).toBeNull();
  });

  test('an undefined leaf normalises to null', () => {
    expect(get({ a: undefined }, 'a')).toBeNull();
  });
});

describe('get through arrays', () => {
  // The real shape that exposed it: `playabilityStatus.messages` is a list.
  const body = {
    playabilityStatus: {
      status: 'UNPLAYABLE',
      messages: ['Join this channel to get access to members-only content.'],
    },
  };

  test('a numeric segment indexes an array', () => {
    expect(get(body, 'playabilityStatus', 'messages', '0')).toBe(
      'Join this channel to get access to members-only content.',
    );
  });

  test('and keeps walking past it', () => {
    const node = { runs: [{ text: 'first' }, { text: 'second' }] };
    expect(get(node, 'runs', '0', 'text')).toBe('first');
    expect(get(node, 'runs', '1', 'text')).toBe('second');
  });

  test('an index past the end is null', () => {
    expect(get(body, 'playabilityStatus', 'messages', '9')).toBeNull();
  });

  test('a path ending on an array still returns the array', () => {
    // Unchanged behaviour, and the common case: every other caller in `src/`
    // stops here and hands the list to `asArray`.
    expect(get(body, 'playabilityStatus', 'messages')).toEqual([
      'Join this channel to get access to members-only content.',
    ]);
  });

  test('a NON-numeric segment against an array is null, deliberately', () => {
    // `get(node, 'runs', 'length')` answering `2` would be a data path quietly
    // returning a property of the container. Nested arrays are addressed the
    // same way as anything else — by index.
    const node = { runs: [{ text: 'first' }, { text: 'second' }] };
    expect(get(node, 'runs', 'length')).toBeNull();
    expect(get(node, 'runs', 'map')).toBeNull();
  });

  test('a negative or non-integer index is null', () => {
    const node = { runs: ['a', 'b'] };
    expect(get(node, 'runs', '-1')).toBeNull();
    expect(get(node, 'runs', '1.5')).toBeNull();
  });

  test('nested arrays index through', () => {
    const node = { rows: [[{ v: 1 }], [{ v: 2 }]] };
    expect(get(node, 'rows', '1', '0', 'v')).toBe(2);
  });
});

describe('isObject still excludes arrays', () => {
  // The fix went into `get`, not here — `isObject`'s job is "is this a renderer
  // payload", and ~30 call sites gate on that meaning. Widening it would make
  // its `value is JsonObject` predicate a lie.
  test('an array is not an object', () => {
    expect(isObject([])).toBe(false);
    expect(isObject([{ a: 1 }])).toBe(false);
  });

  test('a plain object is', () => {
    expect(isObject({})).toBe(true);
  });

  test('null and primitives are not', () => {
    expect(isObject(null)).toBe(false);
    expect(isObject('x')).toBe(false);
    expect(isObject(3)).toBe(false);
  });
});
