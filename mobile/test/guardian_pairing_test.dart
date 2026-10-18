import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:kaze/backend.dart';
import 'package:kaze/guardian_pairing.dart';
import 'package:kaze/session.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

const sessionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
const guardianToken = 'guardian_012345678901234567890123456789012345';
const ownerToken = 'owner_012345678901234567890123456789012345678';

// Exercise decoding, permissions and lifecycle using simulated camera events.
// Physical QR focus/recognition and iPhone signing require device verification.
class ScannerPlatform extends MobileScannerPlatform {
  int starts = 0, stops = 0;
  bool denied = false;
  Completer<MobileScannerViewAttributes>? pendingStart;
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    if (denied) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
      );
    }
    expect(options.returnImage, false);
    if (pendingStart != null) return pendingStart!.future;
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(640, 480),
    );
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ScannerPlatform scanner;
  late MobileScannerPlatform originalScanner;
  late List<String> nativeCalls;
  SessionAccess owner() => SessionAccess(
    baseUrl: kazeBackendUrl,
    id: sessionId,
    token: ownerToken,
    role: 'owner',
    guardianToken: guardianToken,
  );
  Map<String, dynamic> snapshot({String role = 'owner'}) => {
    'role': role,
    'phase': 'armed',
    'shared': role == 'owner',
    'serverNow': DateTime.now().millisecondsSinceEpoch,
    'expiresAt': DateTime.now().millisecondsSinceEpoch + 3600000,
  };
  Map<String, dynamic> invitation() => {
    'code': 'ABCDE-FGHJK',
    'serverNow': DateTime.now().millisecondsSinceEpoch,
    'expiresAt': DateTime.now().millisecondsSinceEpoch + 300000,
  };
  String qr({String base = kazeBackendUrl, String code = 'ABCDE-FGHJK'}) =>
      jsonEncode({'app': 'KAZE', 'version': 1, 'baseUrl': base, 'code': code});
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    nativeCalls = [];
    messenger.setMockMethodCallHandler(SessionController.native, (call) async {
      nativeCalls.add(call.method);
      return call.method == 'guardianStatus'
          ? {'enabled': false}
          : {'active': false};
    });
    originalScanner = MobileScannerPlatform.instance;
    scanner = ScannerPlatform();
    MobileScannerPlatform.instance = scanner;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(SessionController.native, null);
    MobileScannerPlatform.instance = originalScanner;
  });

  test('QR decoding is versioned, validates codes and rejects foreign services or arbitrary links', () {
    expect(guardianCodeFromQr(qr()), 'ABCDEFGHJK');
    expect(guardianPairingCode('abcde fghjk'), 'ABCDEFGHJK');
    for (final input in [
      qr(base: 'https://other.example'),
      qr(code: '00000-00000'),
      'https://example.test/guardian#token=secret',
      '{}',
      'not a code',
      jsonEncode({
        'app': 'KAZE',
        'version': 2,
        'baseUrl': kazeBackendUrl,
        'code': 'ABCDE-FGHJK',
      }),
      'x' * 2049,
    ]) {
      expect(() => guardianCodeFromQr(input), throwsFormatException);
    }
  });

  test('code redemption uses only the configured service, then verifies guardian scope', () async {
    final requests = <http.Request>[];
    final c = SessionController(
      client: MockClient((request) async {
        requests.add(request);
        expect(request.url.origin, Uri.parse(kazeBackendUrl).origin);
        expect(request.followRedirects, false);
        if (request.url.path == '/api/guardian-invites/redeem') {
          expect(request.headers.containsKey('Authorization'), false);
          expect(jsonDecode(request.body), {'code': 'ABCDEFGHJK'});
          return http.Response(
            jsonEncode({'id': sessionId, 'guardianToken': guardianToken}),
            200,
          );
        }
        expect(request.headers['Authorization'], 'Bearer $guardianToken');
        return http.Response(jsonEncode(snapshot(role: 'guardian')), 200);
      }),
    );
    addTearDown(c.dispose);
    await c.joinCode('00000-00000');
    expect(requests, isEmpty);
    await c.joinCode('abcde-fghjk');
    expect(c.guardian, true);
    expect(c.snapshot!['shared'], false);
    expect(nativeCalls, isNot(contains('start')));
  });

  test(
    'expired codes and malformed access never replace saved access',
    () async {
      var status = 404;
      final c = SessionController(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode(
              status == 404
                  ? {'error': 'Pairing code expired.'}
                  : {'id': 5, 'guardianToken': 'bad'},
            ),
            status,
          ),
        ),
      );
      addTearDown(c.dispose);
      final previous = owner();
      c.access = previous;
      await c.joinCode('ABCDE-FGHJK');
      expect(c.access, same(previous));
      expect(c.message, contains('expired'));
      status = 200;
      await c.joinCode('ABCDE-FGHJK');
      expect(c.access, same(previous));
      expect(c.message, contains('invalid guardian access'));
    },
  );

  testWidgets(
    'owner sees scannable QR and short code; backgrounding and revocation hide it',
    (tester) async {
      final c = SessionController(
        client: MockClient((request) async {
          expect(request.url.path, '/api/sessions/$sessionId/guardian-invite');
          expect(request.headers['Authorization'], 'Bearer $ownerToken');
          expect(jsonDecode(request.body), {'guardianToken': guardianToken});
          return http.Response(jsonEncode(invitation()), 201);
        }),
      );
      addTearDown(c.dispose);
      c.access = owner();
      c.snapshot = snapshot();
      c.received = DateTime.now();
      await tester.pumpWidget(
        MaterialApp(home: GuardianPairingScreen(session: c)),
      );
      await tester.pumpAndSettle();
      expect(find.text('ABCDE-FGHJK'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      final payload = (await c.createGuardianInvitation()).qrData;
      expect(guardianCodeFromQr(payload), 'ABCDEFGHJK');
      expect(payload, isNot(contains(guardianToken)));
      expect(payload, isNot(contains(ownerToken)));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsNothing);
      await tester.ensureVisible(find.text('Generate new code'));
      await tester.tap(find.text('Generate new code'));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      c.snapshot!['guardianRevokedAt'] = 1000;
      c.changed();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('unavailable for this session'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('late invitation cannot appear after switching owner access', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    final c = SessionController(client: MockClient((_) => pending.future));
    addTearDown(c.dispose);
    c.access = owner();
    c.snapshot = snapshot();
    c.received = DateTime.now();
    await tester.pumpWidget(
      MaterialApp(home: GuardianPairingScreen(session: c)),
    );
    c.access = owner();
    c.changed();
    pending.complete(http.Response(jsonEncode(invitation()), 201));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  Future<List<String?>> openScanner(WidgetTester tester) async {
    final results = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                results.add(
                  await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) => const GuardianScannerScreen(),
                    ),
                  ),
                );
              },
              child: const Text('Scan'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets(
    'scanner rejects unrelated QR, returns valid code once and closes camera',
    (tester) async {
      final results = await openScanner(tester);
      var widget = tester.widget<MobileScanner>(find.byType(MobileScanner));
      widget.onDetect!(
        BarcodeCapture(barcodes: [Barcode(rawValue: 'https://other.example')]),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Scan a WalkWithMe guardian QR code.'),
        findsOneWidget,
      );
      widget = tester.widget<MobileScanner>(find.byType(MobileScanner));
      final capture = BarcodeCapture(barcodes: [Barcode(rawValue: qr())]);
      widget.onDetect!(capture);
      widget.onDetect!(capture);
      await tester.pumpAndSettle();
      expect(results, ['ABCDEFGHJK']);
      expect(scanner.stops, greaterThan(0));
      expect(find.byType(MobileScanner), findsNothing);
    },
  );

  testWidgets(
    'denied camera offers code entry and backgrounding stops scanning',
    (tester) async {
      scanner.denied = true;
      await openScanner(tester);
      expect(find.textContaining('Camera unavailable.'), findsOneWidget);
      await tester.tap(find.text('Enter code instead'));
      await tester.pumpAndSettle();
      scanner.denied = false;
      await tester.tap(find.text('Scan'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(scanner.stops, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('late camera startup after backgrounding immediately stops', (
    tester,
  ) async {
    final pending = Completer<MobileScannerViewAttributes>();
    scanner.pendingStart = pending;
    await openScanner(tester);
    expect(scanner.starts, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    pending.complete(
      const MobileScannerViewAttributes(
        cameraDirection: CameraFacing.back,
        currentTorchMode: TorchState.off,
        size: Size(640, 480),
      ),
    );
    await tester.pumpAndSettle();
    expect(scanner.stops, greaterThan(0));
    scanner.pendingStart = null;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
