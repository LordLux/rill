// MCP server (stdio) over docs/todo.md. Read-only on purpose: the file's numbering
// rules ("numbers are permanent", "Next number") are kept by editing it as a diff.
// stdout is the protocol channel; anything diagnostic goes to stderr.
import { readFileSync } from 'node:fs';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { TODO_PATH } from './cli.ts';
import {
  formatHits,
  formatIndex,
  formatItem,
  itemsInSection,
  parseTodo,
  searchTodo,
} from './parse.ts';

// Re-read on every call: the file changes while a session is open.
const load = () => parseTodo(readFileSync(TODO_PATH, 'utf8'));
const text = (value: string) => ({ content: [{ type: 'text' as const, text: value }] });
const failure = (value: string) => ({ ...text(value), isError: true });
const readOnly = { readOnlyHint: true, idempotentHint: true, openWorldHint: false };

const server = new McpServer({ name: 'rill-todo', version: '0.1.0' });

server.registerTool(
  'list_todos',
  {
    title: 'List todos',
    description:
      'List the open items in docs/todo.md: number and title, grouped by section ' +
      '(Now, Soon, Triggered, Far future). Cheap; use it before get_todo.',
    inputSchema: { section: z.string().optional().describe('Section name or prefix, e.g. "soon"') },
    annotations: readOnly,
  },
  async ({ section }) => {
    const file = load();
    const items = section ? itemsInSection(file, section) : file.items;
    if (items.length === 0) return failure(`No section starts with '${section}'.`);
    const footer = !section && file.nextNumber !== null ? `\n\nNext number: ${file.nextNumber}` : '';
    return text(formatIndex(items) + footer);
  },
);

server.registerTool(
  'get_todo',
  {
    title: 'Get a todo',
    description:
      'Return one or more items from docs/todo.md in full, by number. Numbers are ' +
      'permanent and finished items are deleted, so a missing number is normal.',
    inputSchema: { numbers: z.array(z.number().int()).min(1).max(10) },
    annotations: readOnly,
  },
  async ({ numbers }) => {
    const file = load();
    const found = numbers.flatMap((n) => file.items.filter((i) => i.number === n));
    const missing = numbers.filter((n) => !found.some((i) => i.number === n));
    const parts = found.map(formatItem);
    if (missing.length > 0) parts.push(`No item: ${missing.join(', ')}`);
    return found.length > 0 ? text(parts.join('\n\n---\n\n')) : failure(parts.join('\n'));
  },
);

server.registerTool(
  'search_todos',
  {
    title: 'Search todos',
    description:
      'Find items in docs/todo.md whose title or body contains every word of the query ' +
      '(case-insensitive). Returns number, title, section and the first matching line.',
    inputSchema: { query: z.string().min(1), section: z.string().optional() },
    annotations: readOnly,
  },
  async ({ query, section }) => {
    const file = load();
    const scoped = { ...file, items: section ? itemsInSection(file, section) : file.items };
    const hits = searchTodo(scoped, query);
    return text(hits.length ? formatHits(hits) : 'No matches.');
  },
);

await server.connect(new StdioServerTransport());
process.stderr.write(`rill-todo: serving ${TODO_PATH}\n`);
