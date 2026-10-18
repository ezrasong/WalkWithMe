import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:kaze/camera_geography.dart';
import 'package:kaze/direction_preview.dart';
import 'package:kaze/spatial_registration.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17, 12);
  Map<String, Object> fix(
    String id, {
    double latitude = 0,
    double longitude = .001,
  }) => {
    'id': id,
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': 3.0,
    'fixAt': now.millisecondsSinceEpoch,
    'mock': false,
  };
  Position position({
    double longitude = 0,
    double accuracy = 3,
    bool mock = false,
    int age = 0,
  }) => Position(
    latitude: 0,
    longitude: longitude,
    timestamp: now.subtract(Duration(seconds: age)),
    accuracy: accuracy,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
    isMocked: mock,
  );
  Map snapshot(List<Map> points, {bool demo = false}) => {
    'sensorMode': demo ? 'simulated' : 'device',
    'geography': {
      'latest': points.last,
      'paths': [
        {'source': 'phone', 'points': points},
      ],
    },
  };
  GeographicCameraGuide? guide(
    Map s, {
    Position? p,
    double heading = 90,
    int headingAge = 0,
    bool authorized = true,
  }) => geographicCameraGuide(
    snapshot: s,
    authorized: authorized,
    position: p ?? position(),
    heading: heading,
    headingAt: now.subtract(Duration(seconds: headingAge)),
    now: now,
    serverNow: now.millisecondsSinceEpoch,
  );
  test('real positions and camera heading determine trail placement and turn direction', () {
    final s = snapshot([fix('a')]);
    final east = guide(s)!;
    expect(east.distance, closeTo(111.31949, .01));
    expect(east.turn, closeTo(0, 1e-8));
    expect(east.points.single['x'] as double, closeTo(0, 1e-8));
    expect(east.points.single['z'] as double, lessThan(-111));
    expect(guide(s, heading: 0)!.turn, closeTo(math.pi / 2, 1e-8));
    expect(guide(s, heading: 180)!.turn, closeTo(-math.pi / 2, 1e-8));
    expect(
      guide(s, p: position(longitude: .0005))!.distance,
      closeTo(east.distance / 2, .01),
    );
    expect(guide(s, p: position(longitude: .00099))!.nearby, true);
    expect(
      directionHeading(CompassEvent.fromList([0, 90, 15]), camera: true),
      90,
    );
  });
  test('weak, mocked, stale, future and unauthorized inputs cannot produce geometry or guidance', () {
    final s = snapshot([fix('a')]);
    for (final result in [
      guide(s, authorized: false),
      guide(s, p: position(accuracy: 21)),
      guide(s, p: position(accuracy: 0)),
      guide(s, p: position(mock: true)),
      guide(s, p: position(age: 11)),
      guide(s, p: position(age: -1)),
      guide(s, heading: double.nan),
      guide(s, headingAge: 4),
      guide(
        snapshot([
          {...fix('a'), 'fixAt': now.millisecondsSinceEpoch + 1000},
        ]),
      ),
      guide(
        snapshot([
          {...fix('a'), 'fixAt': now.millisecondsSinceEpoch - 31000},
        ]),
      ),
      guide(
        snapshot([
          {...fix('a'), 'latitude': double.nan},
        ]),
      ),
    ]) {
      expect(result, isNull);
    }
  });
  test('synthetic server demo positions work only inside an explicitly simulated snapshot', () {
    final f = {
      ...fix('a'),
      'mock': true,
      'simulated': true,
      'provider': 'kaze-demo',
    };
    expect(guide(snapshot([f])), isNull);
    expect(guide(snapshot([f], demo: true)), isNotNull);
    expect(
      guide(
        snapshot([
          {...f, 'provider': 'gps'},
        ], demo: true),
      ),
      isNull,
    );
    expect(
      guide(
        snapshot([
          {...f, 'simulated': false},
        ], demo: true),
      ),
      isNull,
    );
  });
  test('rejected observations and separate source paths never form connecting ribbons', () {
    final s = snapshot([
      fix('a', longitude: .0002),
      {...fix('bad', longitude: .0003), 'mock': true},
      fix('b', longitude: .0004),
      fix('c', longitude: .0005),
    ]);
    final points = guide(s)!.points;
    expect(points, hasLength(3));
    expect(points[0]['segment'], isNot(points[1]['segment']));
    expect(points[1]['segment'], points[2]['segment']);
    expect(points.last['wearer'], true);
  });
  test(
    'camera visibility gaps split paint without splitting walking progress',
    () {
      final s = snapshot([
        fix('a', longitude: .0002),
        fix('b', longitude: -.0002),
        fix('c', longitude: .0004),
      ]);
      final visible = guide(s)!.points;
      expect(visible, hasLength(2));
      expect(visible[0]['segment'], isNot(visible[1]['segment']));
      final progress = CameraTrailGuidance();
      GeographicCameraGuide? update(double longitude, double heading) =>
          geographicCameraGuide(
            snapshot: s,
            authorized: true,
            position: position(longitude: longitude),
            heading: heading,
            headingAt: now,
            now: now,
            serverNow: now.millisecondsSinceEpoch,
            progress: progress,
          );
      expect(update(0, 90), isNotNull);
      expect(progress.target, 'a');
      expect(update(.0002, 90), isNotNull);
      expect(progress.target, 'b');
      expect(update(.0002, 270)!.turn, closeTo(0, 1e-8));
      expect(progress.target, 'b');
    },
  );
}
