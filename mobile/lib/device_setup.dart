import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'session.dart';

class DeviceSetupScreen extends StatefulWidget {
  const DeviceSetupScreen({super.key});
  @override
  State<DeviceSetupScreen> createState() => _DeviceSetupScreenState();
}

class _DeviceSetupScreenState extends State<DeviceSetupScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic> status = {};
  bool busy = false;
  String? error;
  bool get android => defaultTargetPlatform == TargetPlatform.android;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  Future<void> refresh() async {
    try {
      final Map<String, dynamic> next;
      if (android) {
        next = Map<String, dynamic>.from(
          await SessionController.native.invokeMapMethod('setupStatus') ?? {},
        );
      } else {
        final permission = await Geolocator.checkPermission();
        next = {
          'locationAllowed':
              permission == LocationPermission.whileInUse ||
              permission == LocationPermission.always,
          'locationServices': await Geolocator.isLocationServiceEnabled(),
        };
      }
      if (mounted) {
        setState(() {
          status = next;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not read device settings. Review WalkWithMe permissions in Settings.',
        );
      }
    }
  }

  Future<void> act(String method) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (android) {
        await SessionController.native.invokeMethod(method);
      } else if (method == 'permissions') {
        await Geolocator.requestPermission();
      } else if (method == 'locationSettings') {
        await Geolocator.openLocationSettings();
      } else {
        await Geolocator.openAppSettings();
      }
      await refresh();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Open this phone’s Settings and select WalkWithMe to change this setting.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget row(String title, String detail, bool? ready, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    final color = ready == true ? const Color(0xff3f84ff) : colors.primary;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(ready == true ? Icons.check_rounded : icon, color: color),
      ),
      title: Text(title),
      subtitle: Text(detail),
    );
  }

  Widget card(List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final location = status['locationAllowed'] as bool?;
    final services = status['locationServices'] as bool?;
    final battery = status['batteryExempt'] as bool?;
    final notifications = status['notificationsAllowed'] as bool?;
    final vivo = (status['manufacturer'] as String? ?? '')
        .toLowerCase()
        .contains('vivo');
    String known(bool? value, String yes, String no) => value == null
        ? 'Checking…'
        : value
        ? yes
        : no;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up WalkWithMe')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xff173d86), Color(0xff0a1d43)],
                ),
                borderRadius: BorderRadius.circular(26),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.shield_outlined,
                    color: Colors.white,
                    size: 32,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Keep your session connected',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(color: Colors.white),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'A quick readiness check before you head out.',
                          style: TextStyle(color: Color(0xffd7e1ff)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              android
                  ? 'Allow location and reminders, then review battery and background access. Setup does not start recording; each safety session needs your consent.'
                  : 'Location is optional for the guardian camera direction preview. It is used while you use that feature. Setup does not start recording.',
            ),
            card([
              row(
                'Location access',
                known(
                  location,
                  android && status['preciseLocation'] != true
                      ? 'Approximate location allowed. Precise location improves the trail.'
                      : 'Allowed',
                  'Not allowed. A geographic trail needs location permission.',
                ),
                location,
                Icons.location_on_outlined,
              ),
              if (android)
                row(
                  'Reminder notifications',
                  known(
                    notifications,
                    'Allowed',
                    'Not allowed. Check-in reminders may be missed.',
                  ),
                  notifications,
                  Icons.notifications_outlined,
                ),
              if (location != true || (android && notifications != true))
                FilledButton(
                  onPressed: busy ? null : () => act('permissions'),
                  child: const Text('Allow permissions'),
                ),
              TextButton(
                onPressed: busy ? null : () => act('appSettings'),
                child: const Text('App permission settings'),
              ),
              const Divider(),
              row(
                'Location services',
                known(
                  services,
                  'On',
                  'Off. Turn on Location services to receive fixes.',
                ),
                services,
                Icons.gps_off_outlined,
              ),
              if (services != true)
                OutlinedButton(
                  onPressed: busy ? null : () => act('locationSettings'),
                  child: const Text('Open Location settings'),
                ),
            ]),
            if (android) ...[
              card([
                row(
                  'Battery optimization',
                  known(
                    battery,
                    'WalkWithMe is exempt from Android battery optimization.',
                    'Optimization is on. Android may delay background work.',
                  ),
                  battery,
                  Icons.battery_saver_outlined,
                ),
                const Text(
                  'Allow background battery use so an active session can contact the server with the screen off. Battery use may increase.',
                ),
                if (battery != true) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: busy ? null : () => act('batterySettings'),
                    child: const Text('Allow background battery use'),
                  ),
                ],
              ]),
              card([
                row(
                  'Background usage',
                  status['backgroundRestricted'] == true
                      ? 'Android reports background usage is restricted.'
                      : 'Review your phone’s separate background controls.',
                  null,
                  Icons.settings_outlined,
                ),
                Text(
                  vivo
                      ? 'Vivo: App info → Battery usage → Background power control → Allow background power usage. Smart control can freeze WalkWithMe even during an active session.'
                      : 'In WalkWithMe App info, allow background usage or choose Unrestricted under Battery. Some phones have an additional auto-start control.',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: busy ? null : () => act('appSettings'),
                  child: const Text('Open WalkWithMe app settings'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Android’s battery exemption does not confirm the manufacturer setting. Check it on this phone.',
                ),
              ]),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            const Text(
              'You can continue with limited access. Missing permissions or background restrictions can leave location unavailable or delay reminders and session updates.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : () => Navigator.of(context).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}
