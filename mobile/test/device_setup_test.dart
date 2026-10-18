import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaze/device_setup.dart';
import 'package:kaze/main.dart';
import 'package:kaze/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const geo = MethodChannel('flutter.baseflow.com/geolocator');
  late List<String> calls;
  late Map<String, dynamic> status;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterSecureStorage.setMockInitialValues({});
    calls = [];
    status = {
      'locationAllowed': false,
      'preciseLocation': false,
      'locationServices': false,
      'notificationsAllowed': false,
      'batteryExempt': false,
      'backgroundRestricted': false,
      'manufacturer': 'vivo',
    };
    messenger.setMockMethodCallHandler(SessionController.native, (call) async {
      calls.add(call.method);
      return call.method == 'setupStatus' ? status : null;
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(SessionController.native, null);
    messenger.setMockMethodCallHandler(geo, null);
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: kazeTheme(Brightness.dark),
        home: const DeviceSetupScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'setup requests access only after a tap and rechecks denied results',
    (tester) async {
      await open(tester);
      expect(calls, ['setupStatus']);
      expect(
        find.textContaining('Setup does not start recording'),
        findsOneWidget,
      );
      await tester.tap(find.text('Allow permissions'));
      await tester.pumpAndSettle();
      expect(calls, ['setupStatus', 'permissions', 'setupStatus']);
      expect(
        find.textContaining('Not allowed. A geographic trail'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Open Location settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Location settings'));
      await tester.pumpAndSettle();
      expect(calls, contains('locationSettings'));
      status = {
        ...status,
        'locationAllowed': true,
        'preciseLocation': true,
        'locationServices': true,
        'notificationsAllowed': true,
      };
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Open Location settings'), findsNothing);
      expect(find.text('Allow permissions'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'battery and manufacturer controls are separate and fit large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: kazeTheme(Brightness.light),
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: DeviceSetupScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Allow background battery use'),
        350,
      );
      await tester.ensureVisible(find.text('Allow background battery use'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow background battery use'));
      await tester.pumpAndSettle();
      expect(calls, contains('batterySettings'));
      await tester.scrollUntilVisible(
        find.text('Open WalkWithMe app settings'),
        350,
      );
      await tester.ensureVisible(find.text('Open WalkWithMe app settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open WalkWithMe app settings'));
      await tester.pumpAndSettle();
      expect(calls, contains('appSettings'));
      expect(
        find.textContaining('does not confirm the manufacturer setting'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('first launch offers setup once and keeps a manual setup entry', (
    tester,
  ) async {
    await tester.pumpWidget(const KazeApp());
    await tester.pumpAndSettle();
    expect(find.text('Set up WalkWithMe'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Continue'), 450);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('A timed safety session'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const KazeApp());
    await tester.pumpAndSettle();
    expect(find.text('Set up WalkWithMe'), findsNothing);
    expect(find.text('Permissions & background setup'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets(
    'dismissing setup survives an update-style restart and preserves appearance',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({'appearance': 'dark'});
      await tester.pumpWidget(const KazeApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const KazeApp());
      await tester.pumpAndSettle();
      expect(find.text('Set up WalkWithMe'), findsNothing);
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.dark,
      );
      expect(
        calls.where((c) => c != 'setupStatus' && c != 'stopGuardian'),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'iPhone setup offers optional location without Android battery controls',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      messenger.setMockMethodCallHandler(geo, (call) async {
        calls.add('geo:${call.method}');
        return call.method == 'isLocationServiceEnabled' ? false : 0;
      });
      await open(tester);
      expect(find.textContaining('Location is optional'), findsOneWidget);
      expect(find.text('Battery optimization'), findsNothing);
      await tester.tap(find.text('Allow permissions'));
      await tester.pumpAndSettle();
      expect(calls, contains('geo:requestPermission'));
      expect(calls, isNot(contains('permissions')));
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
