import test from 'node:test';
import assert from 'node:assert/strict';
import { guardianArTrail, localHorizontal } from '../src/ar.js';

const gps = (source, fixAt, patch = {}) => ({ id: `${source}-${fixAt}`, source, fixAt, at: fixAt,
  type: 'gps', latitude: 0, longitude: 0, accuracy: 8, provider: 'gps', provenance: 'device-gnss', ...patch });

test('AR frame uses meters east/up/south, including antimeridian and high latitude', () => {
  const origin = { latitude: 0, longitude: 0 };
  const east = localHorizontal(origin, { latitude: 0, longitude: .001 });
  const north = localHorizontal(origin, { latitude: .001, longitude: 0 });
  assert.ok(Math.abs(east.x - 111.31949) < .01); assert.ok(Math.abs(east.z) < .01);
  assert.ok(Math.abs(north.z + 110.57428) < .01); assert.ok(Math.abs(north.x) < .01);
  const crossing = localHorizontal({ latitude: 0, longitude: 179.9999 }, { latitude: 0, longitude: -179.9999 });
  assert.ok(crossing.x > 22 && crossing.x < 23);
  const polar = localHorizontal({ latitude: 89.9, longitude: 0 }, { latitude: 89.9, longitude: .001 });
  assert.ok(polar.x > 0 && polar.x < .3); assert.ok(Number.isFinite(polar.z));
});

test('AR keeps source paths and uncertainty, never merges phone/watch or infers height from pressure', () => {
  const a = guardianArTrail([gps('phone', 1000), gps('watch', 2000, { longitude: .00001, provider: 'fused', provenance: 'possibly-phone-derived' }),
    { type: 'pressure', source: 'watch', at: 2000, pressure: 900 }, { type: 'step', source: 'phone', at: 2000 }], 3000);
  assert.equal(a.available, true); assert.equal(a.frame.cameraAligned, false); assert.equal(a.guidanceAllowed, false);
  assert.deepEqual(a.paths.map(p => p.source), ['phone', 'watch']);
  assert.equal(a.paths[1].points[0].provenance, 'possibly-phone-derived');
  for (const p of a.paths.flatMap(p => p.points)) { assert.equal(p.y, null); assert.equal(p.verticalUncertainty, null); assert.equal(p.relativeHorizontalUncertainty, 16); }
  assert.equal(a.fallback, 'alignment-required');
});

test('AR excludes mock/uncertain observations and preserves time gaps without bridging', () => {
  const a = guardianArTrail([gps('phone', 1000), gps('phone', 2000, { accuracy: 30 }),
    gps('phone', 3000), gps('phone', 4000, { mock: true }), gps('phone', 5000), gps('phone', 50000)], 51000);
  assert.equal(a.omitted, 2); assert.equal(a.paths.length, 4);
  assert.deepEqual(a.paths.map(p => p.points.map(p => p.fixAt)), [[1000], [3000], [5000], [50000]]);
  assert.equal(guardianArTrail([gps('watch', 1000, { mock: true })], 2000).available, false);
  assert.equal(guardianArTrail([], 2000).frame, null);
  assert.equal(guardianArTrail([], 2000).guidanceAllowed, false);
  assert.equal(guardianArTrail([], 2000).fallback, 'map');
});

test('height remains unknown across sources or missing accuracy; stale and distant fixes require map fallback', () => {
  const a = guardianArTrail([gps('phone', 1000, { altitude: 100, verticalAccuracy: 3 }),
    gps('phone', 2000, { altitude: 105, verticalAccuracy: 4 }), gps('phone', 3000, { altitude: 120 }),
    gps('watch', 4000, { altitude: 200, verticalAccuracy: 2 })], 5000);
  assert.equal(a.paths[0].points[1].y, 5); assert.equal(a.paths[0].points[1].verticalUncertainty, 7);
  assert.equal(a.paths[0].points[2].y, null); assert.equal(a.paths[1].points[0].y, null);
  assert.equal(guardianArTrail([gps('phone', 1000)], 32000).fallback, 'map');
  const distant = guardianArTrail([gps('phone', 1000), gps('phone', 200000, { longitude: 1 })], 201000);
  assert.equal(distant.fallback, 'map'); assert.equal(distant.omitted, 1);
});

test('late earlier observations change the explicit anchor ID so clients must re-register', () => {
  const a = guardianArTrail([gps('phone', 2000)], 3000);
  const b = guardianArTrail([gps('phone', 2000), gps('phone', 1000)], 3000);
  assert.notEqual(a.frame.anchor.id, b.frame.anchor.id);
  assert.equal(b.frame.registrationRequired, true);
});

test('AR reports a compatible altitude datum only when both observed heights declare it', () => {
  const a = guardianArTrail([gps('phone', 1000, { altitude: 100, verticalAccuracy: 1, altitudeDatum: 'WGS84-ellipsoid' }),
    gps('phone', 2000, { altitude: 101, verticalAccuracy: 1, altitudeDatum: 'WGS84-ellipsoid' }),
    gps('phone', 3000, { altitude: 102, verticalAccuracy: 1 })], 4000);
  assert.equal(a.frame.anchor.altitudeDatum, 'WGS84-ellipsoid');
  assert.equal(a.paths[0].points[1].altitudeDatum, 'WGS84-ellipsoid');
  assert.equal(a.paths[0].points[2].altitudeDatum, null);
  assert.equal(a.guidanceAllowed, false);
});
