# Phone and watch setup

## Android

Install Flutter, Android SDK tools and Java 17. From the repository root:

```powershell
cd mobile
flutter pub get
flutter build apk --debug
cd ..
.\android\gradlew.bat -p android :watch:assembleDebug
```

Install these APKs:

- Phone: `mobile/build/app/outputs/flutter-apk/app-debug.apk`
- Watch: `android/watch/build/outputs/apk/debug/watch-debug.apk`

With ADB connected:

```powershell
adb -s PHONE_SERIAL install -r mobile/build/app/outputs/flutter-apk/app-debug.apk
adb -s WATCH_ADDRESS install -r android/watch/build/outputs/apk/debug/watch-debug.apk
```

Pair the watch with the phone using its companion app. Start a session in KAZE on the phone, then open KAZE on the watch. It joins automatically. Approve first-use permissions when prompted.

The watch relays through the phone over Bluetooth. Watch Wi-Fi is optional when the paired phone can reach the backend. Reopen KAZE to resume after a force-stop; reopening does not reset the check-in deadline.

An active session publishes a Wear OS Ongoing Activity to keep KAZE available when waking the watch and provide a watch-face return shortcut. Manually opening another app or the watch face remains under the user's control. This does not keep the display at full brightness or disable power management. See [Wear OS ongoing activities](https://developer.android.com/training/wearables/notifications/ongoing-activity).

## iPhone

On a Mac, install Xcode, CocoaPods and Flutter (Dart 3.13.5 or newer). Complete
Xcode's first-launch setup and install its matching iOS simulator runtime under
**Xcode → Settings → Components**. Check the toolchain with `flutter doctor -v`.
The iOS project uses Swift packages plus CocoaPods for the compass plugin.

For a local simulator, run the backend from the repository root in one terminal:

```sh
npm ci
npm start
```

In another terminal:

```sh
cd mobile
flutter pub get
flutter run -d 'iPhone 17 Pro' --dart-define=KAZE_BASE_URL=http://127.0.0.1:4173
```

The iOS simulator can reach the Mac at `127.0.0.1`. A physical iPhone needs a
reachable HTTPS service address. Guardian invitations must match the service
compiled into the app. For a physical iPhone build:

```sh
git clone https://github.com/ezrasong/htv11.git
cd htv11/mobile
flutter pub get
flutter build ios --debug --no-codesign --dart-define=KAZE_BASE_URL=https://your-service.example
open ios/Runner.xcworkspace
```

In Xcode, select Runner, enable **Automatically manage signing**, choose your Apple Account's Personal Team and the connected iPhone, then run. Enable iPhone Developer Mode if requested. This is a signed development build. A free Apple Account supports local installation and local notification reminders, usually with a seven-day provisioning lifetime. It does not provide Apple remote push capability. TestFlight/App Store distribution and remote push require paid Apple Developer membership. Leave the default `Kaze.entitlements` and `KAZE_PUSH_ENABLED=NO` for free-account testing.

Join as guardian by scanning the QR code shown in Settings on the wearer's phone, or entering its 10-character pairing code. Background wearer recording currently runs on Android. Signed builds and real-device permissions still need physical iPhone verification.

### iOS simulator regression suite

From the repository root:

```sh
cd mobile
flutter analyze
flutter test
cd ..
npm test
node test/ios/backend.mjs
```

The last command starts a separate loopback-only service on port 4174 with an in-memory database. In another terminal on a configured Mac, boot an iPhone simulator and run:

```sh
cd mobile
flutter drive --driver=test_driver/ios_guardian.dart \
  --target=integration_test/ios_guardian_test.dart \
  --dart-define=KAZE_BASE_URL=http://127.0.0.1:4174 -d SIMULATOR_UDID
```

Replace `SIMULATOR_UDID` with the identifier from `xcrun simctl list devices available`. Stop the test backend with Ctrl+C when finished.
Screenshots are saved in `artifacts/ios/screenshots/`; set
`KAZE_IOS_EVIDENCE_DIR` to an absolute directory to retain separate device runs.

The suite uses synthetic observations against the real API to check first launch,
invitation validation, private versus live sharing, missed check-ins, map controls,
guardian acknowledgment and arrival, unsupported AR fallback, appearance and
keychain restoration, offline recovery, revocation, deletion, expiry, landscape,
large text, licenses and access removal. It does not measure GPS or compass accuracy,
camera rendering, AR registration, background delivery or paired-watch behavior.
ARKit world tracking and the camera require physical devices.

During an active assistance request, **Guardian spatial AR** requests camera and precise foreground location on the guardian phone. Use a safe outdoor area with space for a 30–100 m walking registration baseline; weak locations return to the map. After alignment it displays the recorded trail, direction chevrons and a live next-point arrow/distance. Missing compatible heights use a labeled floating horizontal guide and do not block the camera. Trail gaps are never joined; ground, floors, stairs and obstacles are not detected. Local alignment processes the camera on the guardian phone. On Android, the optional **Agree & use Google** path sends guardian camera/location sensor data to Google for Geospatial alignment and requires project authorization; **Use local alignment** keeps the existing walking registration. See [registration and verification limits](AR_BACKEND.md). The iPhone 17/iOS 26.6.2 target still needs a signed Xcode run and physical testing; Windows Android tests cannot verify it.

For a shared presentation, choose **Start shared walking demo** with no active session. The app creates a separate simulated wearer and shares its server-generated movement with a paired guardian. Open **Demo walk controls & camera** on the map for pause/resume, restart, 1x/2x/4x speed and camera tracking. Both map and camera follow the same traveled route. A private build preset supplies the presentation area; ordinary builds use a synthetic nearby route, which does not establish safe access. The camera shows a direction card, large arrow and small map. Unsupported AR phones use GPS + compass placement, requiring fresh precise real guardian location and compass data outdoors; it is approximate and not attached to detected ground. Android offers optional Google-assisted alignment with an explicit data notice. See the [keyless project setup](AR_BACKEND.md#optional-google-assisted-alignment-on-android); leave billing unlinked for a free-only demo.

For a camera-only presentation, choose **Local camera animation** on the welcome screen or in **Settings → Device setup**. Point the camera toward an open, well-lit space, then tap **Start demo**. A pink virtual wearer leaves a local camera trail with pause, resume, restart and 1x/2x speed controls. No second person, GPS, server or walking calibration is needed. Phones without native AR use a camera animation labeled **DEMO: Simulated placement**; that fallback does not track phone movement or anchor a trail in the room. The demo stays labeled, sends no fake locations to a safety session, and requires ending active Android wearer recording before the camera can open.

## Permissions and updates

First launch guides location, notifications and background access. Reopen this from **Permissions & background setup**.

On the tested Vivo, background access is under App info → Battery usage → Background power control → **Allow background power usage**. Other phones may use different menus.

Install updates over the existing app using the same signing key. Do not uninstall or clear app data if you want to retain settings.

## Sessions

Choose timing and start a session on the wearer's phone. The HTTPS service address is built into the app and inherited automatically by the watch. Choose **Settings → Show guardian QR code**. On the guardian's phone choose **Scan QR code**, or enter the displayed pairing code. Each code works once for five minutes; generating a new one replaces the previous code. QR invitations for another server are rejected before sending credentials. Both app builds and the backend need the pairing update. Trails are shared after nonresponse unless live sharing was enabled separately. See [pairing behavior and limits](GUARDIAN_PAIRING.md).

On an Android guardian, opt into **Background guardian alerts** on the session screen or in Settings. The native monitor uses a persistent notification and checks the server every five seconds after the previous request completes. It requires notifications, network access and background battery use; it does not request guardian location or motion permissions. Alerts contain no wearer name, location or private link. Open KAZE to view evidence or explicitly acknowledge. Stopping monitoring does not acknowledge or resolve the wearer's alert. Removing the guardian link also stops monitoring and removes its saved access. Expiry, revocation, deletion and session resolution stop monitoring after confirmation; known expiry is enforced locally during network loss. A stale response cannot restore a removed link. After force-stop or a phone reboot, reopen KAZE and enable monitoring again.

The background monitor reads only session status. Its polling never counts as a human opening or acknowledging the request. Network errors produce a separate connection warning, not a safety alert. Notification settings, Do Not Disturb and manufacturer battery controls still apply. Physical background delivery needs a dedicated guardian-device check before relying on it.

On iPhone, enable **Guardian notifications** for a local review reminder at the last known check-in deadline plus grace. It says to reopen KAZE to verify status; it cannot establish nonresponse while the app is closed and may be stale after a wearer check-in, revocation or session change. Confirmed foreground updates refresh or cancel the reminder. No background location, continuous polling or silent-push workaround is used. Optional remote Apple push is implemented but disabled until paid-team signing and server credentials are configured; see [Apple notification setup](IOS_NOTIFICATIONS.md). The new Swift notification code still needs an Xcode build and physical iPhone validation. Calls, SMS, backup-contact escalation and emergency dispatch are not connected on either platform. Check-ins require server confirmation. An acknowledgment does not end the session.

See [network setup](PC_BACKEND.md) for remote access.

For developer builds only, use `flutter build apk --debug --dart-define=KAZE_BASE_URL=https://your-service.example` (or the same define on the iOS build). The default is in `lib/backend.dart`; end users do not configure it. Release builds require HTTPS. App credentials stay in secure/app-private storage, backups are excluded, authenticated redirects are disabled, and server roles, consent, expiry and revocation still apply. A temporary Quick Tunnel address is for development; a stable named hostname is needed for normal distribution.
