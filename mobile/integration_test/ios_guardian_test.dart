import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:kaze/backend.dart';
import 'package:kaze/main.dart' as app;

// Run against scripts/ios-test-backend.mjs on loopback port 4174.
// These synthetic trails verify UI/API behavior, never physical sensor accuracy.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();
  final sessions = <Map<String, dynamic>>[];
  final readyMap = find.byWidgetPredicate(
    (widget) =>
        widget is IconButton &&
        widget.tooltip == 'Recenter on last location' &&
        widget.onPressed != null,
  );

  Future<Map<String, dynamic>> request(
    String path, {
    Map<String, dynamic>? body,
    String? token,
    bool delete = false,
  }) async {
    final uri = Uri.parse('$kazeBackendUrl$path');
    final headers = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    final response = delete
        ? await http.delete(uri, headers: headers)
        : body == null
        ? await http.get(uri, headers: headers)
        : await http.post(uri, headers: headers, body: jsonEncode(body));
    expect(
      response.statusCode,
      inInclusiveRange(200, 299),
      reason: response.body,
    );
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> control(Map<String, dynamic> body) =>
      request('/__test/control', body: body);

  Future<Map<String, dynamic>> create({bool live = false}) async {
    final session = await request(
      '/api/sessions',
      body: {
        'name': 'Simulator Test',
        'consent': true,
        'simulation': true,
        'sensorMode': 'simulated',
        'intervalSeconds': 3600,
        'graceSeconds': 3,
        'liveSharing': live,
        'liveSharingConsent': live,
      },
    );
    sessions.add(session);
    return session;
  }

  String path(Map<String, dynamic> s, [String action = '']) =>
      '/api/sessions/${s['id']}${action.isEmpty ? '' : '/$action'}';
  String invite(Map<String, dynamic> s) =>
      '$kazeBackendUrl/guardian#session=${s['id']}&token=${s['guardianToken']}';

  Future<void> readings(Map<String, dynamic> s) async {
    final now = (await control({}))['now'] as int;
    await request(
      path(s, 'events'),
      token: s['ownerToken'] as String,
      body: {
        'events': [
          for (var i = 0; i < 3; i++)
            {
              'id': 'synthetic-phone-$now-$i',
              'source': 'phone',
              'type': 'gps',
              'seq': now + i,
              'at': now - (2 - i) * 1000,
              'fixAt': now - (2 - i) * 1000,
              'latitude': 43.4723 + i * .00001,
              'longitude': -80.5449 + i * .00001,
              'accuracy': 3,
              'altitude': 330,
              'verticalAccuracy': 1,
              'altitudeDatum': 'WGS84-ellipsoid',
              'provider': 'gps',
              'provenance': 'device-gnss',
            },
          {
            'id': 'synthetic-watch-$now',
            'source': 'watch',
            'type': 'gps',
            'seq': now,
            'at': now,
            'fixAt': now,
            'latitude': 43.47235,
            'longitude': -80.54485,
            'accuracy': 8,
            'provider': 'fused',
            'provenance': 'possibly-phone-derived',
          },
        ],
      },
    );
  }

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    final until = DateTime.now().add(const Duration(seconds: 25));
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(until)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(finder, findsWidgets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> tap(
    WidgetTester tester,
    Finder finder, {
    bool scrollUp = false,
  }) async {
    final target = finder.last;
    await tester.pumpAndSettle();
    for (
      var attempt = 0;
      finder.evaluate().isEmpty && attempt < 20;
      attempt++
    ) {
      final bounds = tester.getRect(find.byType(Scrollable).first);
      // Drag the list's gutter so the native map does not consume the gesture.
      await tester.dragFrom(
        Offset(bounds.left + 4, bounds.center.dy),
        Offset(0, scrollUp ? 250 : -250),
      );
      await tester.pumpAndSettle();
    }
    expect(finder, findsWidgets);
    await Scrollable.ensureVisible(tester.element(target), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.pump(const Duration(milliseconds: 500));
    final bytes = await binding.takeScreenshot(name);
    final directory = Directory(
      '${Directory.systemTemp.path}/kaze-ios-evidence',
    );
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png').writeAsBytes(bytes);
    debugPrint('KAZE_IOS_CAPTURE $name');
  }

  Future<void> launch(WidgetTester tester, {bool onboarding = false}) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    await tester.pump(const Duration(seconds: 1));
    await storage.deleteAll();
    if (!onboarding) {
      await storage.write(key: 'deviceSetupSeenV1', value: 'true');
    }
    app.main();
    await waitFor(
      tester,
      find.text(onboarding ? 'Set up KAZE' : 'Join as guardian'),
    );
  }

  Future<void> join(WidgetTester tester, Map<String, dynamic> s) async {
    await tester.enterText(find.byType(TextField), invite(s));
    await tap(tester, find.text('Open my person’s session'));
    await waitFor(tester, find.byType(CupertinoTabBar));
  }

  setUp(() async {
    expect(Platform.isIOS, isTrue, reason: 'This suite is for iOS simulators.');
    expect(kazeBackendUrl, 'http://127.0.0.1:4174');
    await control({'reset': true});
  });

  tearDown(() async {
    await control({'offline': false});
    for (final s in sessions) {
      await request(path(s), token: s['ownerToken'] as String, delete: true);
    }
    sessions.clear();
    await storage.deleteAll();
  });

  testWidgets('iOS first launch and invitation validation', (tester) async {
    await launch(tester, onboarding: true);
    expect(find.textContaining('Location is optional'), findsOneWidget);
    expect(find.text('Battery optimization'), findsNothing);
    await capture(tester, '01-permission-setup');
    await tap(tester, find.text('Continue'));
    await waitFor(tester, find.text('Join as guardian'));
    expect(find.text('Start safety session'), findsNothing);
    await tester.enterText(find.byType(TextField), 'invalid');
    await tap(tester, find.text('Open my person’s session'));
    await waitFor(tester, find.text('Paste the private guardian link.'));
    final s = await create();
    await tester.enterText(
      find.byType(TextField),
      invite(s).replaceFirst(kazeBackendUrl, 'https://other.example'),
    );
    await tap(tester, find.text('Open my person’s session'));
    await waitFor(tester, find.textContaining('different KAZE service'));
    await tester.enterText(
      find.byType(TextField),
      invite(s).replaceFirst(s['guardianToken'] as String, 'x' * 43),
    );
    await tap(tester, find.text('Open my person’s session'));
    await waitFor(
      tester,
      find.textContaining('Invalid, revoked, or expired access'),
    );
    await join(tester, s);
    await waitFor(tester, find.textContaining('Trail stays private'));
    await capture(tester, '02-private-session');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'iOS missed check-in, native map, AR fallback and guardian responses',
    (tester) async {
      await launch(tester);
      final s = await create();
      await readings(s);
      await join(tester, s);
      await waitFor(tester, find.textContaining('Trail stays private'));
      await control({'advanceMs': 3604000});
      await readings(s);
      await waitFor(tester, find.text('Check-in unanswered'));
      await waitFor(tester, readyMap);
      await tester.pump(const Duration(seconds: 3));
      await capture(tester, '03-alert-map');
      await tap(tester, find.byTooltip('Show entire recorded trail'));
      await tap(tester, find.byTooltip('Recenter on last location'));
      await tap(tester, find.byIcon(Icons.expand_less));
      await waitFor(tester, find.text('Session details'));
      await tap(tester, find.text('I’ve seen the request'));
      await waitFor(
        tester,
        find.text('Acknowledged. Arrival is not verified.'),
      );
      await tap(tester, find.text('Report I’m with them'));
      await waitFor(
        tester,
        find.text('Guardian reports arrival. Not independently verified.'),
      );
      final accepted = await request(path(s), token: s['ownerToken'] as String);
      expect(accepted['phase'], 'alert');
      expect(accepted['acknowledgedAt'], isNotNull);
      expect(accepted['arrivalReportedAt'], isNotNull);
      await readings(s);
      await tap(tester, find.text('Guardian spatial AR'));
      await waitFor(
        tester,
        find.textContaining('ARKit world tracking unsupported'),
      );
      await capture(tester, '04-ar-simulator-fallback');
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('Return to map').hitTestable(), findsOneWidget);
      await tap(tester, find.text('Return to map'));
      await tap(tester, find.byTooltip('Close details'), scrollUp: true);
      await tap(tester, find.text('Activity').last);
      await waitFor(
        tester,
        find.text('Guardian acknowledged · help not verified'),
      );
      expect(
        find.text('Guardian reported arrival · not verified'),
        findsOneWidget,
      );
      await capture(tester, '05-guardian-activity');
      await request(
        path(s, 'resolve'),
        token: s['ownerToken'] as String,
        body: {'confirm': true},
      );
      await tap(tester, find.text('Map').last);
      await waitFor(tester, find.text('Session ended'));
      expect(find.byTooltip('Recenter on last location'), findsNothing);
      expect(find.text('Sharing has stopped.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'iOS appearance, secure restore, offline recovery and revoked access',
    (tester) async {
      await launch(tester);
      final s = await create(live: true);
      await readings(s);
      await join(tester, s);
      await waitFor(tester, readyMap);
      await tap(tester, find.text('Settings').last);
      await tap(tester, find.widgetWithText(ChoiceChip, 'Dark'));
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.dark,
      );
      final navContext = tester.element(find.byType(CupertinoNavigationBar));
      expect(CupertinoTheme.of(navContext).brightness, Brightness.dark);
      expect(
        CupertinoTheme.of(navContext).barBackgroundColor,
        Theme.of(navContext).colorScheme.surface,
      );
      await capture(tester, '06-settings-dark');
      await tap(tester, find.byType(SwitchListTile));
      await tap(tester, find.text('Map').last);
      await tester.pump(const Duration(seconds: 2));
      await capture(tester, '07-map-without-street-tiles');
      await tester.pumpWidget(const SizedBox.shrink());
      app.main();
      await waitFor(tester, find.byType(CupertinoTabBar));
      await waitFor(
        tester,
        find.byWidgetPredicate(
          (widget) =>
              widget is MaterialApp && widget.themeMode == ThemeMode.dark,
        ),
      );
      expect(await storage.read(key: 'appearance'), 'dark');
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.dark,
      );
      expect(await storage.read(key: 'session'), contains(s['id'] as String));
      await control({'offline': true});
      await waitFor(tester, find.text('Reconnect'));
      expect(find.byTooltip('Recenter on last location'), findsNothing);
      await capture(tester, '08-offline-evidence-hidden');
      await control({'offline': false});
      await tap(tester, find.text('Reconnect'));
      await waitFor(tester, readyMap);
      await tap(tester, find.text('Settings').last);
      await tap(tester, find.widgetWithText(ChoiceChip, 'Light'));
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.light,
      );
      await tap(tester, find.text('Map').last);
      await capture(tester, '09-map-light');
      await request(
        path(s, 'revoke-guardian'),
        token: s['ownerToken'] as String,
        body: {'confirm': true},
      );
      await waitFor(tester, find.text('Join as guardian'));
      expect(await storage.read(key: 'session'), isNull);
      expect(find.byType(CupertinoTabBar), findsNothing);
      await capture(tester, '10-revoked-access-cleared');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'iOS landscape, large text, licenses and removing a guardian link',
    (tester) async {
      await launch(tester);
      final s = await create(live: true);
      await readings(s);
      await join(tester, s);
      await waitFor(tester, readyMap);
      addTearDown(() async {
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
        await tester.pump(const Duration(seconds: 1));
      });
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      await capture(tester, '11-map-large-text');
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      await tester.pump(const Duration(seconds: 2));
      final size = MediaQuery.sizeOf(
        tester.element(find.byType(Scaffold).first),
      );
      expect(size.width, greaterThan(size.height));
      expect(tester.takeException(), isNull);
      await capture(tester, '12-map-landscape-large-text');
      await tap(tester, find.byIcon(Icons.expand_less));
      await waitFor(tester, find.text('Session details'));
      expect(tester.takeException(), isNull);
      await tap(tester, find.byTooltip('Close details'));
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pump(const Duration(seconds: 2));
      await tap(tester, find.text('Settings').last);
      await tap(tester, find.text('Permissions & background setup'));
      await waitFor(tester, find.text('Set up KAZE'));
      await tap(tester, find.text('Continue'));
      await tap(tester, find.text('Licenses & map credits'));
      await waitFor(tester, find.byType(LicensePage));
      await capture(tester, '13-map-licenses');
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 500));
      await tap(tester, find.text('Remove this guardian link'));
      await waitFor(tester, find.text('Join as guardian'));
      expect(await storage.read(key: 'session'), isNull);
      final active = await request(path(s), token: s['ownerToken'] as String);
      expect(active['phase'], 'armed');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('iOS deleted and expired sessions clear private access', (
    tester,
  ) async {
    await launch(tester);
    final deleted = await create(live: true);
    await join(tester, deleted);
    await request(
      path(deleted),
      token: deleted['ownerToken'] as String,
      delete: true,
    );
    sessions.remove(deleted);
    await waitFor(tester, find.text('Join as guardian'));
    expect(await storage.read(key: 'session'), isNull);
    final expired = await create(live: true);
    await join(tester, expired);
    await control({'advanceMs': 8 * 3600000 + 1000});
    await waitFor(tester, find.text('Join as guardian'));
    expect(await storage.read(key: 'session'), isNull);
    // Expired access cannot authenticate even as owner; fixture owns disposal.
    sessions.remove(expired);
    await capture(tester, '14-expired-session-cleared');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
