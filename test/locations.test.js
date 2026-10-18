import test from 'node:test';
import assert from 'node:assert/strict';
import { geographicTrail } from '../src/locations.js';
import { validateEvent } from '../src/domain.js';
const gps=(source,fixAt,patch={})=>({id:`${source}-${fixAt}`,seq:fixAt,at:fixAt,type:'gps',source,fixAt,latitude:43,longitude:-79,accuracy:8,provider:'fused',provenance:source==='watch'?'possibly-phone-derived':'unknown',...patch});
test('geographic observations retain source and fix time without averaging or using motion as location',()=>{
 const phone=gps('phone',10000),watch=gps('watch',10000,{longitude:-79.001});
 const t=geographicTrail([watch,phone,{type:'step',source:'phone',at:11000,heading:0}],12000);
 assert.equal(t.fixes.length,2);assert.deepEqual(t.latest,phone);assert.equal(t.paths.length,2);assert.equal(t.ageMs,2000);
 assert.match(t.warnings.join(' '),/paired phone/);
});
test('late uploads cannot replace newer fixes; stale, inaccurate, mock and time gaps remain visible',()=>{
 const t=geographicTrail([gps('phone',20000),gps('phone',10000,{at:90000}),gps('phone',60000),gps('phone',70000,{accuracy:100}),gps('phone',80000,{mock:true})],120000);
 assert.equal(t.latest.fixAt,60000);assert.equal(t.fixes.length,5);assert.equal(t.paths.length,2);assert.ok(t.gaps.some(g=>g.reason.includes('30 seconds')));assert.match(t.warnings.join(' '),/stale/);assert.match(t.warnings.join(' '),/Mock/);
});
test('impossible jumps and duplicate-time disagreement cannot create continuous paths',()=>{
 const t=geographicTrail([gps('phone',10000),gps('phone',11000,{longitude:-78}),gps('phone',11000,{longitude:-77,id:'second',seq:4})],12000);
 assert.equal(t.paths.length,1);assert.equal(t.paths[0].points.length,1);assert.equal(t.fixes.length,3);assert.equal(t.latest.fixAt,10000);
});

test('a precise fix wins competing providers without averaging coordinates',()=>{
 const network=gps('phone',10500,{accuracy:90,longitude:-78.99,provider:'network'});
 const precise=gps('phone',10100,{accuracy:3,provider:'gps'});
 const t=geographicTrail([network,precise],11000);
 assert.deepEqual(t.latest,precise);assert.deepEqual(t.paths[0].points,[precise]);assert.equal(t.fixes.length,2);
});

test('zero reported accuracy cannot displace a usable location or establish a trail',()=>{
 const unknown=gps('phone',10500,{accuracy:0});
 const precise=gps('phone',10100,{accuracy:3});
 assert.deepEqual(geographicTrail([unknown,precise],11000).latest,precise);
 assert.equal(geographicTrail([unknown],11000).paths.length,0);
});

test('stationary drift is simplified only for map geometry, keeping the live endpoint and raw evidence',()=>{
 const readings=Array.from({length:20},(_,i)=>gps('phone',10000+i*1000,{longitude:-79+(i%3)*.00001}));
 const t=geographicTrail(readings,30000);
 assert.equal(t.fixes.length,20);assert.equal(t.paths[0].points.length,20);
 assert.deepEqual(t.mapPaths[0].points,[readings[0],readings.at(-1)]);
 assert.deepEqual(t.latest,readings.at(-1));
});

test('an isolated jump is excluded and recovery starts a new section instead of joining across it',()=>{
 const a=gps('phone',10000),bad=gps('phone',11000,{longitude:-78}),b=gps('phone',12000,{latitude:43.00003});
 const t=geographicTrail([a,bad,b],13000);
 assert.deepEqual(t.paths.map(p=>p.points),[[a],[b]]);
 assert.deepEqual(t.latest,b);assert.equal(t.fixes.length,3);
 assert.match(t.gaps[0].reason,/disagreement/);
});
test('location boundary validates fix clock, source, accuracy, metadata and watch provenance',()=>{
 const s={createdAt:1000};const e=gps('watch',2000);
 assert.equal(validateEvent(e,s,'watch',3000).provenance,'possibly-phone-derived');
 for(const patch of [{fixAt:999999},{latitude:91},{longitude:NaN},{accuracy:-1},{provenance:'independent'},{provenance:'device-gnss'},{source:'camera'}])assert.throws(()=>validateEvent({...e,...patch},s,'owner',3000));
 assert.throws(()=>validateEvent(gps('phone',2000),s,'watch',3000));
 assert.equal(geographicTrail([],3000).latest,null);
});

test('altitude datum is explicit and legacy retry payloads remain unchanged',()=>{
 const s={createdAt:1000}, e=gps('phone',2000,{altitude:100,verticalAccuracy:2});
 assert.equal('altitudeDatum' in validateEvent(e,s,'owner',3000),false);
 assert.equal(validateEvent({...e,altitudeDatum:'WGS84-ellipsoid'},s,'owner',3000).altitudeDatum,'WGS84-ellipsoid');
 assert.throws(()=>validateEvent({...e,altitudeDatum:'MSL'},s,'owner',3000));
 assert.throws(()=>validateEvent({...e,altitude:undefined,altitudeDatum:'WGS84-ellipsoid'},s,'owner',3000));
});
