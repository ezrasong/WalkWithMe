import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, connect } from 'node:http2';
import { generateKeyPairSync, verify } from 'node:crypto';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { ApplePush, applePushFromEnv } from '../src/apple-push.js';
import { createApp } from '../src/server.js';

const registrationId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', deviceToken = 'a'.repeat(64);
async function fixture(t, { provider = { environment: 'development', send: async () => ({ accepted: true }) }, dbPath } = {}) {
  let clock = 1792216000000;
  const app = createApp({ dbPath, applePush: provider, now: () => clock, tickMs: 3600000 });
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening');
  t.after(async () => { if (app.server.listening) await new Promise(r => app.server.close(r)); });
  const request = async (route, token, body, method = 'POST') => {
    const r = await fetch(`http://127.0.0.1:${app.server.address().port}${route}`, {
      method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json' },
      body: body == null ? undefined : JSON.stringify(body) });
    return { status: r.status, body: await r.json() };
  };
  const session = (await request('/api/sessions', null, { consent: true, simulation: true, name: 'Alex', intervalSeconds: 5, graceSeconds: 3 })).body;
  const route = `/api/sessions/${session.id}`;
  const register = (credential = session.guardianToken, changes = {}) => request(`${route}/guardian-push`, credential,
    { registrationId, deviceToken, environment: 'development', ...changes });
  return { app, request, session, route, register, step: async ms => { clock += ms; await app.tick(); } };
}

test('Apple push configuration fails closed, JWT is ES256, and payload contains no private session evidence', async t => {
  assert.equal(applePushFromEnv({}), null);
  assert.throws(() => applePushFromEnv({ KAZE_APNS_KEY_ID: 'ABCDEFGHIJ' }), /all KAZE_APNS/);
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const server = createServer(); server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(r => server.close(r)));
  let received, reason = null;
  server.on('stream', (stream, headers) => {
    let body = ''; stream.on('data', chunk => { body += chunk; });
    stream.on('end', () => {
      received = { headers, body: JSON.parse(body) };
      stream.respond({ ':status': reason ? 400 : 200 }); stream.end(reason ? JSON.stringify({ reason }) : '');
    });
  });
  let host;
  const provider = new ApplePush({ key: privateKey.export({ format: 'pem', type: 'pkcs8' }), keyId: 'ABCDEFGHIJ',
    teamId: 'KLMNOPQRST', topic: 'app.kaze.trail', environment: 'development', now: () => 1792216000000,
    transport: url => { host = url; return connect(`http://127.0.0.1:${server.address().port}`); } });
  assert.deepEqual(await provider.send({ registrationId, token: deviceToken }), { accepted: true, invalid: false });
  assert.equal(host, 'https://api.sandbox.push.apple.com');
  assert.equal(received.headers['apns-expiration'], '0');
  assert.equal(received.headers['apns-push-type'], 'alert');
  const parts = received.headers.authorization.slice(7).split('.');
  assert.deepEqual(JSON.parse(Buffer.from(parts[0], 'base64url')), { alg: 'ES256', kid: 'ABCDEFGHIJ' });
  assert.deepEqual(JSON.parse(Buffer.from(parts[1], 'base64url')), { iss: 'KLMNOPQRST', iat: 1792216000 });
  assert.equal(verify('sha256', Buffer.from(parts.slice(0, 2).join('.')), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(parts[2], 'base64url')), true);
  assert.deepEqual(Object.keys(received.body).sort(), ['aps', 'kazeRegistration']);
  assert.match(received.body.aps.alert.body, /unanswered/);
  reason = 'BadDeviceToken';
  assert.equal((await provider.send({ registrationId, token: deviceToken })).invalid, true);
});

test('only a guardian can register or remove a bounded, valid Apple device; tokens never enter snapshots', async t => {
  const f = await fixture(t);
  for (const credential of [null, f.session.ownerToken, f.session.watchToken]) assert.equal((await f.register(credential)).status, 401);
  for (const changes of [{ registrationId: '../x' }, { deviceToken: 'no' }, { environment: 'production' }]) assert.equal((await f.register(undefined, changes)).status, 400);
  assert.equal((await f.register()).status, 200);
  const snapshot = await f.request(f.route, f.session.ownerToken, null, 'GET');
  assert.equal(JSON.stringify(snapshot.body).includes(deviceToken), false);
  for (let n = 1; n < 5; n++) assert.equal((await f.register(undefined, { registrationId: `${n}aaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee` })).status, 200);
  assert.equal((await f.register(undefined, { registrationId: '6aaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' })).status, 429);
  assert.equal((await f.request(`${f.route}/guardian-push`, f.session.ownerToken, { registrationId }, 'DELETE')).status, 401);
  assert.equal((await f.request(`${f.route}/guardian-push`, f.session.guardianToken, { registrationId }, 'DELETE')).status, 200);
  assert.equal(f.app.store.guardianPush(f.session.id, registrationId), null);
});

test('push requires server setup and is never silently reported as enabled', async t => {
  const f = await fixture(t, { provider: null });
  assert.equal((await f.register()).status, 503);
  assert.deepEqual(f.app.store.guardianPushes(), []);
});

test('push sends only for confirmed nonresponse, retries failures, deduplicates acceptance and never marks a human response', async t => {
  const sends = []; let accepted = false;
  const f = await fixture(t, { provider: { environment: 'development', send: async p => { sends.push(p); return { accepted }; } } });
  await f.register(); await f.step(5000); assert.equal(sends.length, 0);
  await f.step(3000); assert.equal(sends.length, 1);
  await f.step(1000); assert.equal(sends.length, 1);
  accepted = true; await f.step(30000); assert.equal(sends.length, 2);
  await f.register(); await f.step(60000); assert.equal(sends.length, 2);
  const stored = f.app.store.get(f.session.id);
  for (const key of ['guardianSeenAt', 'alertSeenAt', 'acknowledgedAt', 'arrivalReportedAt']) assert.equal(stored[key], undefined);
});

test('acknowledgment suppresses unsent alerts; revoke, resolution, expiry and deletion remove registrations', async t => {
  for (const action of ['acknowledge', 'revoke-guardian', 'resolve', 'expiry', 'delete']) {
    let sends = 0;
    const f = await fixture(t, { provider: { environment: 'development', send: async () => { sends++; return { accepted: true }; } } });
    if (action === 'acknowledge') await f.step(8000);
    await f.register();
    if (action === 'expiry') await f.step(8 * 3600000);
    else if (action === 'delete') await f.request(f.route, f.session.ownerToken, null, 'DELETE');
    else await f.request(`${f.route}/${action}`, action === 'acknowledge' ? f.session.guardianToken : f.session.ownerToken, { confirm: true });
    await f.step(8000); assert.equal(sends, 0);
    if (action !== 'acknowledge') assert.deepEqual(f.app.store.guardianPushes(), []);
  }
});

test('invalid devices are removed and late delivery responses cannot restore removed registrations', async t => {
  const invalid = await fixture(t, { provider: { environment: 'development', send: async () => ({ invalid: true }) } });
  await invalid.register(); await invalid.step(8000); assert.deepEqual(invalid.app.store.guardianPushes(), []);
  let release, entered;
  const ready = new Promise(resolve => { entered = resolve; });
  const f = await fixture(t, { provider: { environment: 'development', send: () => new Promise(resolve => { release = resolve; entered(); }) } });
  await f.register(); const sending = f.step(8000); await ready;
  await f.request(`${f.route}/revoke-guardian`, f.session.ownerToken, { confirm: true });
  release({ accepted: true }); await sending; assert.deepEqual(f.app.store.guardianPushes(), []);
});

test('accepted deliveries stay deduplicated across a server restart', async t => {
  const dir = mkdtempSync(path.join(tmpdir(), 'kaze-push-'));
  const dbPath = path.join(dir, 'test.sqlite');
  let sends = 0;
  const provider = { environment: 'development', send: async () => { sends++; return { accepted: true }; } };
  const f = await fixture(t, { provider, dbPath }); await f.register(); await f.step(8000);
  await new Promise(r => f.app.server.close(r));
  const second = createApp({ dbPath, now: () => 1792216010000, applePush: provider });
  second.server.listen(0, '127.0.0.1'); await once(second.server, 'listening');
  await second.tick(); assert.equal(sends, 1);
  await new Promise(r => second.server.close(r)); rmSync(dir, { recursive: true });
});

test('a late result cannot mark a removed and re-enrolled device as delivered', async t => {
  let release, entered;
  const ready = new Promise(resolve => { entered = resolve; });
  const f = await fixture(t, { provider: { environment: 'development', send: () => new Promise(resolve => { release = resolve; entered(); }) } });
  await f.register(); const first = f.app.store.guardianPush(f.session.id, registrationId);
  const sending = f.step(8000); await ready;
  await f.request(`${f.route}/guardian-push`, f.session.guardianToken, { registrationId }, 'DELETE');
  await f.register();
  release({ accepted: true }); await sending;
  const current = f.app.store.guardianPush(f.session.id, registrationId);
  assert.notEqual(current.generation, first.generation);
  assert.equal(current.acceptedAt, null);
});
