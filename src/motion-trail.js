import { randomUUID } from 'node:crypto';
import { Problem, number } from './domain.js';

// Integrate velocities once in the capture's monotonic frame. Batch-local x/y
// are deliberately ignored: each evaluator segment has its own zero origin.
export function appendMotion(previous, result, now) {
  const stream = result.stream;
  if (!stream) return previous; // Legacy evaluations cannot be stitched.
  if (!/^[a-f0-9-]{36}$/.test(stream.id) || !Number.isSafeInteger(stream.sequence) || stream.sequence < 0 ||
      !Number.isSafeInteger(stream.startedNs) || stream.startedNs < 0 ||
      !Number.isSafeInteger(stream.startedUtcMs)) throw new Problem(422, 'Invalid motion stream');
  number(stream.clockUncertaintyMs, 0, 5000, 'motion clock uncertainty');
  if (!Array.isArray(result.segments) || !result.segments.length || result.segments.length > 30 ||
      result.segments.reduce((n, s) => n + (Array.isArray(s) ? s.length : 1000), 0) > 260)
    throw new Problem(422, 'Invalid motion windows');
  const state = structuredClone(previous ?? { segments: [], retired: [], omittedPoints: 0 });
  const same = state.stream?.id === stream.id;
  if (same && (stream.sequence <= state.stream.sequence || stream.startedNs !== state.stream.startedNs ||
      stream.startedUtcMs !== state.stream.startedUtcMs || stream.clockUncertaintyMs !== state.stream.clockUncertaintyMs))
    throw new Problem(409, 'Motion stream replay or clock change');
  if (!same && (state.retired.includes(stream.id) || state.last && stream.startedUtcMs <= state.last.at))
    throw new Problem(409, 'Older motion stream cannot replace current evidence');
  if (!same) {
    if (state.stream) state.retired.push(state.stream.id);
    state.retired = state.retired.slice(-32);
    state.last = null;
  }
  const minTime = state.last?.t ?? -1;
  let seen = -1, changed = false;
  for (const windows of result.segments) {
    if (!Array.isArray(windows) || windows.length < 2) throw new Problem(422, 'Invalid motion segment');
    let first = true;
    for (const p of windows) {
      number(p.t, 0, 86412, 'monotonic motion time');
      number(p.vx, -5, 5, 'motion velocity'); number(p.vy, -5, 5, 'motion velocity');
      if (p.t <= seen || Math.hypot(p.vx, p.vy) > 5 || typeof p.stationary !== 'boolean' ||
          p.stationary && (p.vx !== 0 || p.vy !== 0)) throw new Problem(422, 'Invalid motion order or velocity');
      seen = p.t;
      const at = stream.startedUtcMs + p.t * 1000;
      number(at, now - 60000, now + 5000, 'motion observation time');
      if (p.t <= minTime + 1e-6) continue; // Overlap supplies context, never another displacement.
      const last = state.last, dt = last ? p.t - last.t : Infinity;
      const continuous = last && dt > 0 && dt <= .051 && (!first || same);
      let segment = state.segments.at(-1);
      if (!continuous) {
        segment = { id: randomUUID(), streamId: stream.id, originKnown: false,
          breakReason: !last ? 'stream-start' : 'missing-motion', points: [] };
        state.segments.push(segment);
      }
      const d = continuous ? Math.hypot((last.vx + p.vx) * dt / 2, (last.vy + p.vy) * dt / 2) : 0;
      const x = continuous ? last.x + (last.vx + p.vx) * dt / 2 : 0;
      const y = continuous ? last.y + (last.vy + p.vy) * dt / 2 : 0;
      const driftBudgetMeters = (state.last?.driftBudgetMeters ?? state.driftBudgetMeters ?? 1) + (continuous ? dt * .03 + d * .25 : 1);
      const point = { t: p.t, at, x, y, stationary: p.stationary, driftBudgetMeters, uncertaintyMeters: null };
      // Integrate at 20 Hz, retain about 5 Hz plus every section's first point.
      if (!segment.points.length || p.t - segment.points.at(-1).t >= .199) segment.points.push(point);
      state.last = { ...point, vx: p.vx, vy: p.vy };
      state.driftBudgetMeters = driftBudgetMeters;
      first = false; changed = true;
    }
  }
  if (!changed) throw new Problem(409, 'Motion batch contains no new supported windows');
  // Preserve the current endpoint even when it falls between retained samples.
  const tail = state.segments.at(-1).points;
  if (tail.at(-1).t !== state.last.t) { const { vx, vy, ...point } = state.last; tail.push(point); }
  state.stream = { ...stream };
  let count = state.segments.reduce((n, s) => n + s.points.length, 0);
  while (state.segments.length > 128 || count > 4096) {
    const first = state.segments[0];
    if (first.points.length <= count - 4096 || state.segments.length > 128) {
      count -= first.points.length; state.omittedPoints += first.points.length; state.segments.shift();
    } else {
      const trim = count - 4096; first.points.splice(0, trim); first.historyTruncated = true;
      state.omittedPoints += trim; count -= trim;
    }
  }
  return state;
}

export function relativeMotion(state, events, now) {
  const base = { version: 1, available: !!state?.segments.length, researchOnly: true,
    guidanceAllowed: false, geographic: false, fieldAccuracyVerified: false, confidenceCalibrated: false,
    frame: { kind: 'phone-game-rotation', units: 'meters', yawKnown: false, originKnown: false,
      room: null, floor: null, height: null, cameraAligned: false },
    warnings: ['Research preview; pocket walking accuracy has not been measured.',
      'Starting position, north, room and floor are unknown. Sections across gaps have separate origins.',
      'Drift budget grows with time and distance; it is not a calibrated error bound.',
      'Watch steps check activity only. Wrist heading, duplicated steps and paired-phone location are not independent position fixes.'] };
  if (!state) return { ...base, reason: 'No consented continuous phone motion yet.', segments: [] };
  const lastAt = state.last.at;
  const nativeSteps = events.filter(e => e.type === 'step' && e.headingBasis === 'device-posture' &&
    e.stepMethod === 'android-step-detector' && e.clockUncertaintyMs <= 1000);
  let conflictBudget = 0;
  const segments = state.segments.map(s => {
    const groups = new Map();
    for (const p of s.points) {
      const bucket = Math.floor((p.t - 1e-6) / 10);
      if (!groups.has(bucket)) groups.set(bucket, []);
      groups.get(bucket).push(p);
    }
    const activityWindows = [];
    const points = [];
    for (const group of groups.values()) {
      const from = group[0].at, to = group.at(-1).at;
      const timing = state.stream.id === s.streamId ? state.stream.clockUncertaintyMs + (to - state.stream.startedUtcMs) * .0001 : 5000;
      const steps = nativeSteps.filter(e => e.at > from + timing + e.clockUncertaintyMs && e.at <= to - timing - e.clockUncertaintyMs);
      const phone = steps.filter(e => e.source === 'phone').length, watch = steps.filter(e => e.source === 'watch').length;
      const covered = timing <= 1000 && to - from >= 4000;
      const disagreement = covered && phone >= 5 && watch >= 5 && Math.abs(phone-watch) / Math.max(phone,watch) > .35;
      const stationaryConflict = covered && watch >= 5 && group.every(p => p.stationary);
      const supported = !stationaryConflict && !disagreement;
      const activity = { from, to, phoneSteps: phone, watchSteps: watch,
        status: !covered ? 'timing-unavailable' : stationaryConflict ? 'stationary-conflict' : disagreement ? 'disagreement' :
          watch >= 5 && phone >= 5 ? 'consistent-activity' : 'insufficient-watch-evidence',
        positionCorrectionApplied: false, supported };
      if (!supported) conflictBudget += Math.max(1, Math.abs(phone-watch) * .36);
      activityWindows.push(activity);
      points.push(...group.map(p => ({ ...p, supported })));
    }
    return { ...s, points, activity: activityWindows.at(-1), activityWindows,
      supported: points.some(p => p.supported), excludedIntervals: activityWindows.filter(w => !w.supported).length };
  });
  return { ...base, segments, latestAt: lastAt, stale: now - lastAt > 30000,
    driftBudgetMeters: state.driftBudgetMeters + conflictBudget, omittedPoints: state.omittedPoints,
    clockUncertaintyMs: state.stream.clockUncertaintyMs + (lastAt - state.stream.startedUtcMs) * .0001 };
}
