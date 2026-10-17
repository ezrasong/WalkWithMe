import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaze/spatial_registration.dart';

void main() {
  final anchor = <String, Object>{
    'id': 'synthetic-anchor',
    'latitude': 0.0,
    'longitude': 0.0,
    'altitude': 100.0,
    'altitudeDatum': 'WGS84-ellipsoid',
  };
  SpatialSample sample(
    double t,
    double east, {
    double south = 0,
    double yaw = .6,
    double dx = 0,
    double dz = 0,
    double accuracy = 1,
    double? altitude = 100,
  }) => SpatialSample(
    t: t,
    east: east,
    south: south,
    x: 7 + math.cos(yaw) * east - math.sin(yaw) * south + dx,
    y: 2,
    z: -4 + math.sin(yaw) * east + math.cos(yaw) * south + dz,
    accuracy: accuracy,
    altitude: altitude,
    verticalAccuracy: altitude == null ? null : 1,
  );
  SpatialRegistration registered({
    Map? origin,
    double yaw = .6,
    double? altitude = 100,
  }) {
    final r = SpatialRegistration(origin ?? anchor);
    for (var i = 0; i <= 36; i++) {
      r.add(sample(i.toDouble(), i.toDouble(), yaw: yaw, altitude: altitude));
    }
    expect(r.ready, true);
    return r;
  }

  Map<String, Object?> point({
    double x = 35,
    double z = 0,
    double? y = 2,
    double horizontal = 2,
    double vertical = 2,
    String? datum = 'WGS84-ellipsoid',
  }) => {
    'x': x,
    'y': y,
    'z': z,
    'relativeHorizontalUncertainty': horizontal,
    'verticalUncertainty': vertical,
    'altitudeDatum': datum,
  };
  Map packet(List<Map> points, {String id = 'synthetic-anchor'}) => {
    'frame': {
      'anchor': {'id': id},
    },
    'paths': [
      {'source': 'phone', 'points': points},
      {'source': 'watch', 'points': points},
    ],
  };

  test(
    'WGS84 projection matches backend cardinal and antimeridian fixtures',
    () {
      final east = localHorizontal(anchor, {'latitude': 0, 'longitude': .001});
      final north = localHorizontal(anchor, {'latitude': .001, 'longitude': 0});
      expect(east.x, closeTo(111.31949, .01));
      expect(east.z, closeTo(0, .01));
      expect(north.z, closeTo(-110.57428, .01));
      final crossing = localHorizontal(
        {'latitude': 0, 'longitude': 179.9999},
        {'latitude': 0, 'longitude': -179.9999},
      );
      expect(crossing.x, inExclusiveRange(22, 23));
    },
  );
  test('native samples require finite precise non-mock locations paired within 200 ms', () {
    final m = <String, Object>{
      't': 1,
      'x': 0,
      'y': 0,
      'z': 0,
      'latitude': 0,
      'longitude': 0,
      'accuracy': 2,
      'ageMs': 100,
      'mock': false,
      'altitude': 100,
      'verticalAccuracy': 2,
      'altitudeDatum': 'WGS84-ellipsoid',
    };
    expect(SpatialSample.parse(m, anchor)?.altitude, 100);
    for (final patch in [
      {'accuracy': 0},
      {'accuracy': 6},
      {'mock': true},
      {'ageMs': 201},
      {'ageMs': -1},
      {'x': double.nan},
      {'latitude': 91},
      {'longitude': .1},
    ]) {
      expect(SpatialSample.parse({...m, ...patch}, anchor), isNull);
    }
    expect(
      SpatialSample.parse({...m, 'altitudeDatum': 'MSL'}, anchor)?.altitude,
      isNull,
    );
  });
  test('two point rigid registration waits for withheld moving fixes and never uses a compass', () {
    final r = SpatialRegistration(anchor);
    for (var i = 0; i <= 30; i++) {
      r.add(sample(i.toDouble(), i.toDouble()));
    }
    expect(r.ready, false);
    expect(r.checks, 0);
    r.add(sample(31, 31));
    expect(r.checks, 0);
    for (var i = 32; i <= 36; i++) {
      r.add(sample(i.toDouble(), i.toDouble()));
    }
    expect(r.ready, true);
    expect(r.baseline, 30);
    expect(r.residual, closeTo(0, 1e-10));
    final dots = r.breadcrumbs(packet([point()]));
    expect(dots.length, 2);
    expect(dots.map((p) => p['source']), ['phone', 'watch']);
    expect(dots.first['x'] as double, closeTo(7 + math.cos(.6) * 35, 1e-10));
    expect(dots.first['z'] as double, closeTo(-4 + math.sin(.6) * 35, 1e-10));
    expect(dots.first['y'], 4);
  });
  test(
    'rotation works in every quadrant without reflecting east/south axes',
    () {
      for (final yaw in [0.0, math.pi / 2, math.pi, -math.pi / 2]) {
        final r = registered(yaw: yaw);
        final dot = r.breadcrumbs(packet([point(z: 3)])).first;
        expect(
          dot['x'] as double,
          closeTo(7 + math.cos(yaw) * 35 - math.sin(yaw) * 3, 1e-8),
        );
        expect(
          dot['z'] as double,
          closeTo(-4 + math.sin(yaw) * 35 + math.cos(yaw) * 3, 1e-8),
        );
      }
    },
  );
  test('stationary GPS wander and short baselines cannot register', () {
    final r = SpatialRegistration(anchor);
    for (var i = 0; i < 80; i++) {
      r.add(
        SpatialSample(
          t: i.toDouble(),
          east: i.toDouble(),
          south: 0,
          x: 0,
          y: 0,
          z: 0,
          accuracy: 1,
        ),
      );
    }
    expect(r.ready, false);
    final short = SpatialRegistration(anchor);
    for (var i = 0; i < 20; i++) {
      short.add(sample(i.toDouble(), i.toDouble()));
    }
    expect(short.ready, false);
  });
  test(
    'scale disagreement and later GNSS/AR disagreement invalidate registration',
    () {
      final scale = SpatialRegistration(anchor);
      for (var i = 0; i < 65; i++) {
        scale.add(sample(i.toDouble(), i.toDouble(), dx: i * .5));
      }
      expect(scale.failed, true);
      final r = registered();
      r.add(sample(37, 37, dx: 7));
      expect(r.failed, true);
      expect(r.breadcrumbs(packet([point()])), isEmpty);
    },
  );
  test('duplicates cannot validate; stale samples, tracking jumps and long sessions invalidate', () {
    final r = registered();
    r.add(sample(36, 999));
    expect(r.failed, false);
    r.add(sample(42, 37));
    expect(r.failed, true);
    final jump = registered();
    jump.add(sample(37, 100));
    expect(jump.failed, true);
    final old = registered();
    for (var t = 37; t <= 151; t++) {
      old.add(sample(t.toDouble(), 36));
    }
    expect(old.failed, true);
  });
  test('missing heights, incompatible datums, excessive uncertainty and distance stay on map', () {
    final r = registered();
    expect(
      r.breadcrumbs(
        packet([
          point(y: null),
          point(datum: null),
          point(horizontal: 11),
          point(vertical: 11),
          point(x: 500),
        ]),
      ),
      isEmpty,
    );
    expect(r.breadcrumbs(packet([point()], id: 'new-anchor')), isEmpty);
    expect(registered(altitude: null).breadcrumbs(packet([point()])), isEmpty);
    expect(
      registered(origin: {...anchor, 'altitudeDatum': null})
          .breadcrumbs(packet([point()])),
      isEmpty,
    );
  });
  test(
    'vertical disagreement invalidates even when horizontal residual is zero',
    () {
      final r = registered();
      r.add(sample(37, 37, altitude: 120));
      expect(r.failed, true);
    },
  );
  test('uncertainty grows with cumulative movement, including a return to the fit point', () {
    final r = registered();
    final before =
        r.breadcrumbs(packet([point()])).first['uncertainty'] as double;
    for (var t = 37; t <= 46; t++) {
      r.add(sample(t.toDouble(), t.toDouble()));
    }
    for (var t = 47; t <= 56; t++) {
      r.add(sample(t.toDouble(), 92.0 - t));
    }
    final after =
        r.breadcrumbs(packet([point()])).first['uncertainty'] as double;
    expect(after, greaterThan(before));
    // These synthetic fixtures prove geometry and rejection behavior, not field accuracy.
  });
}
