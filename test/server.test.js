import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createApp } from '../src/server.js';

async function fixture(t, opts = {}) {
  let clock = 1792216000000;
  const app = createApp({ now: () => clock, ...opts }); app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  const request = async (route, { token, body, method = body ? 'POST' : 'GET', headers = {} } = {}) => {
    const response = await fetch(base + route, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}), ...headers }, body: body ? JSON.stringify(body) : undefined });
    return { status: response.status, body: await response.json() };
  };
  const create = async () => (await request('/api/sessions', { body: { consent: true, simulation: true, name: 'Alex', origin: 'Private entrance', intervalSeconds: 5, graceSeconds: 3 } })).body;
  t.after(async () => { if (app.server.listening) await new Promise(resolve => app.server.close(resolve)); });
  return { app, base, request, create, time: () => clock, jump: ms => { clock += ms; app.tick(); } };
}
test('guardian sees neither route nor origin before an alert, even with a valid private link', async t => {
  const f = await fixture(t), s = await f.create(), url = `/api/sessions/${s.id}`;
  await f.request(`${url}/events`, { token: s.ownerToken, body: { events: [{ id: 's', source: 'phone', seq: 1, at: f.time(), type: 'step', heading: 90 }] } });
  const result = await f.request(url, { token: s.guardianToken });
  assert.equal(result.body.trail, null); assert.equal(result.body.origin, undefined); assert.equal(result.body.lastGps, null); assert.deepEqual(result.body.sources, {});
  f.jump(8000);
  const alert = await f.request(url, { token: s.guardianToken });
  assert.equal(alert.body.phase, 'alert'); assert.equal(alert.body.trail.phoneSteps, 1); assert.equal(alert.body.origin, 'Private entrance'); assert.ok(alert.body.alertSeenAt);
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
