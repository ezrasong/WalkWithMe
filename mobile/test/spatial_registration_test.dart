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
  test('missing or incompatible heights use a labeled horizontal plane; poor horizontal geometry is omitted', () {
    final r = registered();
    final horizontal = r.breadcrumbs(
      packet([point(y: null), point(datum: null), point(vertical: 11)]),
    );
    expect(horizontal, hasLength(6));
    for (final p in horizontal) {
      expect(p['heightMode'], 'horizontal');
      expect(p['verticalUncertainty'], 0);
      expect(p['y'], closeTo(.7, 1e-10));
    }
    expect(
      r.breadcrumbs(packet([point(horizontal: 26), point(x: 500)])),
      isEmpty,
    );
    expect(r.breadcrumbs(packet([point()], id: 'new-anchor')), isEmpty);
    expect(
      registered(altitude: null)
          .breadcrumbs(packet([point()]))
          .first['heightMode'],
      'horizontal',
    );
    expect(
      registered(origin: {...anchor, 'altitudeDatum': null})
          .breadcrumbs(packet([point()]))
          .first['heightMode'],
      'horizontal',
    );
  });
  test('omitted points, source paths and height transitions break renderer segments', () {
    final dots = registered().breadcrumbs(
      packet([
        point(x: 31),
        point(x: 32),
        point(x: 33, horizontal: 30),
        point(x: 34),
        point(x: 35, y: null),
      ]),
    );
    expect(dots, hasLength(8));
    expect(dots[0]['segment'], dots[1]['segment']);
    expect(dots[1]['segment'], isNot(dots[2]['segment']));
    expect(dots[2]['segment'], isNot(dots[3]['segment']));
    expect(dots[0]['segment'], isNot(dots[4]['segment']));
  });

  test('horizontal rendering includes typical 8 m observations without counting the anchor error twice', () {
    final p = {...point(horizontal: 16), 'horizontalAccuracy': 8};
    final dots = registered(altitude: null).breadcrumbs(packet([p]));
    expect(dots, hasLength(2));
    expect(dots.first['uncertainty'] as double, lessThan(12));
  });

  Map<String, Object> waypoint(
    String id,
    double x,
    double z, {
    String section = 'phone:1',
    String source = 'phone',
  }) => {'id': id, 'segment': section, 'source': source, 'x': x, 'z': z};
  test('live camera pose gives correct left/right turns and advances without going backwards', () {
    final guide = CameraTrailGuidance();
    final points = [
      waypoint('a', 0, 0),
      waypoint('b', 10, 0),
      waypoint('c', 10, -10),
    ];
    CameraTrailCue? update(double x, double z, double fx, double fz) =>
        guide.update(points, x: x, z: z, forwardX: fx, forwardZ: fz);
    expect(update(0, 0, 0, -1)!.turn, closeTo(math.pi / 2, 1e-10));
    expect(guide.target, 'b');
    expect(update(0, 0, 0, 1)!.turn, closeTo(-math.pi / 2, 1e-10));
    expect(update(10, 0, 0, -1)!.turn, closeTo(0, 1e-10));
    expect(guide.target, 'c');
    update(0, 0, 0, -1);
    expect(guide.target, 'c');
    expect(
      update(10, -10, 0, -1)!.message,
      contains('arrival is not verified'),
    );
    expect(update(10, -10, 0, 0), isNull);
  });
  test('guidance never jumps source or crosses a gap and retains a visible target after range clipping', () {
    final guide = CameraTrailGuidance();
    CameraTrailCue? update(List<Map<String, Object>> points) =>
        guide.update(points, x: 0, z: 0, forwardX: 0, forwardZ: -1);
    update([
      waypoint('a', 0, 0),
      waypoint('b', 0, -10),
      waypoint('watch', 0, -1, source: 'watch', section: 'watch:1'),
    ]);
    expect(guide.target, 'b');
    expect(
      update([waypoint('b', 0, -10, section: 'phone:clipped')]),
      isNotNull,
    );
    expect(update([waypoint('gap', 0, -11, section: 'phone:2')]), isNull);
    expect(guide.target, 'b');
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
