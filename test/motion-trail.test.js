import test from 'node:test';
import assert from 'node:assert/strict';
import { appendMotion, relativeMotion } from '../src/motion-trail.js';
import { reconstruct } from '../src/trail.js';
const origin = 1792216000000, id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const batch = (sequence, from, to, extra = {}) => ({ stream: { id, sequence, startedNs: 1000000000, startedUtcMs: origin, clockUncertaintyMs: 20, ...extra },
  segments: [Array.from({length:Math.round((to-from)*20)+1},(_,i)=>({t:from+i*.05,vx:1,vy:0,stationary:false,x:999,y:999}))] });
const append = (state, b) => appendMotion(state,b,origin+b.segments.at(-1).at(-1).t*1000);

test('overlap integrates velocities once, discarding independent batch origins',()=>{
 let s=append(null,batch(0,1,10));s=append(s,batch(1,9.75,20));
 assert.equal(s.segments.length,1);assert.ok(Math.abs(s.last.x-19)<1e-8);assert.equal(s.last.y,0);
 assert.ok(s.last.driftBudgetMeters>s.segments[0].points[0].driftBudgetMeters);
 const m=relativeMotion(s,[],origin+21000);assert.equal(m.frame.originKnown,false);assert.equal(m.frame.cameraAligned,false);
 assert.equal(m.guidanceAllowed,false);assert.equal(m.frame.room,null);assert.equal(m.frame.floor,null);
});
test('missing samples, sequence replay, altered clocks and capture restarts cannot create connecting motion',()=>{
 let s=append(null,batch(0,1,10));
 assert.throws(()=>append(s,batch(0,9.75,20)),{status:409});
 assert.throws(()=>append(s,batch(1,9.75,20,{startedNs:2000000000})),{status:409});
 s=append(s,batch(2,21,30));assert.equal(s.segments.length,2);assert.equal(s.segments[1].points[0].x,0);
 const next=batch(0,1,10,{id:'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee',startedUtcMs:origin+31000});
 s=appendMotion(s,next,origin+42000);assert.equal(s.segments.length,3);assert.equal(s.segments[2].points[0].x,0);
 assert.throws(()=>appendMotion(s,batch(3,31,40),origin+42000),{status:409});
});
test('quality gates reject nonfinite, fast, reversed and stale velocities without mutating history',()=>{
 const s=append(null,batch(0,1,10)), saved=structuredClone(s);
 for(const p of [{vx:NaN},{vx:6},{t:1},{stationary:true}]) {
  const b=batch(1,9.75,20);Object.assign(b.segments[0][10],p);assert.throws(()=>append(s,b));assert.deepEqual(s,saved);
 }
 assert.throws(()=>appendMotion(s,batch(1,9.75,20),origin+100000));
});
test('watch activity is time-scoped, posture is never heading and duplicate movement never adds distance',()=>{
 const s=append(null,batch(0,1,10));
 const steps=source=>Array.from({length:8},(_,i)=>({type:'step',source,at:origin+1500+i*900,heading:180,headingBasis:'device-posture',stepMethod:'android-step-detector',clockUncertaintyMs:20}));
 const m=relativeMotion(s,[...steps('phone'),...steps('watch')],origin+10000);
 assert.equal(m.segments[0].activity.status,'consistent-activity');assert.equal(s.last.x,9);
 assert.equal(reconstruct(steps('phone'),{sensorMode:'device'}).distance,0);
 const stale=steps('watch').map(p=>({...p,at:p.at-100000}));
 assert.equal(relativeMotion(s,stale,origin+10000).segments[0].activity.watchSteps,0);
 const ambiguous=steps('watch').map(p=>({...p,clockUncertaintyMs:5000}));
 assert.equal(relativeMotion(s,ambiguous,origin+10000).segments[0].activity.watchSteps,0);
 const b=batch(0,1,10);b.segments[0].forEach(p=>Object.assign(p,{vx:0,stationary:true}));
 const still=append(null,b);assert.equal(relativeMotion(still,steps('watch'),origin+10000).segments[0].supported,false);
});
test('retained history is bounded while the current endpoint and accumulated drift survive',()=>{
 let s=null;
 for(let i=0;i<100;i++)s=append(s,batch(i,Math.max(1,i*10-.25),(i+1)*10));
 assert.ok(s.segments.reduce((n,s)=>n+s.points.length,0)<=4096);assert.ok(s.omittedPoints>0);
 assert.ok(Math.abs(s.last.x-999)<1e-7);assert.ok(s.segments[0].historyTruncated);
 assert.equal(relativeMotion(s,[],origin+1040000).stale,true);
});

test('derived continuation survives SQLite reopening and is deleted with its session',async t=>{
 const {Store}=await import('../src/store.js');const {mkdtempSync,rmSync}=await import('node:fs');
 const {tmpdir}=await import('node:os');const path=await import('node:path');
 const dir=mkdtempSync(path.join(tmpdir(),'kaze-motion-'));t.after(()=>{store.close();rmSync(dir,{recursive:true,force:true});});
 const file=path.join(dir,'state.sqlite');let store=new Store(file);store.save({id});
 store.saveMotion(id,append(null,batch(0,1,10)));store.close();
 store=new Store(file);
 const state=append(store.motion(id),batch(1,9.75,20));store.saveMotion(id,state);
 assert.equal(state.segments.length,1);assert.ok(Math.abs(state.last.x-19)<1e-8);
 store.remove(id);assert.equal(store.motion(id),null);
});
