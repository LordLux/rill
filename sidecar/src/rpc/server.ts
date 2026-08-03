import { createInterface } from 'node:readline';
import type { Session } from '../innertube/session.ts';
import { RpcError, isRpcError } from '../errors.ts';
import { logger } from '../log.ts';
import { announceCapabilities } from '../capabilities.ts';

const log = logger('rpc');

let browseSession: Session | null = null;
let resolveSession: Session | null = null;

async function getBrowseSession(): Promise<Session> {
  if (!browseSession) {
    const { createSession } = await import('../innertube/session.ts');
    browseSession = await createSession({ clientType: 'WEB' });
  }
  return browseSession;
}

async function getResolveSession(): Promise<Session> {
  if (!resolveSession) {
    const { createSession } = await import('../innertube/session.ts');
    resolveSession = await createSession({ clientType: 'MWEB' });
  }
  return resolveSession;
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
      const result = await verifyAuth(session);
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
