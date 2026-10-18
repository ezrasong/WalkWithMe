import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';

import 'session.dart';
import 'direction_preview.dart';
import 'guardian_ar.dart';
import 'guardian_pairing.dart';
import 'motion_capture.dart';
import 'relative_motion.dart';
import 'relative_motion_camera.dart';
import 'device_setup.dart';
import 'trail_map.dart';
import 'backend.dart';
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
  ThemeMode appearance = ThemeMode.dark;
  final storage = const FlutterSecureStorage();
  @override
  void initState() {
    super.initState();
    storage
        .read(key: 'appearance')
        .then((value) {
          if (mounted) {
            setState(
              () => appearance = value == ThemeMode.light.name
                  ? ThemeMode.light
                  : ThemeMode.dark,
            );
          }
        })
        .catchError((Object _) {
          /* Keep the default dark appearance if storage is unavailable. */
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
    title: 'WalkWithMe',
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
  const deepBlue = Color(0xff1746a2);
  final colors =
      ColorScheme.fromSeed(
        seedColor: deepBlue,
        brightness: brightness,
        surface: dark ? const Color(0xff11151c) : const Color(0xfff7f8fa),
      ).copyWith(
        primary: dark ? const Color(0xff4f7cff) : deepBlue,
        onPrimary: Colors.white,
        secondary: dark ? const Color(0xff7597ff) : const Color(0xff2859b8),
        surfaceContainerLowest: dark ? const Color(0xff080a0e) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xff151a23)
            : const Color(0xffeef1f6),
        surfaceContainer: dark
            ? const Color(0xff1a202b)
            : const Color(0xffe7ebf2),
        outline: dark ? const Color(0xff343d4d) : const Color(0xffc1c8d4),
      );
  return ThemeData(
    colorScheme: colors,
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: colors.primary,
      barBackgroundColor: colors.surface,
    ),
    useMaterial3: true,
    scaffoldBackgroundColor: dark
        ? const Color(0xff080a0e)
        : const Color(0xffeef1f5),
    fontFamily: 'Roboto',
    textTheme: const TextTheme(
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        height: 1.08,
        letterSpacing: -.4,
      ),
      headlineSmall: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        height: 1.15,
        letterSpacing: -.2,
      ),
      titleLarge: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 17, height: 1.5),
      bodyMedium: TextStyle(fontSize: 16, height: 1.5),
      bodySmall: TextStyle(fontSize: 14, height: 1.5),
      labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      systemOverlayStyle: dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: colors.onSurface,
        fontSize: 22,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: dark
          ? const Color(0xff111720).withValues(alpha: .92)
          : Colors.white.withValues(alpha: .94),
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colors.outline.withValues(alpha: .55)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.outline.withValues(alpha: .55)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.outline.withValues(alpha: .55)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.primary, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        side: BorderSide(color: colors.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: dark ? const Color(0xff0d1118) : const Color(0xfff8f9fb),
      indicatorColor: colors.primary.withValues(alpha: .2),
      height: 76,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: colors.outline.withValues(alpha: .45),
      thickness: 1,
    ),
    listTileTheme: const ListTileThemeData(
      minVerticalPadding: 16,
      contentPadding: EdgeInsets.symmetric(horizontal: 4),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide(color: colors.outline.withValues(alpha: .55)),
    ),
  );
}

class _BrandTitle extends StatelessWidget {
  final String label;
  const _BrandTitle(this.label);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Image.asset(
            'assets/branding/walkwithme_logo.png',
            width: 34,
            height: 34,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(width: 11),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class SessionScreen extends StatefulWidget {
  final ThemeMode appearance;
  final ValueChanged<ThemeMode>? onAppearanceChanged;
  const SessionScreen({
    super.key,
    this.appearance = ThemeMode.dark,
    this.onAppearanceChanged,
  });
  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen>
    with WidgetsBindingObserver {
  final c = SessionController();
  final name = TextEditingController(text: 'Alex'),
      pairingCode = TextEditingController();
  int tab = 0, interval = 120, grace = 30;
  int setupRole = Platform.isAndroid ? 0 : 1;
  bool consent = false, live = false, tiles = true;
  bool get showDemoControls => c.demoMode;
  bool get hiddenDemo =>
      !showDemoControls && c.snapshot?['sensorMode'] == 'simulated';
  MaterialPageRoute<void>? demoCameraRoute;
  Timer? clock;
  String lastMessage = '';
  bool get transientMessage => const [
    'Check-in confirmed by server.',
    'Confirmed by server.',
  ].contains(c.message);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(update);
    c.restore().then((_) => offerDeviceSetup());
    clock = Timer.periodic(const Duration(seconds: 1), (_) => update());
  }

  void setDemoControls(bool visible) {
    unawaited(c.setDemoMode(visible));
    if (hiddenDemo) setState(() => tab = 0);
    if (!visible && demoCameraRoute?.navigator != null) {
      demoCameraRoute!.navigator!.removeRoute(demoCameraRoute!);
    }
    if (hiddenDemo) ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  Widget demoModeSwitch() => SwitchListTile.adaptive(
    contentPadding: EdgeInsets.zero,
    title: const Text('Demo mode'),
    subtitle: const Text(
      'Enable guardian camera practice and shared simulated walks. Turning off hides all demo screens, controls and simulated session data on this phone. Live sessions stay available.',
    ),
    value: showDemoControls,
    onChanged: setDemoControls,
  );

  Future<void> openPresentationSettings() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ListenableBuilder(
        listenable: c,
        builder: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Settings', style: Theme.of(context).textTheme.titleLarge),
            demoModeSwitch(),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget hiddenDemoPage() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      card([
        const Text('No live session to display.'),
        const Text('Your saved session is hidden on this phone.'),
        TextButton.icon(
          onPressed: openPresentationSettings,
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Settings'),
        ),
        TextButton(onPressed: c.forget, child: const Text('Return to setup')),
      ]),
      const Text(indoorTrackingNotice),
    ],
  );

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
    pairingCode.dispose();
    super.dispose();
  }

  Widget note(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(text, style: Theme.of(context).textTheme.bodySmall),
  );
  Widget card(List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final title = c.access == null
        ? 'WalkWithMe'
        : ['Session', 'Activity', 'Settings'][tab];
    final useDarkTheme =
        widget.appearance == ThemeMode.dark ||
        (widget.appearance == ThemeMode.system && dark);
    final themeToggle = IconButton(
      tooltip: useDarkTheme ? 'Use light theme' : 'Use dark theme',
      onPressed: () => widget.onAppearanceChanged?.call(
        useDarkTheme ? ThemeMode.light : ThemeMode.dark,
      ),
      icon: Icon(
        useDarkTheme ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
      ),
    );
    return Scaffold(
      appBar: Platform.isIOS
          ? CupertinoNavigationBar(
              middle: _BrandTitle(title),
              trailing: themeToggle,
              backgroundColor: colors.surface.withValues(alpha: .9),
              border: Border(
                bottom: BorderSide(
                  color: colors.outline.withValues(alpha: .35),
                ),
              ),
            )
          : AppBar(title: _BrandTitle(title), actions: [themeToggle]),
      body: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: c.access == null
                    ? onboarding()
                    : hiddenDemo
                    ? hiddenDemoPage()
                    : c.snapshot == null
                    ? waiting()
                    : [mapPage(), activityPage(), settingsPage()][tab],
              ),
              if (c.message.isNotEmpty && !transientMessage)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainer,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: colors.outline.withValues(alpha: .45),
                    ),
                  ),
                  child: Semantics(liveRegion: true, child: Text(c.message)),
                ),
              if (c.busy) const LinearProgressIndicator(minHeight: 3),
            ],
          ),
        ),
      ),
      bottomNavigationBar: c.access == null || hiddenDemo
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
                  selectedIcon: Icon(Icons.map_rounded),
                  label: 'Map',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history_outlined),
                  selectedIcon: Icon(Icons.history_rounded),
                  label: 'Activity',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings_rounded),
                  label: 'Settings',
                ),
              ],
            ),
    );
  }

  Widget onboarding() => ListView(
    padding: const EdgeInsets.fromLTRB(22, 16, 22, 40),
    children: [
      Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xff102d62),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xff4f7cff).withValues(alpha: .5),
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              right: 0,
              top: 0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  'assets/branding/walkwithme_logo.png',
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x33ffffff)),
                  ),
                  child: const Text(
                    'A timed safety session',
                    style: TextStyle(
                      color: Color(0xffb9cbff),
                      fontWeight: FontWeight.w700,
                      letterSpacing: .2,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  'Move with confidence.',
                  style: Theme.of(context).textTheme.displaySmall
                      ?.copyWith(color: Colors.white, fontSize: 36),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Stay connected to someone you trust. Start a session or join someone as their guardian.',
                  style: TextStyle(
                    color: Color(0xffd7e1ff),
                    fontSize: 16,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      card([const Text(indoorTrackingNotice)]),
      Card(
        child: ListTile(
          onTap: openDeviceSetup,
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary
                  .withValues(alpha: .15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.settings_suggest_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          title: const Text('Permissions & background setup'),
          subtitle: const Text('Review access before starting a session.'),
          trailing: const Icon(Icons.arrow_forward_rounded),
        ),
      ),
      card([
        TextButton.icon(
          onPressed: openPresentationSettings,
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Settings'),
        ),
        if (showDemoControls) ...[
          OutlinedButton.icon(
            onPressed: () =>
                openGuardianCamera(GuardianAr(session: c, demo: true)),
            icon: const Icon(Icons.view_in_ar),
            label: const Text('Try guardian camera demo'),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: c.busy ? null : startSharedDemo,
            icon: const Icon(Icons.directions_walk),
            label: const Text('Start shared walk'),
          ),
        ],
      ]),
      const SizedBox(height: 22),
      if (Platform.isAndroid)
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline
                  .withValues(alpha: .45),
            ),
          ),
          child: SegmentedButton<int>(
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
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity(vertical: 2),
              side: WidgetStatePropertyAll(BorderSide.none),
            ),
            onSelectionChanged: (value) =>
                setState(() => setupRole = value.first),
          ),
        ),
      if (setupRole == 1)
        card([
          Text(
            'Join as guardian',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          note('Follow their session without sharing your own location.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: c.busy ? null : scanGuardianQr,
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan QR code'),
          ),
          note(
            'Scan the QR code on the wearer’s phone, or enter their pairing code.',
          ),
          TextField(
            controller: pairingCode,
            decoration: const InputDecoration(
              labelText: 'Pairing code',
              hintText: 'ABCDE-FGHJK',
            ),
            maxLength: 11,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z2-9 -]')),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: c.busy ? null : () => c.joinCode(pairingCode.text),
            child: const Text('Open my person’s session'),
          ),
        ]),
      if (Platform.isAndroid && setupRole == 0)
        card([
          Text(
            'Start on the wearer’s phone',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          note('Choose the timing, permissions and person you trust.'),
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
              'I agree to phone/watch recording, compressed phone-motion uploads over Wi-Fi or cellular, retained experimental relative motion and owner-only diagnostics, and sharing after nonresponse with my chosen guardian. Indoor tracking and indoor AR navigation are not working. Motion streaming can be stopped in Settings. Data expires after 8 hours.',
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
      const SizedBox(height: 12),
      card([
        Row(
          children: [
            Icon(
              Icons.verified_user_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Text(
              'Clear limits',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
        note(
          'Android guardians can enable background monitoring. iPhone guardians can enable local review reminders; these cannot confirm a missed check-in while WalkWithMe is closed. Apple push requires paid-team signing and server setup. No emergency dispatch, calls or SMS are connected. The PC and network must stay running.',
        ),
        const Divider(height: 24),
        note(
          'OpenFreeMap serves vector maps using OpenStreetMap data and receives the viewed area and IP address. You can turn the street map off in Settings.',
        ),
        note(
          'Location and camera permission are requested only for their respective features. Local camera modes process images on the guardian phone. Google-assisted alignment asks before sharing sensor data with Google.',
        ),
      ]),
    ],
  );
  Widget waiting() => ListView(
    padding: const EdgeInsets.fromLTRB(20, 56, 20, 24),
    children: [
      card([const Text(indoorTrackingNotice)]),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(19),
                  ),
                  child: Icon(
                    Icons.cloud_off_outlined,
                    color: Theme.of(context).colorScheme.primary,
                    size: 30,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Reconnecting',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(c.connection),
              note(
                c.guardian
                    ? 'Private evidence is hidden while the server cannot confirm access.'
                    : 'The native recorder can continue queuing evidence. This is not server confirmation.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: c.busy ? null : c.refresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reconnect'),
              ),
              TextButton.icon(
                onPressed: openDeviceSetup,
                icon: const Icon(Icons.settings_suggest_outlined),
                label: const Text('Permissions & background setup'),
              ),
              TextButton.icon(
                onPressed: openPresentationSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Settings'),
              ),
              if (!c.guardian)
                OutlinedButton(
                  onPressed: () => c.mutate('resolve'),
                  child: const Text('End session on server'),
                ),
              if (c.guardian)
                TextButton(
                  onPressed: c.forget,
                  child: const Text('Remove guardian access'),
                ),
            ],
          ),
        ),
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

  Widget guardianMonitoring() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (c.backgroundGuardianSupported) ...[
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            c.iosGuardian
                ? 'Guardian notifications'
                : 'Background guardian alerts',
          ),
          subtitle: Text(
            c.device['status'] as String? ??
                'Off. Keep WalkWithMe open for updates.',
          ),
          value: c.device['enabled'] == true,
          onChanged: c.busy ? null : c.setGuardianMonitoring,
        ),
        if (!c.iosGuardian &&
            c.device['enabled'] == true &&
            c.device['running'] != true)
          note(
            'Android has not confirmed the monitor is running. Turn it off and on again while WalkWithMe is open.',
          ),
        note(
          c.iosGuardian
              ? 'With a free Apple Account, reminders use the last known deadline and may be stale after a wearer check-in or access change. Reopen WalkWithMe to verify status. Remote push requires a paid Apple Developer team, signing capability and server credentials; physical delivery is unverified. Focus and notification settings can suppress notifications.'
              : 'Uses a persistent Android notification and an internet connection. Battery restrictions, notification settings, force-stop or restarting the phone can interrupt delivery. Review Permissions & background setup.',
        ),
      ] else
        note('Keep WalkWithMe open for guardian updates on this device.'),
    ],
  );

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
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: (urgent ? colors.error : colors.primary).withValues(
                    alpha: .14,
                  ),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(
                  urgent
                      ? Icons.notifications_active_outlined
                      : phase == 'resolved'
                      ? Icons.check_circle_outline
                      : Icons.shield_outlined,
                  size: 23,
                  color: urgent ? colors.error : colors.primary,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      phaseText,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      c.guardian ? 'Guardian view' : 'Your safety session',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (['armed', 'challenge'].contains(phase))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: (urgent ? colors.error : colors.primary).withValues(
                  alpha: .13,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                countdown(seconds),
                semanticsLabel: '$seconds seconds until response is due',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: urgent ? colors.error : colors.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        phase == 'resolved'
            ? 'Sharing has stopped.'
            : phase == 'alert'
            ? 'Your guardian can view the shared trail. No emergency service has been contacted.'
            : 'Last check-in: ${at(s['lastCheckInAt'])}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (s['sensorMode'] == 'device') note(indoorTrackingNotice),
      if (s['relativeMotion']?['available'] == true)
        OutlinedButton(
          onPressed: showSessionDetails,
          child: const Text('Experimental pocket-motion diagram'),
        ),
      if (showDemoControls && s['demoWalk'] != null)
        OutlinedButton(
          onPressed: () => openGuardianCamera(DirectionPreview(session: c)),
          child: const Text('Open shared walk camera'),
        ),
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
      if (c.guardian && phase != 'resolved')
        if (c.backgroundGuardianSupported)
          TextButton.icon(
            onPressed: () => setState(() => tab = 2),
            icon: const Icon(Icons.notifications_outlined),
            label: Text(
              c.device['enabled'] == true
                  ? 'Review guardian notifications'
                  : 'Set up guardian notifications',
            ),
          )
        else
          note('Keep WalkWithMe open for guardian updates on this device.'),
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
        final map = Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: colors.outline.withValues(alpha: .65)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 24,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(25),
            child: TrailMap(key: ValueKey(s['id']), snapshot: s, tiles: tiles),
          ),
        );
        if (compact) {
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            children: [
              status,
              SizedBox(height: 360, child: map),
              location,
            ],
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
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

  Future<void> openGuardianCamera(Widget screen) async {
    final isDemo =
        (screen is GuardianAr && screen.demo) ||
        c.snapshot?['sensorMode'] == 'simulated';
    if (isDemo && !showDemoControls) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (Platform.isAndroid && screen is GuardianAr && !screen.demo) {
      final google = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Choose camera alignment'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Google-assisted alignment places the trail using outdoor visual features. It needs internet, a compatible phone and available coverage.',
                ),
                const SizedBox(height: 16),
                const Text(
                  'Local alignment processes the camera on this phone and requires an outdoor walking baseline. Unsupported AR phones use a GPS + compass guide.',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Use local alignment'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Agree & use Google'),
            ),
          ],
        ),
      );
      if (google == null || !mounted) return;
      screen = GuardianAr(session: c, geospatial: google);
    }
    if (!mounted || (isDemo && !showDemoControls)) return;
    final route = MaterialPageRoute<void>(builder: (_) => screen);
    if (isDemo) demoCameraRoute = route;
    try {
      await Navigator.of(context).push<void>(route);
    } finally {
      if (identical(demoCameraRoute, route)) demoCameraRoute = null;
    }
  }

  Future<void> startSharedDemo() async {
    if (!showDemoControls) return;
    try {
      List<Map<String, Object>> route;
      if (kazeDemoRoute.isNotEmpty) {
        route = (jsonDecode(kazeDemoRoute) as List)
            .map(
              (p) => {
                'latitude': (p['latitude'] as num).toDouble(),
                'longitude': (p['longitude'] as num).toDouble(),
                if (p['street'] is String) 'street': p['street'] as String,
              },
            )
            .toList();
      } else {
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
            timeLimit: Duration(seconds: 20),
          ),
        );
        if (p.isMocked || !p.accuracy.isFinite || p.accuracy > 20) {
          throw const FormatException(
            'Wait outdoors for a precise location to place the shared walk.',
          );
        }
        route = [
          {'latitude': p.latitude, 'longitude': p.longitude},
          {'latitude': p.latitude + .0004, 'longitude': p.longitude},
          {'latitude': p.latitude + .0004, 'longitude': p.longitude + .0004},
        ];
      }
      if (mounted && showDemoControls) await c.createSharedDemo(route);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start shared walk: $error')),
        );
      }
    }
  }

  Widget sharedDemoControls() {
    final walk = c.snapshot?['demoWalk'] as Map?;
    if (!showDemoControls ||
        c.snapshot?['sensorMode'] != 'simulated' ||
        walk == null) {
      return const SizedBox();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Walker - ${(walk['distance'] as num).round()} / ${(walk['total'] as num).round()} m',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (!c.guardian) ...[
          FilledButton.icon(
            onPressed: c.busy ? null : () => c.controlDemo('begin-take'),
            icon: const Icon(Icons.movie_outlined),
            label: const Text('Start 40-second alert take'),
          ),
          const Text(
            'Restarts the walk at 1x. Check-in is due after 30 seconds; after 10 more seconds without a response, the alert appears and the walker stops. The guardian can approach that position. Starting another take resets the countdown and responses.',
          ),
        ],
        if (!c.guardian)
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: c.busy
                    ? null
                    : () => c.controlDemo(
                        walk['running'] == true ? 'pause' : 'resume',
                      ),
                child: Text(
                  walk['running'] == true ? 'Pause walk' : 'Resume walk',
                ),
              ),
              TextButton(
                onPressed: c.busy ? null : () => c.controlDemo('restart'),
                child: const Text('Restart walk'),
              ),
              for (final speed in [1, 2, 4])
                ChoiceChip(
                  label: Text('${speed}x'),
                  selected: walk['speed'] == speed,
                  onSelected: c.busy
                      ? null
                      : (_) => c.controlDemo('speed', speed: speed),
                ),
            ],
          ),
        OutlinedButton.icon(
          onPressed: () => openGuardianCamera(DirectionPreview(session: c)),
          icon: const Icon(Icons.camera_alt_outlined),
          label: const Text('Open shared walk camera'),
        ),
        OutlinedButton.icon(
          onPressed: () => openGuardianCamera(GuardianAr(session: c)),
          icon: const Icon(Icons.view_in_ar),
          label: const Text('Track shared trail in camera'),
        ),
      ],
    );
  }

  Future<void> scanGuardianQr() async {
    if (!await c.prepareGuardianScan() || !mounted) return;
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const GuardianScannerScreen()),
    );
    if (!mounted || code == null) return;
    pairingCode.text = code;
    await c.joinCode(code);
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
        if (hiddenDemo) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No live session to display.'),
          );
        }
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
              RelativeMotionCard(motion: s['relativeMotion'] as Map?),
              if (c.guardian && phase == 'alert') ...[
                if (s['relativeMotion']?['available'] == true)
                  OutlinedButton.icon(
                    onPressed: () =>
                        openGuardianCamera(RelativeMotionCamera(session: c)),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text('Camera + motion diagram (no indoor AR)'),
                  ),
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
                    onPressed: () => openGuardianCamera(GuardianAr(session: c)),
                    icon: const Icon(Icons.view_in_ar),
                    label: const Text('Outdoor spatial AR (experimental)'),
                  ),
                if (p != null)
                  OutlinedButton.icon(
                    onPressed: () =>
                        openGuardianCamera(DirectionPreview(session: c)),
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: const Text(
                      'Outdoor direction preview (approximate)',
                    ),
                  ),
              ],
              if (showDemoControls && s['demoWalk'] != null)
                sharedDemoControls(),
              const Divider(height: 24),
              Text(
                'Connection',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              note(c.connection),
              if (!c.guardian)
                note(
                  s['sensorMode'] == 'simulated'
                      ? 'Walking session active.'
                      : c.device['status']?.toString() ??
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
      'demo-take': 'Alert take restarted',
    };
    final activity = c.snapshot?['activity'] as List? ?? [];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
      children: [
        Text('Activity', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          'A server-confirmed timeline of this session.',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        if (activity.isEmpty)
          card([
            const Icon(Icons.history_toggle_off_rounded, size: 40),
            const SizedBox(height: 12),
            const Text('No activity is shared yet.'),
          ]),
        for (final entry in activity.reversed)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: ListTile(
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary
                        .withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    entry['action'] == 'alert'
                        ? Icons.notifications_active_outlined
                        : entry['action'] == 'check-in'
                        ? Icons.check_rounded
                        : Icons.route_rounded,
                    color: entry['action'] == 'alert'
                        ? Theme.of(context).colorScheme.error
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
                title: Text(labels[entry['action']] ?? entry['action']),
                subtitle: Text('${at(entry['at'])} · ${entry['role']}'),
              ),
            ),
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
          padding: const EdgeInsets.fromLTRB(6, 24, 6, 2),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
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
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(
          'Control access, appearance and the active session.',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: colors.onSurfaceVariant),
        ),
        section('Presentation', [demoModeSwitch()]),
        section('Device setup', [
          if (showDemoControls)
            action(
              Icons.view_in_ar,
              'Try guardian camera demo',
              () => openGuardianCamera(GuardianAr(session: c, demo: true)),
              subtitle: 'Practice with a virtual walker. No wearer, GPS or missed check-in is required.',
            ),
          action(
            Icons.settings_suggest_outlined,
            'Permissions & background setup',
            openDeviceSetup,
            subtitle: 'Location, reminders and background settings.',
          ),
          if (Platform.isAndroid && !c.guardian)
            action(
              Icons.sensors,
              'Motion trail evaluation',
              () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MotionCapturePage(session: c),
                ),
              ),
              subtitle: 'Experimental relative diagram and tuning logs. Indoor tracking is not working.',
            ),
        ]),
        if (showDemoControls && s['sensorMode'] == 'simulated')
          section('Shared walk', [sharedDemoControls()]),
        if (c.guardian && phase != 'resolved')
          section('Guardian alerts', [guardianMonitoring()]),
        section('Appearance', [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Light theme'),
            subtitle: const Text('Dark theme is used by default.'),
            value: widget.appearance == ThemeMode.light,
            onChanged: (light) => widget.onAppearanceChanged?.call(
              light ? ThemeMode.light : ThemeMode.dark,
            ),
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
                'Open WalkWithMe on your paired watch, then tap Check in.',
              ),
            ),
        ]),
        if (!c.guardian &&
            c.access?.guardianToken != null &&
            s['guardianRevokedAt'] == null &&
            phase != 'resolved')
          section('Your guardian', [
            const Text(
              'Show your guardian a QR code or give them a short pairing code. They can join on iPhone or Android.',
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: c.busy
                  ? null
                  : () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => GuardianPairingScreen(session: c),
                      ),
                    ),
              icon: const Icon(Icons.qr_code),
              label: const Text('Show guardian QR code'),
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
            action(
              Icons.person_remove_outlined,
              'Remove guardian access',
              c.forget,
            ),
        ]),
        section('About this prototype', [
          const Text(
            'Android guardians can enable background monitoring. iPhone local reminders cannot verify background session status. Apple push needs paid-team signing and server credentials, and still needs physical testing. Calls, SMS and emergency dispatch are not connected.',
          ),
          note(indoorTrackingNotice),
          note(
            'Location comes from device location services. Reported uncertainty remains visible.',
          ),
          action(
            Icons.info_outline,
            'Licenses & map credits',
            () => showLicensePage(
              context: context,
              applicationName: 'WalkWithMe',
            ),
          ),
        ]),
      ],
    );
  }
}
