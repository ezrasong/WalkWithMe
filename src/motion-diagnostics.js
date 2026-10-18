// Owner-only technical summaries. Construct an allowlist rather than copying
// model responses or event bodies into diagnostics: neither raw sensors nor
// geographic coordinates, names, tokens or images belong in these records.
const metric = (value, max = 1e9) => Number.isFinite(value) && value >= 0 && value <= max ? value : null;
export function motionDiagnostic(result, { at, bytes, processingMs, error, state, activity } = {}) {
  const record = { at, uploadBytes: bytes, processingMs: Math.round(processingMs), outcome: error ? 'rejected' : 'processed' };
  if (error) return { ...record, code: ['sampling-rate', 'insufficient-coverage', 'resource-limit', 'stream-clock', 'invalid-sensor-data'].includes(error.motionCode)
    ? error.motionCode : error.status === 429 ? 'processor-busy' : error.status === 503 ? 'processor-unavailable' : error.status === 409 ? 'stream-replay-or-order' : error.status === 400 ? 'invalid-timing' : 'processing-failed', httpStatus: error.status ?? 500 };
  const points = (result.segments ?? []).flat().filter(p => Number.isFinite(p.vx) && Number.isFinite(p.vy));
  const speeds = points.map(p => Math.hypot(p.vx, p.vy));
  return { ...record, model: 'RoNIN ResNet', researchOnly: true, fieldAccuracyVerified: false,
    stream: result.stream ? { sequence: metric(result.stream.sequence, 100000), clockUncertaintyMs: metric(result.stream.clockUncertaintyMs, 5000) } : null,
    quality: Object.fromEntries(['accel', 'gyro', 'rotation'].map(name => {
      const q = result.quality?.[name] ?? {};
      return [name, { samples: metric(q.samples, 20000), medianHz: metric(q.medianHz, 10000), maximumGapMs: metric(q.maximumGapMs, 12000), gapsOver25ms: metric(q.gapsOver25ms, 20000) }];
    })),
    inference: { device: result.performance?.device === 'cpu' ? 'cpu' : 'unknown',
      seconds: metric(result.performance?.inferenceSeconds, 60), windows: metric(result.performance?.windows, 300) },
    prediction: { supportedWindows: points.length, sections: result.segments?.length ?? 0,
      stationaryWindows: points.filter(p => p.stationary).length,
      maximumSpeedMetersPerSecond: speeds.length ? metric(Math.max(...speeds), 5) : null,
      meanSpeedMetersPerSecond: speeds.length ? metric(speeds.reduce((a,b)=>a+b,0)/speeds.length, 5) : null,
      batchDistanceMeters: metric(result.estimatedDistanceMeters, 100), includesOverlap: !!result.stream },
    continuity: state ? { retainedSections: state.segments.length, retainedPoints: state.segments.reduce((n,s)=>n+s.points.length,0),
      latestBreakReason: state.segments.at(-1)?.breakReason, driftBudgetMeters: metric(state.driftBudgetMeters), omittedPoints: state.omittedPoints } : null,
    watchActivity: activity ? { status: activity.status, phoneSteps: activity.phoneSteps, watchSteps: activity.watchSteps,
      positionCorrectionApplied: false } : null };
}
