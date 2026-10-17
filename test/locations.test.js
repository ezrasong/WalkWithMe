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
 assert.equal(t.latest.fixAt,80000);assert.ok(t.paths.length>=4);assert.ok(t.gaps.some(g=>g.reason.includes('30 seconds')));assert.match(t.warnings.join(' '),/stale/);assert.match(t.warnings.join(' '),/Mock/);
});
test('impossible jumps and duplicate-time disagreement cannot create continuous paths',()=>{
 const t=geographicTrail([gps('phone',10000),gps('phone',11000,{longitude:-78}),gps('phone',11000,{longitude:-77,id:'second',seq:4})],12000);
 assert.equal(t.paths.length,3);
});
test('location boundary validates fix clock, source, accuracy, metadata and watch provenance',()=>{
 const s={createdAt:1000};const e=gps('watch',2000);
 assert.equal(validateEvent(e,s,'watch',3000).provenance,'possibly-phone-derived');
 for(const patch of [{fixAt:999999},{latitude:91},{longitude:NaN},{accuracy:-1},{provenance:'independent'},{provenance:'device-gnss'},{source:'camera'}])assert.throws(()=>validateEvent({...e,...patch},s,'owner',3000));
 assert.throws(()=>validateEvent(gps('phone',2000),s,'watch',3000));
 assert.equal(geographicTrail([],3000).latest,null);
});
