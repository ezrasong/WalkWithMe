import 'dart:async';

import 'package:flutter/material.dart';

import 'session.dart';

class MotionCapturePage extends StatefulWidget {
  final SessionController session;
  const MotionCapturePage({super.key, required this.session});
  @override
  State<MotionCapturePage> createState() => _MotionCapturePageState();
}

class _MotionCapturePageState extends State<MotionCapturePage> {
  Timer? timer;
  Map status = {};
  bool busy = false, reading = false;
  bool streaming = true, cellular = true;
  String message = '';
  late final SessionAccess? openingAccess;
  bool get authorized =>
      !widget.session.guardian &&
      widget.session.visible &&
      identical(openingAccess, widget.session.access) &&
      openingAccess?.role == 'owner' &&
      [
        'armed',
        'challenge',
        'alert',
      ].contains(widget.session.snapshot?['phase']) &&
      widget.session.serverNow <
          (widget.session.snapshot?['expiresAt'] as num? ?? 0);

  @override
  void initState() {
    super.initState();
    openingAccess = widget.session.access;
    widget.session.addListener(changed);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => refresh());
    refresh();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> refresh() async {
    if (!authorized || reading) return;
    reading = true;
    try {
      final value = await SessionController.native.invokeMapMethod(
        'motionStatus',
      );
      if (mounted && authorized) {
        setState(() {
          status = value ?? {};
          if (status['recording'] == true) {
            streaming = status['streaming'] == true;
            cellular = status['cellular'] == true;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Local motion capture is unavailable on this phone.',
        );
      }
    } finally {
      reading = false;
    }
  }

  Future<void> run(String method) async {
    if (!authorized || busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await SessionController.native.invokeMethod(
        method,
        method == 'startMotionCapture'
            ? {'streaming': streaming, 'cellular': streaming && cellular}
            : null,
      );
      await refresh();
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Capture could not change. Keep the wearer session active and stop capture before deleting it.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete local motion capture?'),
        content: const Text(
          'This removes the capture from this phone. Exported copies on your PC are separate.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && authorized) await run('deleteMotionCapture');
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.session.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Motion trail evaluation')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Motion streaming starts automatically with each wearer session over Wi-Fi or cellular. No raw capture is saved by default. No camera is used.',
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Evaluate a manual capture on the backend'),
            subtitle: const Text(
              'Compressed motion batches are sent every 10 seconds and processed in memory. Stop streaming below before starting an optional 3-minute private capture.',
            ),
            value: streaming,
            onChanged: authorized && !busy && status['recording'] != true
                ? (value) => setState(() => streaming = value)
                : null,
          ),
          if (streaming)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Allow cellular data'),
              subtitle: const Text(
                'On by default. Turn off before a manual capture for unmetered Wi-Fi only. Failed batches are skipped without retries or a backlog.',
              ),
              value: cellular,
              onChanged: authorized && !busy && status['recording'] != true
                  ? (value) => setState(() => cellular = value)
                  : null,
            ),
          const SizedBox(height: 20),
          Semantics(
            liveRegion: true,
            child: Text(
              !authorized
                  ? 'An active wearer phone session is required.'
                  : message.isNotEmpty
                  ? message
                  : status['status'] as String? ?? 'Checking local capture.',
            ),
          ),
          const SizedBox(height: 20),
          if ((status['streamStatus'] as String? ?? '').isNotEmpty)
            Text(status['streamStatus'] as String),
          if ((status['sentBytes'] as num? ?? 0) > 0)
            Text(
              'Upload payload attempted: ${((status['sentBytes'] as num) / 1024).toStringAsFixed(1)} KB. Network overhead is additional.',
            ),
          if ((status['result'] as String? ?? '').isNotEmpty)
            Text(status['result'] as String),
          FilledButton(
            onPressed:
                authorized &&
                    !busy &&
                    status['recording'] != true &&
                    status['available'] != true
                ? () => run('startMotionCapture')
                : null,
            child: const Text('Start 3-minute capture'),
          ),
          OutlinedButton(
            onPressed: authorized && !busy && status['recording'] == true
                ? () => run('stopMotionCapture')
                : null,
            child: Text(
              status['automatic'] == true
                  ? 'Stop streaming for this session'
                  : 'Stop capture',
            ),
          ),
          TextButton(
            onPressed:
                authorized &&
                    !busy &&
                    status['recording'] != true &&
                    status['available'] == true
                ? remove
                : null,
            child: const Text('Delete local capture'),
          ),
          const SizedBox(height: 16),
          const Text(
            'Automatic streaming lasts until the session ends or expires. Stopping it here keeps it off for this session, including after a restart. A new wearer session starts streaming again. Cellular is allowed by default.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Optional manual captures keep a local copy for up to 3 minutes; export it before ending the safety session. Each batch estimates separate relative motion. Accuracy is unverified. Shared locations, guardian guidance and check-in deadlines are unchanged.',
          ),
        ],
      ),
    ),
  );
}
