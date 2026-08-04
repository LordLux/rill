import { createInterface } from 'node:readline';
import type { Session } from '../innertube/session.ts';
import { RpcError, isRpcError } from '../errors.ts';
import { logger } from '../log.ts';
import { announceCapabilities } from '../capabilities.ts';

const log = logger('rpc');

let browseSessionPromise: Promise<Session> | null = null;
let resolveSessionPromise: Promise<Session> | null = null;

// Memoise the promise, not the resolved value: two concurrent callers arriving
// before the first session settles would otherwise each create one.
function getBrowseSession(): Promise<Session> {
  if (!browseSessionPromise) {
    browseSessionPromise = (async () => {
      try {
        const { createSession } = await import('../innertube/session.ts');
        return await createSession({ clientType: 'WEB' });
      } catch (e) {
        browseSessionPromise = null;
        throw e;
      }
    })();
  }
  return browseSessionPromise;
}

function getResolveSession(): Promise<Session> {
  if (!resolveSessionPromise) {
    resolveSessionPromise = (async () => {
      try {
        const { createSession } = await import('../innertube/session.ts');
        return await createSession({ clientType: 'MWEB' });
      } catch (e) {
        resolveSessionPromise = null;
        throw e;
      }
    })();
  }
  return resolveSessionPromise;
}

/**
 * `auth.verify` and `feed.home` both fetch base home, and the app calls them
 * back to back at startup — auth.verify counts tiles and throws the payload
 * away. Hold it briefly so the feed.home moments later is free.
 *
 * Base browse ids only. A continuation or a chip token is a different request
 * and is never served from, or written to, this cache.
 */
const BROWSE_CACHE_TTL_MS = 30_000;
const browseCache = new Map<string, { at: number; data: unknown }>();

async function fetchBaseBrowse(session: Session, browseId: string): Promise<unknown> {
  const hit = browseCache.get(browseId);
  if (hit && Date.now() - hit.at < BROWSE_CACHE_TTL_MS) {
    return hit.data;
  }
  const data = await session.execute('/browse', { browseId });
  browseCache.set(browseId, { at: Date.now(), data });
  return data;
}

const abortControllers = new Map<number | string, AbortController>();

function emitResponse(id: number | string, result: unknown) {
  process.stdout.write(JSON.stringify({ id, result }) + '\n');
}

function emitError(id: number | string, error: unknown) {
  let envelope;
  if (isRpcError(error)) {
    try {
      envelope = error.toEnvelope();
    } catch (e: any) {
      envelope = { code: 'UPSTREAM_ERROR', message: e.message, retry: 'auto' };
    }
  } else {
    envelope = {
      code: 'UPSTREAM_ERROR',
      message: error instanceof Error ? error.message : String(error),
      retry: 'auto'
    };
  }
  process.stdout.write(JSON.stringify({ id, error: envelope }) + '\n');
}

function emitEvent(method: string, params: unknown) {
  process.stdout.write(JSON.stringify({ method, params }) + '\n');
}

async function handleRequest(request: any) {
  const { id, method, params } = request;

  if (method === '$cancel') {
    const cancelId = params?.id;
    if (cancelId !== undefined && abortControllers.has(cancelId)) {
      abortControllers.get(cancelId)!.abort();
    }
    return;
  }

  if (id === undefined) {
    return;
  }

  const abortController = new AbortController();
  abortControllers.set(id, abortController);

  try {
    if (method === 'auth.verify') {
      const { verifyAuth } = await import('../innertube/session.ts');
      const session = await getBrowseSession();
      const result = await verifyAuth(session, (s) => fetchBaseBrowse(s, 'FEwhat_to_watch'));
      emitResponse(id, result);
    } else if (method === 'feed.home') {
      const { parseFeed } = await import('../parser/feed.ts');
      const session = await getBrowseSession();
      const token = params?.continuation || params?.chipToken;
      const raw = token
        ? await session.execute('/browse', { browseId: 'FEwhat_to_watch', continuation: token })
        : await fetchBaseBrowse(session, 'FEwhat_to_watch');
      const result = parseFeed(raw, 'home');
      emitResponse(id, result);
    } else if (method === 'playback.open') {
      const { openPlayback } = await import('../playback/resolve.ts');
      const session = await getResolveSession();
      const result = await openPlayback({ session }, params);
      emitResponse(id, result);
    } else {
      emitError(id, new RpcError('UPSTREAM_ERROR', `Unknown method: ${method}`));
    }
  } catch (error: any) {
    if (error.name === 'AbortError') {
      // Aborted, don't send a response
    } else {
      emitError(id, error);
    }
  } finally {
    abortControllers.delete(id);
  }
}

export function startRpcServer() {
  const capabilities = announceCapabilities();
  emitEvent('event.ready', {
    protocolVersion: 1,
    capabilities
  });

  const rl = createInterface({
    input: process.stdin,
    output: process.stdout,
    terminal: false
  });

  rl.on('line', (line) => {
    if (!line.trim()) return;
    try {
      const request = JSON.parse(line);
      handleRequest(request).catch(e => log.error(`Unhandled request error: ${e}`));
    } catch (e: any) {
      log.error(`Malformed JSON: ${e.message}`);
    }
  });

  rl.on('close', () => {
    process.exit(0);
  });
}
