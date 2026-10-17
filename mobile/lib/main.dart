import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'session.dart';
import 'direction_preview.dart';
import 'guardian_ar.dart';
import 'device_setup.dart';
import 'trail_map.dart';
export 'trail_map.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final notice = await rootBundle.loadString('assets/maps/LICENSE.md');
    yield LicenseEntryWithLineBreaks(['OpenFreeMap map styles'], notice);
  });
  runApp(const KazeApp());
}

class KazeApp extends StatefulWidget {
  const KazeApp({super.key});
  @override
  State<KazeApp> createState() => _KazeAppState();
}

class _KazeAppState extends State<KazeApp> {
  ThemeMode appearance = ThemeMode.system;
  final storage = const FlutterSecureStorage();
  @override
  void initState() {
    super.initState();
    storage
        .read(key: 'appearance')
        .then((value) {
          if (mounted) {
            setState(
              () => appearance = ThemeMode.values.firstWhere(
                (mode) => mode.name == value,
                orElse: () => ThemeMode.system,
              ),
            );
          }
        })
        .catchError((Object _) {
          /* Use system appearance if storage is unavailable. */
        });
  }

  void setAppearance(ThemeMode mode) {
    setState(() => appearance = mode);
    storage
        .write(key: 'appearance', value: mode.name)
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'KAZE',
    debugShowCheckedModeBanner: false,
    theme: kazeTheme(Brightness.light),
    darkTheme: kazeTheme(Brightness.dark),
    themeMode: appearance,
    home: SessionScreen(
      appearance: appearance,
      onAppearanceChanged: setAppearance,
    ),
  );
}

ThemeData kazeTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xff245caa),
    brightness: brightness,
    surface: dark ? const Color(0xff1c1e23) : Colors.white,
  );
  return ThemeData(
    colorScheme: colors,
    useMaterial3: true,
    scaffoldBackgroundColor: dark
        ? const Color(0xff101216)
        : const Color(0xfff3f4f7),
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: -.5,
      ),
      titleLarge: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 17, height: 1.4),
      bodyMedium: TextStyle(fontSize: 16, height: 1.4),
      bodySmall: TextStyle(fontSize: 14, height: 1.4),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      systemOverlayStyle: dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: colors.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: colors.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLow,
      contentPadding: const EdgeInsets.all(16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surface,
      height: 72,
    ),
  );
}

class SessionScreen extends StatefulWidget {
  final ThemeMode appearance;
  final ValueChanged<ThemeMode>? onAppearanceChanged;
  const SessionScreen({
    super.key,
    this.appearance = ThemeMode.system,
    this.onAppearanceChanged,
  });
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  final c = SessionController();
  final name = TextEditingController(text: 'Alex'),
      link = TextEditingController();
  int tab = 0, interval = 120, grace = 30;
  int setupRole = Platform.isAndroid ? 0 : 1;
  bool consent = false, live = false, tiles = true;
  Timer? clock;
  String lastMessage = '';
  bool get transientMessage => const [
    'Check-in confirmed by server.',
    'Confirmed by server.',
    'Private guardian link copied.',
  ].contains(c.message);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(update);
    c.restore().then((_) => offerDeviceSetup());
    clock = Timer.periodic(const Duration(seconds: 1), (_) => update());
  }

  Future<void> offerDeviceSetup() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    try {
      if (await c.storage.read(key: 'deviceSetupSeenV1') == 'true') return;
      if (mounted) await openDeviceSetup();
    } catch (_) {
      /* Setup remains available from onboarding and Settings. */
    }
  }

  Future<void> openDeviceSetup() async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const DeviceSetupScreen(),
        fullscreenDialog: true,
      ),
    );
    // Keep this key stable across app upgrades. Dismissing setup also counts
    // as seeing it; saved choices stay available through the manual entry.
    try {
      await c.storage.write(key: 'deviceSetupSeenV1', value: 'true');
    } catch (_) {
      /* Offer setup again next launch if the preference was not saved. */
    }
  }

  void update() {
    if (!mounted) return;
    if (lastMessage != c.message) {
      lastMessage = c.message;
      if (transientMessage) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(lastMessage),
              duration: const Duration(seconds: 4),
            ),
          );
        });
      }
    }
    setState(() {});
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
    appBar: Platform.isIOS
        ? CupertinoNavigationBar(
            middle: Text(
              c.access == null
                  ? 'KAZE'
                  : ['Session', 'Activity', 'Settings'][tab],
            ),
          )
        : AppBar(
            title: Text(
              c.access == null
                  ? 'KAZE'
                  : ['Session', 'Activity', 'Settings'][tab],
            ),
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
          if (c.message.isNotEmpty && !transientMessage)
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
        : Platform.isIOS
        ? CupertinoTabBar(
            currentIndex: tab,
            onTap: (value) => setState(() => tab = value),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.map),
                label: 'Map',
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.clock),
                label: 'Activity',
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.settings),
                label: 'Settings',
              ),
            ],
          )
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
        'Stay connected to someone you trust. Start a session or join someone as their guardian.',
      ),
      TextButton.icon(
        onPressed: openDeviceSetup,
        icon: const Icon(Icons.settings_suggest_outlined),
        label: const Text('Permissions & background setup'),
      ),
      const SizedBox(height: 20),
      if (Platform.isAndroid)
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              label: Text('For me'),
              icon: Icon(Icons.shield_outlined),
            ),
            ButtonSegment(
              value: 1,
              label: Text('For someone else'),
              icon: Icon(Icons.people_outline),
            ),
          ],
          selected: {setupRole},
          onSelectionChanged: (value) =>
              setState(() => setupRole = value.first),
        ),
      if (setupRole == 1)
        card([
          Text(
            'Join as guardian',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: link,
            decoration: const InputDecoration(
              labelText: 'Private guardian link',
            ),
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
      if (Platform.isAndroid && setupRole == 0)
        card([
          Text(
            'Start on the wearer’s phone',
            style: Theme.of(context).textTheme.titleLarge,
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
          CheckboxListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: consent,
            onChanged: (v) => setState(() => consent = v!),
            title: const Text(
              'I agree to record this session on my phone and paired watch, and share its trail after nonresponse with my chosen guardian. Data expires after 8 hours.',
            ),
          ),
          CheckboxListTile.adaptive(
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
        'OpenFreeMap serves vector maps using OpenStreetMap data and receives the viewed area and IP address. You can turn the street map off in Settings.',
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
      TextButton.icon(
        onPressed: openDeviceSetup,
        icon: const Icon(Icons.settings_suggest_outlined),
        label: const Text('Permissions & background setup'),
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
  String countdown(int seconds) => seconds >= 60
      ? '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}'
      : '${seconds}s';

  Widget mapPage() {
    final s = c.snapshot!, p = latest;
    final deadline =
        (s['dueAt'] as num).toInt() +
        (phase == 'challenge' ? (s['graceSeconds'] as num).toInt() * 1000 : 0);
    final seconds = ((deadline - c.serverNow) / 1000).ceil().clamp(0, 36000);
    final colors = Theme.of(context).colorScheme;
    final urgent = phase == 'challenge' || phase == 'alert';
    final status = card([
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                urgent
                    ? Icons.notifications_active_outlined
                    : phase == 'resolved'
                    ? Icons.check_circle_outline
                    : Icons.shield_outlined,
                size: 22,
                color: urgent ? colors.error : colors.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  phaseText,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          if (['armed', 'challenge'].contains(phase))
            Text(
              countdown(seconds),
              semanticsLabel: '$seconds seconds until response is due',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(color: urgent ? colors.error : colors.primary),
            ),
        ],
      ),
      const SizedBox(height: 4),
      Text(
        phase == 'resolved'
            ? 'Sharing has stopped.'
            : phase == 'alert'
            ? 'Your guardian can view the shared trail. No emergency service has been contacted.'
            : 'Last check-in: ${at(s['lastCheckInAt'])}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (s['sensorMode'] == 'simulated')
        note('Simulated readings · not hardware measurements'),
      if (!c.guardian && phase != 'resolved') ...[
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: c.busy || phase == 'alert'
              ? null
              : () => c.mutate('check-in'),
          icon: const Icon(Icons.check_circle_outline),
          label: const Text('Check in'),
        ),
      ],
      if (c.guardian && phase == 'alert') ...[
        const SizedBox(height: 12),
        FilledButton(
          onPressed: c.busy || s['acknowledgedAt'] != null
              ? null
              : () => c.mutate('acknowledge'),
          child: Text(
            s['acknowledgedAt'] != null
                ? 'Request acknowledged'
                : 'I’ve seen the request',
          ),
        ),
      ],
    ]);
    final location = Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Icon(
          p == null ? Icons.location_searching : Icons.location_on_outlined,
          color: colors.primary,
        ),
        title: Text(
          p == null
              ? (s['shared'] == true
                    ? 'Waiting for location'
                    : 'Trail is private')
              : s['name'],
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Text(
          p == null
              ? 'Session details'
              : '${age(p['fixAt'])} · ±${(p['accuracy'] as num).round()} m${c.serverNow - (p['fixAt'] as num) > 30000 ? ' · Stale' : ''}',
        ),
        trailing: const Icon(Icons.expand_less),
        onTap: showSessionDetails,
      ),
    );
    return LayoutBuilder(
      builder: (context, size) {
        final compact =
            size.maxHeight < 520 ||
            MediaQuery.textScalerOf(context).scale(16) > 23;
        final map = ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: TrailMap(key: ValueKey(s['id']), snapshot: s, tiles: tiles),
        );
        if (compact) {
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              status,
              SizedBox(height: 360, child: map),
              location,
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              status,
              const SizedBox(height: 4),
              Expanded(child: map),
              const SizedBox(height: 4),
              location,
            ],
          ),
        );
      },
    );
  }

  Future<void> showSessionDetails() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.snapshot, p = latest;
        if (s == null) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Session unavailable. Private evidence is hidden.'),
          );
        }
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Session details',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close details',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(s['name'], style: Theme.of(context).textTheme.titleLarge),
              note('Last server-accepted check-in: ${at(s['lastCheckInAt'])}'),
              if (p != null) ...[
                note(
                  '${p['source']} · ${age(p['fixAt'])} · reported accuracy ${(p['accuracy'] as num).round()} m',
                ),
                SelectableText(
                  '${(p['latitude'] as num).toStringAsFixed(5)}, ${(p['longitude'] as num).toStringAsFixed(5)}',
                ),
              ],
              note(
                phase == 'resolved'
                    ? 'Guardian sharing stopped.'
                    : s['guardianRevokedAt'] != null
                    ? 'Guardian access revoked.'
                    : s['liveSharing'] == true
                    ? 'Live sharing enabled for this session.'
                    : 'Guardian sharing only after nonresponse.',
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
                      MaterialPageRoute(builder: (_) => GuardianAr(session: c)),
                    ),
                    icon: const Icon(Icons.view_in_ar),
                    label: const Text('Guardian spatial AR'),
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
              const Divider(height: 24),
              Text(
                'Connection',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              note(c.connection),
              if (!c.guardian)
                note(
                  c.device['status']?.toString() ??
                      'Waiting for recorder status.',
                ),
              for (final warning
                  in (s['geography']?['warnings'] as List? ?? []))
                note(warning.toString()),
              note(
                'Phone and watch trails stay separate. Gaps are not filled. Watch location may come from its paired phone.',
              ),
              note('No emergency service has been contacted.'),
            ],
          ),
        );
      },
    ),
  );

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
      await showAdaptiveDialog<bool>(
        context: context,
        builder: (context) => AlertDialog.adaptive(
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
    final colors = Theme.of(context).colorScheme;
    Widget section(String title, List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 0),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        card(children),
      ],
    );
    Widget action(
      IconData icon,
      String title,
      VoidCallback? onTap, {
      bool destructive = false,
      String? subtitle,
    }) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: destructive ? colors.error : colors.primary),
      title: Text(
        title,
        style: TextStyle(color: destructive ? colors.error : null),
      ),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        section('Device setup', [
          action(
            Icons.settings_suggest_outlined,
            'Permissions & background setup',
            openDeviceSetup,
            subtitle: 'Location, reminders and background settings.',
          ),
        ]),
        section('Appearance', [
          const Text('The map follows your appearance.'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mode in ThemeMode.values)
                ChoiceChip(
                  label: Text(
                    {
                      'system': 'System',
                      'light': 'Light',
                      'dark': 'Dark',
                    }[mode.name]!,
                  ),
                  selected: widget.appearance == mode,
                  onSelected: (_) => widget.onAppearanceChanged?.call(mode),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
            ],
          ),
          const Divider(height: 24),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Street map'),
            subtitle: const Text(
              'OpenFreeMap serves vector maps using OpenStreetMap data and receives the viewed area and IP address.',
            ),
            value: tiles,
            onChanged: (value) => setState(() => tiles = value),
          ),
        ]),
        section('Safety session', [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule_outlined),
            title: Text(
              'Check in every ${countdown((s['intervalSeconds'] as num).toInt())}',
            ),
            subtitle: Text(
              '${s['graceSeconds']} seconds to respond · expires ${at(s['expiresAt'])}',
            ),
          ),
          if (!c.guardian && Platform.isAndroid)
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.watch_outlined),
              title: Text('Watch connects automatically'),
              subtitle: Text(
                'Open KAZE on your paired watch, then tap Check in.',
              ),
            ),
        ]),
        if (!c.guardian &&
            c.access?.guardianLink != null &&
            s['guardianRevokedAt'] == null &&
            phase != 'resolved')
          section('Your guardian', [
            const Text(
              'Give this private link only to the person you trust. They can join on iPhone or Android.',
            ),
            const SizedBox(height: 16),
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
              icon: const Icon(Icons.ios_share),
              label: const Text('Copy guardian link'),
            ),
            const SizedBox(height: 8),
            action(
              Icons.person_remove_outlined,
              'Revoke guardian access',
              c.busy
                  ? null
                  : () async {
                      if (await confirm('Revoke your guardian’s access now?')) {
                        await c.mutate('revoke-guardian');
                      }
                    },
              destructive: true,
            ),
          ]),
        section(c.guardian ? 'Access' : 'Session controls', [
          if (!c.guardian) ...[
            if (phase != 'resolved')
              action(
                Icons.stop_circle_outlined,
                'End session and stop sharing',
                c.busy
                    ? null
                    : () async {
                        if (await confirm(
                          'End this session and stop guardian sharing?',
                        )) {
                          await c.mutate('resolve');
                        }
                      },
                destructive: true,
                subtitle: 'Stop recording and guardian access.',
              ),
            if (phase != 'resolved') const Divider(),
            action(
              Icons.delete_outline,
              'Delete session',
              c.busy
                  ? null
                  : () async {
                      if (await confirm(
                        'Delete the session, its evidence and all access?',
                      )) {
                        await c.deleteSession();
                      }
                    },
              destructive: true,
              subtitle: 'Permanently remove its recorded evidence.',
            ),
            if (phase == 'resolved')
              action(Icons.add_circle_outline, 'Return to setup', c.forget),
          ] else
            action(Icons.link_off, 'Remove this guardian link', c.forget),
        ]),
        section('About this prototype', [
          const Text(
            'The guardian must keep KAZE open. Calls, SMS, background push and emergency dispatch are not connected.',
          ),
          note(
            'Camera direction preview is experimental outdoor guidance. It does not identify rooms, floors or stairs.',
          ),
          note(
            'Location comes from device location services. Reported uncertainty remains visible.',
          ),
          action(
            Icons.info_outline,
            'Licenses & map credits',
            () => showLicensePage(context: context, applicationName: 'KAZE'),
          ),
        ]),
      ],
    );
  }
}
