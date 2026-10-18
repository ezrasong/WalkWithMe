import 'dart:math' as math;

import 'package:flutter/material.dart';

// Perspective overlay for compass-projected or explicitly simulated points.
// It never interprets camera images or claims a tracked world pose.
class CameraTrailOverlay extends CustomPainter {
  final List<Map<String, Object>> points;
  final Color color;
  CameraTrailOverlay(this.points, {this.color = Colors.pinkAccent});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final trail = Path();
    Object? previousSegment;
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final depth = math.max(.1, -(p['z'] as num).toDouble());
      final scale = size.width * .55 / depth;
      final x = size.width / 2 + (p['x'] as num) * scale;
      final y = size.height * .4 + 1.3 * scale;
      if (i == 0 || previousSegment != p['segment']) {
        trail.moveTo(x, y);
      } else {
        trail.lineTo(x, y);
      }
      previousSegment = p['segment'];
      canvas.drawCircle(Offset(x, y), 4, paint);
      if (p['wearer'] == true) {
        final body = math.max(18.0, scale * .65),
            head = math.max(5.0, scale * .16);
        final top = y - body * 1.6;
        canvas.drawCircle(Offset(x, top), head, paint);
        canvas.drawLine(
          Offset(x, top + head),
          Offset(x, y - body * .45),
          paint,
        );
        canvas.drawLine(
          Offset(x - body * .3, y - body),
          Offset(x + body * .3, y - body),
          paint,
        );
        canvas.drawLine(
          Offset(x, y - body * .45),
          Offset(x - body * .25, y),
          paint,
        );
        canvas.drawLine(
          Offset(x, y - body * .45),
          Offset(x + body * .25, y),
          paint,
        );
      }
    }
    canvas.drawPath(trail, paint);
  }

  @override
  bool shouldRepaint(covariant CameraTrailOverlay oldDelegate) =>
      points != oldDelegate.points || color != oldDelegate.color;
}
