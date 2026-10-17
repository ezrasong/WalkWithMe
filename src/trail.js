// Coordinates are local metres east/north of an explicitly chosen starting point.
// Uncertainty is a conservative engineering budget, NOT a calibrated probability.
export function reconstruct(events, { strideMeters = 0.72, useCamera = true } = {}) {
  const sorted = [...events].sort((a, b) => a.at - b.at || a.seq - b.seq);
  const candidates = useCamera ? sorted.filter(e => e.type === 'vision' && e.tracking && e.quality >= 0.6 &&
    e.at > e.fromAt && e.at - e.fromAt <= 1500 &&
    Math.hypot(e.dx, e.dy, e.dz) / ((e.at - e.fromAt) / 1000) <= 3) : [];
  // Overlapping visual intervals may be relocalization/replay artifacts. Count motion once.
  const camera = [];
  for (const e of candidates) if (!camera.length || e.fromAt >= camera.at(-1).at) camera.push(e);
  const acceptedCamera = new Set(camera);
  let cameraCursor = 0;
  let x = 0, y = 0, uncertainty = 2, distance = 0, lastHeading = null;
  const points = [{ x, y, at: sorted[0]?.at ?? 0, uncertainty, source: 'origin' }];
  const turns = [], checkpoints = [], pressure = { phone: [], watch: [] };
  let cameraDistance = 0, phoneSteps = 0, watchSteps = 0;
  for (const e of sorted) {
    if (e.type === 'pressure') pressure[e.source].push(e);
    if (e.type === 'checkpoint') checkpoints.push({ ...e, x, y, uncertainty });
    if (e.type === 'step' && e.source === 'watch') { watchSteps++; continue; }
    if (e.type === 'step' && e.source === 'phone') {
      phoneSteps++;
      // Camera and PDR measure the same motion. Never add both for one interval.
      while (cameraCursor < camera.length && camera[cameraCursor].at < e.at) cameraCursor++;
      const v = camera[cameraCursor];
      if (v && e.at > v.fromAt && e.at <= v.at) continue;
      const length = e.length ?? strideMeters, heading = e.heading * Math.PI / 180;
      x += Math.sin(heading) * length; y += Math.cos(heading) * length;
      uncertainty += length * 0.22;
      distance += length;
      if (lastHeading !== null) {
        const turn = ((e.heading - lastHeading + 540) % 360) - 180;
        if (Math.abs(turn) >= 45) turns.push({ at: e.at, direction: turn > 0 ? 'right' : 'left', degrees: Math.round(Math.abs(turn)), x, y });
      }
      lastHeading = e.heading;
      points.push({ x, y, at: e.at, uncertainty, source: 'phone' });
    }
    if (acceptedCamera.has(e)) {
      x += e.dx; y += e.dy;
      const d = Math.hypot(e.dx, e.dy);
      distance += d; cameraDistance += d;
      // Relative visual odometry cannot erase drift inherited before the scan.
      uncertainty += Math.max(0.02, d * 0.1, e.errorMeters);
      points.push({ x, y, at: e.at, uncertainty, source: 'camera' });
    }
  }
  const elevations = Object.entries(pressure).flatMap(([source, samples]) => {
    if (samples.length < 2) return [];
    const first = samples.slice(0, 5).map(s => s.hpa).sort((a, b) => a - b);
    const base = first[Math.floor(first.length / 2)];
    const latest = samples.slice(-5).map(s => s.hpa).sort((a, b) => a - b);
    const current = latest[Math.floor(latest.length / 2)];
    return [{ source, relativeMeters: 44330 * (1 - Math.pow(current / base, 0.1903)), at: samples.at(-1).at }];
  });
  const stepDisagreement = watchSteps >= 5 && phoneSteps >= 5 && Math.abs(watchSteps - phoneSteps) / Math.max(watchSteps, phoneSteps) > 0.35;
  if (stepDisagreement) uncertainty += Math.abs(watchSteps - phoneSteps) * strideMeters * 0.5;
  const warnings = ['Approximate path, not a floor plan. Origin and orientation must match the chosen entrance.'];
  if (stepDisagreement) warnings.push('Phone/watch step counts disagree. Their positions were not averaged.');
  if (!phoneSteps && !camera.length) warnings.push('No horizontal movement evidence. Watch steps alone do not locate the wearer.');
  if (camera.length) warnings.push('Camera segments are relative visual estimates, not verified locations or independent GPS fixes.');
  if (elevations.length) warnings.push('Pressure suggests relative height only; weather and ventilation can also change pressure.');
  return { points, turns, checkpoints, elevations, distance, uncertainty, phoneSteps, watchSteps, cameraDistance,
    acceptedCameraSamples: camera.length, rejectedCameraSamples: sorted.filter(e => e.type === 'vision').length - camera.length,
    warnings, latestAt: sorted.at(-1)?.at ?? null };
}
