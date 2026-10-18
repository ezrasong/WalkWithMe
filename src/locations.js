// Report observations, never average correlated phone/watch fixes or extrapolate gaps.
export function meters(a, b) {
  const rad = Math.PI / 180, dlat = (b.latitude - a.latitude) * rad, dlon = (b.longitude - a.longitude) * rad;
  const h = Math.sin(dlat / 2) ** 2 + Math.cos(a.latitude * rad) * Math.cos(b.latitude * rad) * Math.sin(dlon / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.sqrt(Math.min(1, h)));
}
export function geographicTrail(events, now) {
  const fixes = events.filter(e => e.type === 'gps').map(e => ({ ...e, fixAt: e.fixAt ?? e.at,
    provider: e.provider ?? 'legacy', provenance: e.provenance ?? 'unknown' }))
    .sort((a, b) => a.fixAt - b.fixAt || a.at - b.at || Number(a.source === 'phone') - Number(b.source === 'phone'));
  const paths = [], gaps = [];
  let rejected = 0;
  const displayed = [];
  for (const source of ['phone', 'watch']) {
    // GPS, network and fused providers can report the same instant. A coarse
    // network fix must not pull a precise GPS trail across the street.
    const buckets = new Map();
    for (const fix of fixes.filter(f => f.source === source)) {
      const key = Math.floor(fix.fixAt / 1000), existing = buckets.get(key);
      if (!existing || (existing.mock && !fix.mock) ||
          (!!existing.mock === !!fix.mock && fix.accuracy > 0 &&
            (existing.accuracy <= 0 || fix.accuracy < existing.accuracy))) buckets.set(key, fix);
    }
    let previous = null, path = null;
    for (const fix of buckets.values()) {
      const dt = previous ? fix.fixAt - previous.fixAt : 0;
      const distance = previous ? meters(previous, fix) : 0;
      const reason = fix.mock ? 'Mock location' : fix.accuracy <= 0 || fix.accuracy > 25 ? 'Low location accuracy' :
        fix.fixAt > now ? 'Future location' : previous && dt <= 30000 &&
        (dt <= 0 || distance > 15 * dt / 1000 + previous.accuracy + fix.accuracy) ? 'Time overlap or location disagreement' : null;
      if (reason) {
        rejected++;
        gaps.push({ source, fromAt: previous?.fixAt ?? fix.fixAt, toAt: fix.fixAt, reason });
        path = null;
        // Rejected fixes never become the baseline for the next jump check.
        continue;
      }
      const gap = previous && dt > 30000;
      if (gap) gaps.push({ source, fromAt: previous.fixAt, toAt: fix.fixAt, reason: 'Location gap over 30 seconds' });
      if (!path || gap) {
        path = { source, points: [] }; paths.push(path);
      }
      path.points.push(fix);
      displayed.push(fix); previous = fix;
    }
  }
  displayed.sort((a, b) => a.fixAt - b.fixAt || Number(a.source === 'phone') - Number(b.source === 'phone'));
  const latest = displayed.at(-1) ?? fixes.at(-1) ?? null;
  const mapPaths = paths.map(path => {
    const points = [];
    for (const fix of path.points) {
      const last = points.at(-1);
      if (!last || meters(last, fix) > Math.max(last.accuracy, fix.accuracy)) points.push(fix);
    }
    // Preserve the live endpoint, even during a stationary interval.
    if (points.at(-1) !== path.points.at(-1)) points.push(path.points.at(-1));
    return { source: path.source, points };
  });
  return { fixes, paths, mapPaths, gaps, rejected, latest, ageMs: latest ? Math.max(0, now - latest.fixAt) : null,
    warnings: [...(!latest ? ['No geographic location received. Check-ins and deadlines still work.'] : []),
      ...(latest && now - latest.fixAt > 30000 ? ['Last location is stale. The person may have moved.'] : []),
      ...(fixes.some(f => f.source === 'watch') ? ['Watch location may come from the paired phone. Sources are shown separately.'] : []),
      ...(gaps.length ? ['Broken trail sections have missing or uncertain location. No route is inferred across them.'] : []),
      ...(fixes.length ? ['Trail vertices use the most accurate fix per second and omit movement within reported precision. Raw readings are retained.'] : []),
      ...(fixes.some(f => f.mock) ? ['Mock locations are test evidence, not physical measurements.'] : [])] };
}
