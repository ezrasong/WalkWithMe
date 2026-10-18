import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:kaze/ar_demo.dart';

void main() {
  Map<String, double> pose({double fx = 0, double fz = -1}) => {
    'x': 10,
    'y': 2,
    'z': 20,
    'forwardX': fx,
    'forwardZ': fz,
  };
  test('demo needs a finite horizontal camera pose, not GPS or an alert', () {
    expect(ArDemoWalk.fromPose({}), isNull);
    expect(ArDemoWalk.fromPose({...pose(), 'y': double.nan}), isNull);
    expect(ArDemoWalk.fromPose(pose(fx: 0, fz: 0)), isNull);
    final walk = ArDemoWalk.fromPose(pose())!;
    expect(walk.points.single['x'], 10);
    expect(walk.points.single['z'], 18);
    expect(walk.points.single['y'], closeTo(.7, 1e-10));
    expect(walk.playing, false);
    expect(walk.points.single['wearer'], true);
  });
  test(
    'virtual wearer follows the anchored turns in every camera quadrant',
    () {
      for (final angle in [0.0, math.pi / 2, math.pi, -math.pi / 2]) {
        final fx = math.cos(angle), fz = math.sin(angle);
        final walk = ArDemoWalk.fromPose(pose(fx: fx, fz: fz))!;
        walk.toggle();
        walk.advance(const Duration(seconds: 15));
        expect(walk.complete, true);
        expect(walk.playing, false);
        final end = walk.points.last;
        expect(end['x'] as double, closeTo(10 + fx * 14 - fz * 6, 1e-9));
        expect(end['z'] as double, closeTo(20 + fz * 14 + fx * 6, 1e-9));
        expect(walk.points, hasLength(19));
        expect(walk.points.where((p) => p['wearer'] == true), hasLength(1));
        expect(walk.points.every((p) => p['source'] == 'demo'), true);
        expect(
          walk.points.any(
            (p) => p.containsKey('latitude') || p.containsKey('fixAt'),
          ),
          false,
        );
      }
    },
  );
  test('pause freezes movement, speed affects progress, and restart/replay are bounded', () {
    final walk = ArDemoWalk.fromPose(pose())!;
    walk.advance(const Duration(seconds: 10));
    expect(walk.distance, 0);
    walk.toggle();
    walk.advance(const Duration(seconds: 1));
    expect(walk.distance, closeTo(1.2, 1e-10));
    walk.toggle();
    final paused = walk.points.last;
    walk.advance(const Duration(seconds: 50));
    expect(walk.points.last, paused);
    walk.speed = 2;
    walk.toggle();
    walk.advance(const Duration(seconds: 1));
    expect(walk.distance, closeTo(3.6, 1e-10));
    walk.restart();
    expect(walk.distance, 0);
    expect(walk.playing, true);
    walk.advance(const Duration(seconds: 100));
    expect(walk.distance, 18);
    expect(walk.playing, false);
    walk.toggle();
    expect(walk.distance, 0);
    expect(walk.playing, true);
  });
}
