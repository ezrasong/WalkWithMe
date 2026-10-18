import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createApp } from '../src/server.js';
import { localHorizontal } from '../src/ar.js';

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

const demoRoute = [{latitude:43,longitude:-79},{latitude:43.001,longitude:-79},{latitude:43.001,longitude:-78.999}];
async function sharedDemo(f) {
 return (await f.request('/api/sessions',{body:{consent:true,simulation:true,sensorMode:'simulated',name:'Virtual wearer',
   liveSharing:true,liveSharingConsent:true,intervalSeconds:3600}})).body;
}
test('shared demo drives identical guardian map and AR evidence while retaining simulated provenance',async t=>{
 const f=await fixture(t),s=await sharedDemo(f),root=`/api/sessions/${s.id}`;
 const started=await f.request(`${root}/demo-walk`,{token:s.ownerToken,body:{command:'start',consent:true,route:demoRoute}});
 assert.equal(started.status,200);assert.equal(started.body.demoWalk.distance,0);assert.equal(started.body.phase,'armed');
 f.jump(10000);
 const owner=(await f.request(root,{token:s.ownerToken})).body;
 const guardian=(await f.request(root,{token:s.guardianToken})).body;
 assert.equal(guardian.demoWalk.distance,12);assert.deepEqual(guardian.geography,owner.geography);
 assert.equal(guardian.geography.latest.mock,true);assert.equal(guardian.geography.latest.simulated,true);
 assert.equal(guardian.geography.latest.provider,'kaze-demo');assert.ok(guardian.geography.paths[0].points.length>5);
 const ar=await f.request(`${root}/ar`,{token:s.guardianToken});
 assert.equal(ar.status,200);assert.equal(ar.body.available,true);assert.equal(ar.body.simulated,true);
 const expected=localHorizontal(ar.body.frame.anchor,guardian.geography.latest),actual=ar.body.paths.at(-1).points.at(-1);
 assert.equal(actual.x,expected.x);assert.equal(actual.z,expected.z);assert.equal(actual.fixAt,guardian.geography.latest.fixAt);
 assert.equal(ar.body.latestId,actual.id);
 assert.equal(f.app.store.events(s.id).length,0);
});
test('shared demo pause, speed, resume and restart are server-clock based and never move the safety deadline',async t=>{
 const f=await fixture(t),s=await sharedDemo(f),root=`/api/sessions/${s.id}`;
 const control=body=>f.request(`${root}/demo-walk`,{token:s.ownerToken,body});
 await control({command:'start',consent:true,route:demoRoute});f.jump(5000);
 const paused=(await control({command:'pause'})).body;assert.equal(paused.demoWalk.distance,6);
 f.jump(60000);const still=(await f.request(root,{token:s.guardianToken})).body;
 assert.equal(still.demoWalk.distance,6);assert.equal(still.geography.ageMs,0);
 await control({command:'speed',speed:4});await control({command:'resume'});f.jump(10000);
 const moved=(await f.request(root,{token:s.ownerToken})).body;assert.equal(moved.demoWalk.distance,54);assert.equal(moved.dueAt,s.dueAt);
 const before=(await f.request(`${root}/ar`,{token:s.ownerToken})).body.frame.anchor.id;
 const restarted=(await control({command:'restart'})).body;assert.equal(restarted.demoWalk.distance,0);
 const after=(await f.request(`${root}/ar`,{token:s.ownerToken})).body.frame.anchor.id;assert.notEqual(before,after);
 f.jump(360000);const done=(await f.request(root,{token:s.ownerToken})).body;
 assert.equal(done.demoWalk.running,false);assert.equal(done.demoWalk.distance,done.demoWalk.total);
 assert.deepEqual([done.geography.latest.latitude,done.geography.latest.longitude],[demoRoute.at(-1).latitude,demoRoute.at(-1).longitude]);
 assert.ok(done.geography.mapPaths.flatMap(p=>p.points).some(p=>p.latitude===demoRoute[1].latitude && p.longitude===demoRoute[1].longitude), 'accelerated demo keeps the exact street corner');
});
test('demo controls cannot inject a route into live sessions, cross roles, or bypass consent and lifecycle',async t=>{
 const f=await fixture(t),live=await f.create(),s=await sharedDemo(f),root=`/api/sessions/${s.id}`;
 const start={command:'start',consent:true,route:demoRoute};
 assert.equal((await f.request(`/api/sessions/${live.id}/demo-walk`,{token:live.ownerToken,body:start})).status,409);
 for(const token of [s.guardianToken,s.watchToken,undefined]) assert.equal((await f.request(`${root}/demo-walk`,{token,body:start})).status,401);
 for(const body of [{...start,consent:false},{...start,route:[]},{...start,route:[demoRoute[0],demoRoute[0]]},{...start,route:[demoRoute[0],{latitude:80,longitude:0}]}])
   assert.equal((await f.request(`${root}/demo-walk`,{token:s.ownerToken,body})).status,400);
 await f.request(`${root}/demo-walk`,{token:s.ownerToken,body:start});
 await f.request(`${root}/resolve`,{token:s.ownerToken,body:{confirm:true}});
 assert.equal((await f.request(`${root}/demo-walk`,{token:s.ownerToken,body:{command:'resume'}})).status,409);
 assert.equal((await f.request(`${root}/ar`,{token:s.guardianToken})).status,409);
});

test('guardian QR/code invitations require owner access and preserve guardian scope and sharing consent', async t => {
  const f = await fixture(t), s = await f.create(), route = `/api/sessions/${s.id}/guardian-invite`;
  for (const token of [undefined, s.guardianToken, s.watchToken]) {
    assert.equal((await f.request(route, { token, body: { guardianToken: s.guardianToken } })).status, 401);
  }
  assert.equal((await f.request(route, { token: s.ownerToken })).status, 405);
  assert.equal((await f.request(route, { token: s.ownerToken, body: { guardianToken: s.ownerToken } })).status, 400);
  const before = f.app.store.get(s.id), activity = f.app.store.activity(s.id);
  const invitation = await f.request(route, { token: s.ownerToken, body: { guardianToken: s.guardianToken } });
  assert.equal(invitation.status, 201);
  assert.match(invitation.body.code, /^[2-9A-HJ-NP-Z]{5}-[2-9A-HJ-NP-Z]{5}$/);
  assert.equal(invitation.body.expiresAt, f.time() + 300000);
  assert.deepEqual(Object.keys(invitation.body).sort(), ['code', 'expiresAt', 'serverNow']);
  const redeem = await f.request('/api/guardian-invites/redeem', { body: { code: invitation.body.code.toLowerCase().replace('-', ' ') } });
  assert.equal(redeem.status, 200);
  assert.deepEqual(redeem.body, { id: s.id, guardianToken: s.guardianToken });
  assert.deepEqual(f.app.store.get(s.id), before);
  assert.deepEqual(f.app.store.activity(s.id), activity);
  const guardian = await f.request(`/api/sessions/${s.id}`, { token: redeem.body.guardianToken });
  assert.equal(guardian.body.role, 'guardian');
  assert.equal(guardian.body.shared, false);
  assert.equal(guardian.body.trail, null);
  assert.equal((await f.request('/api/guardian-invites/redeem', { body: { code: invitation.body.code } })).status, 404);
});

test('regeneration replaces the old code and simultaneous redemption succeeds only once', async t => {
  const f = await fixture(t), s = await f.create();
  const issue = () => f.request(`/api/sessions/${s.id}/guardian-invite`, { token: s.ownerToken, body: { guardianToken: s.guardianToken } });
  const first = await issue(), second = await issue();
  const redeem = code => f.request('/api/guardian-invites/redeem', { body: { code } });
  assert.equal((await redeem(first.body.code)).status, 404);
  assert.deepEqual((await Promise.all([redeem(second.body.code), redeem(second.body.code)])).map(r => r.status).sort(), [200, 404]);
});

test('pairing codes expire and session revocation, resolution or deletion invalidates them', async t => {
  for (const action of ['expire-code', 'expire-session', 'revoke-guardian', 'resolve', 'delete']) {
    const f = await fixture(t), s = await f.create(), route = `/api/sessions/${s.id}`;
    const invitation = await f.request(`${route}/guardian-invite`, { token: s.ownerToken, body: { guardianToken: s.guardianToken } });
    if (action === 'expire-code') f.jump(300000);
    else if (action === 'expire-session') f.jump(8 * 3600000);
    else if (action === 'delete') await f.request(route, { token: s.ownerToken, method: 'DELETE' });
    else await f.request(`${route}/${action}`, { token: s.ownerToken, body: { confirm: true } });
    assert.equal((await f.request('/api/guardian-invites/redeem', { body: { code: invitation.body.code } })).status, 404, action);
    if (['revoke-guardian', 'resolve'].includes(action)) {
      assert.equal((await f.request(`${route}/guardian-invite`, { token: s.ownerToken, body: { guardianToken: s.guardianToken } })).status, 409);
    }
  }
});

test('pairing guesses are validated and rate limited without exposing credentials', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('/api/guardian-invites/redeem')).status, 405);
  for (const code of [null, 123, {}, 'A'.repeat(33), '00000-00000', 'AAAAA-BBBBB', 'https://example.test', '', 'QQQQQ-QQQQQ', 'ZZZZZ-ZZZZZ']) {
    const result = await f.request('/api/guardian-invites/redeem', { body: { code } });
    assert.equal(result.status, 404);
    assert.deepEqual(Object.keys(result.body), ['error']);
  }
  assert.equal((await f.request('/api/guardian-invites/redeem', { body: { code: 'AAAAA-BBBBB' } })).status, 429);
  f.jump(60000);
  assert.equal((await f.request('/api/guardian-invites/redeem', { body: { code: 'AAAAA-BBBBB' } })).status, 404);
});

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

test('derived motion requires separate retention consent, obeys sharing gates and deletes on withdrawal/expiry', async t => {
  const f = await fixture(t, { motion: { close() {}, async evaluate() { return result; } } });
  const s=await f.create(), url=`/api/sessions/${s.id}`;
  let result={captureStartedUtcMs:f.time(),stream:{id:'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',sequence:0,startedNs:1000000000,startedUtcMs:f.time(),clockUncertaintyMs:20},
    segments:[Array.from({length:41},(_,i)=>({t:1+i*.05,vx:1,vy:0,stationary:false}))]};
  const send=()=>f.request(`${url}/motion`,{token:s.ownerToken,body:motionBatch,headers:motionHeaders});
  assert.equal((await send()).body.retained,false);assert.equal(f.app.store.motion(s.id),null);
  for(const token of [s.watchToken,s.guardianToken])assert.equal((await f.request(`${url}/motion-consent`,{token,body:{enabled:true,confirm:true}})).status,401);
  assert.equal((await f.request(`${url}/motion-consent`,{token:s.ownerToken,body:{enabled:true}})).status,400);
  await f.request(`${url}/motion-consent`,{token:s.ownerToken,body:{enabled:true,confirm:true}});
  f.jump(8000);assert.equal((await send()).body.retained,true);assert.ok(f.app.store.motion(s.id));
  assert.equal((await f.request(url,{token:s.watchToken})).body.relativeMotion,null);
  const guardian=(await f.request(url,{token:s.guardianToken})).body;
  assert.equal(guardian.relativeMotion.available,true);assert.equal(guardian.relativeMotion.guidanceAllowed,false);
  const ar=(await f.request(`${url}/ar`,{token:s.guardianToken})).body;
  assert.equal(ar.available,false);assert.deepEqual(ar.relativeMotion,guardian.relativeMotion);
  await f.request(`${url}/motion-consent`,{token:s.ownerToken,body:{enabled:false,confirm:true}});
  assert.equal(f.app.store.motion(s.id),null);
  await f.request(`${url}/motion-consent`,{token:s.ownerToken,body:{enabled:true,confirm:true}});
  f.jump(8000);result.stream.sequence++;await send();
  await f.request(`${url}/revoke-guardian`,{token:s.ownerToken,body:{confirm:true}});
  assert.equal((await f.request(url,{token:s.guardianToken})).status,401);
  f.jump(8*3600000);assert.equal(f.app.store.motion(s.id),null);
});

test('motion sharing withdrawal while inference yields cannot restore retained evidence',async t=>{
 let finish,started;const ready=new Promise(resolve=>started=resolve);
 const f=await fixture(t,{motion:{close(){},evaluate(){started();return new Promise(resolve=>finish=resolve);}}});
 const s=await f.create(), url=`/api/sessions/${s.id}`;
 const consent=enabled=>f.request(`${url}/motion-consent`,{token:s.ownerToken,body:{enabled,confirm:true}});
 await consent(true);
 const pending=f.request(`${url}/motion`,{token:s.ownerToken,body:motionBatch,headers:motionHeaders});await ready;
 assert.equal((await f.request(url,{token:s.guardianToken})).body.relativeMotion,null);
 await consent(false);await consent(true);
 finish({captureStartedUtcMs:f.time(),stream:{}});
 assert.equal((await pending).body.retained,false);assert.equal(f.app.store.motion(s.id),null);
});

test('confirmed simulated filming take repeats countdown, stops at alert time and preserves guardian pairing',async t=>{
 const f=await fixture(t),s=await sharedDemo(f),root=`/api/sessions/${s.id}`;
 const control=body=>f.request(`${root}/demo-walk`,{token:s.ownerToken,body});
 await control({command:'start',consent:true,route:demoRoute});await control({command:'speed',speed:4});
 assert.equal((await control({command:'begin-take'})).status,400);
 for(const token of [s.guardianToken,s.watchToken])assert.equal((await f.request(`${root}/demo-walk`,{token,body:{command:'begin-take',confirm:true}})).status,401);
 const before=await f.request(root,{token:s.ownerToken});
 const take=(await control({command:'begin-take',confirm:true})).body;
 assert.equal(take.dueAt,f.time()+30000);assert.equal(take.graceSeconds,10);assert.equal(take.demoWalk.speed,1);assert.equal(take.demoWalk.distance,0);
 assert.equal(take.expiresAt,before.body.expiresAt);
 f.jump(30000);let g=(await f.request(root,{token:s.guardianToken})).body;
 assert.equal(g.phase,'challenge');assert.equal(g.demoWalk.distance,36);
 f.jump(10000);g=(await f.request(root,{token:s.guardianToken})).body;
 assert.equal(g.phase,'alert');assert.equal(g.demoWalk.distance,48);assert.equal(g.demoWalk.running,false);
 await f.request(`${root}/acknowledge`,{token:s.guardianToken,body:{confirm:true}});
 await f.request(`${root}/arrived`,{token:s.guardianToken,body:{confirm:true}});
 f.jump(60000);assert.equal((await f.request(root,{token:s.guardianToken})).body.demoWalk.distance,48);
 const ar=(await f.request(`${root}/ar`,{token:s.guardianToken})).body;assert.equal(ar.available,true);assert.equal(ar.simulated,true);
 const again=(await control({command:'begin-take',confirm:true})).body;
 assert.equal(again.phase,'armed');assert.equal(again.demoWalk.distance,0);assert.notEqual(again.demoWalk.runId,take.demoWalk.runId);
 for(const key of ['acknowledgedAt','arrivalReportedAt','escalatedAt','alertSeenAt'])assert.equal(again[key],undefined);
 assert.equal((await f.request(root,{token:s.guardianToken})).status,200);
 assert.equal(f.app.store.activity(s.id).filter(a=>a.action==='demo-take').length,2);
});

test('filming controls never reset real alerts or extend expiry, and delayed ticks stop the walk at forty seconds',async t=>{
 const f=await fixture(t),real=await f.create(),s=await sharedDemo(f),root=`/api/sessions/${s.id}`;
 f.jump(8000);const saved=f.app.store.get(real.id);
 assert.equal((await f.request(`/api/sessions/${real.id}/demo-walk`,{token:real.ownerToken,body:{command:'begin-take',confirm:true}})).status,409);
 assert.deepEqual(f.app.store.get(real.id),saved);
 await f.request(`${root}/demo-walk`,{token:s.ownerToken,body:{command:'start',consent:true,route:demoRoute}});
 await f.request(`${root}/demo-walk`,{token:s.ownerToken,body:{command:'begin-take',confirm:true}});
 f.jump(120000);let g=(await f.request(root,{token:s.guardianToken})).body;
 assert.equal(g.phase,'alert');assert.equal(g.demoWalk.distance,48);assert.equal(g.demoWalk.running,false);
 const updated=f.app.store.get(s.id);f.app.store.save({...updated,expiresAt:f.time()+40000});
 assert.equal((await f.request(`${root}/demo-walk`,{token:s.ownerToken,body:{command:'begin-take',confirm:true}})).status,409);
 assert.equal(f.app.store.get(s.id).expiresAt,f.time()+40000);
});

test('motion diagnostics are consented, owner-only, sanitized, bounded and erased on withdrawal or expiry',async t=>{
 let fail=false;
 const f=await fixture(t,{motion:{close(){},async evaluate(){
  if(fail)throw Object.assign(new Error('private raw details must not be logged'),{status:422,motionCode:'sampling-rate'});
  return {captureStartedUtcMs:f.time(),estimatedDistanceMeters:1.2,
   quality:{accel:{samples:2000,medianHz:199.9,maximumGapMs:6,gapsOver25ms:0,raw:'secret'}},
   performance:{device:'cpu',inferenceSeconds:.05,windows:20},segments:[[{vx:0,vy:0,stationary:true}]],
   token:'secret',latitude:43,name:'Private wearer',rawSamples:[9,8,7]};
 }}});
 const s=await f.create(),root=`/api/sessions/${s.id}`,url=root+'/motion-diagnostics';
 const send=()=>f.request(root+'/motion',{token:s.ownerToken,body:motionBatch,headers:motionHeaders});
 const consent=enabled=>f.request(url,{token:s.ownerToken,body:{enabled,confirm:true}});
 assert.equal((await send()).body.diagnosticsRecorded,false);assert.deepEqual(f.app.store.motionDiagnostics(s.id),[]);
 for(const token of [s.guardianToken,s.watchToken,undefined]) {
  assert.equal((await f.request(url,{token})).status,401);
  assert.equal((await f.request(url,{token,body:{enabled:true,confirm:true}})).status,401);
 }
 assert.equal((await f.request(url,{token:s.ownerToken,body:{enabled:true}})).status,400);
 await consent(true);f.jump(8000);assert.equal((await send()).body.diagnosticsRecorded,true);
 let records=(await f.request(url,{token:s.ownerToken})).body.records;
 assert.equal(records.length,1);assert.equal(records[0].quality.accel.medianHz,199.9);assert.equal(records[0].prediction.stationaryWindows,1);
 assert.equal(records[0].inference.device,'cpu');
 for(const word of ['secret','latitude','Private wearer','rawSamples'])assert.ok(!JSON.stringify(records).includes(word));
 assert.equal((await f.request(root,{token:s.guardianToken})).body.records,undefined);
 fail=true;f.jump(8000);assert.equal((await send()).status,422);
 records=(await f.request(url,{token:s.ownerToken})).body.records;assert.equal(records.at(-1).code,'sampling-rate');
 assert.ok(!JSON.stringify(records).includes('private raw details'));
 for(let i=0;i<130;i++)f.app.store.appendMotionDiagnostic(s.id,{at:i,outcome:'test'});
 assert.equal(f.app.store.motionDiagnostics(s.id).length,120);
 await consent(false);assert.deepEqual(f.app.store.motionDiagnostics(s.id),[]);
 await consent(true);f.app.store.appendMotionDiagnostic(s.id,{at:f.time()});
 f.jump(8*3600000);assert.equal((await f.request(url,{token:s.ownerToken})).status,401);assert.deepEqual(f.app.store.motionDiagnostics(s.id),[]);
});

test('diagnostic withdrawal or session deletion during model work cannot recreate logs',async t=>{
 let finish,started;let ready=new Promise(resolve=>started=resolve);
 const f=await fixture(t,{motion:{close(){},evaluate(){started();return new Promise(resolve=>finish=resolve);}}});
 const s=await f.create(),root=`/api/sessions/${s.id}`;
 const consent=enabled=>f.request(root+'/motion-diagnostics',{token:s.ownerToken,body:{enabled,confirm:true}});
 await consent(true);
 let pending=f.request(root+'/motion',{token:s.ownerToken,body:motionBatch,headers:motionHeaders});await ready;
 await consent(false);await consent(true);finish({captureStartedUtcMs:f.time(),segments:[]});
 assert.equal((await pending).body.diagnosticsRecorded,false);assert.deepEqual(f.app.store.motionDiagnostics(s.id),[]);
 f.jump(8000);ready=new Promise(resolve=>started=resolve);
 pending=f.request(root+'/motion',{token:s.ownerToken,body:motionBatch,headers:motionHeaders});await ready;
 await f.request(root,{token:s.ownerToken,method:'DELETE'});finish({captureStartedUtcMs:f.time(),segments:[]});
 assert.equal((await pending).status,404);assert.deepEqual(f.app.store.motionDiagnostics(s.id),[]);
});
