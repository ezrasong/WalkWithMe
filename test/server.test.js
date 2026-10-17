import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createApp } from '../src/server.js';

const motionBatch = Buffer.from([0x1f, 0x8b, 8, 0]);
const motionHeaders = { 'Content-Type': 'application/gzip', 'X-Kaze-Motion-Consent': '1' };

async function fixture(t, opts = {}) {
  let clock = 1792216000000;
  const app = createApp({ now: () => clock, ...opts }); app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  const request = async (route, { token, body, method = body ? 'POST' : 'GET', headers = {} } = {}) => {
    const response = await fetch(base + route, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}), ...headers }, body: body ? (Buffer.isBuffer(body) ? body : JSON.stringify(body)) : undefined });
    return { status: response.status, body: await response.json() };
  };
  const create = async () => (await request('/api/sessions', { body: { consent: true, simulation: true, name: 'Alex', origin: 'Private entrance', intervalSeconds: 5, graceSeconds: 3 } })).body;
  t.after(async () => { if (app.server.listening) await new Promise(resolve => app.server.close(resolve)); });
  return { app, base, request, create, time: () => clock, jump: ms => { clock += ms; app.tick(); } };
}

test('motion batches require owner consent, are rate bounded and cannot alter safety evidence', async t => {
  let evaluations = 0;
  const motion = { close() {}, async evaluate() {
    evaluations++;
    return { captureStartedUtcMs: 1792216000000, geographic: false, guidanceAllowed: false, segments: [] };
  } };
  const f = await fixture(t, { motion }), s = await f.create(), url = `/api/sessions/${s.id}/motion`;
  const send = (token = s.ownerToken, body = motionBatch, headers = motionHeaders) => f.request(url, { token, body, headers });
  assert.equal((await send(s.guardianToken)).status, 401);
  assert.equal((await send(s.watchToken)).status, 401);
  assert.equal((await send(s.ownerToken, motionBatch, { 'Content-Type': 'application/gzip' })).status, 400);
  assert.equal((await send(s.ownerToken, Buffer.from('!bad'))).status, 400);
  assert.equal((await send(s.ownerToken, Buffer.alloc(180001))).status, 413);
  const before = f.app.store.get(s.id), activity = f.app.store.activity(s.id);
  assert.equal((await send()).status, 200);
  assert.equal((await send()).status, 429);
  assert.equal(evaluations, 1);
  assert.deepEqual(f.app.store.get(s.id), before);
  assert.deepEqual(f.app.store.events(s.id), []);
  assert.deepEqual(f.app.store.activity(s.id), activity);
  f.jump(8000);
  assert.equal((await send()).status, 200);
  await f.request(`/api/sessions/${s.id}/resolve`, { token: s.ownerToken, body: { confirm: true } });
  assert.equal((await send()).status, 409);
});

test('motion result is discarded if its session ends during processing', async t => {
  let finish, started;
  const processing = new Promise(resolve => { started = resolve; });
  const motion = { close() {}, evaluate() { started(); return new Promise(resolve => { finish = resolve; }); } };
  const f = await fixture(t, { motion }), s = await f.create(), url = `/api/sessions/${s.id}`;
  const pending = f.request(`${url}/motion`, { token: s.ownerToken, body: motionBatch, headers: motionHeaders });
  await processing;
  await f.request(`${url}/resolve`, { token: s.ownerToken, body: { confirm: true } });
  finish({ captureStartedUtcMs: f.time() });
  assert.equal((await pending).status, 409);
});

test('motion result refuses stale batches and expired access', async t => {
  const motion = { close() {}, async evaluate() { return { captureStartedUtcMs: 0 }; } };
  const f = await fixture(t, { motion }), s = await f.create(), url = `/api/sessions/${s.id}/motion`;
  const send = () => f.request(url, { token: s.ownerToken, body: motionBatch, headers: motionHeaders });
  assert.equal((await send()).status, 400);
  f.jump(8 * 3600000);
  assert.equal((await send()).status, 401);
});
test('guardian sees neither route nor origin before an alert, even with a valid private link', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`;
  await f.request(`${url}/events`, { token: s.ownerToken, body: { events: [{ id: 's', source: 'phone', seq: 1, at: f.time(), type: 'step', heading: 90 }] } });
  const result = await f.request(url, { token: s.guardianToken });
  assert.equal(result.body.trail, null); assert.equal(result.body.origin, undefined); assert.equal(result.body.lastGps, null); assert.deepEqual(result.body.sources, {});
  f.jump(8000);
  const alert = await f.request(url, { token: s.guardianToken });
  assert.equal(alert.body.phase, 'alert'); assert.equal(alert.body.trail.phoneSteps, 1); assert.equal(alert.body.origin, 'Private entrance'); assert.ok(alert.body.alertSeenAt);
});
test('background guardian status is private, scoped and never marks the request as seen', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`;
  const read = token => f.request(`${url}/guardian-status`, { token });
  for (const token of [undefined, s.ownerToken, s.watchToken]) assert.equal((await read(token)).status, 401);
  assert.equal((await f.request(`${url}/guardian-status`, { token: s.guardianToken, body: {} })).status, 405);
  for (const [advance, phase] of [[0, 'armed'], [5000, 'challenge'], [3000, 'alert']]) {
    f.jump(advance);
    const result = await read(s.guardianToken);
    assert.equal(result.status, 200);
    assert.deepEqual(result.body, { id: s.id, role: 'guardian', phase,
      serverNow: f.time(), expiresAt: s.expiresAt, acknowledgedAt: null });
    const stored = f.app.store.get(s.id);
    assert.equal(stored.guardianSeenAt, undefined); assert.equal(stored.alertSeenAt, undefined);
  }
  await f.request(`${url}/acknowledge`, { token: s.guardianToken, body: { confirm: true } });
  assert.equal((await read(s.guardianToken)).body.acknowledgedAt, f.time());
  await f.request(`${url}/resolve`, { token: s.ownerToken, body: { confirm: true } });
  assert.equal((await read(s.guardianToken)).body.phase, 'resolved');
  const other = await f.create();
  await f.request(`/api/sessions/${other.id}/revoke-guardian`, { token: other.ownerToken, body: { confirm: true } });
  assert.equal((await f.request(`/api/sessions/${other.id}/guardian-status`, { token: other.guardianToken })).status, 401);
  await f.request(url, { token: s.ownerToken, method: 'DELETE' });
  assert.equal((await read(s.guardianToken)).status, 404);
  const expiring = await f.create(); f.jump(8 * 3600000);
  assert.equal((await f.request(`/api/sessions/${expiring.id}/guardian-status`, { token: expiring.guardianToken })).status, 401);
});
test('AR evidence is read-only, guardian/owner scoped, alert-only and revoked immediately', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`;
  const read = token => f.request(`${url}/ar`, { token });
  assert.equal((await read(s.guardianToken)).status, 409);
  assert.equal((await read(s.watchToken)).status, 401);
  assert.equal((await read()).status, 401);
  await f.request(`${url}/events`, { token: s.ownerToken, body: { events: [{
    id: 'ar-actual-fix', seq: 1, source: 'phone', type: 'gps', at: f.time(), fixAt: f.time(),
    latitude: 43, longitude: -79, accuracy: 8, provider: 'gps', provenance: 'device-gnss'
  }] } });
  f.jump(8000);
  const result = await read(s.guardianToken);
  assert.equal(result.status, 200); assert.equal(result.body.frame.anchor.id, 'ar-actual-fix');
  assert.equal(result.body.frame.cameraAligned, false); assert.equal(result.body.guidanceAllowed, false);
  const before = f.app.store.get(s.id), activity = f.app.store.activity(s.id);
  assert.equal((await f.request(`${url}/ar`, { token: s.ownerToken, body: {} })).status, 405);
  await read(s.ownerToken);
  assert.deepEqual(f.app.store.get(s.id), before); assert.deepEqual(f.app.store.activity(s.id), activity);
  await f.request(`${url}/revoke-guardian`, { token: s.ownerToken, body: { confirm: true } });
  assert.equal((await read(s.guardianToken)).status, 401);
  await f.request(`${url}/resolve`, { token: s.ownerToken, body: { confirm: true } });
  assert.equal((await read(s.ownerToken)).status, 409);
  await f.request(url, { token: s.ownerToken, method: 'DELETE' });
  assert.equal((await read(s.ownerToken)).status, 404);
});
test('AR is unavailable for expired sessions even when geographic evidence existed', async t => {
  const f = await fixture(t), s = await f.create(); f.jump(8 * 3600000);
  assert.equal((await f.request(`/api/sessions/${s.id}/ar`, { token: s.guardianToken })).status, 401);
});
test('authorization is scoped: guardian cannot cancel, watch cannot read trail or spoof phone readings', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`;
  assert.equal((await f.request(url)).status, 401);
  assert.equal((await f.request(`${url}/resolve`, { token: s.guardianToken, body: { confirm: true } })).status, 401);
  assert.equal((await f.request(url, { token: s.watchToken })).body.trail, null);
  assert.equal((await f.request(`${url}/events`, { token: s.watchToken, body: { events: [{ id: 'x', source: 'phone', seq: 1, at: f.time(), type: 'step', heading: 0 }] } })).status, 403);
});
test('offline device does not prevent escalation and a sensor heartbeat cannot extend the deadline', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`;
  f.jump(6000);
  await f.request(`${url}/events`, { token: s.ownerToken, body: { events: [{ id: 'h', source: 'phone', seq: 1, at: f.time(), type: 'heartbeat' }] } });
  f.jump(2000); assert.equal((await f.request(url, { token: s.ownerToken })).body.phase, 'alert');
});
test('explicit watch response resets a challenge but late response cannot silently erase an alert', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`;
  f.jump(6000);
  assert.equal((await f.request(`${url}/check-in`, { token: s.watchToken, body: { confirm: true } })).body.phase, 'armed');
  f.jump(8000);
  assert.equal((await f.request(`${url}/check-in`, { token: s.watchToken, body: { confirm: true } })).status, 409);
});
test('duplicate event retry is idempotent and conflicting replay rolls back the whole batch', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`;
  const event = { id: 'step1', source: 'phone', seq: 1, at: f.time(), type: 'step', heading: 0 };
  const send = events => f.request(`${url}/events`, { token: s.ownerToken, body: { events } });
  assert.equal((await send([event])).body.accepted, 1); assert.equal((await send([event])).body.accepted, 0);
  assert.equal((await send([{ ...event, id: 'step2', seq: 2 }, { ...event, heading: 90 }])).status, 409);
  assert.equal((await f.request(url, { token: s.ownerToken })).body.trail.phoneSteps, 1);
});
test('acknowledgment and self-reported arrival never resolve the alert', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`; f.jump(8000);
  for (const action of ['acknowledge', 'arrived']) {
    const r = await f.request(`${url}/${action}`, { token: s.guardianToken, body: { confirm: true } }); assert.equal(r.body.phase, 'alert');
  }
  await f.request(`${url}/resolve`, { token: s.ownerToken, body: { confirm: true } });
  assert.equal((await f.request(url, { token: s.guardianToken })).body.trail, null);
  assert.equal((await f.request(`${url}/events`, { token: s.ownerToken, body: { events: [] } })).status, 409);
});
test('deletion revokes every credential and removes readings', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`;
  assert.equal((await f.request(url, { token: s.ownerToken, body: {}, method: 'DELETE' })).status, 200);
  for (const token of [s.ownerToken, s.guardianToken, s.watchToken]) assert.equal((await f.request(url, { token })).status, 404);
  assert.equal(f.app.store.events(s.id).length, 0);
});
test('expiry clears evidence and anonymizes session metadata', async t => {
  const f = await fixture(t), s = await f.create();
  f.jump(8 * 3600000);
  assert.equal((await f.request(`/api/sessions/${s.id}`, { token: s.ownerToken })).status, 401);
  const saved = f.app.store.get(s.id); assert.equal(saved.name, 'Expired session'); assert.equal(saved.origin, 'Expired');
});
test('clock state and access survive a server restart; missed deadline escalates on recovery', async t => {
  const dir = mkdtempSync(path.join(tmpdir(), 'kaze-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const dbPath = path.join(dir, 'state.sqlite'); const f = await fixture(t, { dbPath }); const s = await f.create();
  await new Promise(resolve => f.app.server.close(resolve));
  const second = createApp({ dbPath, now: () => f.time() + 9000 });
  second.server.listen(0, '127.0.0.1'); await once(second.server, 'listening');
  const response = await fetch(`http://127.0.0.1:${second.server.address().port}/api/sessions/${s.id}`, { headers: { Authorization: `Bearer ${s.ownerToken}` } });
  assert.equal((await response.json()).phase, 'alert'); await new Promise(resolve => second.server.close(resolve));
});
test('cross-origin mutation, missing consent and invalid camera timestamps are rejected', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('/api/sessions', { body: { consent: true, simulation: true }, headers: { Origin: 'https://attacker.invalid' } })).status, 403);
  assert.equal((await f.request('/api/sessions', { body: { name: 'x', origin: 'x' } })).status, 400);
  const s = await f.create();
  assert.equal((await f.request(`/api/sessions/${s.id}/events`, { token: s.ownerToken, body: { events: [{ id: 'v', type: 'vision', source: 'camera', seq: 1, at: f.time(), fromAt: f.time() + 1000 }] } })).status, 400);
  const read = await f.request(`/api/sessions/${s.id}`, { token: s.ownerToken }); assert.equal(read.body.ownerHash, undefined); assert.equal(read.body.watchHash, undefined);
});

test('geographic evidence stays private until escalation; watch uploads are source scoped and retry safely',async t=>{
 const f=await fixture(t),s=await f.create(),url=`/api/sessions/${s.id}`;
 const event={id:'watch-location',seq:1,source:'watch',type:'gps',at:f.time(),fixAt:f.time(),latitude:43,longitude:-79,accuracy:12,provider:'fused',provenance:'possibly-phone-derived'};
 const send=()=>f.request(`${url}/events`,{token:s.watchToken,body:{events:[event]}});
 assert.equal((await send()).body.accepted,1);assert.equal((await send()).body.accepted,0);
 assert.equal((await f.request(url,{token:s.guardianToken})).body.geography,null);
 assert.equal((await f.request(url,{token:s.watchToken})).body.geography,null);
 f.jump(8000);const alert=(await f.request(url,{token:s.guardianToken})).body;
 assert.equal(alert.geography.latest.source,'watch');assert.equal(alert.geography.latest.provenance,'possibly-phone-derived');assert.equal(alert.geography.fixes.length,1);
 await f.request(`${url}/resolve`,{token:s.ownerToken,body:{confirm:true}});
 const ended=(await f.request(url,{token:s.guardianToken})).body;assert.equal(ended.geography,null);assert.deepEqual(ended.activity,[]);
});
test('live sharing requires separate consent and guardian revocation immediately invalidates access',async t=>{
 const f=await fixture(t),body={consent:true,simulation:true,name:'Alex',liveSharing:true};
 assert.equal((await f.request('/api/sessions',{body})).status,400);
 const s=(await f.request('/api/sessions',{body:{...body,liveSharingConsent:true}})).body,url=`/api/sessions/${s.id}`;
 assert.equal((await f.request(url,{token:s.guardianToken})).body.shared,true);
 assert.equal((await f.request(`${url}/revoke-guardian`,{token:s.watchToken,body:{confirm:true}})).status,401);
 await f.request(`${url}/revoke-guardian`,{token:s.ownerToken,body:{confirm:true}});
 assert.equal((await f.request(url,{token:s.guardianToken})).status,401);
 assert.equal((await f.request(url,{token:s.ownerToken})).body.liveSharing,false);
});
test('activity records explicit server-accepted responses and server escalation, not sensor activity',async t=>{
 const f=await fixture(t),s=await f.create(),url=`/api/sessions/${s.id}`;
 await f.request(`${url}/check-in`,{token:s.watchToken,body:{confirm:true}});
 const snapshot=(await f.request(url,{token:s.ownerToken})).body;
 assert.deepEqual(snapshot.activity.map(a=>a.action),['started','check-in']);assert.equal(snapshot.lastCheckInAt,f.time());
 f.jump(8000);assert.equal((await f.request(url,{token:s.ownerToken})).body.activity.at(-1).action,'alert');
});
