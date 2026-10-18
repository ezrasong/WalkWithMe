import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A relative diagram. It never maps the unknown frame onto geographic tiles
/// or the guardian camera, and never connects independently restarted origins.
class RelativeMotionCard extends StatelessWidget {
  final Map? motion;
  final bool compact;
  const RelativeMotionCard({
    super.key,
    required this.motion,
    this.compact = false,
  });
  @override
  Widget build(BuildContext context) {
    if (motion == null) return const SizedBox.shrink();
    final segments = motion?['segments'] as List? ?? [];
    final segment = segments.isEmpty ? null : segments.last as Map;
    final points = segment?['points'] as List? ?? [];
    final status = switch (segment?['activity']?['status']) {
      'consistent-activity' => 'Phone and watch activity consistent',
      'stationary-conflict' => 'Watch movement conflicts with a still phone',
      'disagreement' => 'Phone and watch steps disagree',
      'timing-unavailable' => 'Insufficient synchronized interval',
      _ => 'No usable watch activity yet',
    };
    final supported = segment?['supported'] != false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pocket motion · research preview',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              motion?['available'] != true
                  ? 'No shared relative motion yet. Wearer consent and supported phone sampling are required.'
                  : '${motion?['stale'] == true ? 'STALE · ' : ''}${segments.length} separate sections · latest section shown',
            ),
            if (points.length > 1 && supported)
              Semantics(
                label: 'Relative horizontal trail diagram. Unknown origin and direction; not aligned with the camera or map.',
                child: SizedBox(
                  height: compact ? 90 : 160,
                  child: CustomPaint(
                    painter: RelativeMotionPainter(
                      points,
                      Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            if ((motion?['omittedPoints'] as num? ?? 0) > 0)
              const Text(
                'Earlier history has been trimmed to the retention limit.',
              ),
            if (supported && (segment?['excludedIntervals'] as num? ?? 0) > 0)
              const Text(
                'Conflicting activity intervals are omitted. No line crosses them.',
              ),
            if (!supported)
              const Text(
                'Conflicting phone/watch activity. This section is withheld from the diagram.',
              ),
            Text(
              'Watch activity: $status. No independent position correction.',
            ),
            if (motion?['driftBudgetMeters'] is num)
              Text(
                'Growing drift budget: ${(motion!['driftBudgetMeters'] as num).toStringAsFixed(1)} m · uncalibrated',
              ),
            const Text(
              'Position, north, room and floor unknown. No camera alignment or indoor directions.',
            ),
          ],
        ),
      ),
    );
  }
}

class RelativeMotionPainter extends CustomPainter {
  final List points;
  final Color color;
  RelativeMotionPainter(this.points, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final xs = points.map((p) => (p['x'] as num).toDouble());
    final ys = points.map((p) => (p['y'] as num).toDouble());
    final minX = xs.reduce(math.min), maxX = xs.reduce(math.max);
    final minY = ys.reduce(math.min), maxY = ys.reduce(math.max);
    final scale = math.min(
      (size.width - 24) / math.max(2, maxX - minX),
      (size.height - 24) / math.max(2, maxY - minY),
    );
    Offset position(Map p) => Offset(
      size.width / 2 + ((p['x'] as num) - (minX + maxX) / 2) * scale,
      size.height / 2 - ((p['y'] as num) - (minY + maxY) / 2) * scale,
    );
    final path = Path();
    bool drawing = false;
    for (final p in points) {
      if (p['supported'] == false) {
        drawing = false;
        continue;
      }
      final xy = position(p);
      if (drawing) {
        path.lineTo(xy.dx, xy.dy);
      } else {
        path.moveTo(xy.dx, xy.dy);
      }
      drawing = true;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke,
    );
    final accepted = points.where((p) => p['supported'] != false).toList();
    if (accepted.isEmpty) return;
    canvas.drawCircle(
      position(accepted.first),
      4,
      Paint()..color = Colors.grey,
    );
    canvas.drawCircle(position(accepted.last), 6, Paint()..color = color);
  }

  @override
  bool shouldRepaint(RelativeMotionPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.color != color;
}
