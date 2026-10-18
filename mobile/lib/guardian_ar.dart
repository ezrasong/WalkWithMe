import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';

import 'session.dart';
import 'spatial_registration.dart';
import 'ar_demo.dart';
import 'camera_trail_overlay.dart';
import 'direction_preview.dart';
import 'camera_navigation.dart';

class GuardianAr extends StatefulWidget {
  final SessionController session;
  final bool demo;
  final bool geospatial;
  const GuardianAr({
    super.key,
    required this.session,
    this.demo = false,
    this.geospatial = false,
  });
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
  CameraTrailGuidance guidance = CameraTrailGuidance();
  ArDemoWalk? demoWalk;
  CameraController? demoCamera;
  bool demoRendering = false;
  bool compassGuide = false;
  CameraTrailCue? cue;
  List<Map<String, Object>> renderedPoints = [];
  Map<String, Object>? guardianLocation;
  String? get targetStreet {
    for (final point in renderedPoints) {
      if (point['id'] == guidance.target && point['street'] is String) {
        return point['street'] as String;
      }
    }
    return widget.session.snapshot?['geography']?['latest']?['street']
        as String?;
  }

  double? cameraX, cameraZ, forwardX, forwardZ;
  String status = 'Checking guardian access and native AR support.';
  bool get authorized =>
      widget.session.visible &&
      identical(widget.session.access, openingAccess) &&
      (widget.demo ||
          ((widget.session.guardian || sharedSimulation) &&
              (widget.session.snapshot?['phase'] == 'alert' ||
                  sharedSimulation) &&
              widget.session.snapshot?['shared'] == true &&
              widget.session.serverNow <
                  (widget.session.snapshot?['expiresAt'] as num? ?? 0)));
  bool get sharedSimulation =>
      widget.session.snapshot?['sensorMode'] == 'simulated' &&
      widget.session.snapshot?['demoWalk'] != null &&
      widget.session.snapshot?['phase'] != 'resolved';

  @override
  void initState() {
    super.initState();
    openingAccess = widget.session.access;
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(accessChanged);
    timer = Timer.periodic(
      widget.demo
          ? const Duration(milliseconds: 100)
          : const Duration(seconds: 1),
      (_) => tick(),
    );
    start();
  }

  void accessChanged() {
    if (!authorized) close('Guardian access unavailable. Use the map.');
  }

  Future<void> start() async {
    debugPrint(
      widget.demo
          ? '[KAZE AR] Opening local camera preview.'
          : '[KAZE AR] Opening guardian spatial AR.',
    );
    try {
      if (!authorized) {
        throw StateError(
          'An authorized active assistance request is required.',
        );
      }
      if (!widget.demo) await fetch();
      if (closed || !mounted) return;
      debugPrint(
        widget.demo
            ? '[KAZE AR] Checking camera preview support and permission.'
            : '[KAZE AR] Recorded evidence accepted. Checking native support and permissions.',
      );
      final result = await SessionController.native.invokeMethod<String>(
        'prepareGuardianAr',
        widget.demo ? {'demo': true} : null,
      );
      if (closed || !mounted || !authorized) return;
      if (widget.demo && result == 'demo-camera') {
        await startCameraDemo();
        return;
      }
      if (!widget.demo && result == 'camera-guide') {
        timer?.cancel();
        setState(() => compassGuide = true);
        return;
      }
      if (result != 'ready') {
        close(result ?? 'AR unsupported. Use the map.');
        return;
      }
      debugPrint('[KAZE AR] Native AR ready. Starting camera tracking.');
      setState(() {
        prepared = true;
        status = widget.geospatial
            ? 'Look at outdoor buildings and signs while standing safely. Waiting for precise Google-assisted alignment.'
            : 'Move the phone slowly to start camera tracking.';
      });
    } catch (_) {
      if (!closed) {
        close(
          widget.demo
              ? 'Camera access unavailable. Close and reopen the preview.'
              : 'Native AR or camera/precise location access unavailable. Use the map.',
        );
      }
    }
  }

  Future<void> startCameraDemo() async {
    final cameras = await availableCameras();
    if (closed || !mounted || !authorized) return;
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
    );
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    demoCamera = controller;
    await controller.initialize();
    if (closed || !mounted || !authorized) return;
    controller.addListener(() {
      if (!closed && controller.value.hasError) {
        // Dispose after CameraController finishes notifying its listeners.
        scheduleMicrotask(() {
          if (!closed) {
            close('Camera unavailable. Close and reopen the preview.');
          }
        });
      }
    });
    demoWalk = ArDemoWalk.fromPose({
      'x': 0,
      'y': 1.3,
      'z': 0,
      'forwardX': 0,
      'forwardZ': -1,
    });
    cameraX = 0;
    cameraZ = 0;
    forwardX = 0;
    forwardZ = -1;
    renderedPoints = demoWalk!.points;
    setState(() {
      prepared = true;
      status = 'Camera ready. This animation does not track phone movement or locate a real wearer. Start the walker when you are ready.';
    });
    debugPrint('[KAZE AR] Camera preview ready.');
  }

  Future<void> fetch() async {
    if (widget.demo || closed || loading || !authorized) return;
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
    startupTimer = Timer(Duration(seconds: widget.geospatial ? 60 : 15), () {
      if (widget.demo ? demoWalk == null : sampled == null) {
        close(
          widget.demo
              ? 'Camera tracking unavailable. Reopen the preview and point at a well-lit space.'
              : widget.geospatial
              ? 'Google alignment did not obtain precise outdoor tracking. Reopen the camera and choose local alignment or use the map.'
              : 'Precise synchronized outdoor location unavailable. Use the map.',
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
              : widget.demo
              ? 'Camera tracking or permission lost. Close and reopen the preview.'
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
          if (widget.demo && demoWalk == null) {
            demoWalk = ArDemoWalk.fromPose(pose);
            if (demoWalk != null) {
              debugPrint('[KAZE AR] Camera preview tracking ready.');
              startupTimer?.cancel();
              status = 'Ready. Start the walker, then follow the pink trail.';
            }
          }
          updateCue();
          if (mounted) setState(() {});
        }
        return;
      }
      if (widget.demo ||
          call.method != (widget.geospatial ? 'geospatial' : 'sample') ||
          registration == null) {
        return;
      }
      final sample = call.arguments is Map
          ? SpatialSample.parse(call.arguments as Map, registration!.anchor)
          : null;
      if (sample == null) {
        if (registration!.ready) {
          close('Precise synchronized location lost. Use the map.');
        }
        return;
      }
      if (widget.geospatial &&
          !registration!.addGeospatial(call.arguments as Map)) {
        if (registration!.ready) {
          close(
            'Google alignment precision lost. Reopen the camera or use the map.',
          );
        }
        return;
      }
      sampled = DateTime.now();
      startupTimer?.cancel();
      final raw = call.arguments as Map;
      guardianLocation = {
        'latitude': raw['latitude'] as num,
        'longitude': raw['longitude'] as num,
      };
      if (!widget.geospatial) registration!.add(sample);
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
    c
        .invokeMethod(
          'start',
          widget.demo
              ? {'demo': true}
              : widget.geospatial
              ? {'geospatial': true}
              : null,
        )
        .catchError((Object _) {
          close('Native AR unavailable. Use the map.');
        });
  }

  Future<void> tick() async {
    if (closed) return;
    if (!authorized) {
      close('Guardian access unavailable. Use the map.');
      return;
    }
    if (widget.demo) {
      if (demoRendering || demoWalk == null) return;
      demoRendering = true;
      try {
        demoWalk!.advance(const Duration(milliseconds: 100));
        final points = demoWalk!.points;
        renderedPoints = points;
        count = points.length;
        updateCue(points);
        await channel?.invokeMethod('render', points);
        if (mounted && !closed) setState(() {});
      } catch (_) {
        close('Camera overlay unavailable. Close and reopen the preview.');
      } finally {
        demoRendering = false;
      }
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
    if (closed || packet == null) return;
    if (sampled == null) {
      if (widget.geospatial) await channel?.invokeMethod('render', []);
      return;
    }
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
    if ((widget.demo
            ? demoWalk == null
            : registration?.ready != true || packet == null) ||
        cameraX == null) {
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
    demoWalk = null;
    cue = null;
    renderedPoints = [];
    demoCamera?.dispose().catchError((Object _) {});
    demoCamera = null;
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
      close(
        widget.demo
            ? 'Camera closed when the app lost focus. Reopen the preview.'
            : 'Camera closed when app lost focus. Reopen AR from the map.',
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(accessChanged);
    timer?.cancel();
    startupTimer?.cancel();
    demoCamera?.dispose().catchError((Object _) {});
    channel?.invokeMethod('stop').catchError((Object _) {});
    channel?.setMethodCallHandler(null);
    super.dispose();
  }

  Widget demoControls() => Padding(
    padding: const EdgeInsets.all(12),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: demoWalk == null
              ? null
              : () => setState(() {
                  if (demoWalk!.complete) guidance = CameraTrailGuidance();
                  demoWalk!.toggle();
                }),
          icon: Icon(
            demoWalk?.playing == true ? Icons.pause : Icons.play_arrow,
          ),
          label: Text(demoWalk?.button ?? 'Start walk'),
        ),
        TextButton(
          onPressed: demoWalk == null
              ? null
              : () => setState(() {
                  demoWalk!.restart();
                  guidance = CameraTrailGuidance();
                }),
          child: const Text('Restart walk'),
        ),
        for (final speed in [1.0, 2.0])
          ChoiceChip(
            label: Text('${speed.toInt()}x speed'),
            selected: demoWalk?.speed == speed,
            onSelected: demoWalk == null
                ? null
                : (_) => setState(() => demoWalk!.speed = speed),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => compassGuide
      ? DirectionPreview(session: widget.session)
      : !widget.demo && prepared && !closed
      ? CameraNavigation(
          camera: Platform.isAndroid
              ? AndroidView(
                  viewType: 'app.kaze/guardian-ar',
                  onPlatformViewCreated: created,
                )
              : UiKitView(
                  viewType: 'app.kaze/guardian-ar',
                  onPlatformViewCreated: created,
                ),
          snapshot: widget.session.snapshot ?? {},
          guardianLocation: guardianLocation,
          turn: cue?.turn,
          distance: cue?.distance,
          nearby: cue?.nearby ?? false,
          simulated: sharedSimulation,
          mode: registration?.ready == true
              ? widget.geospatial
                    ? 'Outdoor Google-assisted alignment'
                    : 'Outdoor locally aligned AR'
              : widget.geospatial
              ? 'Looking for outdoor visual features'
              : 'Aligning camera',
          street: targetStreet,
          details:
              '$status Outdoor use only; indoor tracking is not working. Missing heights use a floating horizontal guide. No ground or obstacle detection.',
        )
      : Scaffold(
          appBar: AppBar(
            title: Text(
              widget.demo ? 'WalkWithMe camera preview' : 'Outdoor spatial AR',
            ),
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: Column(
                  children: [
                    if (!closed)
                      Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          widget.demo
                              ? 'Follow the walker along the pink camera trail. Point toward a well-lit open space, then start.'
                              : 'Outdoor use only. Indoor tracking and indoor AR navigation are not working. Align using accurate outdoor locations and the instructed registration walk. Missing heights use a floating horizontal guide. Ground, walls, stairs and obstacles are not detected. Camera processing stays on this phone.',
                        ),
                      ),
                    if (widget.demo && !closed) demoControls(),
                    if (!closed)
                      SizedBox(
                        height: constraints.maxHeight * .5,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            prepared && demoCamera != null
                                ? CameraPreview(
                                    demoCamera!,
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: CameraTrailOverlay(
                                          renderedPoints,
                                        ),
                                      ),
                                    ),
                                  )
                                : prepared
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
                            if (widget.demo || sharedSimulation)
                              Positioned(
                                top: 12,
                                left: 12,
                                right: 12,
                                child: IgnorePointer(
                                  child: Material(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surface,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Text(
                                        demoCamera != null
                                            ? 'Camera placement'
                                            : sharedSimulation
                                            ? 'Shared walker'
                                            : 'Walker',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (cue != null)
                              Positioned(
                                left: 16,
                                bottom: 16,
                                child: Semantics(
                                  label: widget.demo
                                      ? 'Direction: ${cue!.direction}. Walker about ${cue!.distance.round()} metres away.'
                                      : cue!.message,
                                  child: Material(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .surface,
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
                            if (cue != null && !widget.demo) ...[
                              const SizedBox(height: 8),
                              Text(cue!.message),
                            ],
                            if (cue != null && widget.demo)
                              Text(
                                'Direction: ${cue!.direction}; walker about ${cue!.distance.round()} m away.',
                              ),
                            if (registration?.ready == true && cue == null)
                              const Text(
                                'Point the camera ahead. If this trail section is no longer visible, use the map to choose the next safe section.',
                              ),
                            const SizedBox(height: 8),
                            Text(
                              closed
                                  ? widget.demo
                                        ? 'No positions were saved or shared.'
                                        : 'Recorded locations remain on the map.'
                                  : widget.demo
                                  ? '${demoWalk?.distance.toStringAsFixed(1) ?? '0.0'} / 18 m walk. Pink figure: walker.'
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
                        child: Text(
                          widget.demo ? 'Close preview' : 'Return to map',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
}
