import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaze/direction_preview.dart';
import 'package:kaze/session.dart';

// Platform responses are simulated: these prove fallback/access behavior, not
// physical permission prompts, camera alignment or compass accuracy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const geo = MethodChannel('flutter.baseflow.com/geolocator');
  const camera = MethodChannel('plugins.flutter.io/camera');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SessionController session;
  late List<String> calls;

  setUp(() {
    calls = [];
    session = SessionController();
    session.access = SessionAccess(
      baseUrl: 'https://test.example',
      id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      token: 'guardian_012345678901234567890123456789012345',
      role: 'guardian',
    );
    session.snapshot = {'phase': 'alert', 'shared': true};
    messenger.setMockMethodCallHandler(geo, (call) async {
      calls.add('location:${call.method}');
      return 2; // while in use
    });
    messenger.setMockMethodCallHandler(camera, (call) async {
      calls.add('camera:${call.method}');
      return <Map<String, Object>>[];
    });
  });
  tearDown(() {
    session.dispose();
    messenger.setMockMethodCallHandler(geo, null);
    messenger.setMockMethodCallHandler(camera, null);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: DirectionPreview(session: session)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    expect(find.byType(CameraPreview), findsNothing);
    expect(find.textContaining('Use the map:'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('an unshared session never requests camera or location', (
    tester,
  ) async {
    session.snapshot = {'phase': 'armed', 'shared': false};
    await open(tester);
    expect(calls, isEmpty);
    expect(find.textContaining('authorized active assistance'), findsOneWidget);
    await close(tester);
  });

  testWidgets('denied location leaves the camera closed and offers the map', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(geo, (call) async {
      calls.add('location:${call.method}');
      return call.method == 'checkPermission' ? 0 : 1;
    });
    await open(tester);
    expect(calls, ['location:checkPermission', 'location:requestPermission']);
    expect(find.textContaining('Location permission denied'), findsOneWidget);
    await close(tester);
  });

  testWidgets('absent camera leaves the server alert unchanged', (
    tester,
  ) async {
    await open(tester);
    expect(find.textContaining('Camera unavailable'), findsOneWidget);
    expect(session.snapshot?['phase'], 'alert');
    await close(tester);
  });

  testWidgets(
    'camera permission failure is visible without a preview or capture',
    (tester) async {
      messenger.setMockMethodCallHandler(camera, (call) async {
        calls.add('camera:${call.method}');
        if (call.method == 'availableCameras') {
          return [
            {'name': 'back', 'lensFacing': 'back', 'sensorOrientation': 90},
          ];
        }
        if (call.method == 'create') {
          expect(call.arguments['enableAudio'], false);
          throw PlatformException(
            code: 'CameraAccessDenied',
            message: 'Camera permission denied',
          );
        }
        return null;
      });
      await open(tester);
      expect(find.textContaining('CameraAccessDenied'), findsOneWidget);
      expect(calls, isNot(contains('camera:startVideoRecording')));
      expect(calls, isNot(contains('camera:takePicture')));
      expect(session.snapshot?['phase'], 'alert');
      await close(tester);
    },
  );

  testWidgets(
    'authorization loss while permission is pending cannot open a camera',
    (tester) async {
      final permission = Completer<int>();
      messenger.setMockMethodCallHandler(geo, (_) => permission.future);
      await open(tester);
      session.setVisible(false);
      permission.complete(2);
      await tester.pumpAndSettle();
      expect(session.snapshot, isNull);
      expect(calls, isEmpty);
      expect(find.textContaining('Access unavailable'), findsOneWidget);
      await close(tester);
    },
  );
}
