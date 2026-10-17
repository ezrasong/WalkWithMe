import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:kaze/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Vivo real app: start, queue actual readings, check in and end', (
    tester,
  ) async {
    bool endedThroughUI = false;
    app.main();
    addTearDown(() async {
      // Dispose every test-owned session even if a hardware assertion fails.
      final raw = await const FlutterSecureStorage().read(key: 'session');
      if (raw == null) return;
      final access = jsonDecode(raw);
      if (access['role'] != 'owner') return;
      await http.post(
        Uri.parse('${access['baseUrl']}/api/sessions/${access['id']}/resolve'),
        headers: {
          'Authorization': 'Bearer ${access['token']}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'confirm': true}),
      );
      if (!endedThroughUI && const bool.fromEnvironment('KAZE_VERIFY_WATCH')) {
        // Preserve the relay during failure cleanup as well as the happy path.
        await Future<void>.delayed(const Duration(seconds: 20));
      }
      await const FlutterSecureStorage().delete(key: 'session');
    });
    Future<void> waitFor(Finder finder, {int seconds = 25}) async {
      final until = DateTime.now().add(Duration(seconds: seconds));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(until)) {
        await tester.pump(const Duration(milliseconds: 200));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(finder, findsWidgets);
    }

    await waitFor(
      find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            ['Set up KAZE', 'A timed safety session'].contains(widget.data),
      ),
    );
    if (find.text('Set up KAZE').evaluate().isNotEmpty) {
      // OS permissions are prepared by the physical tester. This harness
      // acknowledges the explanation without silently granting OS access.
      final next = find.text('Continue');
      await tester.scrollUntilVisible(
        next,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      await tester.tap(next);
    }
    await waitFor(find.text('A timed safety session'));
    final consent = find.byType(CheckboxListTile).first;
    await tester.scrollUntilVisible(
      consent,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(consent);
    await tester.pump();
    final start = find.text('Start safety session');
    await tester.scrollUntilVisible(
      start,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(start);
    await waitFor(find.text('Session active'));
    final check = find.text('Check in');
    await tester.ensureVisible(check);
    await tester.tap(check);
    await waitFor(find.text('Check-in confirmed by server.'));
    await tester.tap(find.text('Activity'));
    await tester.pump();
    expect(find.text('Check-in accepted by server'), findsOneWidget);
    // Wait for actual native callbacks/queue uploads. No synthetic location/sensor events are sent.
    await Future<void>.delayed(const Duration(seconds: 16));
    await tester.pump();
    final raw = await const FlutterSecureStorage().read(key: 'session');
    expect(raw, isNotNull);
    final access = jsonDecode(raw!);
    final response = await http.get(
      Uri.parse('${access['baseUrl']}/api/sessions/${access['id']}'),
      headers: {'Authorization': 'Bearer ${access['token']}'},
    );
    expect(response.statusCode, 200);
    final snapshot = jsonDecode(response.body);
    expect(snapshot['sources']['phone'], isNotNull);
    if (const bool.fromEnvironment('KAZE_VERIFY_UI')) {
      await binding.convertFlutterSurfaceToImage();
      Future<void> capture(String name) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        await tester.pump();
        final bytes = await binding.takeScreenshot(name);
        final directory = Directory('/data/user/0/app.kaze.trail/files');
        await directory.create(recursive: true);
        await File('${directory.path}/$name.png').writeAsBytes(bytes);
        debugPrint('KAZE_CAPTURE_$name');
      }

      await tester.tap(find.text('Settings'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Dark'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.dark,
      );
      await capture('ui-settings-dark');
      await tester.tap(find.text('Map'));
      await tester.pumpAndSettle();
      await capture('ui-map-dark');
      expect(find.byTooltip('Recenter on last location'), findsOneWidget);
      await tester.tap(find.byTooltip('Show entire recorded trail'));
      await tester.pump();
      await tester.tap(find.byTooltip('Recenter on last location'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.expand_less));
      await tester.pumpAndSettle();
      expect(find.text('Session details'), findsOneWidget);
      await tester.tap(find.byTooltip('Close details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Light'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        Brightness.light,
      );
      await tester.tap(find.text('Map'));
      await tester.pumpAndSettle();
      await capture('ui-map-light');
      debugPrint('KAZE_UI_VERIFIED');
    }
    if (const bool.fromEnvironment('KAZE_VERIFY_WATCH')) {
      // The host opens the real watch app; there is no Start/enable tap.
      // No manual phone 'Pair watch' action or fabricated watch readings are used.
      debugPrint('KAZE_WATCH_DISCOVERY_READY');
      final until = DateTime.now().add(const Duration(seconds: 120));
      Map<String, dynamic> watchSnapshot = snapshot;
      while (watchSnapshot['sources']['watch'] == null &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await tester.pump();
        final read = await http.get(
          Uri.parse('${access['baseUrl']}/api/sessions/${access['id']}'),
          headers: {'Authorization': 'Bearer ${access['token']}'},
        );
        expect(read.statusCode, 200);
        watchSnapshot = jsonDecode(read.body);
      }
      expect(
        watchSnapshot['sources']['watch'],
        isNotNull,
        reason: 'The real watch must discover the phone session and upload its own heartbeat.',
      );
      debugPrint('KAZE_WATCH_UPLOAD_CONFIRMED');
      debugPrint('KAZE_WATCH_CHECKIN_READY');
      final responseUntil = DateTime.now().add(const Duration(seconds: 45));
      bool watchAccepted = false;
      while (!watchAccepted && DateTime.now().isBefore(responseUntil)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final read = await http.get(
          Uri.parse('${access['baseUrl']}/api/sessions/${access['id']}'),
          headers: {'Authorization': 'Bearer ${access['token']}'},
        );
        expect(read.statusCode, 200);
        final data = jsonDecode(read.body);
        watchAccepted = (data['activity'] as List).any(
          (a) => a['action'] == 'check-in' && a['role'] == 'watch',
        );
      }
      expect(
        watchAccepted,
        isTrue,
        reason: 'Only an explicit, server-accepted watch response proves watch check-in.',
      );
      debugPrint('KAZE_WATCH_CHECKIN_CONFIRMED');
      if (const bool.fromEnvironment('KAZE_LONG_DEVICE_TEST')) {
        final done = File(
          '/data/user/0/app.kaze.trail/files/kaze-device-long-run.json',
        );
        if (await done.exists()) await done.delete();
        debugPrint('KAZE_SCREEN_OFF_READY');
        final longUntil = DateTime.now().add(const Duration(minutes: 16));
        // Do not pump frames while screens are off: Java services own collection.
        while (!await done.exists() && DateTime.now().isBefore(longUntil)) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        expect(
          await done.exists(),
          isTrue,
          reason: 'The host must provide actual screen/offline evidence.',
        );
        final result = jsonDecode(await done.readAsString());
        expect(result['passed'], isTrue, reason: result['error']?.toString());
        binding.reportData = {'deviceReliability': result};
        await tester.pump();
      }
    }
    binding.reportData = {
      'phoneHeartbeatReceived': true,
      'geographicFixesReceived':
          (snapshot['geography']['fixes'] as List).length,
      'checkInAccepted': snapshot['lastCheckInAt'] != null,
      'physicalRouteAccuracyMeasured': false,
    };
    await tester.tap(find.text('Settings'));
    await tester.pump();
    final end = find.text('End session and stop sharing');
    await tester.scrollUntilVisible(
      end,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(end), alignment: .4);
    await tester.pumpAndSettle();
    await tester.tap(end);
    await tester.pumpAndSettle();
    await waitFor(find.text('Confirm'));
    await tester.tap(find.text('Confirm'));
    await waitFor(find.text('Return to setup'));
    await tester.scrollUntilVisible(
      find.text('Return to setup'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    final ended = await http.get(
      Uri.parse('${access['baseUrl']}/api/sessions/${access['id']}'),
      headers: {'Authorization': 'Bearer ${access['token']}'},
    );
    expect(jsonDecode(ended.body)['phase'], 'resolved');
    endedThroughUI = true;
    debugPrint('KAZE_SESSION_END_CONFIRMED');
    if (const bool.fromEnvironment('KAZE_VERIFY_WATCH')) {
      // Flutter device-test cleanup removes the phone app. Keep its relay alive
      // long enough for the watch's independent control poll to observe the end.
      await Future<void>.delayed(const Duration(seconds: 20));
      await tester.pump();
    }
    await tester.tap(find.text('Return to setup'));
    await tester.pump();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
