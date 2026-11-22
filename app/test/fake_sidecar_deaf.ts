// A sidecar that says it is ready and then closes its stdin, staying alive: every line written to
// it after that fails on the pipe with Windows' errno 232, "The pipe is being closed" — the write
// failure a sidecar killed mid-write produces (`rpc_client_test.dart`, `client.dart`'s
// `stdin.done` listener).
import { closeSync } from 'fs';

process.stdout.write(JSON.stringify({
  method: 'event.ready',
  params: { protocolVersion: 1, capabilities: {} }
}) + '\n');
closeSync(0);
setInterval(() => {}, 1000);
