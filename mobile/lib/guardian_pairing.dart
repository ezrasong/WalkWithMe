import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'session.dart';

class GuardianPairingScreen extends StatefulWidget {
  final SessionController session;
  const GuardianPairingScreen({super.key, required this.session});
  @override
  State<GuardianPairingScreen> createState() => _GuardianPairingScreenState();
}

class _GuardianPairingScreenState extends State<GuardianPairingScreen>
    with WidgetsBindingObserver {
  late final SessionAccess? openingAccess = widget.session.access;
  GuardianInvitation? invitation;
  Timer? timer;
  bool loading = false, foreground = true;
  String error = '';
  bool get authorized =>
      identical(openingAccess, widget.session.access) &&
      openingAccess?.role == 'owner' &&
      widget.session.snapshot != null &&
      widget.session.snapshot!['guardianRevokedAt'] == null &&
      !['resolved', 'expired'].contains(widget.session.snapshot!['phase']) &&
      widget.session.serverNow <
          (widget.session.snapshot!['expiresAt'] as num? ?? 0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(update);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => update());
    generate();
  }

  void update() {
    if (!mounted) return;
    setState(() {
      if (!authorized) {
        invitation = null;
        error = 'Guardian pairing is unavailable for this session.';
      }
    });
  }

  Future<void> generate() async {
    if (loading || !authorized || !foreground) return;
    setState(() {
      loading = true;
      invitation = null;
      error = '';
    });
    try {
      final next = await widget.session.createGuardianInvitation();
      if (mounted && authorized && foreground) {
        setState(() => invitation = next);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message.toString()
              : e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground && mounted) setState(() => invitation = null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(update);
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = invitation;
    final usable =
        authorized && foreground && current != null && current.secondsLeft > 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Invite your guardian')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xff173d86), Color(0xff0a1d43)],
                ),
                borderRadius: BorderRadius.circular(24),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.people_alt_outlined, color: Colors.white),
                  SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'On their phone, open WalkWithMe → Join as guardian → Scan QR code. Or tell them the pairing code below.',
                      style: TextStyle(color: Color(0xffd7e1ff), height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (loading) const Center(child: CircularProgressIndicator()),
            if (usable) ...[
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 24,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: QrImageView(
                        data: current.qrData,
                        backgroundColor: Colors.white,
                        padding: const EdgeInsets.all(16),
                        semanticsLabel:
                            'Private WalkWithMe guardian pairing QR code',
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Pairing code', textAlign: TextAlign.center),
              SelectableText(
                current.code,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(
                'Expires in ${current.secondsLeft ~/ 60}:${(current.secondsLeft % 60).toString().padLeft(2, '0')}',
                textAlign: TextAlign.center,
              ),
            ] else if (!loading && error.isEmpty)
              const Text(
                'Code expired or hidden. Generate a new code to pair.',
              ),
            if (error.isNotEmpty)
              Semantics(liveRegion: true, child: Text(error)),
            const SizedBox(height: 16),
            const Text(
              'Show this only to someone you trust. Each code works once for up to 5 minutes. A new code replaces the previous one. Your sharing settings still control when your guardian sees the trail.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: loading || !authorized || !foreground
                  ? null
                  : generate,
              child: const Text('Generate new code'),
            ),
          ],
        ),
      ),
    );
  }
}

class GuardianScannerScreen extends StatefulWidget {
  const GuardianScannerScreen({super.key});
  @override
  State<GuardianScannerScreen> createState() => _GuardianScannerScreenState();
}

class _GuardianScannerScreenState extends State<GuardianScannerScreen>
    with WidgetsBindingObserver {
  final controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool complete = false, foreground = true;
  String message =
      'Point the camera at the guardian QR code on the wearer’s phone.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(cameraChanged);
  }

  void cameraChanged() {
    // A first-use permission/start response can arrive after losing focus.
    if (controller.value.isRunning && (!foreground || complete)) {
      unawaited(stopCamera());
    }
  }

  Future<void> stopCamera() async {
    try {
      await controller.stop();
    } catch (_) {
      if (mounted && !complete) {
        setState(
          () => message =
              'Camera unavailable. Go back and enter the pairing code.',
        );
      }
    }
  }

  Future<void> detected(BarcodeCapture capture) async {
    if (complete || !foreground) return;
    String? error;
    for (final barcode in capture.barcodes) {
      if (barcode.rawValue == null) continue;
      try {
        final code = guardianCodeFromQr(barcode.rawValue!);
        complete = true;
        // Remove the scanner as soon as a valid code is found.
        setState(() {});
        await stopCamera();
        if (mounted) Navigator.of(context).pop(code);
        return;
      } on FormatException catch (e) {
        error = e.message.toString();
      }
    }
    if (error != null && error != message) setState(() => message = error!);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Permission dialogs can arrive before camera initialization completes.
    if (!complete &&
        state == AppLifecycleState.resumed &&
        controller.value.hasCameraPermission &&
        !controller.value.isStarting &&
        !controller.value.isRunning) {
      unawaited(controller.start());
    } else if (state != AppLifecycleState.resumed) {
      unawaited(stopCamera());
    }
    if (state == AppLifecycleState.inactive) {
      foreground = false;
      return;
    }
    setState(() => foreground = state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(cameraChanged);
    unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan guardian QR code')),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: complete || !foreground
                ? const SizedBox()
                : MobileScanner(
                    controller: controller,
                    onDetect: detected,
                    onDetectError: (_, _) {
                      if (mounted && !complete) {
                        setState(
                          () => message = 'Could not read that QR code. Try again or enter the pairing code.',
                        );
                      }
                    },
                    errorBuilder: (context, error) => const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          'Camera unavailable. Allow Camera access for WalkWithMe in your phone’s Settings, or go back and enter the pairing code.',
                        ),
                      ),
                    ),
                  ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    '$message\nScanning stays on this phone. Images are not recorded or uploaded.',
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Enter code instead'),
            ),
          ),
        ],
      ),
    ),
  );
}
