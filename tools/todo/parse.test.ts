import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { itemsInSection, parseTodo, searchTodo } from './parse.ts';

const SAMPLE = `# Todo

**Next number: 9.** A new item takes it.

---

## Now

### 4. First thing

Body of four.

\`\`\`
### 99. not an item, it is inside a fence
\`\`\`

---

## Soon

### 7. Second thing

Mentions the Watchdog here.
### 2. Third thing
Last line.

---

## Far future — ideas

### 5. Fourth thing
`;

describe('parseTodo', () => {
  const file = parseTodo(SAMPLE);

  test('reads items in file order with their section', () => {
    expect(file.items.map((i) => [i.number, i.section])).toEqual([
      [4, 'Now'],
      [7, 'Soon'],
      [2, 'Soon'],
      [5, 'Far future — ideas'],
    ]);
  });

  test('a heading inside a code fence is body, not an item', () => {
    expect(file.items.find((i) => i.number === 99)).toBeUndefined();
    expect(file.items[0]!.body).toContain('### 99.');
  });

  test('the closing rule and blank lines are not part of the body', () => {
    expect(file.items[0]!.body.endsWith('```')).toBe(true);
    expect(file.items[2]!.body).toBe('Last line.');
  });

  test('reads the advertised next number and line numbers', () => {
    expect(file.nextNumber).toBe(9);
    expect(file.items[0]!.line).toBe(9);
  });

  test('a section matches by prefix, case-insensitively', () => {
    expect(itemsInSection(file, 'SO').map((i) => i.number)).toEqual([7, 2]);
    expect(itemsInSection(file, 'far').map((i) => i.number)).toEqual([5]);
    expect(itemsInSection(file, 'nope')).toEqual([]);
  });

  test('search needs every word and reports the matching line', () => {
    const hits = searchTodo(file, 'watchdog second');
    expect(hits.map((h) => h.item.number)).toEqual([7]);
    expect(hits[0]!.excerpt).toBe('Mentions the Watchdog here.');
    expect(searchTodo(file, 'watchdog fourth')).toEqual([]);
  });
});

// The real file: the format the parser relies on is a convention, so check it holds.
describe('docs/todo.md', () => {
  const path = resolve(import.meta.dir, '../../docs/todo.md');
  const file = parseTodo(readFileSync(path, 'utf8'));

  test('has items, each under a section', () => {
    expect(file.items.length).toBeGreaterThan(10);
    expect(file.items.every((i) => i.section !== '' && i.title !== '')).toBe(true);
  });

  test('numbers are unique and below the advertised next number', () => {
    const numbers = file.items.map((i) => i.number);
    expect(new Set(numbers).size).toBe(numbers.length);
    expect(file.nextNumber).not.toBeNull();
    expect(Math.max(...numbers)).toBeLessThan(file.nextNumber!);
  });
});
