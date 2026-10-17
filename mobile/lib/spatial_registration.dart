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
  bool failed = false;
  bool get ready => checks >= 3 && !failed;
  String get status => failed
      ? 'Registration lost. Return to the map and reopen AR.'
      : _end == null
      ? 'Walk safely outdoors with camera tracking. Need a 30–100 m baseline and precise locations.'
      : !ready
      ? 'Continue walking: validating registration ($checks/3 later fixes).'
      : 'Registered locally. Baseline ${baseline.round()} m; validation residual ${residual.toStringAsFixed(1)} m. Experimental recorded observations only.';

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
    for (final path in packet['paths'] as List) {
      for (final p in path['points'] as List) {
        // Do not invent camera-height, ground, floor or terrain coordinates.
        if (p['y'] is! num ||
            p['verticalUncertainty'] is! num ||
            p['altitudeDatum'] != 'WGS84-ellipsoid' ||
            !_vertical.isFinite) {
          continue;
        }
        final x = _n(p, 'x'), z = _n(p, 'z');
        final middleX = (_first!.east + _end!.east) / 2;
        final middleZ = (_first!.south + _end!.south) / 2;
        final uncertainty =
            _n(p, 'relativeHorizontalUncertainty') +
            _uncertainty +
            residual +
            _distance(x - middleX, z - middleZ) * math.sin(yawAllowance) +
            (_travel - _fitTravel) * .02;
        final vertical = _n(p, 'verticalUncertainty') + _vertical;
        final wx = _c * x - _s * z + _tx, wz = _s * x + _c * z + _tz;
        if (uncertainty > 10 ||
            vertical > 10 ||
            _distance(wx - _last!.x, wz - _last!.z) > 50) {
          continue;
        }
        points.add({
          'x': wx,
          'y': _n(p, 'y') + _ty,
          'z': wz,
          'uncertainty': uncertainty,
          'verticalUncertainty': vertical,
          'source': path['source'] as String,
        });
      }
    }
    // Bound rendering cost without joining or filling missing observations.
    return points.length <= 200 ? points : points.sublist(points.length - 200);
  }
}
