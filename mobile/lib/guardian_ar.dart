import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'session.dart';
import 'spatial_registration.dart';

class GuardianAr extends StatefulWidget {
  final SessionController session;
  const GuardianAr({super.key, required this.session});
  @override
  State<GuardianAr> createState() => _GuardianArState();
}

class _GuardianArState extends State<GuardianAr> with WidgetsBindingObserver {
  MethodChannel? channel;
  SpatialRegistration? registration;
  Map<String, dynamic>? packet;
  Timer? timer, startupTimer;
  DateTime? fetched, sampled;
  late final SessionAccess? openingAccess;
  bool prepared = false, closed = false, loading = false;
  int count = 0;
  String status = 'Checking guardian access and native AR support.';
  bool get authorized =>
      widget.session.visible &&
      identical(widget.session.access, openingAccess) &&
      widget.session.guardian &&
      widget.session.snapshot?['phase'] == 'alert' &&
      widget.session.snapshot?['shared'] == true &&
      widget.session.serverNow <
          (widget.session.snapshot?['expiresAt'] as num? ?? 0);

  @override
  void initState() {
    super.initState();
    openingAccess = widget.session.access;
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(accessChanged);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    start();
  }

  void accessChanged() {
    if (!authorized) close('Guardian access unavailable. Use the map.');
  }

  Future<void> start() async {
    try {
      if (!authorized) {
        throw StateError(
          'An authorized active assistance request is required.',
        );
      }
      await fetch();
      if (closed || !mounted) return;
      final result = await SessionController.native.invokeMethod<String>(
        'prepareGuardianAr',
      );
      if (closed || !mounted || !authorized) return;
      if (result != 'ready') {
        close(result ?? 'AR unsupported. Use the map.');
        return;
      }
      setState(() {
        prepared = true;
        status = 'Move the phone slowly to start camera tracking.';
      });
    } catch (_) {
      if (!closed) {
        close(
          'Native AR or camera/precise location access unavailable. Use the map.',
        );
      }
    }
  }

  Future<void> fetch() async {
    if (closed || loading || !authorized) return;
    loading = true;
    final access = widget.session.access;
    try {
      final next = await widget.session.api(action: 'ar');
      if (closed ||
          !mounted ||
          !authorized ||
          access != widget.session.access) {
        return;
      }
      if (next['version'] != 1 ||
          next['available'] != true ||
          next['fallback'] == 'map' ||
          next['frame']?['kind'] != 'WGS84-local-tangent' ||
          next['frame']?['units'] != 'meters' ||
          next['frame']?['axes']?['x'] != 'east' ||
          next['frame']?['axes']?['y'] != 'up' ||
          next['frame']?['axes']?['z'] != 'south') {
        close('Fresh usable recorded locations unavailable. Use the map.');
        return;
      }
      final anchor = next['frame']['anchor'] as Map;
      if (anchor['altitudeDatum'] != 'WGS84-ellipsoid' ||
          anchor['altitude'] is! num ||
          !(next['paths'] as List).any(
            (path) => (path['points'] as List).any(
              (p) => p['y'] is num && p['altitudeDatum'] == 'WGS84-ellipsoid',
            ),
          )) {
        close(
          'Recorded heights have no compatible vertical reference. Use the map.',
        );
        return;
      }
      if (registration != null && registration!.anchor['id'] != anchor['id']) {
        close('Recorded frame changed. Reopen AR to register again.');
        return;
      }
      registration ??= SpatialRegistration(anchor);
      packet = next;
      fetched = DateTime.now();
    } catch (_) {
      close('Recorded evidence or authorization unavailable. Use the map.');
    } finally {
      loading = false;
    }
  }

  void created(int id) {
    startupTimer = Timer(const Duration(seconds: 15), () {
      if (sampled == null) {
        close(
          'Precise synchronized outdoor location unavailable. Use the map.',
        );
      }
    });
    final c = MethodChannel('app.kaze/guardian-ar/$id');
    channel = c;
    c.setMethodCallHandler((call) async {
      if (closed || !authorized) {
        close('Guardian access unavailable. Use the map.');
        return;
      }
      if (call.method == 'failure') {
        close('Camera tracking, permissions or location lost. Use the map.');
        return;
      }
      if (call.method != 'sample' || registration == null) return;
      final sample = call.arguments is Map
          ? SpatialSample.parse(call.arguments as Map, registration!.anchor)
          : null;
      if (sample == null) {
        if (registration!.ready) {
          close('Precise synchronized location lost. Use the map.');
        }
        return;
      }
      sampled = DateTime.now();
      registration!.add(sample);
      if (registration!.failed) {
        close(registration!.status);
        return;
      }
      if (mounted) setState(() => status = registration!.status);
    });
    if (closed) {
      startupTimer?.cancel();
      c.invokeMethod('stop');
      return;
    }
    c.invokeMethod('start').catchError((Object _) {
      close('Native AR unavailable. Use the map.');
    });
  }

  Future<void> tick() async {
    if (closed) return;
    if (!authorized) {
      close('Guardian access unavailable. Use the map.');
      return;
    }
    final now = DateTime.now();
    if ((fetched != null && now.difference(fetched!).inSeconds >= 5) ||
        (sampled != null && now.difference(sampled!).inSeconds >= 3)) {
      close('Location or connection is stale. Reopen AR to register again.');
      return;
    }
    if (packet != null &&
        widget.session.serverNow - (packet!['latestFixAt'] as num) > 30000) {
      close('Last wearer location is stale. Use the map.');
      return;
    }
    await fetch();
    if (closed || packet == null || sampled == null) return;
    final points = registration!.breadcrumbs(packet!);
    if (registration!.ready && points.isEmpty) {
      close(
        'No recorded observations meet current 3D uncertainty limits. Use the map.',
      );
      return;
    }
    count = points.length;
    try {
      await channel?.invokeMethod('render', points);
    } catch (_) {
      close('Native renderer unavailable. Use the map.');
      return;
    }
    if (mounted) setState(() {});
  }

  void close(String reason) {
    if (closed) return;
    closed = true;
    timer?.cancel();
    startupTimer?.cancel();
    packet = null;
    registration = null;
    channel?.invokeMethod('stop').catchError((Object _) {});
    if (mounted) {
      setState(() {
        prepared = false;
        status = reason;
        count = 0;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        (prepared || state != AppLifecycleState.inactive)) {
      close('Camera closed when app lost focus. Reopen AR from the map.');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(accessChanged);
    timer?.cancel();
    startupTimer?.cancel();
    channel?.invokeMethod('stop').catchError((Object _) {});
    channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Guardian spatial AR')),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Experimental outdoor observations. Walk only where safe. Camera processing stays on this guardian phone. No floor, stair, wall, obstacle or route guidance.',
                ),
              ),
              SizedBox(
                height: constraints.maxHeight * .5,
                child: prepared
                    ? (Platform.isAndroid
                          ? AndroidView(
                              viewType: 'app.kaze/guardian-ar',
                              onPlatformViewCreated: created,
                            )
                          : UiKitView(
                              viewType: 'app.kaze/guardian-ar',
                              onPlatformViewCreated: created,
                            ))
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            closed
                                ? 'AR closed. Recorded locations remain on the map.'
                                : status,
                          ),
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    '$status\n$count supported breadcrumbs. Cyan: phone. Orange: watch (may be phone-derived). Rings and bars show uncertainty allowances up to 10 m. Unknown heights and excessive uncertainty are omitted; gaps are never joined.',
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Return to map'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
