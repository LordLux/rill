import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import { spawn } from 'node:child_process';
import { resolve } from 'node:path';
import * as readline from 'node:readline';

describe('RPC Transport', () => {
  let child: ReturnType<typeof spawn>;
  let rl: readline.Interface;
  let lines: any[] = [];
  let onLine: ((line: any) => void) | null = null;

  beforeEach(async () => {
    lines = [];
    child = spawn('bun', ['run', resolve(__dirname, '../src/main.ts')]);
    rl = readline.createInterface({ input: child.stdout! });
    
    rl.on('line', (line) => {
      const parsed = JSON.parse(line);
      lines.push(parsed);
      if (onLine) onLine(parsed);
    });

    // Wait for event.ready
    await new Promise<void>((resolve) => {
      if (lines.length > 0 && lines[0].method === 'event.ready') {
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.method === 'event.ready') resolve();
        };
      }
    });
    onLine = null;
  });

  afterEach(() => {
    child.kill();
  });

  it('emits event.ready before any response and matches §2 shape', () => {
    expect(lines[0]).toMatchObject({
      method: 'event.ready',
      params: {
        protocolVersion: 1,
        capabilities: expect.any(Object)
      }
    });
  });

  it('handles a request split across chunk boundaries, fed one byte at a time', async () => {
    const msg = JSON.stringify({ id: 1, method: 'unknown.method' }) + '\n';
    for (let i = 0; i < msg.length; i++) {
      child.stdin!.write(msg[i]);
      // Small delay to ensure it actually flushes out as separate chunks
      await new Promise(r => setTimeout(r, 1));
    }
    
    await new Promise<void>((resolve) => {
      onLine = (parsed) => {
        if (parsed.id === 1) resolve();
      };
    });
    
    const res = lines.find(l => l.id === 1);
    expect(res.error.code).toBe('UPSTREAM_ERROR');
  });

  it('unknown method returns UPSTREAM_ERROR', async () => {
    child.stdin!.write(JSON.stringify({ id: 2, method: 'foo.bar' }) + '\n');
    await new Promise<void>((resolve) => {
      onLine = (parsed) => {
        if (parsed.id === 2) resolve();
      };
    });
    const res = lines.find(l => l.id === 2);
    expect(res.error).toMatchObject({
      code: 'UPSTREAM_ERROR',
      retry: 'auto'
    });
  });

  it('malformed JSON on one line does not kill the process; the next line works', async () => {
    child.stdin!.write('{ malformed json\n');
    child.stdin!.write(JSON.stringify({ id: 3, method: 'foo.bar' }) + '\n');
    
    await new Promise<void>((resolve) => {
      onLine = (parsed) => {
        if (parsed.id === 3) resolve();
      };
    });
    
    const res = lines.find(l => l.id === 3);
    expect(res.error.code).toBe('UPSTREAM_ERROR');
  });

  it('$cancel on an unknown id is a no-op', async () => {
    child.stdin!.write(JSON.stringify({ method: '$cancel', params: { id: 999 } }) + '\n');
    child.stdin!.write(JSON.stringify({ id: 4, method: 'foo.bar' }) + '\n');
    
    await new Promise<void>((resolve) => {
      onLine = (parsed) => {
        if (parsed.id === 4) resolve();
      };
    });
    
    const res = lines.find(l => l.id === 4);
    expect(res.error.code).toBe('UPSTREAM_ERROR');
  });

});
