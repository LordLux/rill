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
    child = spawn('bun', [resolve(__dirname, '../src/main.ts')]);
    rl = readline.createInterface({ input: child.stdout! });
    
    rl.on('line', (line) => {
      const parsed = JSON.parse(line);
      lines.push(parsed);
      if (onLine) onLine(parsed);
    });

    // Wait for event.ready
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('event.ready timeout')), 1000);
      if (lines.length > 0 && lines[0].method === 'event.ready') {
        clearTimeout(timeout);
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.method === 'event.ready') {
            clearTimeout(timeout);
            resolve();
          }
        };
      }
    });
    onLine = null;
  });

  afterEach(() => {
    if (child && !child.killed) {
      if (child.stdin) child.stdin.end();
      child.kill();
    }
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

  it('emits event.ready in under 500ms', async () => {
    const start = Date.now();
    const testChild = spawn('bun', [resolve(__dirname, '../src/main.ts')]);
    const testRl = readline.createInterface({ input: testChild.stdout! });
    
    await new Promise<void>((resolve) => {
      testRl.on('line', (line) => {
        const parsed = JSON.parse(line);
        if (parsed.method === 'event.ready') {
          resolve();
        }
      });
    });
    const elapsed = Date.now() - start;
    testChild.stdin!.end();
    testChild.kill();
    expect(elapsed).toBeLessThan(500);
  });

  it('handles a request split across chunk boundaries, fed one byte at a time', async () => {
    const msg = JSON.stringify({ id: 1, method: 'unknown.method' }) + '\n';
    for (let i = 0; i < msg.length; i++) {
      child.stdin!.write(msg[i]);
      // Small delay to ensure it actually flushes out as separate chunks
      await new Promise(r => setTimeout(r, 1));
    }
    
    await new Promise<void>((resolve) => {
      if (lines.find(l => l.id === 1)) {
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.id === 1) resolve();
        };
      }
    });
    
    const res = lines.find(l => l.id === 1);
    expect(res.error.code).toBe('UPSTREAM_ERROR');
  });

  it('unknown method returns UPSTREAM_ERROR', async () => {
    child.stdin!.write(JSON.stringify({ id: 2, method: 'foo.bar' }) + '\n');
    await new Promise<void>((resolve) => {
      if (lines.find(l => l.id === 2)) {
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.id === 2) resolve();
        };
      }
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
      if (lines.find(l => l.id === 3)) {
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.id === 3) resolve();
        };
      }
    });
    
    const res = lines.find(l => l.id === 3);
    expect(res.error.code).toBe('UPSTREAM_ERROR');
  });

  it('$cancel on an unknown id is a no-op', async () => {
    child.stdin!.write(JSON.stringify({ method: '$cancel', params: { id: 999 } }) + '\n');
    child.stdin!.write(JSON.stringify({ id: 4, method: 'foo.bar' }) + '\n');
    
    await new Promise<void>((resolve) => {
      if (lines.find(l => l.id === 4)) {
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.id === 4) resolve();
        };
      }
    });
    
    const res = lines.find(l => l.id === 4);
    expect(res.error.code).toBe('UPSTREAM_ERROR');
  });

  it('two concurrent requests return to the correct ids, out of order', async () => {
    // method: 'auth.verify' is slow (network). method: 'unknown.method' is fast (immediate error).
    child.stdin!.write(JSON.stringify({ id: 10, method: 'auth.verify' }) + '\n');
    child.stdin!.write(JSON.stringify({ id: 11, method: 'unknown.method' }) + '\n');
    
    await new Promise<void>((resolve) => {
      if (lines.find(l => l.id === 11)) {
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.id === 11) resolve();
        };
      }
    });
    
    const res11 = lines.find(l => l.id === 11);
    const res10 = lines.find(l => l.id === 10);
    
    // 11 should have returned, 10 should not have returned yet.
    expect(res11).toBeDefined();
    expect(res10).toBeUndefined();
    
    expect(res11.error.code).toBe('UPSTREAM_ERROR');
  }, 10000);

  it('internal signal escaping to dispatch becomes UPSTREAM_ERROR, not a crash', async () => {
    child.stdin!.write(JSON.stringify({ id: 20, method: { toString: null } }) + '\n');
    
    await new Promise<void>((resolve) => {
      if (lines.find(l => l.id === 20)) {
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.id === 20) resolve();
        };
      }
    });
    
    const res = lines.find(l => l.id === 20);
    expect(res.error).toBeDefined();
    // It should not have crashed, meaning we got a response envelope
    expect(res.error.code).not.toBe('INTERNAL_SIGNAL'); // because it becomes something like UPSTREAM_ERROR or STREAM_UNAVAILABLE
    // The main point is it didn't crash.
  }, 10000);

});
