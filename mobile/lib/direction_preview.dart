import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import 'session.dart';
import 'camera_geography.dart';
import 'camera_trail_overlay.dart';
import 'camera_navigation.dart';
import 'spatial_registration.dart';

// A fallback outdoor compass cue. No shared spatial anchor or geometry is assumed.
class DirectionPreview extends StatefulWidget {
  final SessionController session;
  const DirectionPreview({super.key, required this.session});
  @override
  State<DirectionPreview> createState() => _DirectionPreviewState();
}

class _DirectionPreviewState extends State<DirectionPreview>
    with WidgetsBindingObserver {
  CameraController? camera;
  StreamSubscription<Position>? positions;
  StreamSubscription<CompassEvent>? compass;
  Position? position;
  double? heading;
  double? trueNorthOffset = Platform.isAndroid ? null : 0;
  bool declinationPending = false;
  CameraTrailGuidance progress = CameraTrailGuidance();
  Object? demoRun;
  DateTime? headingAt;
  Timer? timer;
  late final SessionAccess? openingAccess;
  bool closed = false;
  String status = 'Waiting for camera, location and compass permission…';
  bool get authorized =>
      widget.session.visible &&
      identical(widget.session.access, openingAccess) &&
      (widget.session.guardian || sharedDemo) &&
      (widget.session.snapshot?['phase'] == 'alert' || sharedDemo) &&
      widget.session.snapshot?['shared'] == true &&
      (widget.session.snapshot?['expiresAt'] == null ||
          widget.session.serverNow <
              (widget.session.snapshot!['expiresAt'] as num));
  bool get sharedDemo =>
      widget.session.snapshot?['sensorMode'] == 'simulated' &&
      widget.session.snapshot?['demoWalk'] != null &&
      widget.session.snapshot?['phase'] != 'resolved';
  @override
  void initState() {
    super.initState();
    openingAccess = widget.session.access;
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(sessionChanged);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
      sessionChanged();
    });
    start();
  }

  void sessionChanged() {
    if (!authorized) {
      stop();
      if (mounted) {
        setState(
          () => status =
              'Access unavailable or session ended. Return to the map.',
        );
      }
    }
  }

  Future<void> start() async {
    try {
      if (!authorized) {
        throw StateError(
          'An authorized active assistance request is required.',
        );
      }
      var permission = await Geolocator.checkPermission();
      if (closed || !mounted || !authorized) return;
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (closed || !mounted || !authorized) return;
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Location permission denied. Use the map.');
      }
      final cameras = await availableCameras();
      if (closed || !mounted || !authorized) return;
      if (cameras.isEmpty) throw StateError('Camera unavailable. Use the map.');
      final c = CameraController(
        cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        ),
        ResolutionPreset.medium,
        enableAudio: false,
      );
      camera = c;
      await c.initialize();
      if (closed || !mounted || !authorized) {
        await c.dispose();
        return;
      }
      c.addListener(() {
        if (!closed && c.value.hasError) {
          scheduleMicrotask(() {
            if (!closed) {
              stop();
              if (mounted) {
                setState(
                  () => status = 'Camera unavailable. Return to the map.',
                );
              }
            }
          });
        }
      });
      positions =
          Geolocator.getPositionStream(
            locationSettings: Platform.isAndroid
                ? AndroidSettings(
                    accuracy: LocationAccuracy.bestForNavigation,
                    distanceFilter: 0,
                    intervalDuration: const Duration(seconds: 1),
                  )
                : AppleSettings(
                    accuracy: LocationAccuracy.bestForNavigation,
                    distanceFilter: 0,
                    pauseLocationUpdatesAutomatically: false,
                  ),
          ).listen(
            (p) {
              if (mounted) setState(() => position = p);
              if (Platform.isAndroid &&
                  trueNorthOffset == null &&
                  !declinationPending &&
                  !p.isMocked) {
                declinationPending = true;
                SessionController.native
                    .invokeMethod<num>('magneticDeclination', {
                      'latitude': p.latitude,
                      'longitude': p.longitude,
                    })
                    .then((value) {
                      if (!closed &&
                          mounted &&
                          value != null &&
                          value.isFinite) {
                        setState(() => trueNorthOffset = value.toDouble());
                      }
                    })
                    .catchError((Object _) {})
                    .whenComplete(() => declinationPending = false);
              }
            },
            onError: (_) {
              if (mounted) {
                setState(() {
                  position = null;
                  status = 'Location unavailable. Use the map.';
                });
              }
            },
          );
      compass = FlutterCompass.events?.listen(
        (e) {
          if (mounted) {
            setState(() {
              final raw = directionHeading(e, camera: true);
              heading = raw == null || trueNorthOffset == null
                  ? null
                  : (raw + trueNorthOffset! + 360) % 360;
              headingAt = DateTime.now();
            });
          }
        },
        onError: (_) {
          if (mounted) setState(() => heading = null);
        },
      );
      setState(
        () => status =
            'Move outdoors and wait for a fresh location and compass heading.',
      );
    } catch (e) {
      stop();
      if (mounted) setState(() => status = 'Camera direction unavailable: $e');
    }
  }

  void stop() {
    closed = true;
    positions?.cancel();
    positions = null;
    compass?.cancel();
    compass = null;
    final c = camera;
    camera = null;
    c?.dispose().catchError((Object _) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      stop();
      if (mounted) {
        setState(
          () => status =
              'Camera closed. Return to the map and reopen the preview.',
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(sessionChanged);
    timer?.cancel();
    stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nextRun = widget.session.snapshot?['demoWalk']?['runId'];
    if (nextRun != demoRun) {
      demoRun = nextRun;
      progress = CameraTrailGuidance();
    }
    final guide = geographicCameraGuide(
      snapshot: widget.session.snapshot ?? {},
      authorized: authorized && !closed,
      position: position,
      heading: heading,
      headingAt: headingAt,
      now: DateTime.now(),
      serverNow: widget.session.serverNow,
      progress: progress,
    );
    if (camera?.value.isInitialized == true && !closed) {
      return CameraNavigation(
        camera: CameraPreview(
          camera!,
          child: guide == null || guide.nearby
              ? null
              : IgnorePointer(
                  child: CustomPaint(
                    painter: CameraTrailOverlay(
                      guide.points,
                      color: sharedDemo
                          ? Colors.pinkAccent
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
        ),
        snapshot: widget.session.snapshot ?? {},
        guardianLocation: position == null || position!.isMocked
            ? null
            : {
                'latitude': position!.latitude,
                'longitude': position!.longitude,
              },
        turn: guide?.turn,
        distance: guide?.distance,
        nearby: guide?.nearby ?? false,
        street: guide?.street,
        simulated: sharedDemo,
        mode: 'Approximate GPS + compass',
        details: guide == null
            ? 'Waiting for fresh precise locations and compass. Move outdoors, hold the phone upright and calibrate the compass. Guidance stays hidden until readings are usable.'
            : 'Next recorded point. Location uncertainty allowance ${guide.uncertainty.round()} m. No ground or obstacle detection; arrival is not verified.',
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Guardian camera guide')),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'GPS + compass camera guide. Trail placement and height are approximate, not anchored to the room or ground. Keep the phone upright. Check the map and real surroundings; obstacles and floors are not detected.',
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(status),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  guide != null
                      ? '${sharedDemo ? 'DEMO. ' : ''}${guide.nearby ? 'Within combined location uncertainty; search nearby, arrival is not verified.' : 'Approximate direction to the last shared point. Turn the camera toward the arrow.'} About ${guide.distance.round()} m, horizontal uncertainty allowance ${guide.uncertainty.round()} m.'
                      : directionCue(
                          authorized: authorized,
                          target:
                              widget.session.snapshot?['geography']?['latest']
                                  as Map?,
                          position: position,
                          heading: heading,
                          headingAt: headingAt,
                          now: DateTime.now(),
                          serverNow: widget.session.serverNow,
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Return to map'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String directionCue({
  required bool authorized,
  required Map? target,
  required Position? position,
  required double? heading,
  required DateTime? headingAt,
  required DateTime now,
  required int serverNow,
}) {
  final p = position;
  if (!authorized ||
      target == null ||
      p == null ||
      heading == null ||
      headingAt == null ||
      now.difference(headingAt).inSeconds > 3 ||
      now.difference(p.timestamp).inSeconds > 10 ||
      serverNow - (target['fixAt'] as num) > 30000 ||
      (target['accuracy'] as num) > 20 ||
      p.accuracy > 20 ||
      p.isMocked ||
      target['mock'] == true) {
    return 'Use the map: direction requires fresh outdoor locations with reported accuracy of 20 m or better and a current compass heading.';
  }
  final lat = (target['latitude'] as num).toDouble(),
      lon = (target['longitude'] as num).toDouble();
  final distance = Geolocator.distanceBetween(
    p.latitude,
    p.longitude,
    lat,
    lon,
  );
  if (distance <= p.accuracy + (target['accuracy'] as num)) {
    return 'Within combined reported location uncertainty. No precise direction is supported.';
  }
  final bearing = Geolocator.bearingBetween(p.latitude, p.longitude, lat, lon);
  final turn = ((bearing - heading + 540) % 360) - 180;
  return 'Approximate outdoor cue: ${turn.abs() < 20
      ? 'ahead'
      : turn > 0
      ? 'turn right'
      : 'turn left'} · ${distance.round()} m to last recorded point. Compass alignment is unvalidated.';
}

double? directionHeading(CompassEvent event, {bool camera = false}) {
  final accuracy = event.accuracy;
  // Android's plugin sends a placeholder zero for headingForCameraMode; its
  // primary heading already remaps the rotation for upright camera use.
  final heading = camera && !Platform.isAndroid
      ? event.headingForCameraMode ?? event.heading
      : event.heading;
  // The plugin maps unknown accuracy to null; Android's low precision
  // category is 45 degrees. Neither supports a useful turn indication.
  if (accuracy == null ||
      !accuracy.isFinite ||
      accuracy < 0 ||
      accuracy > 30 ||
      heading == null ||
      !heading.isFinite) {
    return null;
  }
  return heading;
}
