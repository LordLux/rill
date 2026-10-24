// Reads docs/todo.md into items. Shared by the `rill todo` CLI and the MCP server,
// so the two cannot disagree about what the file contains. No dependencies: the
// CLI has to work on a checkout where nothing has been installed.

export interface TodoItem {
  number: number;
  title: string;
  /** The `##` heading it sits under, e.g. "Soon". Empty before the first one. */
  section: string;
  /** 1-based line of the `###` heading. */
  line: number;
  /** Everything under the heading, without the trailing blank lines and `---`. */
  body: string;
}

export interface TodoFile {
  items: TodoItem[];
  /** The "Next number" the file advertises; null if the line is missing. */
  nextNumber: number | null;
}

const ITEM = /^###\s+(\d+)\.\s+(.*\S)\s*$/;
const SECTION = /^##\s+(.*\S)\s*$/;
const NEXT = /^\*\*Next number:\s*(\d+)\.\*\*/;

export function parseTodo(text: string): TodoFile {
  const items: TodoItem[] = [];
  let nextNumber: number | null = null;
  let section = '';
  let current: { item: TodoItem; lines: string[] } | null = null;
  let fence = false;

  const finish = () => {
    if (!current) return;
    const lines = current.lines;
    // A `---` rule only ever closes a section; it is not part of the item.
    while (lines.length > 0 && /^(\s*|---)$/.test(lines[lines.length - 1]!)) lines.pop();
    current.item.body = lines.join('\n');
    items.push(current.item);
    current = null;
  };

  text.split(/\r?\n/).forEach((raw, index) => {
    // A heading inside a code fence is an example, not structure.
    if (/^\s*```/.test(raw)) fence = !fence;
    const heading = !fence;

    const item = heading ? ITEM.exec(raw) : null;
    if (item) {
      finish();
      current = {
        item: { number: Number(item[1]), title: item[2]!, section, line: index + 1, body: '' },
        lines: [],
      };
      return;
    }
    const sec = heading ? SECTION.exec(raw) : null;
    if (sec) {
      finish();
      section = sec[1]!;
      return;
    }
    const next = NEXT.exec(raw);
    if (next && !current) nextNumber = Number(next[1]);
    current?.lines.push(raw);
  });
  finish();

  return { items, nextNumber };
}

/** A section matches by case-insensitive prefix of its name: "soon", "far", "trig". */
export function itemsInSection(file: TodoFile, name: string): TodoItem[] {
  const wanted = name.trim().toLowerCase();
  return file.items.filter((i) => i.section.toLowerCase().startsWith(wanted));
}

export interface SearchHit {
  item: TodoItem;
  /** First line that matched, trimmed; the title when only the title did. */
  excerpt: string;
}

/** Every word must appear (case-insensitive) in the title or body. */
export function searchTodo(file: TodoFile, query: string): SearchHit[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return [];
  const hits: SearchHit[] = [];
  for (const item of file.items) {
    const haystack = `${item.title}\n${item.body}`.toLowerCase();
    if (!words.every((w) => haystack.includes(w))) continue;
    const lines = item.body.split('\n');
    const line = lines.find((l) => l.toLowerCase().includes(words[0]!));
    hits.push({ item, excerpt: (line ?? item.title).trim() });
  }
  return hits;
}

export function formatItem(item: TodoItem): string {
  const head = `### ${item.number}. ${item.title}  [${item.section}, docs/todo.md:${item.line}]`;
  return item.body ? `${head}\n${item.body}` : head;
}

/** One line per item, grouped by section, in file order. */
export function formatIndex(items: TodoItem[]): string {
  const out: string[] = [];
  let section: string | null = null;
  for (const item of items) {
    if (item.section !== section) {
      if (section !== null) out.push('');
      section = item.section;
      out.push(section || '(no section)');
    }
    out.push(`  ${String(item.number).padStart(3)}  ${item.title}`);
  }
  return out.join('\n');
}

export function formatHits(hits: SearchHit[]): string {
  return hits
    .map(({ item, excerpt }) => {
      const line = `  ${String(item.number).padStart(3)}  ${item.title}  [${item.section}]`;
      return excerpt === item.title ? line : `${line}\n         ${excerpt.slice(0, 160)}`;
    })
    .join('\n');
}
