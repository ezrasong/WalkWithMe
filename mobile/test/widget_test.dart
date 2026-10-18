import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kaze/main.dart';
import 'package:kaze/session.dart';
import 'package:kaze/backend.dart';
import 'package:kaze/guardian_ar.dart';
import 'package:kaze/direction_preview.dart';

const id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const token = 'guardian_012345678901234567890123456789012345';
SessionAccess guardian() => SessionAccess(
  baseUrl: 'https://test.example',
  id: id,
  token: token,
  role: 'guardian',
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SessionController.native,
          (call) async =>
              call.method == 'guardianStatus' ? {'enabled': false} : null,
        );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SessionController.native, null),
  );
  test(
    'guardian invitations cannot redirect access to a different service',
    () async {
      var requests = 0;
      final c = SessionController(
        client: MockClient((request) async {
          requests++;
          expect(request.url.origin, Uri.parse(kazeBackendUrl).origin);
          expect(request.followRedirects, false);
          return http.Response(
            '{"role":"guardian","phase":"armed","shared":false,"serverNow":1000,"expiresAt":10000}',
            200,
          );
        }),
      );
      addTearDown(c.dispose);
      await c.join('https://other.example/guardian#session=$id&token=$token');
      expect(requests, 0);
      expect(c.access, isNull);
      expect(c.message, contains('different WalkWithMe service'));
      await c.join('$kazeBackendUrl/guardian#session=$id&token=$token');
      expect(requests, greaterThan(0));
      expect(c.access?.role, 'guardian');
    },
  );
  test(
    'shared demo creation and controls never start physical wearer recording',
    () async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SessionController.native, (call) async {
            calls.add(call.method);
            return call.method == 'status' ? {'active': false} : null;
          });
      final bodies = <Map>[];
      final controller = SessionController(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          bodies.add(body);
          if (request.url.path == '/api/sessions') {
            return http.Response(
              jsonEncode({
                'id': id,
                'ownerToken': token,
                'guardianToken': token,
                'watchToken': token,
                'phase': 'armed',
                'sensorMode': 'simulated',
                'serverNow': 1000,
              }),
              201,
            );
          }
          expect(request.url.path, '/api/sessions/$id/demo-walk');
          return http.Response(
            jsonEncode({
              'id': id,
              'phase': 'armed',
              'sensorMode': 'simulated',
              'serverNow': 1000,
              'demoWalk': {'running': body['command'] != 'pause'},
            }),
            200,
          );
        }),
      );
      addTearDown(controller.dispose);
      await controller.createSharedDemo([
        {'latitude': 0, 'longitude': 0},
        {'latitude': .001, 'longitude': 0},
      ]);
      expect(controller.access?.role, 'owner');
      expect(controller.snapshot?['demoWalk']?['running'], true);
      expect(bodies[0]['sensorMode'], 'simulated');
      expect(bodies[0]['liveSharingConsent'], true);
      expect(bodies[1]['command'], 'start');
      await controller.controlDemo('pause');
      expect(controller.snapshot?['demoWalk']?['running'], false);
      await controller.controlDemo('begin-take');
      expect(bodies.last['command'], 'begin-take');
      expect(bodies.last['confirm'], true);
      expect(calls, isNot(contains('start')));
      expect(calls, isNot(contains('permissions')));
    },
  );
  test(
    'guardian links preserve scoped credentials and reject unsafe origins',
    () {
      final a = SessionAccess.guardian(
        'https://test.example/guardian#session=$id&token=$token',
      );
      expect(a.baseUrl, 'https://test.example');
      expect(a.token, token);
      expect(a.role, 'guardian');
      for (final url in [
        'http://public.example',
        'https://user:pass@test.example',
        'https://test.example/path',
        'http://192.168.evil.example',
        'https://test.example#secret',
      ]) {
        expect(() => validateBaseUrl(url), throwsFormatException);
      }
      expect(
        () => validateBaseUrl('http://127.0.0.1:4174', allowLocalHttp: false),
        throwsFormatException,
      );
      expect(
        validateBaseUrl('http://192.168.2.10:4174', allowLocalHttp: true),
        'http://192.168.2.10:4174',
      );
    },
  );
  test(
    'authorized guardian data is cleared on revocation and offline failure',
    () async {
      var status = 200;
      final c = SessionController(
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer $token');
          expect(request.followRedirects, false);
          return http.Response(
            jsonEncode(
              status == 200
                  ? {
                      'shared': true,
                      'phase': 'alert',
                      'serverNow': 1000,
                      'expiresAt': 10000,
                      'geography': {
                        'latest': {'latitude': 43},
                      },
                    }
                  : {'error': 'revoked'},
            ),
            status,
          );
        }),
      );
      addTearDown(c.dispose);
      c.access = guardian();
      await c.refresh();
      expect(c.snapshot?['shared'], true);
      status = 503;
      await c.refresh();
      expect(c.snapshot, isNull);
      expect(c.access, isNotNull);
      status = 401;
      await c.refresh();
      expect(c.access, isNull);
      expect(c.snapshot, isNull);
      expect(c.message, contains('revoked'));
    },
  );
  test('a rejected check-in cannot show a server confirmation', () async {
    final c = SessionController(
      client: MockClient(
        (_) async => http.Response('{"error":"alert remains active"}', 409),
      ),
    );
    addTearDown(c.dispose);
    c.access = guardian();
    await c.mutate('check-in');
    expect(c.message, contains('alert remains active'));
    expect(c.message, isNot(contains('confirmed by server')));
  });
  test(
    'an earlier in-flight read cannot undo an accepted end-session response',
    () async {
      final old = Completer<http.Response>();
      final c = SessionController(
        client: MockClient(
          (r) async => r.method == 'GET'
              ? old.future
              : http.Response(
                  '{"phase":"resolved","shared":true,"serverNow":1000}',
                  200,
                ),
        ),
      );
      addTearDown(c.dispose);
      c.access = SessionAccess(
        baseUrl: 'https://test.example',
        id: id,
        token: token,
        role: 'owner',
      );
      final read = c.refresh();
      await c.mutate('resolve');
      old.complete(
        http.Response('{"phase":"alert","shared":true,"serverNow":1000}', 200),
      );
      await read;
      expect(c.snapshot?['phase'], 'resolved');
    },
  );
  test('backgrounding the guardian hides cached evidence', () {
    final c = SessionController();
    addTearDown(c.dispose);
    c.access = guardian();
    c.snapshot = {'shared': true};
    c.setVisible(false);
    expect(c.snapshot, isNull);
  });
  testWidgets(
    'native Flutter map handles missing location without invented markers',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrailMap(
              snapshot: {
                'id': id,
                'shared': true,
                'geography': {'latest': null, 'paths': []},
              },
              tiles: false,
            ),
          ),
        ),
      );
      expect(find.textContaining('No location received'), findsOneWidget);
      expect(find.byIcon(Icons.person_pin_circle), findsNothing);
    },
  );
  testWidgets(
    'demo mode defaults off and its settings choice survives reopening',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({'deviceSetupSeenV1': 'true'});
      await tester.pumpWidget(const MaterialApp(home: SessionScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Start shared walk'), findsNothing);
      expect(find.text('Try guardian camera demo'), findsNothing);
      await tester.ensureVisible(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Try guardian camera demo'), findsOneWidget);
      expect(
        await const FlutterSecureStorage().read(key: 'showDemoControls'),
        'true',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const MaterialApp(home: SessionScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Start shared walk'), findsOneWidget);
      await tester.ensureVisible(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Start shared walk'), findsNothing);
      expect(find.text('Try guardian camera demo'), findsNothing);
      expect(
        await const FlutterSecureStorage().read(key: 'showDemoControls'),
        'false',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const MaterialApp(home: SessionScreen()));
      await tester.pumpAndSettle();
      expect(find.text('Start shared walk'), findsNothing);
      expect(
        find.textContaining('Indoor tracking is not working'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  Map<String, dynamic> sessionSnapshot({bool simulated = false}) => {
    'id': id,
    'name': simulated ? 'Simulated walker' : 'Real wearer',
    'sensorMode': simulated ? 'simulated' : 'device',
    'phase': 'armed',
    'shared': true,
    'serverNow': DateTime.now().millisecondsSinceEpoch,
    'dueAt': DateTime.now().millisecondsSinceEpoch + 60000,
    'expiresAt': DateTime.now().millisecondsSinceEpoch + 3600000,
    'intervalSeconds': 120,
    'graceSeconds': 30,
    'geography': {'latest': null, 'paths': []},
    if (simulated)
      'demoWalk': {'distance': 10, 'total': 50, 'running': false, 'speed': 1},
  };

  test('demo off stops simulated guardian alerts without ending or changing its session', () async {
    var monitoring = false;
    var starts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SessionController.native, (call) async {
          if (call.method == 'startGuardian') {
            monitoring = true;
            starts++;
          }
          if (call.method == 'stopGuardian') monitoring = false;
          return call.method == 'guardianStatus'
              ? {'enabled': monitoring}
              : null;
        });
    final c = SessionController();
    addTearDown(c.dispose);
    c.access = guardian();
    final data = sessionSnapshot(simulated: true);
    c.snapshot = data;
    await c.setDemoMode(true);
    await c.setGuardianMonitoring(true);
    expect(monitoring, isTrue);
    await c.setDemoMode(false);
    expect(monitoring, isFalse);
    expect(c.snapshot, same(data));
    expect(c.access?.role, 'guardian');
    await c.setGuardianMonitoring(true);
    expect(starts, 1);
    expect(c.message, contains('Enable demo mode'));
  });

  test('demo off preserves live guardian alerts and access', () async {
    var stops = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SessionController.native, (call) async {
          if (call.method == 'stopGuardian') stops++;
          return call.method == 'guardianStatus' ? {'enabled': true} : null;
        });
    final c = SessionController();
    addTearDown(c.dispose);
    c.access = guardian();
    final data = sessionSnapshot();
    c.snapshot = data;
    await c.setDemoMode(true);
    await c.setGuardianMonitoring(true);
    await c.setDemoMode(false);
    expect(stops, 0);
    expect(c.snapshot, same(data));
    expect(c.device['enabled'], isTrue);
    expect(c.access?.role, 'guardian');
  });

  testWidgets(
    'guardian can open standalone demo without changing live access, and disabling closes it',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'deviceSetupSeenV1': 'true',
        'showDemoControls': 'true',
      });
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SessionController.native, (call) async {
            calls.add(call.method);
            if (call.method == 'prepareGuardianAr') {
              expect(call.arguments, {'demo': true});
              return 'Camera permission denied. Use the map.';
            }
            return call.method == 'guardianStatus' ? {'enabled': false} : null;
          });
      await tester.pumpWidget(const MaterialApp(home: SessionScreen()));
      await tester.pumpAndSettle();
      final dynamic screen = tester.state(find.byType(SessionScreen));
      final c = screen.c as SessionController;
      c.timer?.cancel();
      final access = guardian();
      c.access = access;
      c.snapshot = sessionSnapshot();
      c.received = DateTime.now();
      screen.tab = 2;
      c.changed();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Try guardian camera demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try guardian camera demo'));
      await tester.pumpAndSettle();
      expect(find.byType(GuardianAr), findsOneWidget);
      expect(calls, contains('prepareGuardianAr'));
      expect(c.access, same(access));
      expect(c.snapshot?['phase'], 'armed');
      screen.setDemoControls(false);
      await tester.pumpAndSettle();
      expect(find.byType(GuardianAr), findsNothing);
      expect(find.text('Try guardian camera demo'), findsNothing);
      expect(c.access, same(access));
      expect(c.snapshot?['sensorMode'], 'device');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'shared guardian camera is available before alert and demo off hides its data and controls',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'deviceSetupSeenV1': 'true',
        'showDemoControls': 'true',
      });
      await tester.pumpWidget(const MaterialApp(home: SessionScreen()));
      await tester.pumpAndSettle();
      final dynamic screen = tester.state(find.byType(SessionScreen));
      final c = screen.c as SessionController;
      c.timer?.cancel();
      c.access = guardian();
      c.snapshot = sessionSnapshot(simulated: true);
      c.received = DateTime.now();
      c.changed();
      await tester.pumpAndSettle();
      expect(find.text('Open shared walk camera'), findsOneWidget);
      await tester.tap(find.text('Open shared walk camera'));
      await tester.pumpAndSettle();
      expect(find.byType(DirectionPreview), findsOneWidget);
      screen.setDemoControls(false);
      await tester.pumpAndSettle();
      expect(find.byType(DirectionPreview), findsNothing);
      expect(find.text('No live session to display.'), findsOneWidget);
      expect(find.byType(TrailMap), findsNothing);
      expect(find.text('Open shared walk camera'), findsNothing);
      expect(find.text('Start 40-second alert take'), findsNothing);
      expect(find.text('Track shared trail in camera'), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(c.snapshot?['sensorMode'], 'simulated');
      screen.setDemoControls(true);
      await tester.pumpAndSettle();
      expect(find.text('Open shared walk camera'), findsOneWidget);
      expect(find.text('Start 40-second alert take'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
