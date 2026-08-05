import { createInterface } from 'node:readline';

const version = parseInt(process.argv[2] || '1', 10);
// 'empty-home': the base browse returns no items and auth.verify answers
// slowly. That is the one shape in which a response the client did NOT cancel
// can land after a newer request — auth.verify is issued with a plain call —
// so it is the only way to exercise the controller's generation guard on its
// own, rather than behind $cancel.
const mode = process.argv[3] || '';
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
      const replyAuth = () => process.stdout.write(JSON.stringify({
        id: req.id,
        result: mode === 'empty-home'
          ? { state: 'anonymous', tileCount: 0 }
          : { state: 'authenticated', tileCount: 10 },
      }) + '\n');
      // Deliberately not registered in `pending`: the client issues auth.verify
      // with a plain call and never cancels it, which is exactly the point.
      if (mode === 'empty-home') setTimeout(replyAuth, 400); else replyAuth();
    } else if (req.method === 'playback.open') {
      process.stdout.write(JSON.stringify({ id: req.id, result: { sessionId: 's1', durationMs: 1000, variants: [] } }) + '\n');
    } else if (req.method === 'feed.home') {
      // Token grammar, for tests only:
      //
      //   ""                 base browse — ships a chip bar, like the real one
      //   "MUSIC"            filtered — echoed back in every item title
      //   "MUSIC@250"        the same, answered after 250 ms
      //   "MUSIC@250!keepalive"  answered even after $cancel
      //
      // `!keepalive` makes the sidecar answer a request the client cancelled,
      // so a superseded payload is genuinely put on the wire after its
      // replacement rather than never being sent. What drops it on the client
      // is layered — see the test — but without this the scenario cannot even
      // be staged.
      const raw = (req.params && (req.params.continuation || req.params.chipToken)) || '';
      const keepalive = raw.endsWith('!keepalive');
      const spec = keepalive ? raw.slice(0, -'!keepalive'.length) : raw;
      const at = spec.indexOf('@');
      const label = at === -1 ? spec : spec.slice(0, at);
      const delay = at === -1 ? 0 : parseInt(spec.slice(at + 1), 10) || 0;
      const tag = label === '' ? 'BASE' : label;

      const send = () => {
        pending.delete(req.id);
        process.stdout.write(JSON.stringify({
          id: req.id,
          result: {
            // A filtered or paged response carries no feed chips — that is the
            // behaviour measured in home-continuation.json.
            chips: label === '' ? [
              { label: 'All', token: '', selected: true, scope: 'feed' },
              { label: 'Music', token: 'MUSIC', selected: false, scope: 'feed' },
              { label: 'Gaming', token: 'GAMING', selected: false, scope: 'feed' },
            ] : [],
            items: (mode === 'empty-home' && label === '' ? [] : [0, 1, 2]).map((n) => ({
              kind: 'video',
              id: `vid_${tag}_${n}`,
              title: `${tag} item ${n}`,
              channelName: 'Fake Channel',
              channelId: 'chan_001',
              channelAvatarUrl: null,
              thumbnailUrl: 'https://fake.url/img.jpg',
              durationSeconds: 60,
              isLive: false,
              viewCountText: null,
              publishedText: null,
              badges: [],
              canWatchLater: true,
              canAddToQueue: true,
            })),
            continuation: null,
          },
        }) + '\n');
      };

      if (delay === 0) {
        send();
      } else {
        const timer = setTimeout(send, delay);
        // Only a cancellable request goes in `pending`; $cancel clears that map.
        if (!keepalive) pending.set(req.id, timer);
      }
    } else if (req.method === 'test.large_payload') {
      const largeStr = 'x'.repeat(1000000);
      process.stdout.write(JSON.stringify({ id: req.id, result: largeStr }) + '\n');
    }
  } catch (err) {
    process.stderr.write(`fake_sidecar error: ${err}\n`);
  }
});
