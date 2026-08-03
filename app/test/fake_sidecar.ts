import { createInterface } from 'node:readline';

const version = parseInt(process.argv[2] || '1', 10);
process.stdout.write(JSON.stringify({
  method: 'event.ready',
  params: { protocolVersion: version, capabilities: {} }
}) + '\n');

const rl = createInterface({ input: process.stdin });
const pending = new Map();

const parentPid = process.env.FLUTTER_PARENT_PID;
if (parentPid) {
  setInterval(() => {
    try {
      process.kill(parseInt(parentPid, 10), 0);
    } catch (e) {
      process.stderr.write(`fake_sidecar: process.kill failed: ${e}\n`);
      process.exit(0);
    }
  }, 3000).unref();
}

process.stdin.on('end', () => {
  process.stderr.write('fake_sidecar: stdin end\n');
  process.exit(0);
});
process.stdin.on('error', (e) => {
  process.stderr.write(`fake_sidecar: stdin error ${e}\n`);
  process.exit(0);
});

rl.on('close', () => {
  process.exit(0);
});

rl.on('line', (line) => {
  if (!line.trim()) return;
  try {
    const req = JSON.parse(line);
    
    if (req.method === '$cancel') {
      const id = req.params.id;
      if (pending.has(id)) {
        clearTimeout(pending.get(id));
        pending.delete(id);
      }
    } else if (req.method === 'test.echo') {
      const delay = req.params.delay || 0;
      const timer = setTimeout(() => {
        pending.delete(req.id);
        process.stdout.write(JSON.stringify({ id: req.id, result: req.params.msg }) + '\n');
      }, delay);
      pending.set(req.id, timer);
    } else if (req.method === 'test.error') {
      process.stdout.write(JSON.stringify({
        id: req.id,
        error: { code: 'TEST_ERROR', message: 'test error', retry: 'auto' }
      }) + '\n');
    } else if (req.method === 'auth.verify') {
      process.stdout.write(JSON.stringify({ id: req.id, result: { state: 'authenticated', tileCount: 10 } }) + '\n');
    } else if (req.method === 'playback.open') {
      process.stdout.write(JSON.stringify({ id: req.id, result: { sessionId: 's1', durationMs: 1000, variants: [] } }) + '\n');
    } else if (req.method === 'test.large_payload') {
      const largeStr = 'x'.repeat(1000000);
      process.stdout.write(JSON.stringify({ id: req.id, result: largeStr }) + '\n');
    }
  } catch (err) {
    process.stderr.write(`fake_sidecar error: ${err}\n`);
  }
});
