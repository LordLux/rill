import { describe, it, expect, beforeEach, afterEach } from 'bun:test';
import { spawn } from 'node:child_process';
import { resolve } from 'node:path';
import * as readline from 'node:readline';

/**
 * A frame read off the sidecar's stdout.
 *
 * The transport's whole job is that these are the only four keys, so a test that
 * reaches for a fifth is asserting something the protocol does not promise —
 * which is exactly what `any` here used to allow.
 */
interface Frame {
  id?: number;
  method?: string;
  result?: unknown;
  error?: { code: string; message: string; retry: string };
  params?: Record<string, unknown>;
}

/**
 * The frame for `id`, or a failure naming the id that never arrived.
 *
 * `Array.find` returns `T | undefined`, and reaching straight through it — which
 * `any` used to permit — turns "the sidecar never answered id 3" into
 * `Cannot read properties of undefined`, a message about the test rather than
 * about the transport.
 */
function frameFor(lines: Frame[], id: number): Frame {
  const frame = lines.find((l) => l.id === id);
  if (!frame) throw new Error(`no frame arrived for id ${id}`);
  return frame;
}

/** The error envelope on a frame, or a failure saying it carried none. */
function errorOf(frame: Frame): { code: string; message: string; retry: string } {
  if (!frame.error) {
    throw new Error(`frame ${frame.id} carried no error envelope (result: ${JSON.stringify(frame.result)})`);
  }
  return frame.error;
}

describe('RPC Transport', () => {
  let child: ReturnType<typeof spawn>;
  let rl: readline.Interface;
  let lines: Frame[] = [];
  let onLine: ((line: Frame) => void) | null = null;

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
      if (lines.length > 0 && lines[0]?.method === 'event.ready') {
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

  it('starts and emits event.ready with no network', async () => {
    // Force broken network using a dead proxy
    const testChild = spawn('bun', [resolve(__dirname, '../src/main.ts')], {
      env: { ...process.env, HTTP_PROXY: 'http://0.0.0.0:12345', HTTPS_PROXY: 'http://0.0.0.0:12345' }
    });
    const testRl = readline.createInterface({ input: testChild.stdout! });
    
    const start = Date.now();
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timeout')), 1000);
      testRl.on('line', (line) => {
        const parsed = JSON.parse(line);
        if (parsed.method === 'event.ready') {
          clearTimeout(timer);
          resolve();
        }
      });
    });
    const elapsed = Date.now() - start;
    
    testChild.stdin!.end();
    testChild.kill();
    expect(elapsed).toBeLessThan(1000);
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
    
    const res = frameFor(lines, 1);
    expect(errorOf(res).code).toBe('BAD_REQUEST');
  });

  it('unknown method returns BAD_REQUEST with retry no', async () => {
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
    const res = frameFor(lines, 2);
    // `no`, not `auto`: retrying an unknown method can never succeed, and an
    // `auto` here had the app backing off four times over a client bug.
    expect(errorOf(res)).toMatchObject({
      code: 'BAD_REQUEST',
      retry: 'no'
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
    
    const res = frameFor(lines, 3);
    expect(errorOf(res).code).toBe('BAD_REQUEST');
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
    
    const res = frameFor(lines, 4);
    expect(errorOf(res).code).toBe('BAD_REQUEST');
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
    
    const res10 = lines.find(l => l.id === 10);
    
    // 11 should have returned, 10 should not have returned yet.
    expect(res10).toBeUndefined();

    // `frameFor` throws if 11 never arrived, which is the assertion that used to
    // be `expect(res11).toBeDefined()`.
    expect(errorOf(frameFor(lines, 11)).code).toBe('BAD_REQUEST');
  }, 10000);

  it('a non-string method is answered, not crashed on', async () => {
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
    
    // The point is the envelope, not the code: dispatch must answer rather than
    // die, and an internal signal must never be what it answers with.
    const res = frameFor(lines, 20);
    expect(errorOf(res).code).toBe('BAD_REQUEST');
    expect(['STREAM_REQUIRES_SABR', 'PARSE_FAILED']).not.toContain(errorOf(res).code);
  }, 10000);

  it('playback.open without a videoId is BAD_REQUEST, not a retried UPSTREAM_ERROR', async () => {
    // The concrete regression: params that fail validation used to answer
    // UPSTREAM_ERROR (`auto`), so the app retried a call that can never work.
    // §3 is about to grow five more methods that all take params.
    child.stdin!.write(JSON.stringify({ id: 30, method: 'playback.open', params: {} }) + '\n');

    await new Promise<void>((resolve) => {
      if (lines.find(l => l.id === 30)) {
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.id === 30) resolve();
        };
      }
    });

    expect(errorOf(frameFor(lines, 30))).toMatchObject({ code: 'BAD_REQUEST', retry: 'no' });
  }, 10000);

  /**
   * Send a request and wait for its answer.
   *
   * The watch-page methods below all fail validation before anything touches the
   * network, which is the property under test: a malformed frame must be refused
   * by the transport, not carried into a session it would then wait on.
   */
  async function answer(id: number, method: string, params: unknown): Promise<Frame> {
    child.stdin!.write(JSON.stringify({ id, method, params }) + '\n');
    await new Promise<void>((resolve) => {
      if (lines.find((l) => l.id === id)) {
        resolve();
      } else {
        onLine = (parsed) => {
          if (parsed.id === id) resolve();
        };
      }
    });
    onLine = null;
    return frameFor(lines, id);
  }

  describe('watch-page parameter validation (§3.3–3.5)', () => {
    // Each of these is a client bug, and every one of them used to be the kind
    // that reaches YouTube as a request about a video nobody asked for. `no`,
    // not `auto`: the same bytes fail the same way forever.
    const malformed: Array<[string, string, unknown]> = [
      ['video.info with no videoId', 'video.info', {}],
      ['video.info with a blank videoId', 'video.info', { videoId: '   ' }],
      ['video.related with no videoId', 'video.related', {}],
      [
        'video.related with a non-string continuation',
        'video.related',
        { videoId: 'aqz-KE-bpKQ', continuation: 42 },
      ],
      ['action.addToWatchLater with no videoId', 'action.addToWatchLater', {}],
      [
        'action.addToPlaylist with no playlistId',
        'action.addToPlaylist',
        { videoId: 'aqz-KE-bpKQ' },
      ],
      ['playback.report with no sessionId', 'playback.report', { positionMs: 0, state: 'playing' }],
      [
        'playback.report with a missing position',
        'playback.report',
        { sessionId: 's1', state: 'playing' },
      ],
      [
        // NaN survives JSON as null, and a string "NaN" survives intact. Either
        // reaches the stats endpoint as st=NaN, which answers 200 and records
        // nothing — the exact failure mode this method cannot afford.
        'playback.report with a non-numeric position',
        'playback.report',
        { sessionId: 's1', positionMs: 'NaN', state: 'playing' },
      ],
      [
        'playback.report with an unknown state',
        'playback.report',
        { sessionId: 's1', positionMs: 0, state: 'scrubbing' },
      ],
      ['playback.close with no sessionId', 'playback.close', {}],
    ];

    let nextId = 100;
    for (const [label, method, params] of malformed) {
      const id = nextId++;
      it(`${label} is BAD_REQUEST with retry no`, async () => {
        expect(errorOf(await answer(id, method, params))).toMatchObject({
          code: 'BAD_REQUEST',
          retry: 'no',
        });
      }, 10000);
    }

    it('playback.close on an unknown session succeeds — a double close is not an error', async () => {
      const frame = await answer(200, 'playback.close', { sessionId: 'never-opened' });
      expect(frame.error).toBeUndefined();
      expect(frame.result).toEqual({});
    }, 10000);
  });
});
