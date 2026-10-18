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
  final guidance = CameraTrailGuidance();
  CameraTrailCue? cue;
  List<Map<String, Object>> renderedPoints = [];
  double? cameraX, cameraZ, forwardX, forwardZ;
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
    debugPrint('[KAZE AR] Opening guardian spatial AR.');
    try {
      if (!authorized) {
        throw StateError(
          'An authorized active assistance request is required.',
        );
      }
      await fetch();
      if (closed || !mounted) return;
      debugPrint(
        '[KAZE AR] Recorded evidence accepted. Checking native support and permissions.',
      );
      final result = await SessionController.native.invokeMethod<String>(
        'prepareGuardianAr',
      );
      if (closed || !mounted || !authorized) return;
      if (result != 'ready') {
        close(result ?? 'AR unsupported. Use the map.');
        return;
      }
      debugPrint('[KAZE AR] Native AR ready. Starting camera tracking.');
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
        close(
          call.arguments is String
              ? call.arguments as String
              : 'Camera tracking, permissions or location lost. Use the map.',
        );
        return;
      }
      if (call.method == 'pose' && call.arguments is Map) {
        final pose = call.arguments as Map;
        if ([
          'x',
          'z',
          'forwardX',
          'forwardZ',
        ].every((key) => pose[key] is num && (pose[key] as num).isFinite)) {
          cameraX = (pose['x'] as num).toDouble();
          cameraZ = (pose['z'] as num).toDouble();
          forwardX = (pose['forwardX'] as num).toDouble();
          forwardZ = (pose['forwardZ'] as num).toDouble();
          updateCue();
          if (mounted) setState(() {});
        }
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
        'No nearby recorded points meet horizontal accuracy limits. Use the map.',
      );
      return;
    }
    count = points.length;
    renderedPoints = points;
    updateCue(points);
    try {
      await channel?.invokeMethod('render', points);
    } catch (_) {
      close('Native renderer unavailable. Use the map.');
      return;
    }
    if (mounted) setState(() {});
  }

  void updateCue([List<Map<String, Object>>? points]) {
    if (registration?.ready != true || packet == null || cameraX == null) {
      cue = null;
      return;
    }
    cue = guidance.update(
      points ?? renderedPoints,
      x: cameraX!,
      z: cameraZ!,
      forwardX: forwardX!,
      forwardZ: forwardZ!,
    );
  }

  void close(String reason) {
    if (closed) return;
    // Reasons are local status messages, never evidence packets or credentials.
    debugPrint('[KAZE AR] Closed: $reason');
    closed = true;
    timer?.cancel();
    startupTimer?.cancel();
    packet = null;
    registration = null;
    cue = null;
    renderedPoints = [];
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
              if (!closed)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Follow the recorded outdoor trail only where safe. Align the camera by walking as instructed. Missing heights use a floating horizontal guide, not the ground or a floor. Walls, stairs and obstacles are not detected. Camera processing stays on this phone.',
                  ),
                ),
              if (!closed)
                SizedBox(
                  height: constraints.maxHeight * .5,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      prepared
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
                                child: Text(status),
                              ),
                            ),
                      if (cue != null)
                        Positioned(
                          left: 16,
                          bottom: 16,
                          child: Semantics(
                            label: cue!.message,
                            child: Material(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(16),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (!cue!.nearby)
                                      Transform.rotate(
                                        angle: cue!.turn,
                                        child: const Icon(
                                          Icons.arrow_upward,
                                          size: 48,
                                        ),
                                      )
                                    else
                                      const Icon(
                                        Icons.location_searching,
                                        size: 48,
                                      ),
                                    Text('~${cue!.distance.round()} m'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Semantics(
                  liveRegion: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (closed) ...[
                        Text(
                          'AR closed',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(status),
                      if (cue != null) ...[
                        const SizedBox(height: 8),
                        Text(cue!.message),
                      ],
                      if (registration?.ready == true && cue == null)
                        const Text(
                          'Point the camera ahead. If this trail section is no longer visible, use the map to choose the next safe section.',
                        ),
                      const SizedBox(height: 8),
                      Text(
                        closed
                            ? 'Recorded locations remain on the map.'
                            : '$count recorded breadcrumbs. Cyan: phone. Orange: watch (may be phone-derived). Rings show horizontal uncertainty up to 25 m. Vertical bars appear only with compatible measured heights. Floating guides have no measured height. Gaps are never joined.',
                      ),
                    ],
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
