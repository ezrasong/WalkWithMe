import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kaze/session.dart';

const id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const token = 'guardian_012345678901234567890123456789012345';
SessionAccess access() => SessionAccess(
  baseUrl: 'https://test.example',
  id: id,
  token: token,
  role: 'guardian',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late SessionController c;
  late Map<String, dynamic> nativeStatus;
  var status = 200;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterSecureStorage.setMockInitialValues({});
    status = 200;
    calls = [];
    nativeStatus = {
      'enabled': true,
      'running': true,
      'sessionId': id,
      'status': 'Monitoring',
    };
    messenger.setMockMethodCallHandler(SessionController.native, (call) async {
      calls.add(call);
      return call.method == 'guardianStatus' ? nativeStatus : null;
    });
    c = SessionController(
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            status == 200
                ? {
                    'id': id,
                    'role': 'guardian',
                    'phase': 'armed',
                    'serverNow': 1000,
                    'expiresAt': 100000,
                  }
                : {'error': 'Access revoked'},
          ),
          status,
        ),
      ),
    );
    c.access = access();
    c.snapshot = {'phase': 'armed'};
  });
  tearDown(() {
    c.dispose();
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(SessionController.native, null);
  });
  test('opt-in sends only guardian credentials and backgrounding does not stop the native monitor', () async {
    await c.setGuardianMonitoring(true);
    expect(calls.map((c) => c.method), [
      'guardianPermissions',
      'startGuardian',
      'guardianStatus',
    ]);
    final config = jsonDecode(calls[1].arguments as String) as Map;
    expect(config, {
      'baseUrl': 'https://test.example',
      'id': id,
      'guardianToken': token,
    });
    expect(c.device['enabled'], true);
    c.setVisible(false);
    expect(c.snapshot, isNull);
    expect(calls.any((c) => c.method == 'stopGuardian'), false);
  });
  test('a denied native start never reports monitoring enabled', () async {
    messenger.setMockMethodCallHandler(SessionController.native, (call) async {
      if (call.method == 'startGuardian') {
        throw PlatformException(
          code: 'blocked',
          message: 'Allow KAZE guardian notifications first.',
        );
      }
      return null;
    });
    await c.setGuardianMonitoring(true);
    expect(c.device['enabled'], isNot(true));
    expect(c.message, 'Allow KAZE guardian notifications first.');
  });
  test(
    'removing a link stops monitoring before clearing the saved session',
    () async {
      await c.storage.write(
        key: 'session',
        value: jsonEncode(access().toJson()),
      );
      await c.forget();
      expect(calls.map((c) => c.method), ['stopGuardian']);
      expect(c.access, isNull);
      expect(c.snapshot, isNull);
      expect(await c.storage.read(key: 'session'), isNull);
    },
  );
  test(
    'revocation stops the native monitor as well as clearing evidence',
    () async {
      status = 401;
      await c.refresh();
      expect(calls.map((c) => c.method), ['stopGuardian']);
      expect(c.access, isNull);
      expect(c.snapshot, isNull);
    },
  );
  test(
    'a delayed native status cannot restore state after the link is removed',
    () async {
      final entered = Completer<void>();
      final pending = Completer<Map<String, dynamic>>();
      messenger.setMockMethodCallHandler(SessionController.native, (
        call,
      ) async {
        if (call.method == 'guardianStatus') {
          entered.complete();
          return pending.future;
        }
        return null;
      });
      final read = c.refresh();
      await entered.future;
      await c.forget();
      pending.complete(nativeStatus);
      await read;
      expect(c.access, isNull);
      expect(c.snapshot, isNull);
      expect(c.device, isEmpty);
    },
  );
  test(
    'a delayed revocation cleanup cannot clear replacement access',
    () async {
      status = 401;
      final entered = Completer<void>(), stopped = Completer<void>();
      messenger.setMockMethodCallHandler(SessionController.native, (
        call,
      ) async {
        if (call.method == 'stopGuardian') {
          entered.complete();
          await stopped.future;
        }
        return null;
      });
      final read = c.refresh();
      await entered.future;
      final replacement = access();
      c.access = replacement;
      c.revision++;
      c.snapshot = {'phase': 'armed'};
      stopped.complete();
      await read;
      expect(c.access, same(replacement));
      expect(c.snapshot?['phase'], 'armed');
    },
  );
  test(
    'restoring another guardian session stops a mismatched persisted monitor',
    () async {
      nativeStatus['sessionId'] = 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee';
      await c.storage.write(
        key: 'session',
        value: jsonEncode(access().toJson()),
      );
      await c.restore();
      expect(calls.map((c) => c.method), contains('stopGuardian'));
    },
  );
  test('iPhone enables local review reminders without passing guardian credentials', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    c.received = DateTime.now();
    c.snapshot = {
      'phase': 'armed',
      'dueAt': 6000,
      'graceSeconds': 3,
      'serverNow': 1000,
      'expiresAt': 20000,
    };
    await c.setGuardianMonitoring(true);
    final config = jsonDecode(
      calls.firstWhere((c) => c.method == 'startGuardian').arguments as String,
    ) as Map;
    expect(config.containsKey('guardianToken'), false);
    expect(config['dueAt'], 6000);
    expect(c.backgroundGuardianSupported, true);
    expect(calls.any((c) => c.method == 'guardianPushRegistration'), false);
  });
}
