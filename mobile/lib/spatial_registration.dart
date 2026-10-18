import 'dart:math' as math;

// Local-only geometry. Native tracking poses and GNSS observations must refer
// to the same instant (within 200 ms), in one uninterrupted AR world.
double _n(Map m, String k) => (m[k] as num).toDouble();
double _distance(double x, double z) => math.sqrt(x * x + z * z);

({double x, double z}) localHorizontal(Map anchor, Map point) {
  List<double> surface(Map p) {
    final lat = _n(p, 'latitude') * math.pi / 180;
    final lon = _n(p, 'longitude') * math.pi / 180;
    final n =
        6378137 /
        math.sqrt(1 - 6.6943799901413165e-3 * math.pow(math.sin(lat), 2));
    return [
      n * math.cos(lat) * math.cos(lon),
      n * math.cos(lat) * math.sin(lon),
      n * (1 - 6.6943799901413165e-3) * math.sin(lat),
    ];
  }

  final a = surface(anchor), b = surface(point);
  final dx = b[0] - a[0], dy = b[1] - a[1], dz = b[2] - a[2];
  final lat = _n(anchor, 'latitude') * math.pi / 180,
      lon = _n(anchor, 'longitude') * math.pi / 180;
  return (
    x: -math.sin(lon) * dx + math.cos(lon) * dy,
    z:
        math.sin(lat) * math.cos(lon) * dx +
        math.sin(lat) * math.sin(lon) * dy -
        math.cos(lat) * dz,
  );
}

class SpatialSample {
  final double t, x, y, z, east, south, accuracy;
  final double? altitude, verticalAccuracy;
  SpatialSample({
    required this.t,
    required this.x,
    required this.y,
    required this.z,
    required this.east,
    required this.south,
    required this.accuracy,
    this.altitude,
    this.verticalAccuracy,
  });

  static SpatialSample? parse(Map m, Map anchor) {
    const keys = [
      't',
      'x',
      'y',
      'z',
      'latitude',
      'longitude',
      'accuracy',
      'ageMs',
    ];
    if (keys.any((k) => m[k] is! num || !(m[k] as num).isFinite) ||
        m['mock'] != false ||
        _n(m, 'ageMs') < 0 ||
        _n(m, 'ageMs') > 200 ||
        _n(m, 'accuracy') <= 0 ||
        _n(m, 'accuracy') > 5 ||
        _n(m, 'latitude').abs() > 90 ||
        _n(m, 'longitude').abs() > 180) {
      return null;
    }
    final p = localHorizontal(anchor, m);
    if (_distance(p.x, p.z) > 2000) return null;
    final vertical =
        m['altitudeDatum'] == 'WGS84-ellipsoid' &&
        m['altitude'] is num &&
        (m['altitude'] as num).isFinite &&
        m['verticalAccuracy'] is num &&
        (m['verticalAccuracy'] as num).isFinite &&
        _n(m, 'verticalAccuracy') > 0 &&
        _n(m, 'verticalAccuracy') <= 5;
    return SpatialSample(
      t: _n(m, 't'),
      x: _n(m, 'x'),
      y: _n(m, 'y'),
      z: _n(m, 'z'),
      east: p.x,
      south: p.z,
      accuracy: _n(m, 'accuracy'),
      altitude: vertical ? _n(m, 'altitude') : null,
      verticalAccuracy: vertical ? _n(m, 'verticalAccuracy') : null,
    );
  }
}

class SpatialRegistration {
  final Map anchor;
  SpatialRegistration(this.anchor);
  SpatialSample? _first, _end, _last, _validation;
  double _c = 1, _s = 0, _tx = 0, _tz = 0, _ty = 0;
  double _travel = 0, _fitTravel = 0;
  double baseline = 0,
      yawAllowance = 0,
      residual = 0,
      _uncertainty = 0,
      _vertical = double.infinity;
  int checks = 0;
  bool geospatial = false;
  bool failed = false;
  bool get ready => (geospatial || checks >= 3) && !failed;
  String get status => failed
      ? 'Registration lost. Return to the map and reopen AR.'
      : geospatial
      ? 'Google-assisted alignment active. Follow the recorded trail where passable.'
      : _end == null
      ? 'Walk safely outdoors with camera tracking. Need a 30–100 m baseline and precise locations.'
      : !ready
      ? 'Continue walking: validating registration ($checks/3 later fixes).'
      : 'Camera aligned. Baseline ${baseline.round()} m; validation residual ${residual.toStringAsFixed(1)} m. Follow the recorded trail where safe.';

  // The native Earth pose supplies a current EUS-to-camera-world transform.
  // Reuse the same range, source, gap, height and uncertainty rendering gates.
  bool addGeospatial(Map m) {
    final p = SpatialSample.parse(m, anchor);
    if (failed ||
        p == null ||
        m['yaw'] is! num ||
        !(m['yaw'] as num).isFinite ||
        m['yawAccuracy'] is! num ||
        !(m['yawAccuracy'] as num).isFinite ||
        _n(m, 'yawAccuracy') <= 0 ||
        _n(m, 'yawAccuracy') > 10 ||
        (_last != null && p.t <= _last!.t)) {
      return false;
    }
    geospatial = true;
    _first = _end = _last = p;
    _c = math.cos(_n(m, 'yaw'));
    _s = math.sin(_n(m, 'yaw'));
    _tx = p.x - _c * p.east + _s * p.south;
    _tz = p.z - _s * p.east - _c * p.south;
    _uncertainty = p.accuracy;
    yawAllowance = _n(m, 'yawAccuracy') * math.pi / 180;
    _vertical = double.infinity;
    if (anchor['altitudeDatum'] == 'WGS84-ellipsoid' &&
        anchor['altitude'] is num &&
        (anchor['altitude'] as num).isFinite &&
        p.altitude != null) {
      _ty = p.y - (p.altitude! - _n(anchor, 'altitude'));
      _vertical = p.verticalAccuracy!;
    }
    return true;
  }

  // A frozen two-point rigid fit is checked against later, withheld fixes.
  // GPS accuracy values are allowances, never calibrated confidence intervals.
  void add(SpatialSample p) {
    if (failed || (_last != null && p.t <= _last!.t)) return;
    if (_last != null &&
        (p.t - _last!.t > 5 ||
            _distance(p.x - _last!.x, p.z - _last!.z) > 5 * (p.t - _last!.t))) {
      failed = true;
      return;
    }
    if (_last != null) _travel += _distance(p.x - _last!.x, p.z - _last!.z);
    _last = p;
    _first ??= p;
    final a = _first!;
    if (_end == null) {
      final ex = p.east - a.east, ez = p.south - a.south;
      final wx = p.x - a.x, wz = p.z - a.z;
      final d = _distance(ex, ez), w = _distance(wx, wz);
      if (w > 200 || p.t - a.t > 180) {
        failed = true;
        return;
      }
      if (d + 1e-6 < math.max(30, 8 * (a.accuracy + p.accuracy)) ||
          w + 1e-6 < 30) {
        return;
      }
      if ((d - w).abs() > a.accuracy + p.accuracy + w * .02) {
        failed = true;
        return;
      }
      _c = (ex * wx + ez * wz) / (d * w);
      _s = (ex * wz - ez * wx) / (d * w);
      _tx = (a.x + p.x - _c * (a.east + p.east) + _s * (a.south + p.south)) / 2;
      _tz = (a.z + p.z - _s * (a.east + p.east) - _c * (a.south + p.south)) / 2;
      baseline = d;
      yawAllowance = math.asin(((a.accuracy + p.accuracy) / d).clamp(0, 1));
      _uncertainty =
          math.max(a.accuracy, p.accuracy) + (d - w).abs() / 2 + .02 * _travel;
      if (anchor['altitudeDatum'] == 'WGS84-ellipsoid' &&
          anchor['altitude'] is num &&
          a.altitude != null &&
          p.altitude != null) {
        final ay = a.y - (a.altitude! - _n(anchor, 'altitude'));
        final by = p.y - (p.altitude! - _n(anchor, 'altitude'));
        if ((ay - by).abs() <= a.verticalAccuracy! + p.verticalAccuracy!) {
          _ty = (ay + by) / 2;
          _vertical =
              math.max(a.verticalAccuracy!, p.verticalAccuracy!) +
              (ay - by).abs() / 2;
        }
      }
      _end = p;
      _fitTravel = _travel;
      _validation = p;
      return;
    }
    final v = _validation!;
    if (p.t - _end!.t > 120 || _travel - _fitTravel > 100) {
      failed = true;
      return;
    }
    final error = _distance(
      _c * p.east - _s * p.south + _tx - p.x,
      _s * p.east + _c * p.south + _tz - p.z,
    );
    // Every later fix can invalidate the fit, including while stationary.
    if (error > 5 || error > _uncertainty + p.accuracy) {
      failed = true;
      return;
    }
    if (_vertical.isFinite &&
        p.altitude != null &&
        (p.y - (p.altitude! - _n(anchor, 'altitude')) - _ty).abs() >
            _vertical + p.verticalAccuracy!) {
      failed = true;
      return;
    }
    residual = math.max(residual, error);
    if (p.t - v.t >= 2 && _distance(p.x - v.x, p.z - v.z) + 1e-6 >= 2) {
      checks++;
      _validation = p;
    }
  }

  List<Map<String, Object>> breadcrumbs(Map packet) {
    if (!ready ||
        _last == null ||
        packet['frame']?['anchor']?['id'] != anchor['id']) {
      return [];
    }
    final points = <Map<String, Object>>[];
    var pathIndex = 0;
    for (final path in packet['paths'] as List) {
      String? segment, lastMode;
      var index = 0;
      for (final p in path['points'] as List) {
        final id = (p['id'] ?? '${pathIndex}_${index++}').toString();
        if ([
          'x',
          'z',
          'relativeHorizontalUncertainty',
        ].any((key) => p[key] is! num || !(p[key] as num).isFinite)) {
          segment = null;
          continue;
        }
        final x = _n(p, 'x'), z = _n(p, 'z');
        final middleX = (_first!.east + _end!.east) / 2;
        final middleZ = (_first!.south + _end!.south) / 2;
        final uncertainty =
            // Anchor coordinates occur on both sides of the rigid fit and
            // cancel; include the fix's accuracy once, not the anchor twice.
            (p['horizontalAccuracy'] is num
                ? _n(p, 'horizontalAccuracy')
                : _n(p, 'relativeHorizontalUncertainty')) +
            _uncertainty +
            residual +
            _distance(x - middleX, z - middleZ) * math.sin(yawAllowance) +
            (_travel - _fitTravel) * .02;
        final vertical = p['verticalUncertainty'] is num
            ? _n(p, 'verticalUncertainty') + _vertical
            : double.infinity;
        final measured =
            p['y'] is num &&
            (p['y'] as num).isFinite &&
            p['altitudeDatum'] == 'WGS84-ellipsoid' &&
            vertical > 0 &&
            vertical <= 10;
        final mode = measured ? 'measured' : 'horizontal';
        final wx = _c * x - _s * z + _tx, wz = _s * x + _c * z + _tz;
        if (!uncertainty.isFinite ||
            uncertainty <= 0 ||
            uncertainty > 25 ||
            _distance(wx - _last!.x, wz - _last!.z) > 50) {
          segment = null;
          continue;
        }
        if (segment == null || lastMode != mode) segment = '$pathIndex:$id';
        lastMode = mode;
        points.add({
          'id': id,
          'wearer': packet['simulated'] == true && id == packet['latestId'],
          if (p['street'] is String) 'street': p['street'] as String,
          'segment': segment,
          'heightMode': mode,
          'x': wx,
          // A presentation plane below the initial camera, never an inferred
          // ground surface, floor, or recorded altitude.
          'y': measured ? _n(p, 'y') + _ty : _first!.y - 1.3,
          'z': wz,
          'uncertainty': uncertainty,
          'verticalUncertainty': measured ? vertical : 0.0,
          'source': packet['simulated'] == true
              ? 'demo'
              : path['source'] as String,
        });
      }
      pathIndex++;
    }
    // Bound rendering cost without joining or filling missing observations.
    return points.length <= 200 ? points : points.sublist(points.length - 200);
  }
}

class CameraTrailCue {
  final double turn, distance, uncertainty;
  final bool last;
  CameraTrailCue(this.turn, this.distance, this.last, this.uncertainty);
  bool get nearby => distance <= math.max(3, uncertainty);
  String get direction => turn.abs() < .35
      ? 'ahead'
      : turn.abs() > 2.6
      ? 'turn around'
      : turn > 0
      ? 'turn right'
      : 'turn left';
  String get message =>
      '${nearby ? 'Near the recorded point' : 'Approximate direction: $direction'}; about ${distance.round()} m. ${last ? 'Last supported point. Search within the uncertainty ring; arrival is not verified.' : 'Next recorded point. Follow the trail only where passable.'}';
}

// Progress stays within one continuous source segment. A gap cannot silently
// become a straight-line instruction to the next trail section.
class CameraTrailGuidance {
  String? segment, target;
  CameraTrailCue? update(
    List<Map<String, Object>> points, {
    required double x,
    required double z,
    required double forwardX,
    required double forwardZ,
    double reachRadius = 3,
  }) {
    if (_distance(forwardX, forwardZ) < .2) return null;
    if (segment == null) {
      final phone = points.where((p) => p['source'] == 'phone').toList();
      final candidates = phone.isNotEmpty ? phone : points;
      if (candidates.isEmpty) return null;
      final nearest = candidates.reduce(
        (a, b) =>
            _distance(_n(a, 'x') - x, _n(a, 'z') - z) <=
                _distance(_n(b, 'x') - x, _n(b, 'z') - z)
            ? a
            : b,
      );
      segment = nearest['segment'] as String;
      target = nearest['id'] as String;
    }
    // Range clipping can change the visible segment's first point. Retain
    // progress only when the same target observation is still present.
    final retained = points.where((p) => p['id'] == target);
    if (retained.isNotEmpty) segment = retained.first['segment'] as String;
    final path = points.where((p) => p['segment'] == segment).toList();
    var index = path.indexWhere((p) => p['id'] == target);
    if (index < 0) return null;
    while (index < path.length - 1 &&
        _distance(_n(path[index], 'x') - x, _n(path[index], 'z') - z) <=
            reachRadius) {
      index++;
    }
    final p = path[index];
    target = p['id'] as String;
    final dx = _n(p, 'x') - x, dz = _n(p, 'z') - z;
    final turn = math.atan2(
      forwardX * dz - forwardZ * dx,
      forwardX * dx + forwardZ * dz,
    );
    return CameraTrailCue(
      turn,
      _distance(dx, dz),
      index == path.length - 1,
      (p['uncertainty'] as num? ?? 0).toDouble(),
    );
  }
}
