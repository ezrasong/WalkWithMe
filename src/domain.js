import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';

export class Problem extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
export const token = () => randomBytes(32).toString('base64url');
export const hash = value => createHash('sha256').update(value).digest('hex');
export function matches(value, digest) {
  return typeof value === 'string' && value.length <= 256 && typeof digest === 'string' &&
    timingSafeEqual(Buffer.from(hash(value)), Buffer.from(digest));
}
export function number(value, min, max, field) {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) throw new Problem(400, `Invalid ${field}`);
  return value;
}
export function label(value, max, field) {
  if (typeof value !== 'string' || !value.trim() || value.length > max) throw new Problem(400, `Invalid ${field}`);
  return value.trim();
}
export function advance(s, now) {
  if (now >= s.expiresAt) return { ...s, phase: 'expired' };
  if (s.phase === 'armed' && now >= s.dueAt) s = { ...s, phase: 'challenge' };
  if (s.phase === 'challenge' && now >= s.dueAt + s.graceSeconds * 1000)
    s = { ...s, phase: 'alert', escalatedAt: s.dueAt + s.graceSeconds * 1000 };
  return s;
}
export function validateEvent(input, session, role, now) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new Problem(400, 'Invalid event');
  const e = { id: label(input.id, 80, 'event id'), source: input.source,
    seq: number(input.seq, 0, Number.MAX_SAFE_INTEGER, 'sequence'),
    at: number(input.at, session.createdAt - 5000, now + 5000, 'event time (sync device clock first)'), type: input.type };
  if (!Number.isInteger(e.seq)) throw new Problem(400, 'Sequence must be an integer');
  if (!['phone', 'watch', 'camera'].includes(e.source) || (role === 'watch' && e.source !== 'watch')) throw new Problem(403, 'Invalid device source');
  switch (e.type) {
    case 'heartbeat':
      e.battery = input.battery == null ? null : number(input.battery, 0, 100, 'battery');
      e.sensors = Array.isArray(input.sensors) ? input.sensors.slice(0, 12).map(s => label(s, 60, 'sensor')) : [];
      break;
    case 'step':
      if (e.source === 'camera') throw new Problem(400, 'Camera cannot report steps');
      e.heading = number(input.heading, 0, 360, 'heading');
      if (input.length != null) e.length = number(input.length, 0.2, 1.5, 'stride');
      break;
    case 'pressure':
      if (e.source === 'camera') throw new Problem(400, 'Camera cannot report pressure');
      e.hpa = number(input.hpa, 300, 1100, 'pressure');
      break;
    case 'vision':
      if (e.source !== 'camera') throw new Problem(400, 'Vision requires camera source');
      e.scanId = label(input.scanId, 80, 'scan id');
      e.fromAt = number(input.fromAt, session.createdAt - 5000, e.at, 'camera interval');
      e.dx = number(input.dx, -10, 10, 'camera east'); e.dy = number(input.dy, -10, 10, 'camera north');
      e.dz = number(input.dz, -10, 10, 'camera height');
      e.quality = number(input.quality, 0, 1, 'tracking quality');
      e.errorMeters = number(input.errorMeters, 0.01, 20, 'camera error budget');
      e.tracking = input.tracking === true;
      break;
    case 'checkpoint':
      if (e.source !== 'camera' && e.source !== 'phone') throw new Problem(400, 'Invalid checkpoint source');
      e.label = label(input.label, 100, 'checkpoint label');
      // An annotated image is supporting evidence, never a verified position fix.
      if (input.imageData != null) {
        if (input.shareImage !== true || typeof input.imageData !== 'string' || !/^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(input.imageData)) throw new Problem(400, 'JPEG sharing requires explicit consent');
        const data = Buffer.from(input.imageData.split(',')[1], 'base64');
        if (data.length > 200000 || data.length < 4 || data[0] !== 255 || data[1] !== 216 || data.at(-2) !== 255 || data.at(-1) !== 217) throw new Problem(400, 'Invalid or oversized JPEG');
        e.imageData = input.imageData;
      }
      break;
    case 'gps':
      if (!['phone', 'watch'].includes(e.source)) throw new Problem(400, 'Location requires phone or watch source');
      e.latitude = number(input.latitude, -90, 90, 'latitude'); e.longitude = number(input.longitude, -180, 180, 'longitude');
      e.accuracy = number(input.accuracy, 0, 100000, 'GPS accuracy');
      // Preserve the canonical shape of legacy GPS uploads so pending retries stay idempotent.
      if (input.fixAt != null) e.fixAt = number(input.fixAt, session.createdAt - 5000, e.at + 1000, 'location fix time');
      if (input.provider != null) e.provider = label(input.provider, 40, 'location provider');
      if (input.provenance != null) e.provenance = input.provenance;
      if (e.provenance != null && !['device-gnss', 'possibly-phone-derived', 'unknown'].includes(e.provenance)) throw new Problem(400, 'Invalid location provenance');
      if (e.source === 'watch' && e.provenance === 'device-gnss' && e.provider !== 'gps') throw new Problem(400, 'Watch fused fixes cannot claim independent GNSS');
      if (input.mock != null) {
        if (typeof input.mock !== 'boolean') throw new Problem(400, 'Invalid mock flag');
        e.mock = input.mock;
      }
      if (input.altitude != null) e.altitude = number(input.altitude, -1500, 30000, 'altitude');
      if (input.altitudeDatum != null) {
        if (input.altitudeDatum !== 'WGS84-ellipsoid' || e.altitude == null) throw new Problem(400, 'Invalid altitude datum');
        e.altitudeDatum = input.altitudeDatum;
      }
      if (input.verticalAccuracy != null) e.verticalAccuracy = number(input.verticalAccuracy, 0, 100000, 'vertical accuracy');
      break;
    default: throw new Problem(400, 'Unknown event type');
  }
  return e;
}
