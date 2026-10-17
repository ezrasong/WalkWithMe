// Report observations, never average correlated phone/watch fixes or extrapolate gaps.
export function meters(a, b) {
  const rad = Math.PI / 180, dlat = (b.latitude - a.latitude) * rad, dlon = (b.longitude - a.longitude) * rad;
  const h = Math.sin(dlat / 2) ** 2 + Math.cos(a.latitude * rad) * Math.cos(b.latitude * rad) * Math.sin(dlon / 2) ** 2;
  return 6371000 * 2 * Math.asin(Math.sqrt(Math.min(1, h)));
}
export function geographicTrail(events, now) {
  const fixes = events.filter(e => e.type === 'gps').map(e => ({ ...e, fixAt: e.fixAt ?? e.at,
    provider: e.provider ?? 'legacy', provenance: e.provenance ?? 'unknown' }))
    .sort((a, b) => a.fixAt - b.fixAt || a.at - b.at || (a.source === 'phone' ? 1 : -1));
  const paths = [], gaps = [];
  for (const source of ['phone', 'watch']) {
    let previous = null, path = null;
    for (const fix of fixes.filter(f => f.source === source)) {
      const dt = previous ? fix.fixAt - previous.fixAt : 0;
      const distance = previous ? meters(previous, fix) : 0;
      const reason = fix.mock ? 'Mock location' : fix.accuracy > 50 ? 'Low location accuracy' : previous?.mock || previous?.accuracy > 50 ? 'Uncertain preceding fix' :
        previous && dt > 30000 ? 'Location gap over 30 seconds' : previous && (dt <= 0 || distance > 15 * dt / 1000 + previous.accuracy + fix.accuracy) ? 'Time overlap or location disagreement' : null;
      if (!path || reason) {
        path = { source, points: [] }; paths.push(path);
        if (previous) gaps.push({ source, fromAt: previous.fixAt, toAt: fix.fixAt, reason });
      }
      path.points.push(fix); previous = fix;
    }
  }
  const latest = fixes.at(-1) ?? null;
  return { fixes, paths, gaps, latest, ageMs: latest ? Math.max(0, now - latest.fixAt) : null,
    warnings: [...(!latest ? ['No geographic location received. Check-ins and deadlines still work.'] : []),
      ...(latest && now - latest.fixAt > 30000 ? ['Last location is stale. The person may have moved.'] : []),
      ...(fixes.some(f => f.source === 'watch') ? ['Watch location may come from the paired phone. Sources are shown separately.'] : []),
      ...(gaps.length ? ['Broken trail sections have missing or uncertain location. No route is inferred across them.'] : []),
      ...(fixes.some(f => f.mock) ? ['Mock locations are test evidence, not physical measurements.'] : [])] };
}
