import { geographicTrail, meters } from './locations.js';

// A geographic frame for a guardian's AR session, not a camera registration.
// WGS84 surface coordinates are projected into a local tangent plane. Height
// stays separate: an ellipsoid's curvature is never interpreted as a stair.
function surface(latitude, longitude) {
  const lat = latitude * Math.PI / 180, lon = longitude * Math.PI / 180;
  const n = 6378137 / Math.sqrt(1 - 6.6943799901413165e-3 * Math.sin(lat) ** 2);
  return [n * Math.cos(lat) * Math.cos(lon), n * Math.cos(lat) * Math.sin(lon),
    n * (1 - 6.6943799901413165e-3) * Math.sin(lat)];
}

export function localHorizontal(anchor, point) {
  const a = surface(anchor.latitude, anchor.longitude), p = surface(point.latitude, point.longitude);
  const [dx, dy, dz] = p.map((v, i) => v - a[i]);
  const lat = anchor.latitude * Math.PI / 180, lon = anchor.longitude * Math.PI / 180;
  return { x: -Math.sin(lon) * dx + Math.cos(lon) * dy,
    z: Math.sin(lat) * Math.cos(lon) * dx + Math.sin(lat) * Math.sin(lon) * dy - Math.cos(lat) * dz };
}

const horizontalUsable = f => !f.mock && Number.isFinite(f.latitude) && Number.isFinite(f.longitude)
  && Number.isFinite(f.accuracy) && f.accuracy > 0 && f.accuracy <= 25;
const verticalUsable = f => Number.isFinite(f.altitude) && Number.isFinite(f.verticalAccuracy)
  && f.verticalAccuracy > 0 && f.verticalAccuracy <= 10;

export function guardianArTrail(events, now) {
  const geography = geographicTrail(events, now);
  // The anchor ID identifies the frame. Earlier fixes arriving late can change
  // it, in which case the guardian must discard its old camera registration.
  const anchorFix = geography.fixes.find(horizontalUsable);
  const warnings = [...geography.warnings,
    'Camera registration is required. Geographic coordinates alone do not align an AR camera.',
    'This is an experimental recorded trail, not a navigable route through walls or stairs.'];
  if (!anchorFix) return { version: 1, available: false, generatedAt: now,
    reason: 'No sufficiently accurate non-mock geographic anchor.', frame: null, paths: [],
    guidanceAllowed: false, fallback: 'map', latestFixAt: geography.latest?.fixAt ?? null, warnings };
  const anchor = { id: anchorFix.id, latitude: anchorFix.latitude, longitude: anchorFix.longitude,
    fixAt: anchorFix.fixAt, source: anchorFix.source, accuracy: anchorFix.accuracy,
    altitude: verticalUsable(anchorFix) ? anchorFix.altitude : null,
    verticalAccuracy: verticalUsable(anchorFix) ? anchorFix.verticalAccuracy : null };
  const paths = [];
  let omitted = 0, included = 0;
  for (const path of geography.paths) {
    let segment = null;
    for (const fix of path.points) {
      // A local frame has a bounded extent; excluded observations break lines.
      if (!horizontalUsable(fix) || meters(anchor, fix) > 2000) { segment = null; omitted++; continue; }
      if (!segment) { segment = { source: path.source, points: [] }; paths.push(segment); }
      const heightKnown = fix.source === anchor.source && verticalUsable(fix) && anchor.altitude !== null;
      segment.points.push({ id: fix.id, fixAt: fix.fixAt, ...localHorizontal(anchor, fix),
        y: heightKnown ? fix.altitude - anchor.altitude : null,
        horizontalAccuracy: fix.accuracy, relativeHorizontalUncertainty: fix.accuracy + anchor.accuracy,
        verticalUncertainty: heightKnown ? fix.verticalAccuracy + anchor.verticalAccuracy : null,
        provider: fix.provider, provenance: fix.provenance });
      included++;
    }
  }
  const latest = geography.latest;
  const current = !!latest && horizontalUsable(latest) && now - latest.fixAt <= 30000 && now >= latest.fixAt
    && meters(anchor, latest) <= 2000;
  if (omitted) warnings.push('Uncertain or distant observations were omitted; no line crosses those gaps.');
  return { version: 1, available: included > 0, generatedAt: now,
    frame: { kind: 'WGS84-local-tangent', units: 'meters', axes: { x: 'east', y: 'up', z: 'south' },
      anchor, registrationRequired: true, cameraAligned: false },
    paths, omitted, latestFixAt: latest?.fixAt ?? null,
    guidanceAllowed: false, fallback: current ? 'alignment-required' : 'map',
    warnings };
}
