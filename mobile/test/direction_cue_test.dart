import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:kaze/direction_preview.dart';

void main() {
  final now = DateTime.utc(2026, 10, 17, 12);
  Position position({
    double latitude = 43,
    double accuracy = 5,
    bool mock = false,
    int age = 0,
  }) => Position(
    latitude: latitude,
    longitude: -79,
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
  Map<String, Object> target({
    double latitude = 43.001,
    double accuracy = 5,
    bool mock = false,
    int age = 0,
  }) => {
    'latitude': latitude,
    'longitude': -79,
    'accuracy': accuracy,
    'fixAt': now.subtract(Duration(seconds: age)).millisecondsSinceEpoch,
    'mock': mock,
  };
  String cue({
    bool authorized = true,
    Position? guardian,
    Map? wearer,
    double heading = 0,
    int headingAge = 0,
  }) => directionCue(
    authorized: authorized,
    target: wearer ?? target(),
    position: guardian ?? position(),
    heading: heading,
    headingAt: now.subtract(Duration(seconds: headingAge)),
    now: now,
    serverNow: now.millisecondsSinceEpoch,
  );
  test(
    'fresh separated locations give approximate left, ahead and right cues',
    () {
      expect(cue(), contains('ahead'));
      expect(cue(heading: 90), contains('turn left'));
      expect(cue(heading: 270), contains('turn right'));
      expect(cue(heading: 350), contains('ahead'));
      expect(cue(), contains('alignment is unvalidated'));
    },
  );
  test('overlapping location uncertainty cannot give a precise direction', () {
    expect(
      cue(wearer: target(latitude: 43.00001)),
      contains('Within combined reported location uncertainty'),
    );
  });
  test('stale and inaccurate inputs fall back to the map', () {
    for (final result in [
      cue(guardian: position(age: 11)),
      cue(wearer: target(age: 31)),
      cue(headingAge: 4),
      cue(guardian: position(accuracy: 21)),
      cue(wearer: target(accuracy: 21)),
    ]) {
      expect(result, startsWith('Use the map:'));
    }
  });
  test(
    'authorization loss and mock positions on either phone block guidance',
    () {
      expect(cue(authorized: false), startsWith('Use the map:'));
      expect(cue(wearer: target(mock: true)), startsWith('Use the map:'));
      expect(cue(guardian: position(mock: true)), startsWith('Use the map:'));
    },
  );
  test('unknown and low precision compass reports cannot give a direction', () {
    expect(directionHeading(CompassEvent.fromList([90, 0, -1])), isNull);
    expect(directionHeading(CompassEvent.fromList([90, 0, 45])), isNull);
    expect(
      directionHeading(CompassEvent.fromList([double.nan, 0, 15])),
      isNull,
    );
    expect(directionHeading(CompassEvent.fromList([90, 0, 15])), 90);
  });
}
