import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { gzipSync } from 'node:zlib';
import { MotionEvaluator } from '../src/motion.js';

const cache = path.join(homedir(), '.cache/kaze-motion');
const python = path.join(cache, 'venv', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python');
test('backend loads actual weights once, refuses concurrent work and survives malformed sensor batches', {
  skip: !existsSync(python) || !existsSync(path.join(cache, 'ronin_resnet.zip')), timeout: 30000,
}, async t => {
  const evaluator = new MotionEvaluator(python); t.after(() => evaluator.close());
  const origin = 1000000000;
  const metadata = { version:1, source:'phone', clock:'elapsedRealtimeNanos', startedNs:origin, startedUtcMs:Date.now(),
    frame:'Android-game-rotation-z-up-yaw-unknown', accelSensor:1, gyroSensor:4, rotationSensor:15,
    accelerationUnits:'m/s^2-including-gravity', angularRateUnits:'rad/s' };
  const rows = [];
  for (let i = 0; i <= 500; i++) {
    const ns = origin + i * 5000000;
    rows.push(`${ns},accel,0,0,9.81,,,,`, `${ns},gyro,0,0,0,,,,`, `${ns},rotation,0,0,0,1,,,`);
  }
  const capture = `# ${JSON.stringify(metadata)}\nt_ns,sensor,x,y,z,w,bx,by,bz\n${rows.join('\n')}\n# ${JSON.stringify({ complete:true, reason:'user-stopped', samples:rows.length })}\n`;
  const payload = gzipSync(capture).toString('base64');
  const pending = evaluator.evaluate(payload);
  await assert.rejects(evaluator.evaluate(payload), { status:429 });
  const result = await pending, pid = evaluator.child.pid;
  assert.equal(result.geographic, false); assert.equal(result.guidanceAllowed, false);
  assert.equal(result.independentBatchOrigin, true); assert.ok(result.segments.length);
  await assert.rejects(evaluator.evaluate(gzipSync('# []\n').toString('base64')), { status:422 });
  assert.equal((await evaluator.evaluate(payload)).performance.device, 'cpu');
  assert.equal(evaluator.child.pid, pid);
});

// This uses the actual cached checkpoint behind HTTP. Synthetic stationary
// observations establish integration and privacy, never field accuracy.
test('actual stream estimates pass through HTTP to the authorized shared preview without geographic promotion', {
 skip: !existsSync(python)||!existsSync(path.join(cache,'ronin_resnet.zip')),timeout:30000,
},async t=>{
 const {createApp}=await import('../src/server.js');const {once}=await import('node:events');
 let clock=Date.now();const utc=clock,app=createApp({now:()=>clock});
 app.server.listen(0,'127.0.0.1');await once(app.server,'listening');
 t.after(()=>new Promise(resolve=>app.server.close(resolve)));
 const base=`http://127.0.0.1:${app.server.address().port}`;
 const request=async(route,token,body,headers={})=>{
  const res=await fetch(base+route,{method:body?'POST':'GET',headers:{...(token?{Authorization:`Bearer ${token}`} : {}),'Content-Type':'application/json',...headers},body:body?Buffer.isBuffer(body)?body:JSON.stringify(body):undefined});
  return {status:res.status,body:await res.json()};
 };
 const created=await request('/api/sessions',null,{consent:true,simulation:true,name:'Motion integration',motionSharingConsent:true,motionDiagnosticsConsent:true,intervalSeconds:5,graceSeconds:3});
 const s=created.body,url=`/api/sessions/${s.id}`;
 function payload(from,to,seq){
  const ns=1000000000;
  const meta={version:1,source:'phone',clock:'elapsedRealtimeNanos',startedNs:ns+from*1e9,startedUtcMs:utc+from*1000,
   streamVersion:2,streamId:'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',batchSequence:seq,streamStartedNs:ns,streamStartedUtcMs:utc,clockUncertaintyMs:20,
   frame:'Android-game-rotation-z-up-yaw-unknown',accelSensor:1,gyroSensor:4,rotationSensor:15,accelerationUnits:'m/s^2-including-gravity',angularRateUnits:'rad/s'};
  const rows=[];for(let i=Math.round(from*200);i<=to*200;i++){
   const stamp=ns+i*5000000;rows.push(`${stamp},accel,0,0,9.80665,,,,`,`${stamp},gyro,0,0,0,,,,`,`${stamp},rotation,0,0,0,1,,,`);
  }
  return gzipSync(`# ${JSON.stringify(meta)}\nt_ns,sensor,x,y,z,w,bx,by,bz\n${rows.join('\n')}\n# ${JSON.stringify({complete:true,reason:'user-stopped',samples:rows.length})}\n`);
 }
 const headers={'Content-Type':'application/gzip','X-Kaze-Motion-Consent':'1'};
 const first=await request(`${url}/motion`,s.ownerToken,payload(0,2.5,0),headers);
 assert.equal(first.status,200);assert.equal(first.body.retained,true);assert.equal(first.body.diagnosticsRecorded,true);
 assert.equal((await request(url,s.guardianToken)).body.relativeMotion,null);
 clock+=8000;
 assert.equal((await request(`${url}/motion`,s.ownerToken,payload(1.2,4,1),headers)).status,200);
 const g=(await request(url,s.guardianToken)).body;
 assert.equal(g.relativeMotion.available,true);assert.equal(g.relativeMotion.segments.length,1);
 assert.equal(g.relativeMotion.segments[0].points.at(-1).x,0);assert.equal(g.geography.latest,null);
 assert.equal(g.relativeMotion.guidanceAllowed,false);assert.equal(app.store.events(s.id).length,0);
 const ar=(await request(`${url}/ar`,s.guardianToken)).body;
 assert.equal(ar.available,false);assert.equal(ar.relativeMotion.available,true);
 const log=await request(`${url}/motion-diagnostics`,s.ownerToken);
 assert.equal(log.status,200);assert.equal(log.body.records.length,2);
 assert.equal(log.body.records[0].inference.device,'cpu');assert.ok(log.body.records[0].prediction.stationaryWindows>0);
 assert.ok(log.body.records[0].quality.accel.medianHz>180);
 assert.ok(!JSON.stringify(log.body).includes('ownerToken'));
});
