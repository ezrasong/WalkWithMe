import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kaze/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  const registration = 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee';
  const token = 'guardian_012345678901234567890123456789012345';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late SessionController c;
  late List<MethodCall> calls;
  late List<http.Request> requests;
  late Map<String, dynamic> state;
  late Map<String, dynamic> session;
  var status = 200;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    FlutterSecureStorage.setMockInitialValues({});
    calls = [];
    requests = [];
    status = 200;
    state = {
      'enabled': false,
      'pushAvailable': false,
      'sessionId': id,
      'registrationId': registration,
    };
    session = {
      'id': id,
      'role': 'guardian',
      'phase': 'armed',
      'serverNow': 1000,
      'dueAt': 6000,
      'graceSeconds': 3,
      'expiresAt': 20000,
    };
    messenger.setMockMethodCallHandler(SessionController.native, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'guardianStatus':
          return Map<String, dynamic>.from(state);
        case 'startGuardian':
          state['enabled'] = true;
        case 'stopGuardian':
          state['enabled'] = false;
        case 'guardianPushPending':
          state['pushPending'] = true;
        case 'guardianPushRegistered':
          state['pushRegistered'] = true;
          state['pushPending'] = false;
        case 'clearGuardianPush':
          state.clear();
        case 'guardianPushRegistration':
          return {
            'registrationId': registration,
            'deviceToken': 'a' * 64,
            'environment': 'development',
          };
      }
      return null;
    });
    c = SessionController(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/guardian-push')) {
          return http.Response(
            jsonEncode(
              status == 200
                  ? {'registered': request.method == 'POST'}
                  : {
                      'error': 'Apple push is not configured. Local reminders remain available.',
                    },
            ),
            status,
          );
        }
        return http.Response(jsonEncode(session), 200);
      }),
    );
    c.access = SessionAccess(
      baseUrl: 'https://test.example',
      id: id,
      token: token,
      role: 'guardian',
    );
    c.snapshot = session;
    c.received = DateTime.now();
  });
  tearDown(() {
    c.dispose();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(SessionController.native, null);
  });

  test('free-account mode schedules review reminders without sending an Apple device token to the server', () async {
    await c.setGuardianMonitoring(true);
    expect(requests, isEmpty);
    expect(c.device['enabled'], true);
    expect(
      calls.any((call) => call.method == 'guardianPushRegistration'),
      false,
    );
    final raw =
        calls.firstWhere((call) => call.method == 'startGuardian').arguments
            as String;
    expect(raw.contains(token), false);
    expect(jsonDecode(raw)['dueAt'], 6000);
    c.setVisible(false);
    expect(c.snapshot, isNull);
    expect(calls.any((call) => call.method == 'stopGuardian'), false);
  });
  test('foreground refresh reschedules from confirmed check-ins and forwards acknowledgment for cancellation', () async {
    await c.setGuardianMonitoring(true);
    calls.clear();
    session = {...session, 'dueAt': 12000, 'acknowledgedAt': 2000};
    await c.refresh();
    final data =
        calls.firstWhere((call) => call.method == 'updateGuardian').arguments
            as Map;
    expect(data['dueAt'], 12000);
    expect(data['acknowledged'], true);
    expect(data.containsKey('guardianToken'), false);
  });
  test('Apple mode registers with guardian authorization before reporting push registered', () async {
    state['pushAvailable'] = true;
    await c.setGuardianMonitoring(true);
    expect(requests, hasLength(1));
    expect(requests.single.headers['Authorization'], 'Bearer $token');
    expect(jsonDecode(requests.single.body), {
      'registrationId': registration,
      'deviceToken': 'a' * 64,
      'environment': 'development',
    });
    expect(c.device['pushRegistered'], true);
    expect(
      calls.indexWhere((call) => call.method == 'guardianPushPending'),
      lessThan(
        calls.indexWhere((call) => call.method == 'guardianPushRegistered'),
      ),
    );
  });
  test('server setup failure retains local reminders and cleanup metadata without claiming push works', () async {
    state['pushAvailable'] = true;
    status = 503;
    await c.setGuardianMonitoring(true);
    expect(state['enabled'], true);
    expect(state['pushPending'], true);
    expect(state['pushRegistered'], isNot(true));
    expect(calls.any((call) => call.method == 'guardianPushRegistered'), false);
    expect(c.message, contains('not configured'));
  });
  test('forget stops local reminders and removes remote registration before clearing access', () async {
    state['enabled'] = true;
    state['pushRegistered'] = true;
    await c.forget();
    expect(requests.single.method, 'DELETE');
    expect(jsonDecode(requests.single.body), {'registrationId': registration});
    expect(c.access, isNull);
    expect(state, isEmpty);
    expect(calls.map((call) => call.method), [
      'guardianStatus',
      'stopGuardian',
      'clearGuardianPush',
    ]);
  });
  test(
    'failed deregistration stops local reminders but retains access for retry',
    () async {
      state['enabled'] = true;
      state['pushPending'] = true;
      status = 503;
      await c.forget();
      expect(state['enabled'], false);
      expect(state['pushPending'], true);
      expect(c.access, isNotNull);
      expect(calls.any((call) => call.method == 'clearGuardianPush'), false);
    },
  );
}
