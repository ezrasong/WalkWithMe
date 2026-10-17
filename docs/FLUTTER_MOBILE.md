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

On a Mac with Flutter and Xcode:

```sh
git clone --branch codex/kaze-flutter-verification https://github.com/ezrasong/htv11.git
cd htv11/mobile
flutter pub get
flutter build ios --debug --no-codesign
open ios/Runner.xcworkspace
```

In Xcode, select Runner, your signing team and the connected iPhone, then run. Enable iPhone Developer Mode if requested.

Join as guardian using the link copied from the wearer's phone. Background wearer recording currently runs on Android. The iPhone build and permission flow still need device verification.

## Permissions and updates

First launch guides location, notifications and background access. Reopen this from **Permissions & background setup**.

On the tested Vivo, background access is under App info → Battery usage → Background power control → **Allow background power usage**. Other phones may use different menus.

Install updates over the existing app using the same signing key. Do not uninstall or clear app data if you want to retain settings.

## Sessions

Choose timing and start a session on the wearer's phone. The HTTPS service address is built into the app and inherited automatically by the watch. Copy the guardian link from Settings to the guardian's phone. Invitations for another server are rejected before sending credentials. Trails are shared after nonresponse unless live sharing was enabled separately.

Keep the guardian app open to receive updates. Check-ins require server confirmation. An acknowledgment does not end the session.

See [network setup](PC_BACKEND.md) for remote access.

For developer builds only, use `flutter build apk --debug --dart-define=KAZE_BASE_URL=https://your-service.example` (or the same define on the iOS build). The default is in `lib/backend.dart`; end users do not configure it. Release builds require HTTPS. App credentials stay in secure/app-private storage, backups are excluded, authenticated redirects are disabled, and server roles, consent, expiry and revocation still apply. A temporary Quick Tunnel address is for development; a stable named hostname is needed for normal distribution.
