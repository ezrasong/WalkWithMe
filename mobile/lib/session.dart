import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'backend.dart';

String guardianPairingCode(String value) {
  final code = value.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  if (value.length > 32 || !RegExp(r'^[2-9A-HJ-NP-Z]{10}$').hasMatch(code)) {
    throw const FormatException(
      'Enter the 10-character pairing code shown on the wearer’s phone.',
    );
  }
  return code;
}

String guardianCodeFromQr(String value, {String baseUrl = kazeBackendUrl}) {
  if (value.length > 2048) {
    throw const FormatException('Scan a KAZE guardian QR code.');
  }
  final dynamic data;
  try {
    data = jsonDecode(value);
  } catch (_) {
    throw const FormatException('Scan a KAZE guardian QR code.');
  }
  if (data is! Map ||
      data['app'] != 'KAZE' ||
      data['version'] != 1 ||
      data['baseUrl'] is! String ||
      data['code'] is! String) {
    throw const FormatException('Scan a KAZE guardian QR code.');
  }
  if (validateBaseUrl(data['baseUrl']) != validateBaseUrl(baseUrl)) {
    throw const FormatException(
      'This QR code belongs to a different KAZE service. Ask for a current invitation.',
    );
  }
  return guardianPairingCode(data['code']);
}

class GuardianInvitation {
  final String code, baseUrl;
  final int expiresAt, serverNow;
  final DateTime received = DateTime.now();
  GuardianInvitation({
    required this.code,
    required this.baseUrl,
    required this.expiresAt,
    required this.serverNow,
  });
  int get secondsLeft =>
      ((expiresAt -
                  serverNow -
                  DateTime.now().difference(received).inMilliseconds) /
              1000)
          .ceil()
          .clamp(0, 300);
  String get qrData => jsonEncode({
    'app': 'KAZE',
    'version': 1,
    'baseUrl': baseUrl,
    'code': code,
  });
}

String validateBaseUrl(String input, {bool allowLocalHttp = kDebugMode}) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('Invalid KAZE server address.');
  }
  final ip = InternetAddress.tryParse(uri.host);
  final b = ip?.rawAddress;
  final local =
      uri.host == 'localhost' ||
      (b != null &&
          b.length == 4 &&
          (b[0] == 127 ||
              b[0] == 10 ||
              (b[0] == 192 && b[1] == 168) ||
              (b[0] == 172 && b[1] >= 16 && b[1] <= 31)));
  if (uri.scheme != 'https' &&
      !(allowLocalHttp && uri.scheme == 'http' && local)) {
    throw const FormatException('KAZE requires a secure server connection.');
  }
  return uri.replace(path: '').toString();
}

class SessionAccess {
  final String baseUrl, id, token, role;
  final String? watchToken, guardianToken;
  SessionAccess({
    required String baseUrl,
    required this.id,
    required this.token,
    required this.role,
    this.watchToken,
    this.guardianToken,
  }) : baseUrl = validateBaseUrl(baseUrl) {
    if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(id) ||
        !RegExp(r'^[A-Za-z0-9_-]{32,128}$').hasMatch(token) ||
        !['owner', 'guardian'].contains(role)) {
      throw const FormatException('Invalid private session access.');
    }
  }
  factory SessionAccess.guardian(String link) {
    final uri = Uri.parse(link.trim());
    if (uri.path != '/guardian' || uri.userInfo.isNotEmpty || uri.hasQuery) {
      throw const FormatException('Paste the private guardian link.');
    }
    final fragment = Uri.splitQueryString(uri.fragment);
    return SessionAccess(
      baseUrl: uri.origin,
      id: fragment['session'] ?? '',
      token: fragment['token'] ?? '',
      role: 'guardian',
    );
  }
  factory SessionAccess.fromJson(Map<String, dynamic> j) => SessionAccess(
    baseUrl: j['baseUrl'],
    id: j['id'],
    token: j['token'],
    role: j['role'],
    watchToken: j['watchToken'],
    guardianToken: j['guardianToken'],
  );
  Map<String, dynamic> toJson() => {
    'baseUrl': baseUrl,
    'id': id,
    'token': token,
    'role': role,
    'watchToken': watchToken,
    'guardianToken': guardianToken,
  };
  Map<String, dynamic> get nativeConfig => {
    'baseUrl': baseUrl,
    'id': id,
    'ownerToken': token,
    'watchToken': watchToken,
  };
  String? get guardianLink => guardianToken == null
      ? null
      : Uri.parse('$baseUrl/guardian')
            .replace(
              fragment: Uri(
                queryParameters: {'session': id, 'token': guardianToken!},
              ).query,
            )
            .toString();
}

class ApiFailure implements Exception {
  final int status;
  final String message;
  ApiFailure(this.status, this.message);
  @override
  String toString() => message;
}

class SessionController extends ChangeNotifier {
  static const native = MethodChannel('app.kaze/session');
  final http.Client client;
  final FlutterSecureStorage storage;
  SessionAccess? access;
  Map<String, dynamic>? snapshot;
  Map<String, dynamic> device = {};
  String message = '', connection = 'Connecting to the PC…';
  bool busy = false, polling = false, visible = true, disposed = false;
  Timer? timer;
  int revision = 0;
  DateTime? received;
  SessionController({http.Client? client, FlutterSecureStorage? storage})
    : client = client ?? http.Client(),
      storage = storage ?? const FlutterSecureStorage();
  bool get guardian => access?.role == 'guardian';
  bool get backgroundGuardianSupported =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  bool get iosGuardian => defaultTargetPlatform == TargetPlatform.iOS;
  Map<String, dynamic> get _guardianConfiguration => {
    'id': access!.id,
    'baseUrl': access!.baseUrl,
    if (!iosGuardian) 'guardianToken': access!.token,
    if (iosGuardian && snapshot != null) ...{
      'phase': snapshot!['phase'],
      'serverNow': serverNow,
      'dueAt': snapshot!['dueAt'],
      'graceSeconds': snapshot!['graceSeconds'],
      'expiresAt': snapshot!['expiresAt'],
      'acknowledged': snapshot!['acknowledgedAt'] != null,
    },
  };
  Future<void> _refreshGuardianStatus() async {
    if (!backgroundGuardianSupported || !guardian) return;
    final current = access;
    final startedRevision = revision;
    try {
      final status = Map<String, dynamic>.from(
        await native.invokeMapMethod('guardianStatus') ?? {},
      );
      if (current != access || startedRevision != revision || disposed) return;
      device = status;
      if (iosGuardian && status['enabled'] == true && snapshot != null) {
        await native.invokeMethod('updateGuardian', _guardianConfiguration);
      }
    } catch (_) {
      if (current != access || startedRevision != revision || disposed) return;
      device = {'status': 'Background monitoring unavailable. Keep KAZE open.'};
    }
  }

  Future<void> setGuardianMonitoring(bool enabled) => run(() async {
    if (!guardian || !backgroundGuardianSupported) {
      throw const FormatException(
        'Guardian notifications are available on Android and iPhone.',
      );
    }
    if (enabled) {
      if (snapshot == null ||
          !['armed', 'challenge', 'alert'].contains(snapshot!['phase'])) {
        throw const FormatException(
          'Reconnect to an active session before enabling guardian alerts.',
        );
      }
      await native.invokeMethod('guardianPermissions');
      await native.invokeMethod(
        'startGuardian',
        jsonEncode(_guardianConfiguration),
      );
      if (iosGuardian) await _refreshGuardianStatus();
      if (iosGuardian && device['pushAvailable'] == true) {
        final registration = Map<String, dynamic>.from(
          await native.invokeMapMethod('guardianPushRegistration') ?? {},
        );
        // Keep cleanup metadata even if the registration response is lost.
        await native.invokeMethod('guardianPushPending');
        await api(action: 'guardian-push', body: registration);
        await native.invokeMethod(
          'guardianPushRegistered',
          registration['registrationId'],
        );
      }
    } else {
      await _stopGuardianMonitoring();
    }
    await _refreshGuardianStatus();
  });

  Future<void> _stopGuardianMonitoring() async {
    if (!backgroundGuardianSupported) return;
    final current = access;
    final startedRevision = revision;
    final status = iosGuardian
        ? await native.invokeMapMethod('guardianStatus')
        : null;
    if (current != access || startedRevision != revision || disposed) return;
    await native.invokeMethod('stopGuardian');
    if (current != access || startedRevision != revision || disposed) return;
    if (iosGuardian) {
      if ((status?['pushRegistered'] == true ||
              status?['pushPending'] == true) &&
          guardian &&
          status?['sessionId'] == access!.id) {
        try {
          await api(
            action: 'guardian-push',
            method: 'DELETE',
            body: {'registrationId': status!['registrationId']},
          );
        } on ApiFailure catch (e) {
          if (![401, 404].contains(e.status)) rethrow;
        }
        // If offline, preserve the access and registration metadata for a retry.
      }
      if (current != access || startedRevision != revision || disposed) return;
      await native.invokeMethod('clearGuardianPush');
    }
  }

  int get serverNow => (snapshot?['serverNow'] as num?)?.toInt() == null
      ? DateTime.now().millisecondsSinceEpoch
      : (snapshot!['serverNow'] as num).toInt() +
            DateTime.now().difference(received!).inMilliseconds;
  Future<Map<String, dynamic>> request(
    String base,
    String path, {
    String? token,
    Map<String, dynamic>? body,
    String? method,
  }) async {
    final req = http.Request(
      method ?? (body == null ? 'GET' : 'POST'),
      Uri.parse('$base$path'),
    )..followRedirects = false;
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 10)),
    ).timeout(const Duration(seconds: 10));
    final dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw ApiFailure(
        response.statusCode,
        'The server did not return a KAZE response.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiFailure(
        response.statusCode,
        decoded is Map
            ? decoded['error'] ?? 'Server refused the request.'
            : 'Server refused the request.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw ApiFailure(502, 'Invalid server response.');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> api({
    String action = '',
    Map<String, dynamic>? body,
    String? method,
  }) {
    final a = access!;
    return request(
      a.baseUrl,
      '/api/sessions/${a.id}${action.isEmpty ? '' : '/$action'}',
      token: a.token,
      body: body,
      method: method,
    );
  }

  Future<void> restore() async {
    try {
      final raw = await storage.read(key: 'session');
      if (raw != null) access = SessionAccess.fromJson(jsonDecode(raw));
    } catch (_) {
      message = 'Saved access could not be restored. Scan a new guardian QR code or enter a pairing code.';
    }
    if (backgroundGuardianSupported) {
      try {
        if (guardian) {
          await _refreshGuardianStatus();
          if (device['enabled'] == true && device['sessionId'] != access!.id) {
            await _stopGuardianMonitoring();
            await _refreshGuardianStatus();
          }
        } else {
          await _stopGuardianMonitoring();
        }
      } catch (_) {
        message = 'Could not confirm background guardian monitoring. Review Settings.';
      }
    }
    startPolling();
  }

  void startPolling() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (visible) {
        refresh();
      }
    });
    refresh();
  }

  void setVisible(bool value) {
    visible = value;
    if (!value && guardian) snapshot = null;
    if (value) refresh();
    changed();
  }

  Future<void> refresh() async {
    if (access == null || polling || busy || !visible || disposed) return;
    polling = true;
    final current = access;
    final startedRevision = revision;
    try {
      final data = await api();
      if (current != access ||
          startedRevision != revision ||
          !visible ||
          disposed) {
        return;
      }
      snapshot = data;
      received = DateTime.now();
      connection =
          'Connected to the PC. Only uploaded readings are available remotely.';
      if (Platform.isAndroid && !guardian) {
        device = Map<String, dynamic>.from(
          await native.invokeMapMethod('status') ?? {},
        );
      }
      if (guardian && backgroundGuardianSupported) {
        if (data['phase'] == 'resolved') await _stopGuardianMonitoring();
        await _refreshGuardianStatus();
      }
    } catch (e) {
      if (current != access || startedRevision != revision || disposed) return;
      connection = 'PC unavailable. New readings may still be queued on the wearer’s phone. Remote evidence is unavailable.';
      if (guardian) snapshot = null;
      if (e is ApiFailure && [401, 404].contains(e.status)) {
        try {
          await _stopGuardianMonitoring();
        } catch (_) {
          /* The native monitor independently checks revocation. */
        }
        if (current != access || startedRevision != revision || disposed) {
          return;
        }
        snapshot = null;
        message = 'Access expired, deleted or revoked. Evidence cleared.';
        access = null;
        await storage.delete(key: 'session');
      } else if (snapshot != null &&
          serverNow >= (snapshot!['expiresAt'] as num).toInt()) {
        snapshot = null;
      }
    } finally {
      polling = false;
      changed();
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    revision++;
    message = '';
    changed();
    try {
      await action();
    } catch (e) {
      message = e is FormatException
          ? e.message.toString()
          : e is PlatformException
          ? e.message ?? 'Could not change this setting.'
          : e.toString();
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> create({
    required String name,
    required int interval,
    required int grace,
    required bool live,
  }) => run(() async {
    if (!Platform.isAndroid) {
      throw const FormatException(
        'Use the Vivo Android phone for wearer recording. This phone can join as guardian.',
      );
    }
    await _stopGuardianMonitoring();
    final base = validateBaseUrl(kazeBackendUrl);
    final status = await native.invokeMapMethod('status');
    if (status?['active'] == true) {
      throw const FormatException(
        'End the active wearer session before creating another.',
      );
    }
    await native.invokeMethod('permissions');
    final data = await request(
      base,
      '/api/sessions',
      body: {
        'name': name.trim(),
        'consent': true,
        'simulation': true,
        'sensorMode': 'device',
        'motionSharingConsent': true,
        'intervalSeconds': interval,
        'graceSeconds': grace,
        'liveSharing': live,
        'liveSharingConsent': live,
      },
    );
    access = SessionAccess(
      baseUrl: base,
      id: data['id'],
      token: data['ownerToken'],
      role: 'owner',
      watchToken: data['watchToken'],
      guardianToken: data['guardianToken'],
    );
    snapshot = data;
    received = DateTime.now();
    await storage.write(key: 'session', value: jsonEncode(access!.toJson()));
    try {
      await native.invokeMethod('start', jsonEncode(access!.nativeConfig));
    } catch (_) {
      message = 'Session is registered on the server, but phone recording did not start. End it here if you do not intend to continue.';
    }
    startPolling();
  });

  Future<void> createSharedDemo(List<Map<String, Object>> route) => run(
    () async {
      if (access != null) {
        throw const FormatException(
          'Leave or end the current session before starting a shared demo.',
        );
      }
      if (Platform.isAndroid) {
        final status = await native.invokeMapMethod('status');
        if (status?['active'] == true) {
          throw const FormatException(
            'End wearer recording before starting a shared demo.',
          );
        }
      }
      final data = await request(
        validateBaseUrl(kazeBackendUrl),
        '/api/sessions',
        body: {
          'name': 'Virtual wearer (demo)',
          'consent': true,
          'simulation': true,
          'sensorMode': 'simulated',
          'liveSharing': true,
          'liveSharingConsent': true,
          'intervalSeconds': 3600,
          'graceSeconds': 30,
          'retentionHours': 1,
        },
      );
      access = SessionAccess(
        baseUrl: kazeBackendUrl,
        id: data['id'],
        token: data['ownerToken'],
        role: 'owner',
        guardianToken: data['guardianToken'],
        watchToken: data['watchToken'],
      );
      snapshot = data;
      received = DateTime.now();
      await storage.write(key: 'session', value: jsonEncode(access!.toJson()));
      startPolling();
      snapshot = await api(
        action: 'demo-walk',
        body: {'command': 'start', 'consent': true, 'route': route},
      );
      received = DateTime.now();
    },
  );

  Future<void> controlDemo(String command, {int? speed}) => run(() async {
    if (guardian || snapshot?['sensorMode'] != 'simulated') {
      throw const FormatException(
        'Only the demo owner controls simulated movement.',
      );
    }
    snapshot = await api(
      action: 'demo-walk',
      body: {'command': command, 'speed': ?speed},
    );
    received = DateTime.now();
  });
  Future<GuardianInvitation> createGuardianInvitation() async {
    final current = access;
    if (current == null ||
        guardian ||
        current.guardianToken == null ||
        snapshot == null ||
        snapshot!['guardianRevokedAt'] != null ||
        snapshot!['phase'] == 'resolved') {
      throw const FormatException(
        'An active wearer session is required to invite a guardian.',
      );
    }
    final data = await api(
      action: 'guardian-invite',
      body: {'guardianToken': current.guardianToken},
    );
    if (disposed ||
        current != access ||
        snapshot == null ||
        snapshot!['guardianRevokedAt'] != null ||
        snapshot!['phase'] == 'resolved') {
      throw const FormatException(
        'Session access changed. Reopen guardian pairing.',
      );
    }
    if (data['code'] is! String ||
        data['expiresAt'] is! int ||
        data['serverNow'] is! int ||
        data['expiresAt'] <= data['serverNow'] ||
        data['expiresAt'] - data['serverNow'] > 300000) {
      throw const FormatException(
        'The server returned an invalid pairing code.',
      );
    }
    final code = guardianPairingCode(data['code']);
    return GuardianInvitation(
      code: '${code.substring(0, 5)}-${code.substring(5)}',
      baseUrl: current.baseUrl,
      expiresAt: data['expiresAt'],
      serverNow: data['serverNow'],
    );
  }

  // Retain legacy invitations for saved builds; the app presents QR/code pairing.
  Future<void> join(String link) => run(() async {
    final next = SessionAccess.guardian(link);
    if (Uri.parse(next.baseUrl).origin !=
        Uri.parse(validateBaseUrl(kazeBackendUrl)).origin) {
      throw const FormatException(
        'This invitation belongs to a different KAZE service. Ask the wearer for a current invitation.',
      );
    }
    await _ensureGuardianDevice();
    await _joinGuardian(next);
  });

  Future<void> joinCode(String input) => run(() async {
    final code = guardianPairingCode(input);
    await _ensureGuardianDevice();
    final startedRevision = revision;
    final base = validateBaseUrl(kazeBackendUrl);
    final data = await request(
      base,
      '/api/guardian-invites/redeem',
      body: {'code': code},
    );
    if (disposed || !visible || revision != startedRevision) return;
    if (data['id'] is! String || data['guardianToken'] is! String) {
      throw const FormatException(
        'The server returned invalid guardian access.',
      );
    }
    await _joinGuardian(
      SessionAccess(
        baseUrl: base,
        id: data['id'],
        token: data['guardianToken'],
        role: 'guardian',
      ),
    );
  });

  Future<bool> prepareGuardianScan() async {
    var allowed = false;
    await run(() async {
      await _ensureGuardianDevice();
      allowed = true;
    });
    return allowed && !disposed && visible;
  }

  Future<void> _ensureGuardianDevice() async {
    if (Platform.isAndroid &&
        (await native.invokeMapMethod('status'))?['active'] == true) {
      throw const FormatException(
        'End your local recording session before using this phone as guardian.',
      );
    }
  }

  Future<void> _joinGuardian(SessionAccess next) async {
    final startedRevision = revision;
    final data = await request(
      next.baseUrl,
      '/api/sessions/${next.id}',
      token: next.token,
    );
    if (data['role'] != 'guardian') {
      throw const FormatException(
        'This invitation does not grant guardian access.',
      );
    }
    if (disposed || !visible || revision != startedRevision) return;
    await _stopGuardianMonitoring();
    if (disposed || !visible || revision != startedRevision) return;
    access = next;
    device = {};
    snapshot = data;
    received = DateTime.now();
    await storage.write(key: 'session', value: jsonEncode(next.toJson()));
    if (disposed || !visible || revision != startedRevision) return;
    await _refreshGuardianStatus();
    startPolling();
  }

  Future<void> mutate(String action) => run(() async {
    final data = await api(action: action, body: {'confirm': true});
    snapshot = data;
    received = DateTime.now();
    message = action == 'check-in'
        ? 'Check-in confirmed by server.'
        : 'Confirmed by server.';
    if (Platform.isAndroid && !guardian) await native.invokeMethod('refresh');
  });
  Future<void> deleteSession() => run(() async {
    await api(body: {}, method: 'DELETE');
    if (Platform.isAndroid && !guardian) await native.invokeMethod('refresh');
    await _clearAccess();
  });
  Future<void> forget() => run(_clearAccess);
  Future<void> _clearAccess() async {
    revision++;
    await _stopGuardianMonitoring();
    await storage.delete(key: 'session');
    access = null;
    snapshot = null;
    device = {};
    changed();
  }

  void changed() {
    if (!disposed) notifyListeners();
  }

  @override
  void dispose() {
    disposed = true;
    timer?.cancel();
    client.close();
    super.dispose();
  }
}
