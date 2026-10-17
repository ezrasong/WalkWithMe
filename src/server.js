import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { Store } from './store.js';
import { Problem, token, hash, matches, number, label, advance, validateEvent } from './domain.js';
import { reconstruct } from './trail.js';
import { geographicTrail } from './locations.js';
import { guardianArTrail } from './ar.js';
import { MotionEvaluator } from './motion.js';

const root = fileURLToPath(new URL('../', import.meta.url));
export function createApp({ dbPath = ':memory:', now = Date.now, tickMs = 1000, motion = new MotionEvaluator() } = {}) {
  const store = new Store(dbPath), limits = new Map();
  const motionLimits = new Map();
  function current(id) {
    let s = store.get(id);
    if (!s) throw new Problem(404, 'Session not found');
    const updated = advance(s, now());
    if (['expired', 'resolved'].includes(updated.phase)) motionLimits.delete(id);
    if (updated.phase === 'expired' && s.phase !== 'expired') { store.clearEvents(s.id); updated.origin = 'Expired'; updated.name = 'Expired session'; }
    if (JSON.stringify(updated) !== JSON.stringify(s)) store.transaction(() => {
      store.save(updated);
      if (updated.phase !== s.phase && updated.phase !== 'expired') store.recordActivity(s.id, updated.phase, updated.escalatedAt ?? s.dueAt, 'server');
    });
    return updated;
  }
  function auth(req, s, allowed) {
    const credential = req.headers.authorization?.replace(/^Bearer /, '');
    const role = ['owner', 'guardian', 'watch'].find(r => matches(credential, s[`${r}Hash`]));
    if (!role || !allowed.includes(role) || s.phase === 'expired') throw new Problem(401, 'Invalid, revoked, or expired access');
    return role;
  }
  function snapshot(s, role) {
    const { ownerHash, guardianHash, watchHash, ...safe } = s;
    const shared = role === 'owner' || (role === 'guardian' && !s.guardianRevokedAt && (s.phase === 'alert' || (s.liveSharing === true && ['armed', 'challenge'].includes(s.phase))));
    if (!shared) delete safe.origin;
    const events = shared ? store.events(s.id) : [];
    const sources = {};
    for (const e of events) {
      const prev = sources[e.source];
      if (!prev || e.at >= prev.lastAt) sources[e.source] = { lastAt: e.at, maxSeq: Math.max(e.seq, prev?.maxSeq ?? 0), battery: e.battery ?? prev?.battery, sensors: e.sensors ?? prev?.sensors };
      else prev.maxSeq = Math.max(prev.maxSeq, e.seq);
    }
    const geography = shared ? geographicTrail(events, now()) : null;
    return { ...safe, serverNow: now(), role, shared, sources, geography,
      activity: shared ? store.activity(s.id) : [],
      guardianConnected: !!s.guardianSeenAt && now() - s.guardianSeenAt < 15000,
      trail: shared ? reconstruct(events, s) : null,
      withoutCamera: shared ? reconstruct(events, { ...s, useCamera: false }) : null,
      lastGps: geography?.latest ?? null };
  }
  async function bytes(req, maximum = 350000) {
    const chunks = []; let size = 0;
    for await (const chunk of req) { size += chunk.length; if (size > maximum) throw new Problem(413, 'Request too large'); chunks.push(chunk); }
    return Buffer.concat(chunks);
  }
  async function body(req) {
    const raw = await bytes(req);
    try { const value = JSON.parse(raw); if (!value || typeof value !== 'object' || Array.isArray(value)) throw 0; return value; }
    catch { throw new Problem(400, 'Expected a JSON object'); }
  }
  const server = http.createServer(async (req, res) => {
    const json = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https://tile.openstreetmap.org; connect-src 'self'; media-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'");
    try {
      const url = new URL(req.url, 'http://localhost');
      if (req.method !== 'GET' && req.headers.origin && req.headers.origin !== `http://${req.headers.host}` && req.headers.origin !== `https://${req.headers.host}`) throw new Problem(403, 'Cross-origin request denied');
      if (url.pathname === '/api/health') return json(200, { ok: true, simulation: true, serverNow: now() });
      if (url.pathname === '/api/sessions' && req.method === 'POST') {
        const key = req.socket.remoteAddress, limit = limits.get(key) ?? { at: now(), count: 0 };
        if (now() - limit.at > 3600000) { limit.at = now(); limit.count = 0; }
        if (++limit.count > 30) throw new Problem(429, 'Too many new sessions. Reuse or delete an existing session.');
        limits.set(key, limit);
        const b = await body(req);
        if (b.consent !== true || b.simulation !== true) throw new Problem(400, 'Explicit session consent and simulation mode required');
        const owner = token(), guardian = token(), watch = token();
        const intervalSeconds = number(b.intervalSeconds ?? 120, 5, 3600, 'check-in interval');
        if (b.liveSharing === true && b.liveSharingConsent !== true) throw new Problem(400, 'Live sharing requires separate explicit consent');
        const s = { id: randomUUID(), name: label(b.name, 60, 'name'), origin: label(b.origin ?? 'Location services', 100, 'entrance'), simulation: true,
          liveSharing: b.liveSharing === true,
          sensorMode: b.sensorMode === 'simulated' ? 'simulated' : 'device',
          createdAt: now(), expiresAt: now() + number(b.retentionHours ?? 8, 0.01, 24, 'retention') * 3600000,
          phase: 'armed', intervalSeconds, graceSeconds: number(b.graceSeconds ?? 30, 3, 300, 'grace period'),
          dueAt: now() + intervalSeconds * 1000, strideMeters: number(b.strideMeters ?? 0.72, 0.2, 1.5, 'stride'),
          initialHeading: number(b.initialHeading ?? 0, 0, 360, 'initial heading'), ownerHash: hash(owner), guardianHash: hash(guardian), watchHash: hash(watch) };
        store.save(s); store.recordActivity(s.id, 'started', now(), 'owner'); return json(201, { ...snapshot(s, 'owner'), ownerToken: owner, guardianToken: guardian, watchToken: watch });
      }
      const match = /^\/api\/sessions\/([a-f0-9-]{36})(?:\/(events|check-in|acknowledge|arrived|resolve|pair|revoke-guardian|ar|motion))?$/.exec(url.pathname);
      if (match) {
        const id = match[1], action = match[2]; let s = current(id);
        if (action === 'motion') {
          auth(req, s, ['owner']);
          if (req.method !== 'POST') throw new Problem(405, 'Method not allowed');
          if (s.phase === 'resolved' || s.sensorMode !== 'device') throw new Problem(409, 'An active device session is required');
          if (req.headers['x-kaze-motion-consent'] !== '1' || req.headers['content-type'] !== 'application/gzip')
            throw new Problem(400, 'Expected an explicitly consented compressed motion batch');
          const compressed = await bytes(req, 180000);
          s = current(id); auth(req, s, ['owner']);
          if (s.phase === 'resolved') throw new Problem(409, 'Session has ended');
          if (compressed[0] !== 0x1f || compressed[1] !== 0x8b || compressed[2] !== 8)
            throw new Problem(400, 'Expected a gzip motion batch');
          if (motionLimits.has(id) && now() - motionLimits.get(id) < 8000) throw new Problem(429, 'Send motion batches at most once per eight seconds');
          motionLimits.set(id, now());
          const result = await motion.evaluate(compressed.toString('base64'));
          // Evaluation yields. Ending/deleting/expiring the session invalidates the result too.
          s = current(id); auth(req, s, ['owner']);
          if (s.phase === 'resolved') throw new Problem(409, 'Session has ended');
          number(result?.captureStartedUtcMs, Math.max(s.createdAt - 5000, now() - 60000), now() + 5000, 'motion batch time');
          return json(200, { accepted: true, serverNow: now(), result });
        }
        if (action === 'ar') {
          auth(req, s, ['owner', 'guardian']);
          if (req.method !== 'GET') throw new Problem(405, 'Method not allowed');
          if (s.phase !== 'alert') throw new Problem(409, 'An active assistance request is required');
          return json(200, guardianArTrail(store.events(s.id), now()));
        }
        if (req.method === 'GET' && !action) {
          const role = auth(req, s, ['owner', 'guardian', 'watch']);
          if (role === 'guardian') { s.guardianSeenAt = now(); if (s.phase === 'alert') s.alertSeenAt ??= now(); store.save(s); }
          return json(200, snapshot(s, role));
        }
        if (req.method === 'DELETE' && !action) { auth(req, s, ['owner']); motionLimits.delete(id); store.remove(id); return json(200, { deleted: true }); }
        if (req.method === 'POST' && action) {
          const role = auth(req, s, action === 'events' || action === 'check-in' ? ['owner', 'watch'] :
            action === 'acknowledge' || action === 'arrived' ? ['guardian'] : ['owner']);
          const b = await body(req);
          // Parsing the body yields to the event loop. Recheck the persisted clock/state afterwards.
          s = current(id); auth(req, s, [role]);
          if (action === 'pair') return json(200, { id, watchToken: b.rotate === true ? (() => { const next = token(); s.watchHash = hash(next); store.save(s); return next; })() : null });
          if (['resolved'].includes(s.phase)) throw new Problem(409, 'Session has ended');
          if (action === 'revoke-guardian') {
            if (b.confirm !== true) throw new Problem(400, 'Explicit confirmation required');
            s.guardianHash = hash(token()); s.guardianRevokedAt = now(); s.liveSharing = false;
          }
          if (action === 'events') {
            if (!Array.isArray(b.events) || b.events.length < 1 || b.events.length > 100) throw new Problem(400, 'Expected 1–100 events');
            const events = b.events.map(e => validateEvent(e, s, role, now()));
            const added = store.transaction(() => {
              const added = store.append(id, events);
              if (store.count(id) > 50000) throw new Problem(413, 'Session event limit reached');
              return added;
            });
            return json(200, { accepted: added, serverNow: now(), phase: s.phase, dueAt: s.dueAt, graceSeconds: s.graceSeconds, intervalSeconds: s.intervalSeconds });
          }
          if (action === 'check-in') {
            if (s.phase === 'alert') throw new Problem(409, 'Alert remains active. Wearer must explicitly end the session.');
            if (b.confirm !== true) throw new Problem(400, 'Check-in requires an explicit response');
            s.phase = 'armed'; s.dueAt = now() + s.intervalSeconds * 1000; s.lastCheckInAt = now();
          }
          if (action === 'acknowledge' || action === 'arrived') {
            if (s.phase !== 'alert' || b.confirm !== true) throw new Problem(409, 'An active alert and explicit confirmation are required');
            if (action === 'acknowledge') s.acknowledgedAt ??= now();
            else s.arrivalReportedAt ??= now();
          }
          if (action === 'resolve') { if (b.confirm !== true) throw new Problem(400, 'Explicit confirmation required'); s.phase = 'resolved'; s.resolvedAt = now(); }
          store.transaction(() => { store.save(s); store.recordActivity(id, action, now(), role); }); return json(200, snapshot(s, role));
        }
        throw new Problem(405, 'Method not allowed');
      }
      const files = { '/': ['public/index.html', 'text/html'], '/guardian': ['public/index.html', 'text/html'], '/app.js': ['public/app.js', 'text/javascript'], '/style.css': ['public/style.css', 'text/css'],
        '/leaflet.js': ['node_modules/leaflet/dist/leaflet.js', 'text/javascript'], '/leaflet.css': ['node_modules/leaflet/dist/leaflet.css', 'text/css'] };
      if (req.method === 'GET' && files[url.pathname]) {
        const [file, type] = files[url.pathname]; res.writeHead(200, { 'Content-Type': `${type}; charset=utf-8`, 'Cache-Control': 'no-cache' }); res.end(await readFile(path.join(root, file))); return;
      }
      throw new Problem(404, 'Not found');
    } catch (e) { if (!res.headersSent) json(e.status ?? 500, { error: e.status ? e.message : 'Internal server error' }); else res.end(); }
  });
  const timer = setInterval(() => { for (const s of store.all()) current(s.id); }, tickMs); timer.unref();
  server.on('close', () => { clearInterval(timer); motion.close(); store.close(); });
  return { server, store, tick: () => { for (const s of store.all()) current(s.id); } };
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  mkdirSync(path.join(root, 'data'), { recursive: true });
  const { server } = createApp({ dbPath: process.env.KAZE_DB ?? path.join(root, 'data/kaze.sqlite') });
  server.listen(Number(process.env.PORT ?? 4173), process.env.HOST ?? '127.0.0.1', () => console.log(`KAZE simulation: http://${process.env.HOST ?? '127.0.0.1'}:${process.env.PORT ?? 4173}`));
}
