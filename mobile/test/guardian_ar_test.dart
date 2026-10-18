import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:camera/camera.dart';
import 'package:kaze/camera_trail_overlay.dart';
import 'package:kaze/guardian_ar.dart';
import 'package:kaze/session.dart';

// Simulated channel and service responses prove privacy and lifecycle gates.
// They do not prove native rendering, permissions or physical registration.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const cameraChannel = MethodChannel('plugins.flutter.io/camera');
  late List<String> cameraCalls;
  Future<void> cameraEvent(String method, Map<String, Object> args) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      'flutter.io/cameraPlugin/camera42',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) => done.complete(),
    );
    await done.future;
  }

  late SessionController session;
  late List<String> calls;
  late Map<String, dynamic> evidence;
  late String support;
  late int viewId, requests;
  late bool deny;
  late List<List> renders;
  late List<MethodCall> nativeCalls;
  SessionAccess access(String role) => SessionAccess(
    baseUrl: 'https://test.example',
    id: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
    token: 'guardian_012345678901234567890123456789012345',
    role: role,
  );
  void snapshot() {
    session.snapshot = {
      'phase': 'alert',
      'shared': true,
      'serverNow': DateTime.now().millisecondsSinceEpoch,
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 3600000,
    };
    session.received = DateTime.now();
  }

  setUp(() {
    calls = [];
    support = 'ready';
    viewId = -1;
    requests = 0;
    deny = false;
    renders = [];
    nativeCalls = [];
    cameraCalls = [];
    messenger.setMockMethodCallHandler(cameraChannel, (call) async {
      cameraCalls.add(call.method);
      if (call.method == 'availableCameras') {
        return [
          {'name': 'back', 'lensFacing': 'back', 'sensorOrientation': 90},
        ];
      }
      if (call.method == 'create') {
        expect(call.arguments['enableAudio'], false);
        return {'cameraId': 42};
      }
      if (call.method == 'initialize') {
        await cameraEvent('initialized', {
          'previewWidth': 640.0,
          'previewHeight': 480.0,
          'exposureMode': 'auto',
          'focusMode': 'auto',
          'exposurePointSupported': false,
          'focusPointSupported': false,
        });
      }
      return null;
    });
    evidence = {
      'version': 1,
      'available': true,
      'fallback': 'alignment-required',
      'latestFixAt': DateTime.now().millisecondsSinceEpoch,
      'frame': {
        'kind': 'WGS84-local-tangent',
        'units': 'meters',
        'axes': {'x': 'east', 'y': 'up', 'z': 'south'},
        'anchor': {
          'id': 'synthetic-anchor',
          'latitude': 0,
          'longitude': 0,
          'altitude': 100,
          'altitudeDatum': 'WGS84-ellipsoid',
        },
      },
      'paths': [
        {
          'source': 'phone',
          'points': [
            {'x': 0, 'y': 0, 'z': 0, 'altitudeDatum': 'WGS84-ellipsoid'},
          ],
        },
      ],
    };
    session = SessionController(
      client: MockClient((request) async {
        requests++;
        expect(request.url.path, endsWith('/ar'));
        expect(request.method, 'GET');
        expect(request.followRedirects, false);
        return http.Response(
          deny ? '{"error":"revoked"}' : jsonEncode(evidence),
          deny ? 401 : 200,
        );
      }),
    );
    session.access = access('guardian');
    snapshot();
    messenger.setMockMethodCallHandler(SessionController.native, (call) async {
      calls.add(call.method);
      nativeCalls.add(call);
      return support;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        viewId = call.arguments['id'] as int;
        messenger.setMockMethodCallHandler(
          MethodChannel('app.kaze/guardian-ar/$viewId'),
          (call) async {
            calls.add(call.method);
            nativeCalls.add(call);
            if (call.method == 'render') renders.add(call.arguments as List);
            return null;
          },
        );
      }
      return null;
    });
  });
  tearDown(() {
    session.dispose();
    messenger.setMockMethodCallHandler(SessionController.native, null);
    messenger.setMockMethodCallHandler(cameraChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    if (viewId >= 0) {
      messenger.setMockMethodCallHandler(
        MethodChannel('app.kaze/guardian-ar/$viewId'),
        null,
      );
    }
  });
  Future<void> open(
    WidgetTester tester, {
    bool demo = false,
    bool geospatial = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: GuardianAr(session: session, demo: demo, geospatial: geospatial),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> event(String method, [Object? args]) async {
    final done = Completer<void>();
    messenger.handlePlatformMessage(
      'app.kaze/guardian-ar/$viewId',
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
      (_) => done.complete(),
    );
    await done.future;
  }

  testWidgets(
    'Google alignment opts in, waits without directions, then renders and closes on precision loss',
    (tester) async {
      evidence['paths'] = [
        {
          'source': 'phone',
          'points': [
            {
              'id': 'next',
              'x': 15,
              'z': 0,
              'y': null,
              'horizontalAccuracy': 1,
              'relativeHorizontalUncertainty': 2,
            },
          ],
        },
      ];
      await open(tester, geospatial: true);
      expect(nativeCalls.firstWhere((c) => c.method == 'start').arguments, {
        'geospatial': true,
      });
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(calls, isNot(contains('stop')));
      expect(find.textContaining('Finding your direction'), findsWidgets);
      final sample = {
        't': 100.0,
        'x': 0.0,
        'y': 1.5,
        'z': 0.0,
        'latitude': 0.0,
        'longitude': 0.0,
        'accuracy': 1.0,
        'ageMs': 0.0,
        'mock': false,
        'yaw': 0.0,
        'yawAccuracy': 2.0,
      };
      await event('geospatial', sample);
      await event('pose', {
        'x': 0.0,
        'z': 0.0,
        'forwardX': 1.0,
        'forwardZ': 0.0,
      });
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(renders.last, hasLength(1));
      expect(renders.last.single['heightMode'], 'horizontal');
      expect(find.textContaining('Continue ahead'), findsWidgets);
      await event('geospatial', {...sample, 't': 101.0, 'yawAccuracy': 11.0});
      await tester.pumpAndSettle();
      expect(calls, contains('stop'));
      expect(
        find.textContaining('Google alignment precision lost'),
        findsOneWidget,
      );
      await close(tester);
    },
  );

  testWidgets(
    'unsupported AR opens a labeled camera animation, plays locally and stops on camera failure',
    (tester) async {
      support = 'demo-camera';
      session.access = null;
      session.snapshot = null;
      await open(tester, demo: true);
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(find.text('DEMO: Simulated placement'), findsOneWidget);
      expect(
        find.textContaining('does not track phone movement'),
        findsOneWidget,
      );
      expect(calls, isNot(contains('start')));
      expect(viewId, -1);
      expect(requests, 0);
      CameraTrailOverlay overlay() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<CameraTrailOverlay>()
          .single;
      final initial = overlay().points.last['z'] as double;
      await tester.ensureVisible(find.text('Start demo'));
      await tester.tap(find.text('Start demo'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(overlay().points.last['z'] as double, lessThan(initial));
      expect(cameraCalls, isNot(contains('startVideoRecording')));
      expect(cameraCalls, isNot(contains('takePicture')));
      expect(requests, 0);
      await cameraEvent('error', {'description': 'synthetic camera failure'});
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsNothing);
      expect(find.textContaining('Demo camera unavailable'), findsOneWidget);
      expect(cameraCalls, contains('dispose'));
      await close(tester);
    },
  );

  testWidgets('fallback camera permission failure keeps playback closed', (
    tester,
  ) async {
    support = 'demo-camera';
    messenger.setMockMethodCallHandler(cameraChannel, (call) async {
      if (call.method == 'availableCameras') {
        return [
          {'name': 'back', 'lensFacing': 'back', 'sensorOrientation': 90},
        ];
      }
      if (call.method == 'create') {
        throw PlatformException(code: 'CameraAccessDenied');
      }
      return null;
    });
    await open(tester, demo: true);
    expect(find.byType(CameraPreview), findsNothing);
    expect(find.textContaining('camera access unavailable'), findsOneWidget);
    expect(requests, 0);
    await close(tester);
  });

  testWidgets(
    'backgrounding during fallback camera discovery prevents initialization',
    (tester) async {
      support = 'demo-camera';
      final pending = Completer<List<Map<String, Object>>>();
      messenger.setMockMethodCallHandler(cameraChannel, (call) async {
        cameraCalls.add(call.method);
        return pending.future;
      });
      await open(tester, demo: true);
      session.setVisible(false);
      pending.complete([
        {'name': 'back', 'lensFacing': 'back', 'sensorOrientation': 90},
      ]);
      await tester.pumpAndSettle();
      expect(cameraCalls, ['availableCameras']);
      expect(find.byType(CameraPreview), findsNothing);
      await close(tester);
    },
  );

  testWidgets(
    'wearer or unshared access never requests native camera permission',
    (tester) async {
      session.access = access('owner');
      await open(tester);
      expect(calls, isEmpty);
      expect(requests, 0);
      await close(tester);
    },
  );
  testWidgets(
    'local demo plays, pauses and restarts without a session, GPS sample or server request',
    (tester) async {
      session.access = null;
      session.snapshot = null;
      await open(tester, demo: true);
      expect(requests, 0);
      expect(
        nativeCalls
            .where(
              (call) => ['prepareGuardianAr', 'start'].contains(call.method),
            )
            .every((call) => call.arguments['demo'] == true),
        true,
      );
      expect(find.text('DEMO: Virtual wearer'), findsOneWidget);
      expect(renders, isEmpty);
      await event('pose', {
        'x': 0.0,
        'y': 1.5,
        'z': 0.0,
        'forwardX': 0.0,
        'forwardZ': -1.0,
      });
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      final start = renders.last.last['z'] as double;
      await tester.ensureVisible(find.text('Start demo'));
      await tester.tap(find.text('Start demo'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
      }
      final moved = renders.last.last['z'] as double;
      expect(moved, lessThan(start));
      expect(renders.last.every((p) => p['source'] == 'demo'), true);
      await tester.tap(find.text('Pause demo'));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(renders.last.last['z'], moved);
      await tester.tap(find.text('Restart demo'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(renders.last.last['z'] as double, greaterThan(moved));
      expect(requests, 0);
      expect(session.snapshot, isNull);
      expect(session.access, isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(calls, contains('stop'));
      expect(find.byType(UiKitView), findsNothing);
      expect(
        find.text('No demo positions were saved or shared.'),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await close(tester);
    },
  );
  testWidgets('demo camera refusal leaves real session evidence unchanged', (
    tester,
  ) async {
    support = 'End wearer recording before using a guardian camera.';
    final original = jsonEncode(session.snapshot);
    await open(tester, demo: true);
    expect(viewId, -1);
    expect(find.textContaining('End wearer recording'), findsWidgets);
    expect(jsonEncode(session.snapshot), original);
    expect(requests, 0);
    await close(tester);
  });
  testWidgets(
    'demo waits for camera tracking and times out without requesting geographic evidence',
    (tester) async {
      await open(tester, demo: true);
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(calls, contains('stop'));
      expect(find.textContaining('Camera tracking unavailable'), findsWidgets);
      expect(requests, 0);
      await close(tester);
    },
  );
  testWidgets('unsupported AR and denied permission expose a map fallback', (
    tester,
  ) async {
    support = 'Camera permission denied. Use the map.';
    await open(tester);
    expect(calls, ['prepareGuardianAr']);
    expect(viewId, -1);
    expect(find.textContaining('Camera permission denied'), findsWidgets);
    expect(
      find.text('Camera permission denied. Use the map.').hitTestable(),
      findsOneWidget,
    );
    expect(
      find.text('AR closed. Recorded locations remain on the map.'),
      findsNothing,
    );
    expect(find.textContaining('supported breadcrumbs'), findsNothing);
    await close(tester);
  });
  testWidgets('stale wearer evidence prevents even opening native camera', (
    tester,
  ) async {
    evidence['fallback'] = 'map';
    await open(tester);
    expect(calls, isEmpty);
    expect(viewId, -1);
    await close(tester);
  });
  testWidgets('legacy heights open a horizontal trail camera session', (
    tester,
  ) async {
    (evidence['frame']['anchor'] as Map).remove('altitudeDatum');
    await open(tester);
    expect(calls, contains('start'));
    expect(find.textContaining('floating horizontal guide'), findsOneWidget);
    expect(find.textContaining('compatible vertical reference'), findsNothing);
    await close(tester);
  });
  testWidgets(
    'legacy trail renders after alignment and camera turns update live guidance',
    (tester) async {
      (evidence['frame']['anchor'] as Map).remove('altitudeDatum');
      evidence['paths'] = [
        {
          'source': 'phone',
          'points': [
            {
              'id': 'next',
              'x': 45,
              'z': 0,
              'y': null,
              'horizontalAccuracy': 1,
              'relativeHorizontalUncertainty': 2,
            },
            {
              'id': 'later',
              'x': 50,
              'z': 0,
              'y': null,
              'horizontalAccuracy': 1,
              'relativeHorizontalUncertainty': 2,
            },
          ],
        },
      ];
      await open(tester);
      for (var i = 0; i <= 36; i++) {
        evidence['latestFixAt'] = session.serverNow;
        await event('sample', {
          't': 100.0 + i,
          'x': i.toDouble(),
          'y': 1.5,
          'z': 0.0,
          'latitude': 0.0,
          'longitude': i / 111319.490793,
          'accuracy': 1.0,
          'ageMs': 50.0,
          'mock': false,
        });
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
      }
      expect(renders.last, hasLength(2));
      expect(renders.last.first['heightMode'], 'horizontal');
      expect(renders.last.first['verticalUncertainty'], 0);
      expect(renders.last.first['segment'], renders.last.last['segment']);
      await event('pose', {
        'x': 36.0,
        'z': 0.0,
        'forwardX': 0.0,
        'forwardZ': -1.0,
      });
      await tester.pump();
      expect(find.textContaining('9 m - Turn right'), findsWidgets);
      await event('pose', {
        'x': 36.0,
        'z': 0.0,
        'forwardX': 1.0,
        'forwardZ': 0.0,
      });
      await tester.pump();
      expect(find.textContaining('Continue ahead'), findsWidgets);
      session.snapshot = null;
      session.changed();
      await tester.pumpAndSettle();
      expect(find.textContaining('Continue ahead'), findsNothing);
      expect(calls, contains('stop'));
      await close(tester);
    },
  );
  testWidgets(
    'native failure reason is visible and logged without private evidence',
    (tester) async {
      final originalPrint = debugPrint;
      final diagnostics = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) diagnostics.add(message);
      };
      try {
        await open(tester);
        const reason = 'ARKit camera tracking lost. Reopen AR from the map.';
        await event('failure', reason);
        await tester.pumpAndSettle();
        expect(find.text(reason).hitTestable(), findsOneWidget);
        expect(calls, contains('stop'));
        expect(diagnostics.first, '[KAZE AR] Opening guardian spatial AR.');
        expect(diagnostics.last, '[KAZE AR] Closed: $reason');
        final log = diagnostics.join('\n');
        for (final privateValue in [
          session.access!.token,
          session.access!.id,
          session.access!.baseUrl,
          'synthetic-anchor',
          'latitude',
          'longitude',
        ]) {
          expect(log, isNot(contains(privateValue)));
        }
        await close(tester);
      } finally {
        debugPrint = originalPrint;
      }
    },
  );
  testWidgets(
    'access lost during permission request cannot start native tracking',
    (tester) async {
      final permission = Completer<String>();
      messenger.setMockMethodCallHandler(
        SessionController.native,
        (_) => permission.future,
      );
      await open(tester);
      session.snapshot = null;
      session.changed();
      permission.complete('ready');
      await tester.pumpAndSettle();
      expect(viewId, -1);
      expect(calls, isNot(contains('start')));
      await close(tester);
    },
  );
  testWidgets(
    'spatial screen and map fallback fit small screens at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      support = 'Camera permission denied. Use the map.';
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2.5)),
            child: child!,
          ),
          home: GuardianAr(session: session),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.text('Camera permission denied. Use the map.').hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Return to map'));
      expect(tester.takeException(), isNull);
      await close(tester);
    },
  );
  testWidgets(
    'authorization loss stops the native session and clears the view',
    (tester) async {
      await open(tester);
      expect(calls, contains('start'));
      session.snapshot = null;
      session.changed();
      await tester.pumpAndSettle();
      expect(calls, contains('stop'));
      expect(find.byType(UiKitView), findsNothing);
      await close(tester);
    },
  );
  testWidgets('late changed anchor requires a new camera session', (
    tester,
  ) async {
    await open(tester);
    evidence['frame']['anchor']['id'] = 'late-earlier-fix';
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(calls, contains('stop'));
    expect(find.textContaining('Recorded frame changed'), findsWidgets);
    await close(tester);
  });
  testWidgets(
    'AR endpoint revocation closes immediately without mutating the incident',
    (tester) async {
      await open(tester);
      deny = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(calls, contains('stop'));
      expect(session.snapshot?['phase'], 'alert');
      await close(tester);
    },
  );
  testWidgets('native tracking loss and app backgrounding close the camera', (
    tester,
  ) async {
    await open(tester);
    await event('failure');
    await tester.pumpAndSettle();
    expect(calls, contains('stop'));
    await close(tester);
    calls.clear();
    await open(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(calls, contains('stop'));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await close(tester);
  });
  testWidgets(
    'startup without synchronized precise location times out to map',
    (tester) async {
      await open(tester);
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(calls, contains('stop'));
      expect(find.textContaining('synchronized outdoor'), findsWidgets);
      await close(tester);
    },
  );
  testWidgets(
    'switching credentials cannot retain an old camera registration',
    (tester) async {
      await open(tester);
      session.access = access('guardian');
      session.changed();
      await tester.pumpAndSettle();
      expect(calls, contains('stop'));
      await close(tester);
    },
  );
}
