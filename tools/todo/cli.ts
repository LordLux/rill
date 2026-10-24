// `rill todo` — read docs/todo.md without opening 1,500 lines of it.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import {
  formatHits,
  formatIndex,
  formatItem,
  itemsInSection,
  parseTodo,
  searchTodo,
  type TodoFile,
} from './parse.ts';

export const TODO_PATH = process.env.TODO_FILE ?? resolve(import.meta.dir, '../../docs/todo.md');

const HELP = `Usage: rill todo [number...] [options]

  rill todo                    List every item: number and title, by section.
  rill todo 44 101             Print those items in full.
  rill todo -s soon            List one section (prefix match: soon, far, trig, now).
  rill todo -q "audio watchdog"  Items containing every word, with the matching line.

Options:
  -s, --section <name>   Limit the list to a section.
  -q, --search <text>    Search titles and bodies.
  -h, --help             Show this help.

Read-only. The file is docs/todo.md; edit it by hand (numbers are permanent).`;

function fail(message: string): never {
  process.stderr.write(`rill todo: ${message}\n`);
  process.exit(2);
}

function main(args: string[]): void {
  const numbers: number[] = [];
  let section: string | null = null;
  let query: string | null = null;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === '-h' || arg === '--help') {
      process.stdout.write(`${HELP}\n`);
      return;
    }
    if (arg === '-s' || arg === '--section' || arg === '-q' || arg === '--search') {
      const value = args[++i];
      if (value === undefined || value.startsWith('-')) fail(`${arg} needs a value`);
      if (arg === '-s' || arg === '--section') section = value;
      else query = value;
    } else if (/^\d+$/.test(arg)) {
      numbers.push(Number(arg));
    } else {
      fail(`unrecognised argument '${arg}'. Run 'rill todo --help'.`);
    }
  }

  let file: TodoFile;
  try {
    file = parseTodo(readFileSync(TODO_PATH, 'utf8'));
  } catch (e) {
    fail(`cannot read ${TODO_PATH}: ${(e as Error).message}`);
  }

  if (numbers.length > 0) {
    const blocks: string[] = [];
    for (const n of numbers) {
      const item = file.items.find((i) => i.number === n);
      if (!item) fail(`no item ${n} (finished items are deleted and their numbers are not reused)`);
      blocks.push(formatItem(item));
    }
    process.stdout.write(`${blocks.join('\n\n---\n\n')}\n`);
    return;
  }

  if (query !== null) {
    const hits = searchTodo({ ...file, items: section ? itemsInSection(file, section) : file.items }, query);
    process.stdout.write(hits.length ? `${formatHits(hits)}\n` : 'No matches.\n');
    return;
  }

  const items = section ? itemsInSection(file, section) : file.items;
  if (items.length === 0) fail(`no section starts with '${section}'`);
  process.stdout.write(`${formatIndex(items)}\n`);
  if (!section && file.nextNumber !== null) process.stdout.write(`\nNext number: ${file.nextNumber}\n`);
}

if (import.meta.main) main(process.argv.slice(2));
