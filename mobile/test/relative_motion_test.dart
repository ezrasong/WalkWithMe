import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaze/relative_motion.dart';
import 'package:kaze/relative_motion_camera.dart';
import 'package:kaze/session.dart';

void main() {
  final motion = {
    'available': true,
    'segments': [
      {
        'points': [
          {'x': 0, 'y': 0},
          {'x': 1, 'y': 2},
        ],
        'supported': true,
        'activity': {'status': 'consistent-activity'},
      },
    ],
    'driftBudgetMeters': 3.2,
  };
  testWidgets(
    'relative diagram labels unknown frame and uncalibrated drift without geographic placement',
    (t) async {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(body: RelativeMotionCard(motion: motion)),
        ),
      );
      expect(
        find.textContaining('Position, north, room and floor unknown'),
        findsOneWidget,
      );
      expect(find.textContaining('3.2 m'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(
        find.textContaining('No independent position correction'),
        findsOneWidget,
      );
    },
  );
  testWidgets('private motion is absent and contradictory motion is withheld', (
    t,
  ) async {
    await t.pumpWidget(
      const MaterialApp(home: RelativeMotionCard(motion: null)),
    );
    expect(find.textContaining('Pocket motion'), findsNothing);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RelativeMotionCard(
            motion: {
              ...motion,
              'segments': [
                {
                  'points': [
                    {'x': 0, 'y': 0},
                    {'x': 2, 'y': 1},
                  ],
                  'supported': false,
                  'activity': {'status': 'stationary-conflict'},
                },
              ],
            },
          ),
        ),
      ),
    );
    expect(find.textContaining('withheld from the diagram'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is RelativeMotionPainter,
      ),
      findsNothing,
    );
  });
  testWidgets(
    'camera without guardian authorization exposes no motion or camera',
    (t) async {
      final session = SessionController();
      addTearDown(session.dispose);
      await t.pumpWidget(
        MaterialApp(home: RelativeMotionCamera(session: session)),
      );
      await t.pump();
      expect(find.textContaining('Camera closed.'), findsOneWidget);
      expect(find.byType(RelativeMotionCard), findsNothing);
    },
  );
  testWidgets(
    'revocation while opening the camera cannot expose the retained diagram or initialize a camera',
    (t) async {
      final session = SessionController();
      addTearDown(session.dispose);
      session.access = SessionAccess(
        baseUrl: 'https://test.example',
        id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        token: 'guardian_012345678901234567890123456789012345',
        role: 'guardian',
      );
      session.received = DateTime.now();
      session.snapshot = {
        'phase': 'alert',
        'shared': true,
        'serverNow': DateTime.now().millisecondsSinceEpoch,
        'expiresAt': DateTime.now().millisecondsSinceEpoch + 3600000,
        'relativeMotion': motion,
      };
      final pending = Completer<List<Map<String, Object>>>();
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/camera');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'availableCameras') return pending.future;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await t.pumpWidget(
        MaterialApp(home: RelativeMotionCamera(session: session)),
      );
      await t.pump();
      session.snapshot = null;
      session.changed();
      pending.complete([
        {'name': 'back', 'lensFacing': 'back', 'sensorOrientation': 90},
      ]);
      await t.pump();
      await t.pump();
      expect(calls, contains('availableCameras'));
      expect(calls, isNot(contains('create')));
      expect(find.byType(RelativeMotionCard), findsNothing);
      expect(find.textContaining('Camera closed.'), findsOneWidget);
    },
  );
}
