import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kaze/guardian_ar.dart';
import 'package:kaze/session.dart';

// Simulated channel and service responses prove privacy and lifecycle gates.
// They do not prove native rendering, permissions or physical registration.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SessionController session;
  late List<String> calls;
  late Map<String, dynamic> evidence;
  late String support;
  late int viewId, requests;
  late bool deny;
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
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    if (viewId >= 0) {
      messenger.setMockMethodCallHandler(
        MethodChannel('app.kaze/guardian-ar/$viewId'),
        null,
      );
    }
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: GuardianAr(session: session)));
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
    'wearer or unshared access never requests native camera permission',
    (tester) async {
      session.access = access('owner');
      await open(tester);
      expect(calls, isEmpty);
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
  testWidgets('legacy heights cannot open a spatial camera session', (
    tester,
  ) async {
    (evidence['frame']['anchor'] as Map).remove('altitudeDatum');
    await open(tester);
    expect(calls, isEmpty);
    expect(find.textContaining('compatible vertical reference'), findsWidgets);
    await close(tester);
  });
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
