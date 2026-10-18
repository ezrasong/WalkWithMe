import 'dart:math' as math;

// Synthetic camera-world geometry only. No geographic coordinates, session
// evidence, permissions, networking or persistence belong to this model.
class ArDemoWalk {
  final double x, y, z, forwardX, forwardZ;
  double distance = 0, speed = 1;
  bool playing = false;
  ArDemoWalk._(this.x, this.y, this.z, this.forwardX, this.forwardZ);

  static ArDemoWalk? fromPose(Map pose) {
    if ([
      'x',
      'y',
      'z',
      'forwardX',
      'forwardZ',
    ].any((key) => pose[key] is! num || !(pose[key] as num).isFinite)) {
      return null;
    }
    final fx = (pose['forwardX'] as num).toDouble();
    final fz = (pose['forwardZ'] as num).toDouble();
    final length = math.sqrt(fx * fx + fz * fz);
    if (length < .2) return null;
    return ArDemoWalk._(
      (pose['x'] as num).toDouble(),
      (pose['y'] as num).toDouble() - 1.3,
      (pose['z'] as num).toDouble(),
      fx / length,
      fz / length,
    );
  }

  bool get complete => distance >= 18;
  String get button => playing
      ? 'Pause demo'
      : complete || distance == 0
      ? 'Start demo'
      : 'Resume demo';
  void toggle() {
    if (complete) distance = 0;
    playing = !playing;
  }

  void restart() {
    distance = 0;
    playing = true;
  }

  void advance(Duration elapsed) {
    if (!playing) return;
    distance = math.min(
      18,
      distance + elapsed.inMicroseconds / 1e6 * 1.2 * speed,
    );
    if (complete) playing = false;
  }

  Map<String, Object> point(double at, {bool wearer = false}) {
    final right = at <= 6 ? 0.0 : math.min(6.0, at - 6);
    final ahead = at <= 6
        ? at + 2
        : at <= 12
        ? 8.0
        : at - 4;
    return {
      'id': wearer ? 'demo-wearer' : 'demo-${at.toStringAsFixed(3)}',
      'segment': 'demo',
      'source': 'demo',
      'heightMode': 'horizontal',
      'wearer': wearer,
      'x': x + forwardX * ahead - forwardZ * right,
      'y': y,
      'z': z + forwardZ * ahead + forwardX * right,
      'uncertainty': .35,
      'verticalUncertainty': 0.0,
    };
  }

  List<Map<String, Object>> get points => [
    for (var i = 0; i < distance; i++) point(i.toDouble()),
    point(distance, wearer: true),
  ];
}
