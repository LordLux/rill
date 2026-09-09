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
import { traverse, type Collector } from '../src/parser/feed.ts';
import { get, isObject, walk, type Json, type JsonObject } from '../src/parser/tree.ts';

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

describe('the three "is this an object?" implementations agree', () => {
  /**
   * CLAUDE.md names this directly: "'Is this an object?' exists three times
   * in the parser, and the three do not share a line of code" —
   *
   *   1. `isObject` in `src/parser/tree.ts`
   *   2. the inline `Array.isArray` branch inside `walk` (also tree.ts —
   *      `walk`/`deepFind`/`deepCollect` do not call `isObject`, each has
   *      its own copy of the check)
   *   3. `traverse` in `src/parser/feed.ts`
   *
   * "They agree today. Nothing makes them agree" — this test is what makes a
   * future disagreement loud instead of silent. It drives all three over one
   * table of edge-case values and asserts they classify every value the same
   * way: as an object to descend into, an array to iterate, or neither. The
   * three have different signatures and no shared return type, so "agree"
   * here means classification *behaviour*, observed rather than compared
   * structurally — see the three `classify*` helpers below.
   */

  type Shape = 'object' | 'array' | 'skip';

  function freshCollector(): Collector {
    return {
      items: [],
      chips: [],
      continuation: null,
      seenChips: new Set(),
      stripped: { shorts: 0, ads: 0 },
      artistPanel: null,
      subscriptionEntities: new Map(),
    };
  }

  /** `isObject`'s own contract is binary (renderer payload or not); the array
   *  vs. skip split below it is filled in with the platform's own
   *  `Array.isArray`, so the interesting comparison is purely whether
   *  `isObject`'s "object" case lines up with the other two. */
  function classifyIsObject(value: unknown): Shape {
    if (isObject(value)) return 'object';
    if (Array.isArray(value)) return 'array';
    return 'skip';
  }

  /** `walk` exposes a real visitor callback, so classification is read
   *  straight off which node identities it hands back — no instrumentation
   *  needed. An extra marker object is appended when probing an array,
   *  since `walk` never visits the array itself, only what is inside it. */
  function classifyWalk(value: unknown): Shape {
    let sawValueItself = false;
    let sawArrayMarker = false;
    const marker = {};
    const probe = Array.isArray(value) ? [...value, marker] : value;

    walk(probe, (node) => {
      if (node === value) sawValueItself = true;
      if (node === marker) sawArrayMarker = true;
      return true;
    });

    if (sawValueItself) return 'object';
    if (sawArrayMarker) return 'array';
    return 'skip';
  }

  /** `traverse` has no generic visitor hook — its object branch reveals
   *  itself by reading `node['type']` as its very first act, before it ever
   *  consults vocabulary.ts. A getter planted in that slot is a faithful,
   *  side-effect-free tripwire for "this value was handled as an object
   *  node", independent of whether anything recognises it as a renderer.
   *  For an array, the same getter sits on a marker element instead, since
   *  `traverse`'s array branch only ever recurses into elements. */
  function classifyTraverse(value: unknown): Shape {
    const collector = freshCollector();

    if (Array.isArray(value)) {
      const marker: JsonObject = {};
      let markerEntered = false;
      Object.defineProperty(marker, 'type', {
        configurable: true,
        get() {
          markerEntered = true;
          return undefined;
        },
      });
      traverse(collector, [...value, marker], 'test', 0);
      return markerEntered ? 'array' : 'skip';
    }

    if (value !== null && typeof value === 'object') {
      const target = value as Record<string, unknown>;
      const hadOwn = Object.prototype.hasOwnProperty.call(target, 'type');
      const original = hadOwn ? Object.getOwnPropertyDescriptor(target, 'type') : undefined;
      let entered = false;
      try {
        Object.defineProperty(target, 'type', {
          configurable: true,
          get() {
            entered = true;
            return undefined;
          },
        });
        traverse(collector, value as Json, 'test', 0);
      } finally {
        if (original) Object.defineProperty(target, 'type', original);
        else delete target.type;
      }
      return entered ? 'object' : 'skip';
    }

    traverse(collector, value as Json, 'test', 0);
    return 'skip';
  }

  class Thing {
    x = 1;
  }

  const table: Array<[label: string, value: unknown, expected: Shape]> = [
    ['a plain object', { a: 1 }, 'object'],
    ['an empty object', {}, 'object'],
    ['an array', [1, 2, 3], 'array'],
    ['an empty array', [], 'array'],
    ['null', null, 'skip'],
    ['undefined', undefined, 'skip'],
    ['a string', 'hello', 'skip'],
    ['a number', 42, 'skip'],
    ['Object.create(null)', Object.create(null), 'object'],
    ['a class instance', new Thing(), 'object'],
    ['a Map', new Map([['k', 'v']]), 'object'],
    ['a Date', new Date(0), 'object'],
    ['a nested mix of arrays and objects', { list: [1, { b: 2 }, [3]], n: null }, 'object'],
  ];

  for (const [label, value, expected] of table) {
    test(`${label} classifies as "${expected}" in all three`, () => {
      expect(classifyIsObject(value)).toBe(expected);
      expect(classifyWalk(value)).toBe(expected);
      expect(classifyTraverse(value)).toBe(expected);
    });
  }
});
