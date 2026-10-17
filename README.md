# KAZE

KAZE is a timed safety-session prototype: the wearer carries the Vivo in a pocket, checks in when reminded, and an authorized guardian can see recorded geographic evidence after nonresponse. Optional live sharing requires a separate choice. The backend and SQLite database run on the PC.

The phone app is now **Flutter for Android and iOS**, with shared Map / Activity / Settings screens, not a WebView. Android runs the existing native foreground recorder and Galaxy Watch companion. The current iPhone role is guardian for the designated Vivo wearer. See [mobile build and pairing](docs/FLUTTER_MOBILE.md), [revised goal](KAZE_BUILD_GOAL.md), and [PC connectivity](docs/PC_BACKEND.md).

No wearer camera is used for tracking. Phone/watch location fixes retain timestamp, accuracy, provider and provenance. Sources are never blindly averaged. Gaps and uncertain observations remain visible; motion/pressure never invent geographic coordinates, rooms, floors or stairs.

## PC backend

Node 22.13+ is required for built-in SQLite.

```powershell
npm.cmd install
npm.cmd start
```

The default address is `http://127.0.0.1:4173`. Do not start another server if the port is already occupied. An existing process must be deliberately restarted before it can serve changed backend code. The browser dashboard remains a local testing/administration surface; phones use Flutter.

For a dedicated tethered phone test, use another terminal:

```powershell
$env:PORT = '4174'
$env:KAZE_DB = 'data/device-test.sqlite'
npm.cmd start
```

Then `adb -s PHONE_SERIAL reverse tcp:4174 tcp:4174`. For a separate guardian phone, use a shared reachable HTTPS URL; localhost on either phone points to that phone. No Cloudflare tunnel is assumed installed, and no remote delivery is promised while the PC/backend/network is down.

## Build

```powershell
cd mobile
flutter.bat pub get
flutter.bat build apk --debug
cd ..
.\android\gradlew.bat -p android :watch:assembleDebug
```

The Flutter phone APK is `mobile/build/app/outputs/flutter-apk/app-debug.apk`; the watch APK is `android/watch/build/outputs/apk/debug/watch-debug.apk`. [Mac/Xcode instructions](docs/FLUTTER_MOBILE.md) describe the iPhone guardian build and signing. iOS is not build-verified on Windows.

## Verification

```powershell
npm.cmd test
npm.cmd run test:browser
.\android\gradlew.bat -p android :shared:testDebugUnitTest :watch:lintDebug :shared:lintDebug
cd mobile
flutter.bat analyze
flutter.bat test
flutter.bat build apk --debug
```

Auth roles, persistent deadlines, idempotent offline queues, retention, expiry, end/delete and revocation remain required. Guardian acknowledgment does not resolve an incident or verify arrival. Keep the guardian app open: push, SMS, calls and emergency dispatch are not implemented.

The optional guardian camera view is an **experimental approximate outdoor direction cue**, not a shared spatially anchored AR route. No custom learned motion estimator is integrated. Compilation and simulated tests do not establish real route accuracy, screen-off reliability or successful assistance. See [implementation/evidence](docs/IMPLEMENTATION.md) and [demo](docs/DEMO.md).

Current test/device evidence is recorded in [the verification ledger](docs/VERIFICATION.md). Watch setup is automatic from the watch after a phone session starts; only an explicit watch Start tap is needed to consent.
