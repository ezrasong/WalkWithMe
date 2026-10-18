import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'session.dart';
import 'relative_motion.dart';

/// Camera context with an explicitly unregistered diagram; no projected arrows.
class RelativeMotionCamera extends StatefulWidget {
  final SessionController session;
  const RelativeMotionCamera({super.key, required this.session});
  @override
  State<RelativeMotionCamera> createState() => _RelativeMotionCameraState();
}

class _RelativeMotionCameraState extends State<RelativeMotionCamera>
    with WidgetsBindingObserver {
  late final SessionAccess? access;
  CameraController? camera;
  Timer? timer;
  bool closed = false;
  String message = 'Opening local camera. No recording or upload.';
  bool get authorized =>
      !closed &&
      widget.session.visible &&
      identical(access, widget.session.access) &&
      widget.session.guardian &&
      widget.session.snapshot?['shared'] == true &&
      widget.session.snapshot?['phase'] == 'alert' &&
      widget.session.received != null &&
      DateTime.now().difference(widget.session.received!).inSeconds < 5 &&
      widget.session.serverNow <
          (widget.session.snapshot?['expiresAt'] as num? ?? 0);
  @override
  void initState() {
    super.initState();
    access = widget.session.access;
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(changed);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => changed());
    open();
  }

  Future<void> open() async {
    try {
      if (!authorized) {
        stop();
        return;
      }
      final cameras = await availableCameras();
      if (!mounted || !authorized) return;
      final controller = CameraController(
        cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back),
        ResolutionPreset.medium,
        enableAudio: false,
      );
      camera = controller;
      await controller.initialize();
      if (!mounted || !authorized) {
        stop();
        return;
      }
      controller.addListener(() {
        if (controller.value.hasError) scheduleMicrotask(stop);
      });
      setState(
        () => message = 'Camera alignment unavailable: starting room, floor and direction are unknown.',
      );
    } catch (_) {
      camera?.dispose().catchError((Object _) {});
      camera = null;
      if (mounted) {
        setState(
          () =>
              message = 'Camera unavailable. Relative evidence remains below.',
        );
      }
    }
  }

  void stop() {
    if (closed) return;
    closed = true;
    timer?.cancel();
    camera?.dispose().catchError((Object _) {});
    camera = null;
    if (mounted) {
      setState(
        () => message =
            'Camera closed. Reopen from an authorized assistance request.',
      );
    }
  }

  void changed() {
    if (!authorized) {
      stop();
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        (camera?.value.isInitialized == true ||
            state != AppLifecycleState.inactive)) {
      stop();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.session.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    camera?.dispose().catchError((Object _) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('WalkWithMe pocket motion camera')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text(message),
          if (authorized && camera?.value.isInitialized == true)
            SizedBox(
              height: 220,
              child: ClipRect(child: CameraPreview(camera!)),
            ),
          if (authorized)
            RelativeMotionCard(
              motion: widget.session.snapshot?['relativeMotion'] as Map?,
            ),
          const Text(
            'The diagram is separate from the camera view. No walls, obstacles or safe route are detected.',
          ),
        ],
      ),
    ),
  );
}
