import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

import 'session.dart';

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
  DateTime? headingAt;
  Timer? timer;
  bool closed = false;
  String status = 'Waiting for camera, location and compass permission…';
  bool get authorized =>
      widget.session.visible &&
      widget.session.guardian &&
      widget.session.snapshot?['phase'] == 'alert' &&
      widget.session.snapshot?['shared'] == true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(sessionChanged);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
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
      positions =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 0,
            ),
          ).listen(
            (p) {
              if (mounted) setState(() => position = p);
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
              heading = e.accuracy != null && e.accuracy! < 0
                  ? null
                  : e.heading;
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
    c?.dispose();
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

  String cue() {
    final target = widget.session.snapshot?['geography']?['latest'] as Map?;
    final p = position;
    if (!authorized ||
        target == null ||
        p == null ||
        heading == null ||
        headingAt == null ||
        DateTime.now().difference(headingAt!).inSeconds > 3 ||
        DateTime.now().difference(p.timestamp).inSeconds > 10 ||
        widget.session.serverNow - (target['fixAt'] as num) > 30000 ||
        (target['accuracy'] as num) > 20 ||
        p.accuracy > 20 ||
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
    final bearing = Geolocator.bearingBetween(
      p.latitude,
      p.longitude,
      lat,
      lon,
    );
    final turn = ((bearing - heading! + 540) % 360) - 180;
    return 'Approximate outdoor cue: ${turn.abs() < 20
        ? 'ahead'
        : turn > 0
        ? 'turn right'
        : 'turn left'} · ${distance.round()} m to last recorded point. Compass alignment is unvalidated.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Camera direction preview')),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Experimental outdoor compass cue. No anchored breadcrumbs, floor, stair or obstacle guidance. Camera stays on this phone; no recording or upload.',
            ),
          ),
          Expanded(
            child: camera?.value.isInitialized == true
                ? CameraPreview(camera!)
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(status),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Semantics(liveRegion: true, child: Text(cue())),
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
