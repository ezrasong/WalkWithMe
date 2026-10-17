import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'session.dart';
import 'direction_preview.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KazeApp());
}

class KazeApp extends StatelessWidget {
  const KazeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'KAZE',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff225cbe)),
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff6f7f9),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      ),
    ),
    home: const SessionScreen(),
  );
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  final c = SessionController();
  final base = TextEditingController(
    text: const String.fromEnvironment('KAZE_BASE_URL'),
  );
  final name = TextEditingController(text: 'Alex'),
      link = TextEditingController();
  int tab = 0, interval = 120, grace = 30;
  bool consent = false, live = false, tiles = true;
  Timer? clock;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(update);
    c.restore();
    clock = Timer.periodic(const Duration(seconds: 1), (_) => update());
  }

  void update() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.inactive) {
      c.setVisible(state == AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clock?.cancel();
    c.removeListener(update);
    c.dispose();
    base.dispose();
    name.dispose();
    link.dispose();
    super.dispose();
  }

  Widget note(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
  Widget card(List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('KAZE'),
      actions: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: Text(
              'Team test',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: c.access == null
                ? onboarding()
                : c.snapshot == null
                ? waiting()
                : [mapPage(), activityPage(), settingsPage()][tab],
          ),
          if (c.message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Semantics(liveRegion: true, child: Text(c.message)),
            ),
          if (c.busy) const LinearProgressIndicator(),
        ],
      ),
    ),
    bottomNavigationBar: c.access == null
        ? null
        : NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (value) => setState(() => tab = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.map_outlined),
                label: 'Map',
              ),
              NavigationDestination(
                icon: Icon(Icons.history),
                label: 'Activity',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                label: 'Settings',
              ),
            ],
          ),
  );
  Widget onboarding() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(
        'A timed safety session',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const Text(
        'The Vivo records the wearer’s journey. A second iPhone or Android phone can join as guardian. No wearer camera is used.',
      ),
      card([
        Text('Join as guardian', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        TextField(
          controller: link,
          decoration: const InputDecoration(labelText: 'Private guardian link'),
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: c.busy ? null : () => c.join(link.text),
          child: const Text('Open my person’s session'),
        ),
      ]),
      if (Platform.isAndroid)
        card([
          Text(
            'Start on the wearer’s phone',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: base,
            decoration: const InputDecoration(
              labelText: 'PC server URL',
              hintText: 'https://your-server.example',
            ),
            autocorrect: false,
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'First name'),
            maxLength: 60,
          ),
          DropdownButtonFormField<int>(
            initialValue: interval,
            decoration: const InputDecoration(labelText: 'Check in every'),
            items: const [
              DropdownMenuItem(value: 120, child: Text('2 minutes')),
              DropdownMenuItem(value: 300, child: Text('5 minutes')),
              DropdownMenuItem(value: 600, child: Text('10 minutes')),
            ],
            onChanged: (v) => setState(() => interval = v!),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: grace,
            decoration: const InputDecoration(labelText: 'Time to respond'),
            items: const [
              DropdownMenuItem(value: 30, child: Text('30 seconds')),
              DropdownMenuItem(value: 60, child: Text('1 minute')),
              DropdownMenuItem(value: 120, child: Text('2 minutes')),
            ],
            onChanged: (v) => setState(() => grace = v!),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: consent,
            onChanged: (v) => setState(() => consent = v!),
            title: const Text(
              'I agree to record this session and share its trail after nonresponse with the person I give the private link to. Data expires after 8 hours.',
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: live,
            onChanged: (v) => setState(() => live = v!),
            title: const Text(
              'Also share my location throughout this session (optional).',
            ),
          ),
          FilledButton(
            onPressed: !consent || c.busy
                ? null
                : () => c.create(
                    baseUrl: base.text,
                    name: name.text,
                    interval: interval,
                    grace: grace,
                    live: live,
                  ),
            child: const Text('Start safety session'),
          ),
        ]),
      note(
        'No emergency dispatch, calls, SMS or push are connected. A guardian must keep the app open. The PC and its network connection must stay running.',
      ),
      note(
        'Street maps use OpenStreetMap, which receives the viewed map area and IP address. You can turn tiles off in Settings.',
      ),
      note(
        'Location and camera permission are requested only for their respective features. The optional guardian camera preview stays on that phone.',
      ),
    ],
  );
  Widget waiting() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Icon(Icons.cloud_off_outlined, size: 48),
      const SizedBox(height: 16),
      Text(c.connection),
      note(
        c.guardian
            ? 'Private evidence is hidden while the server cannot confirm access.'
            : 'The native recorder can continue queuing evidence. This is not server confirmation.',
      ),
      FilledButton(
        onPressed: c.busy ? null : c.refresh,
        child: const Text('Reconnect'),
      ),
      if (!c.guardian)
        OutlinedButton(
          onPressed: () => c.mutate('resolve'),
          child: const Text('End session on server'),
        ),
      if (c.guardian)
        TextButton(
          onPressed: c.forget,
          child: const Text('Remove this guardian link'),
        ),
    ],
  );
  String get phase => c.snapshot?['phase'] ?? '';
  String get phaseText =>
      {
        'armed': 'Session active',
        'challenge': 'Check in now',
        'alert': 'Check-in unanswered',
        'resolved': 'Session ended',
      }[phase] ??
      phase;
  Map<String, dynamic>? get latest =>
      (c.snapshot?['geography'] as Map?)?['latest'] as Map<String, dynamic>?;
  String age(num? at) => at == null
      ? 'No readings'
      : '${((c.serverNow - at) / 1000).clamp(0, double.infinity).floor()}s ago';
  String at(num? value) => value == null
      ? 'None yet'
      : TimeOfDay.fromDateTime(
          DateTime.fromMillisecondsSinceEpoch(value.toInt()),
        ).format(context);
  Widget mapPage() {
    final s = c.snapshot!, p = latest;
    final deadline =
        (s['dueAt'] as num).toInt() +
        (phase == 'challenge' ? (s['graceSeconds'] as num).toInt() * 1000 : 0);
    final seconds = ((deadline - c.serverNow) / 1000).ceil().clamp(0, 36000);
    return LayoutBuilder(
      builder: (context, size) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(phaseText),
            trailing: Text(
              ['armed', 'challenge'].contains(phase) ? '${seconds}s' : '',
            ),
            subtitle: const Text('No emergency service has been contacted.'),
          ),
          if (s['sensorMode'] == 'simulated')
            const Text('Simulated readings · not hardware measurements'),
          SizedBox(
            height: (size.maxHeight * .44).clamp(180, 420),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: TrailMap(snapshot: s, tiles: tiles),
            ),
          ),
          card([
            Text(s['name'], style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              s['shared'] != true
                  ? 'Trail stays private until a check-in goes unanswered.'
                  : p == null
                  ? 'No location received. Check-ins still work.'
                  : '${p['source']} · ${age(p['fixAt'])} · reported accuracy ${(p['accuracy'] as num).round()} m${c.serverNow - (p['fixAt'] as num) > 30000 ? ' · Stale' : ''}',
            ),
            if (p != null)
              note(
                '${(p['latitude'] as num).toStringAsFixed(5)}, ${(p['longitude'] as num).toStringAsFixed(5)}',
              ),
            note('Last server-accepted check-in: ${at(s['lastCheckInAt'])}'),
            note(
              phase == 'resolved'
                  ? 'Guardian sharing stopped.'
                  : s['guardianRevokedAt'] != null
                  ? 'Guardian access revoked.'
                  : s['liveSharing'] == true
                  ? 'Live sharing explicitly enabled for this session.'
                  : 'Guardian sharing only after nonresponse.',
            ),
            if (!c.guardian && phase != 'resolved')
              FilledButton.icon(
                onPressed: c.busy || phase == 'alert'
                    ? null
                    : () => c.mutate('check-in'),
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('Check in'),
              ),
            if (c.guardian && phase == 'alert') ...[
              FilledButton(
                onPressed: c.busy || s['acknowledgedAt'] != null
                    ? null
                    : () => c.mutate('acknowledge'),
                child: const Text('I’ve seen the request'),
              ),
              OutlinedButton(
                onPressed: c.busy || s['arrivalReportedAt'] != null
                    ? null
                    : () => c.mutate('arrived'),
                child: const Text('Report I’m with them'),
              ),
              note(
                s['arrivalReportedAt'] != null
                    ? 'Guardian reports arrival. Not independently verified.'
                    : s['acknowledgedAt'] != null
                    ? 'Acknowledged. Arrival is not verified.'
                    : 'An acknowledgment does not resolve the incident.',
              ),
              if (p != null)
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.https('www.google.com', '/maps/dir/', {
                      'api': '1',
                      'destination': '${p['latitude']},${p['longitude']}',
                    }),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.directions),
                  label: const Text('Directions to last point'),
                ),
              if (p != null)
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DirectionPreview(session: c),
                    ),
                  ),
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Camera direction preview'),
                ),
            ],
          ]),
          note(c.connection),
          if (!c.guardian)
            note(
              c.device['status']?.toString() ?? 'Waiting for recorder status.',
            ),
          for (final warning in (s['geography']?['warnings'] as List? ?? []))
            note(warning.toString()),
          note(
            'Phone and watch paths are shown separately. Gaps are not filled. Watch location may come from its paired phone.',
          ),
        ],
      ),
    );
  }

  Widget activityPage() {
    const labels = {
      'started': 'Session started',
      'check-in': 'Check-in accepted by server',
      'challenge': 'Check-in due',
      'alert': 'Assistance requested after nonresponse',
      'acknowledge': 'Guardian acknowledged · help not verified',
      'arrived': 'Guardian reported arrival · not verified',
      'resolve': 'Session ended',
      'revoke-guardian': 'Guardian access revoked',
    };
    final activity = c.snapshot?['activity'] as List? ?? [];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Activity', style: Theme.of(context).textTheme.headlineSmall),
        if (activity.isEmpty) const Text('No activity is shared yet.'),
        for (final entry in activity.reversed)
          ListTile(
            leading: const Icon(Icons.history),
            title: Text(labels[entry['action']] ?? entry['action']),
            subtitle: Text('${at(entry['at'])} · ${entry['role']}'),
          ),
      ],
    );
  }

  Future<bool> confirm(String prompt) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(prompt),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;
  Widget settingsPage() {
    final s = c.snapshot!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
        note(
          'Check in every ${s['intervalSeconds']}s with ${s['graceSeconds']}s to respond. Expires ${at(s['expiresAt'])}.',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Load street map'),
          subtitle: const Text(
            'OpenStreetMap receives the viewed map area and IP address. Recorded points work without tiles.',
          ),
          value: tiles,
          onChanged: (value) => setState(() => tiles = value),
        ),
        if (!c.guardian) ...[
          if (c.access?.guardianLink != null &&
              s['guardianRevokedAt'] == null &&
              phase != 'resolved') ...[
            const Text(
              'Give this private link only to your consenting guardian. They can paste it into KAZE on iPhone or Android.',
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: c.access!.guardianLink!),
                );
                if (mounted) {
                  c.message = 'Private guardian link copied.';
                  update();
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy guardian link'),
            ),
            OutlinedButton(
              onPressed: c.busy
                  ? null
                  : () async {
                      if (await confirm('Revoke your guardian’s access now?')) {
                        await c.mutate('revoke-guardian');
                      }
                    },
              child: const Text('Revoke guardian access'),
            ),
          ],
          if (Platform.isAndroid)
            note(
              'Galaxy Watch connects automatically when you open KAZE on it. Tap Start there to consent.',
            ),
          if (phase != 'resolved')
            FilledButton(
              onPressed: c.busy
                  ? null
                  : () async {
                      if (await confirm(
                        'End this session and stop guardian sharing?',
                      )) {
                        await c.mutate('resolve');
                      }
                    },
              child: const Text('End session and stop sharing'),
            ),
          OutlinedButton(
            onPressed: c.busy
                ? null
                : () async {
                    if (await confirm(
                      'Delete the session, its evidence and all access?',
                    )) {
                      await c.deleteSession();
                    }
                  },
            child: const Text('Delete session'),
          ),
          if (phase == 'resolved')
            TextButton(
              onPressed: c.forget,
              child: const Text('Return to setup'),
            ),
        ] else
          TextButton(
            onPressed: c.forget,
            child: const Text('Remove this guardian link'),
          ),
        const Divider(),
        note(
          'Keep the guardian app open to receive requests. Background push, calls, SMS and emergency dispatch are not connected.',
        ),
        note(
          'Camera direction preview is experimental. It shows an approximate outdoor bearing, not an anchored trail, room, floor or stair route.',
        ),
        note(
          'No custom AI estimator is integrated. Geographic points come from location services.',
        ),
      ],
    );
  }
}

class TrailMap extends StatelessWidget {
  final Map<String, dynamic> snapshot;
  final bool tiles;
  const TrailMap({super.key, required this.snapshot, required this.tiles});
  @override
  Widget build(BuildContext context) {
    final geo = snapshot['geography'] as Map?;
    final latest = geo?['latest'] as Map?;
    final center = latest == null
        ? const LatLng(20, 0)
        : LatLng(
            (latest['latitude'] as num).toDouble(),
            (latest['longitude'] as num).toDouble(),
          );
    return Stack(
      children: [
        FlutterMap(
          key: ValueKey('${snapshot['id']}-${latest == null}'),
          options: MapOptions(
            initialCenter: center,
            initialZoom: latest == null ? 2 : 17,
          ),
          children: [
            if (tiles)
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'app.kaze.trail',
              ),
            PolylineLayer(
              polylines: [
                for (final path in (geo?['paths'] as List? ?? []))
                  if ((path['points'] as List).length > 1)
                    Polyline(
                      points: [
                        for (final p in path['points'])
                          LatLng(
                            (p['latitude'] as num).toDouble(),
                            (p['longitude'] as num).toDouble(),
                          ),
                      ],
                      strokeWidth: 4,
                      color: path['source'] == 'phone'
                          ? Colors.blue.shade700
                          : Colors.purple,
                    ),
              ],
            ),
            if (latest != null) ...[
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: center,
                    radius: (latest['accuracy'] as num).toDouble(),
                    useRadiusInMeter: true,
                    color: Colors.blue.withValues(alpha: .1),
                    borderStrokeWidth: 1,
                    borderColor: Colors.blue,
                  ),
                ],
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: center,
                    width: 36,
                    height: 36,
                    child: Semantics(
                      label: 'Last reported location',
                      child: Icon(
                        Icons.person_pin_circle,
                        size: 36,
                        color: Color(0xff225cbe),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (tiles)
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(
                    'OpenStreetMap contributors',
                    onTap: () => launchUrl(
                      Uri.parse('https://www.openstreetmap.org/copyright'),
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ],
              ),
          ],
        ),
        if (latest == null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                snapshot['shared'] == true
                    ? 'No location received yet.\nCheck-ins still work.'
                    : 'Trail stays private until\na check-in goes unanswered.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        if (!tiles && latest != null)
          const Positioned(
            bottom: 8,
            left: 8,
            child: Text(
              'Recorded coordinates · street map off',
              style: TextStyle(fontSize: 11),
            ),
          ),
      ],
    );
  }
}
