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

Enter the backend HTTPS address on the wearer's phone, choose timing and start a session. Copy the guardian link from Settings to the guardian's phone. Trails are shared after nonresponse unless live sharing was enabled separately.

Keep the guardian app open to receive updates. Check-ins require server confirmation. An acknowledgment does not end the session.

See [network setup](PC_BACKEND.md) for remote access.
