import { randomUUID } from 'node:crypto';
import { number, label, Problem } from './domain.js';
import { meters } from './locations.js';

export function demoPoint(walk, distance) {
  let remaining = distance;
  for (let i = 1; i < walk.route.length; i++) {
    const a = walk.route[i - 1], b = walk.route[i], length = meters(a, b);
    if (remaining <= length || i === walk.route.length - 1) {
      const f = Math.min(1, remaining / length);
      return { latitude: a.latitude + (b.latitude - a.latitude) * f,
        longitude: a.longitude + (b.longitude - a.longitude) * f,
        ...(a.street ? { street: a.street } : {}) };
    }
    remaining -= length;
  }
}

export function advanceDemo(walk, now) {
  if (!walk?.running || now <= walk.updatedAt) return walk;
  const until = Math.min(now, walk.stopAt ?? now);
  const distance = Math.min(walk.total, walk.distance + (until - walk.updatedAt) / 1000 * 1.2 * walk.speed);
  // Sample metre crossings and every route corner, so turns never cut across
  // a property. A full run is bounded to 2 km and needs no client timer.
  let length = 0;
  const corners = walk.route.slice(1).map((p, i) => (length += meters(walk.route[i], p)));
  const crossings = [...new Set([
    ...Array.from({ length: Math.max(0, Math.floor(distance) - Math.floor(walk.distance)) }, (_, i) => Math.floor(walk.distance) + i + 1),
    ...corners.filter(d => d > walk.distance && d <= distance),
  ])].sort((a, b) => a - b);
  const samples = [...walk.samples, ...crossings.map(d => ({ distance: d,
    at: walk.updatedAt + (d - walk.distance) / (1.2 * walk.speed) * 1000 }))];
  return { ...walk, samples, distance, updatedAt: now, running: distance < walk.total && (walk.stopAt == null || now < walk.stopAt) };
}

export function controlDemo(session, body, now) {
  if (session.sensorMode !== 'simulated') throw new Problem(409, 'Use a separate simulated session for demo movement');
  let walk = advanceDemo(session.demoWalk, now);
  if (body.command === 'start') {
    if (body.consent !== true || !Array.isArray(body.route) || body.route.length < 2 || body.route.length > 40)
      throw new Problem(400, 'Confirm sharing a demo route of 2-40 points');
    const route = body.route.map(p => ({ latitude: number(p?.latitude, -85, 85, 'demo latitude'),
      longitude: number(p?.longitude, -180, 180, 'demo longitude'),
      ...(p?.street == null ? {} : { street: label(p.street, 60, 'demo street') }) }));
    const lengths = route.slice(1).map((p, i) => meters(route[i], p));
    const total = lengths.reduce((sum, d) => sum + d, 0);
    if (lengths.some(d => d < .5) || total < 10 || total > 2000) throw new Problem(400, 'Demo route must span 10-2000 metres with distinct points');
    walk = { runId: randomUUID(), route, total, distance: 0, speed: 1,
      running: true, stopAt: null, updatedAt: now, samples: [{ distance: 0, at: now }] };
  } else {
    if (!walk) throw new Problem(409, 'Start a demo route first');
    if (body.command === 'pause') walk = { ...walk, running: false };
    else if (body.command === 'resume') walk = { ...walk, running: walk.distance < walk.total, updatedAt: now,
      stopAt: walk.stopAt != null && now >= walk.stopAt ? null : walk.stopAt };
    else if (body.command === 'restart') walk = { ...walk, runId: randomUUID(), distance: 0,
      running: true, stopAt: null, updatedAt: now, samples: [{ distance: 0, at: now }] };
    else if (body.command === 'speed' && [1, 2, 4].includes(body.speed)) walk = { ...walk, speed: body.speed };
    else throw new Problem(400, 'Invalid demo control');
  }
  return walk;
}

export function demoEvents(walk, now) {
  if (!walk) return [];
  const samples = [...walk.samples];
  if (samples.at(-1).at < now) samples.push({ distance: walk.distance, at: now });
  return samples.map((p, i) => ({ id: `demo-${walk.runId}-${i}`, seq: i, type: 'gps', source: 'phone',
    at: p.at, fixAt: p.at, ...demoPoint(walk, p.distance), accuracy: 1,
    provider: 'kaze-demo', provenance: 'unknown', mock: true, simulated: true }));
}

// Only this explicitly confirmed simulated scenario resets a countdown. Normal
// movement controls and real wearer sessions never re-arm an assistance request.
export function beginDemoTake(session, body, now) {
  if (session.sensorMode !== 'simulated' || !session.demoWalk || ['resolved', 'expired'].includes(session.phase))
    throw new Problem(409, 'Start an active shared walking demo first');
  if (body.confirm !== true) throw new Problem(400, 'Confirm restarting the simulated walk and alert countdown');
  if (session.expiresAt <= now + 40000) throw new Problem(409, 'Demo expires too soon; start a new demo session');
  const result = { ...session, phase: 'armed', intervalSeconds: 30, graceSeconds: 10, dueAt: now + 30000,
    demoWalk: { ...controlDemo(session, { command: 'restart' }, now), speed: 1, stopAt: now + 40000 } };
  for (const key of ['escalatedAt', 'acknowledgedAt', 'arrivalReportedAt', 'alertSeenAt', 'lastCheckInAt']) delete result[key];
  return result;
}
