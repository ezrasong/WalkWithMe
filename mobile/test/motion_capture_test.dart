import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaze/motion_capture.dart';
import 'package:kaze/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SessionController session;
  late List<String> calls;
  late Map? startOptions;
  late bool recording, available, automatic;
  SessionAccess access(String role) => SessionAccess(
    baseUrl: 'https://test.example',
    id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    token: 'owner_012345678901234567890123456789012345',
    role: role,
  );
  setUp(() {
    calls = [];
    startOptions = null;
    recording = false;
    available = false;
    automatic = false;
    session = SessionController();
    session.access = access('owner');
    session.received = DateTime.now();
    session.snapshot = {
      'phase': 'armed',
      'serverNow': DateTime.now().millisecondsSinceEpoch,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 3600000,
    };
    messenger.setMockMethodCallHandler(SessionController.native, (call) async {
      calls.add(call.method);
      if (call.method == 'startMotionCapture') {
        recording = true;
        startOptions = call.arguments as Map?;
      }
      if (call.method == 'stopMotionCapture') {
        recording = false;
        available = true;
      }
      if (call.method == 'deleteMotionCapture') available = false;
      if (call.method == 'motionStatus') {
        return {
          'recording': recording,
          'available': available,
          'automatic': automatic,
          'streaming': startOptions?['streaming'] ?? true,
          'cellular': startOptions?['cellular'] ?? true,
          'status': 'Local capture status',
        };
      }
      return null;
    });
  });
  tearDown(() {
    session.dispose();
    messenger.setMockMethodCallHandler(SessionController.native, null);
  });
  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: MotionCapturePage(session: session)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  }

  testWidgets('guardian cannot start or inspect wearer motion capture', (
    tester,
  ) async {
    session.access = access('guardian');
    await open(tester);
    expect(calls, isEmpty);
    await tester.tap(find.text('Start 3-minute capture'));
    await tester.pump();
    expect(calls, isEmpty);
    await close(tester);
  });
  testWidgets(
    'capture start and stop do not mutate session timing or request a camera',
    (tester) async {
      final snapshot = session.snapshot;
      await open(tester);
      await tester.tap(find.text('Start 3-minute capture'));
      await tester.pumpAndSettle();
      expect(calls, contains('startMotionCapture'));
      expect(recording, true);
      expect(startOptions, {'streaming': true, 'cellular': true});
      await tester.tap(find.text('Stop capture'));
      await tester.pumpAndSettle();
      expect(calls, contains('stopMotionCapture'));
      expect(session.snapshot, same(snapshot));
      expect(
        calls.every(
          (method) => [
            'motionStatus',
            'startMotionCapture',
            'stopMotionCapture',
          ].contains(method),
        ),
        true,
      );
      await close(tester);
    },
  );
  testWidgets(
    'existing capture requires explicit deletion confirmation before replacement',
    (tester) async {
      available = true;
      await open(tester);
      await tester.tap(find.text('Start 3-minute capture'));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('startMotionCapture')));
      await tester.tap(find.text('Delete local capture'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('deleteMotionCapture')));
      await tester.tap(find.text('Delete local capture'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(calls, contains('deleteMotionCapture'));
      await close(tester);
    },
  );
  testWidgets(
    'expired access disables capture and cannot use replacement credentials',
    (tester) async {
      await open(tester);
      calls.clear();
      session.access = access('owner');
      session.changed();
      await tester.pump();
      await tester.tap(find.text('Start 3-minute capture'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await close(tester);
    },
  );
  testWidgets('local-only capture sends no streaming or cellular consent', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('Evaluate a manual capture on the backend'));
    await tester.pumpAndSettle();
    expect(find.text('Allow cellular data'), findsNothing);
    await tester.tap(find.text('Start 3-minute capture'));
    await tester.pumpAndSettle();
    expect(startOptions, {'streaming': false, 'cellular': false});
    await close(tester);
  });
  testWidgets(
    'automatic streaming is shown as running and can be stopped for the session',
    (tester) async {
      automatic = true;
      recording = true;
      await open(tester);
      expect(find.text('Stop streaming for this session'), findsOneWidget);
      await tester.tap(find.text('Start 3-minute capture'));
      expect(calls, isNot(contains('startMotionCapture')));
      await tester.tap(find.text('Stop streaming for this session'));
      await tester.pumpAndSettle();
      expect(calls, contains('stopMotionCapture'));
      expect(recording, false);
      await close(tester);
    },
  );
}
