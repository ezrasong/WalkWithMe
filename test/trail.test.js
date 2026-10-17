import test from 'node:test';
import assert from 'node:assert/strict';
import { reconstruct } from '../src/trail.js';
import { advance, validateEvent } from '../src/domain.js';

const step = (at, heading = 0, source = 'phone') => ({ id: `s-${source}-${at}`, type: 'step', source, seq: at, at, heading, length: 1 });
const vision = overrides => ({ id: 'v', type: 'vision', source: 'camera', seq: 1, at: 2000, fromAt: 1000, dx: 1, dy: 0, dz: 0, tracking: true, quality: 0.8, errorMeters: 0.1, scanId: 'scan', ...overrides });
test('reconstructs relative north/east displacement rather than averaging device coordinates', () => {
  const t = reconstruct([step(1000), step(2000, 90)]);
  assert.ok(Math.abs(t.points.at(-1).x - 1) < 1e-9); assert.ok(Math.abs(t.points.at(-1).y - 1) < 1e-9);
  assert.equal(t.turns[0].direction, 'right');
});
test('watch steps never become a duplicate path or independently locate the wearer', () => {
  const t = reconstruct([step(1000), step(1000, 90, 'watch')]);
  assert.equal(t.distance, 1); assert.equal(t.watchSteps, 1);
  assert.equal(reconstruct([step(1000, 90, 'watch')]).distance, 0);
});
test('accepted camera motion substitutes for overlapping phone steps', () => {
  const t = reconstruct([step(1500), step(2500), vision()]);
  assert.equal(t.distance, 2); assert.equal(t.cameraDistance, 1); assert.equal(t.phoneSteps, 2);
});
test('camera disabled leaves a complete independent phone baseline', () => {
  const events = [step(1500), step(2500), vision()];
  assert.equal(reconstruct(events, { useCamera: false }).cameraDistance, 0);
  assert.equal(reconstruct(events, { useCamera: false }).distance, 2);
});
test('overlapping camera intervals cannot double count the same movement', () => {
  const first = vision(), overlap = vision({ id: 'v2', seq: 2, at: 2200, fromAt: 1200 });
  const t = reconstruct([first, overlap]);
  assert.equal(t.cameraDistance, 1); assert.equal(t.acceptedCameraSamples, 1); assert.equal(t.rejectedCameraSamples, 1);
});
test('camera never clears inherited drift even with high quality', () => {
  const before = reconstruct([step(500)]);
  const after = reconstruct([step(500), vision({ quality: 1 })]);
  assert.ok(after.uncertainty > before.uncertainty);
});
test('tracking loss, low features, long gaps and relocalization jumps fall back to phone', () => {
  for (const patch of [{ tracking: false }, { quality: 0.2 }, { fromAt: 0 }, { dx: 9 }]) {
    const t = reconstruct([step(1500), vision(patch)]);
    assert.equal(t.cameraDistance, 0); assert.equal(t.distance, 1); assert.equal(t.rejectedCameraSamples, 1);
  }
});
test('out-of-order uploads reconstruct in event time order', () => {
  const events = [step(1000), step(2000, 90), step(3000, 180)];
  assert.deepEqual(reconstruct(events), reconstruct([...events].reverse()));
});
test('watch disagreement increases uncertainty instead of asserting accuracy', () => {
  const phone = Array.from({ length: 10 }, (_, i) => step(1000 + i));
  const watch = Array.from({ length: 25 }, (_, i) => step(1000 + i, 0, 'watch'));
  assert.ok(reconstruct([...phone, ...watch]).uncertainty > reconstruct(phone).uncertainty);
});
test('pressure provides relative height with no floor claim', () => {
  const events = Array.from({ length: 12 }, (_, i) => ({ type: 'pressure', source: 'watch', at: i, seq: i, hpa: i < 6 ? 1013.25 : 1012.89 }));
  const t = reconstruct(events); assert.ok(t.elevations[0].relativeMeters > 2.5); assert.ok(t.elevations[0].relativeMeters < 3.5); assert.equal(t.elevations[0].floor, undefined);
});
test('checkpoint images and labels cannot reset location or uncertainty', () => {
  const before = reconstruct([step(500)]);
  const after = reconstruct([step(500), { type: 'checkpoint', source: 'camera', at: 1000, seq: 1, label: 'Room 204' }]);
  assert.equal(after.uncertainty, before.uncertainty); assert.equal(after.points.at(-1).x, before.points.at(-1).x);
});
test('server timer escalates after nonresponse, without receiving any sensor events', () => {
  const s = { phase: 'armed', dueAt: 1000, graceSeconds: 3, expiresAt: 10000 };
  assert.equal(advance(s, 1000).phase, 'challenge'); assert.equal(advance(s, 4000).phase, 'alert');
  assert.equal(advance(s, 7000).escalatedAt, 4000);
});
test('invalid numbers, timestamps, spoofed device sources and unconsented images are rejected', () => {
  const s = { createdAt: 1000 };
  for (const e of [step(999999), { ...step(1500), heading: NaN }, { ...vision(), source: 'watch' }, { ...step(1500), type: 'checkpoint', label: 'x', imageData: 'data:image/jpeg;base64,/9j/2Q==' }]) assert.throws(() => validateEvent(e, s, 'owner', 3000));
  assert.throws(() => validateEvent(step(1500), s, 'watch', 3000));
});
