import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import 'spatial_registration.dart';

class GeographicCameraGuide {
  final List<Map<String, Object>> points;
  final double distance, turn, uncertainty;
  final String? street;
  GeographicCameraGuide(
    this.points,
    this.distance,
    this.turn,
    this.uncertainty, {
    this.street,
  });
  bool get nearby => distance <= uncertainty;
}

// Approximate compass projection, never a shared AR world or measured height.
// One eligibility gate owns both the geometry and the on-camera direction.
GeographicCameraGuide? geographicCameraGuide({
  required Map snapshot,
  required bool authorized,
  required Position? position,
  required double? heading,
  required DateTime? headingAt,
  required DateTime now,
  required int serverNow,
  CameraTrailGuidance? progress,
}) {
  final target = snapshot['geography']?['latest'] as Map?;
  final p = position;
  bool usable(Map fix) =>
      [
        'latitude',
        'longitude',
        'accuracy',
        'fixAt',
      ].every((k) => fix[k] is num && (fix[k] as num).isFinite) &&
      (fix['latitude'] as num).abs() <= 90 &&
      (fix['longitude'] as num).abs() <= 180 &&
      (fix['accuracy'] as num) > 0 &&
      (fix['accuracy'] as num) <= 20 &&
      (fix['mock'] != true ||
          snapshot['sensorMode'] == 'simulated' &&
              fix['simulated'] == true &&
              fix['provider'] == 'kaze-demo');
  if (!authorized ||
      target == null ||
      p == null ||
      heading == null ||
      !heading.isFinite ||
      headingAt == null ||
      now.difference(headingAt).inMilliseconds < 0 ||
      now.difference(headingAt).inMilliseconds > 3000 ||
      now.difference(p.timestamp).inMilliseconds < 0 ||
      now.difference(p.timestamp).inMilliseconds > 10000 ||
      !p.latitude.isFinite ||
      p.latitude.abs() > 90 ||
      !p.longitude.isFinite ||
      p.longitude.abs() > 180 ||
      !p.accuracy.isFinite ||
      p.accuracy <= 0 ||
      p.accuracy > 20 ||
      p.isMocked ||
      !usable(target) ||
      serverNow < (target['fixAt'] as num) ||
      serverNow - (target['fixAt'] as num) > 30000) {
    return null;
  }
  final angle = heading * math.pi / 180;
  final anchor = {'latitude': p.latitude, 'longitude': p.longitude};
  final points = <Map<String, Object>>[];
  final worldPoints = <Map<String, Object>>[];
  final streets = <String, String>{};
  var section = 0;
  for (final path in snapshot['geography']?['paths'] as List? ?? []) {
    var gap = 0, worldGap = 0;
    for (final fix in path['points'] as List) {
      if (!usable(fix)) {
        gap++;
        worldGap++;
        continue;
      }
      final offset = localHorizontal(anchor, fix);
      final id = (fix['id'] ?? '$section:${worldPoints.length}').toString();
      worldPoints.add({
        'id': id,
        'x': offset.x,
        'z': offset.z,
        'source': path['source'] as String,
        'segment': '$section:$worldGap',
        'uncertainty': p.accuracy + (fix['accuracy'] as num).toDouble(),
      });
      if (fix['street'] is String) streets[id] = fix['street'] as String;
      final forward = offset.x * math.sin(angle) - offset.z * math.cos(angle);
      if (forward <= 1 ||
          math.sqrt(offset.x * offset.x + offset.z * offset.z) > 200) {
        gap++;
        continue;
      }
      points.add({
        'x': offset.x * math.cos(angle) + offset.z * math.sin(angle),
        'z': -forward,
        'segment': '$section:$gap',
        'wearer': fix['id'] == target['id'],
      });
    }
    section++;
  }
  final offset = localHorizontal(anchor, target);
  final bearing = math.atan2(offset.x, -offset.z);
  final turn = math.atan2(math.sin(bearing - angle), math.cos(bearing - angle));
  final cue = progress?.update(
    worldPoints,
    x: 0,
    z: 0,
    forwardX: math.sin(angle),
    forwardZ: -math.cos(angle),
    reachRadius: math.max(8, p.accuracy * 2),
  );
  if (progress != null && cue == null) return null;
  return GeographicCameraGuide(
    points.length <= 200 ? points : points.sublist(points.length - 200),
    cue?.distance ?? math.sqrt(offset.x * offset.x + offset.z * offset.z),
    cue?.turn ?? turn,
    cue?.uncertainty ?? p.accuracy + (target['accuracy'] as num).toDouble(),
    street: streets[progress?.target] ?? target['street'] as String?,
  );
}
