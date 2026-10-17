// Loopback-only, in-memory service for the iOS guardian integration tests.
// Exercises the real API with synthetic observations; never use for real sessions.
import { createApp } from '../src/server.js';

let offset = 0;
let offline = false;
const app = createApp({ now: () => Date.now() + offset });
const handle = app.server.listeners('request')[0];
app.server.removeAllListeners('request');
app.server.on('request', async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  if (url.pathname === '/__test/control' && req.method === 'POST') {
    try {
      let raw = '';
      for await (const chunk of req) {
        raw += chunk;
        if (raw.length > 1024) throw new Error('Control body too large');
      }
      const body = JSON.parse(raw);
      if (body.reset === true) { offset = 0; offline = false; }
      if (Number.isFinite(body.advanceMs) && body.advanceMs >= 0) offset += body.advanceMs;
      if (typeof body.offline === 'boolean') offline = body.offline;
      app.tick();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ now: Date.now() + offset, offline }));
    } catch {
      res.writeHead(400);
      res.end('{}');
    }
    return;
  }
  if (offline) {
    res.writeHead(503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Simulated service outage' }));
    return;
  }
  await handle(req, res);
});
app.server.listen(4174, '127.0.0.1', () => {
  console.log('KAZE iOS test service: http://127.0.0.1:4174 (synthetic data only)');
});
