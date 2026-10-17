# KAZE mobile (Flutter)

The phone app is Flutter for Android and iOS. It renders widgets and the geographic map directly; it does not embed the browser dashboard or a WebView. The Vivo is the wearer recorder; an iPhone or second Android phone joins as guardian. Wear OS stays native Java.

## Android on this Windows PC

Flutter 3.47.7 / Dart 3.13.5 was installed at `C:\Users\ezras\.cache\kaze-flutter`. Add its `bin` folder to PATH, or call `flutter.bat` by absolute path. The Android SDK is `C:\Users\ezras\.cache\kaze-android-sdk`; Java 17 is configured in Flutter.

From `mobile/`:

```powershell
flutter.bat pub get
flutter.bat analyze
flutter.bat test
flutter.bat build apk --debug --dart-define=KAZE_BASE_URL=http://127.0.0.1:4174
```

Install `mobile/build/app/outputs/flutter-apk/app-debug.apk` on the Vivo. It uses `app.kaze.trail`, matching the Watch4 package/debug signature for Wear Data Layer. The Java Android host in `android/phone/src` is included by `mobile/android/app/build.gradle.kts`; the existing `android/shared` module owns recording, queues, clock sync and reminders. The standalone `android` Gradle root builds the watch and shared tests; it no longer builds the old phone UI.

A USB debug test can run a dedicated PC server on 4174 and `adb reverse tcp:4174 tcp:4174`. This localhost URL only works on that tethered device. It cannot be used as the guardian invitation on another phone. For the two-phone demo, use the same reachable HTTPS origin on both phones; see [PC connectivity](PC_BACKEND.md). No public tunnel is installed or launched automatically.

## iPhone on the available Mac

Clone the complete branch on the Mac:

```sh
git clone --branch codex/kaze-flutter-verification https://github.com/ezrasong/htv11.git
cd htv11/mobile
```

If you already cloned the repository, run `git fetch origin`, then `git switch codex/kaze-flutter-verification` from that checkout before entering `mobile/`.

Transfer the source checkout (including `mobile`, `android/shared` and `android/phone`; excluding generated builds, private data and local.properties). Install the same Flutter stable version, Xcode, Xcode command-line tools and the signing requirements shown by `flutter doctor`. From the transferred `mobile/` directory:

```sh
flutter pub get
flutter analyze
flutter test
flutter build ios --debug --no-codesign
open ios/Runner.xcworkspace
```

In Xcode choose Runner, a unique bundle identifier if necessary, your Apple development team and the connected iPhone, then run. Enable Developer Mode on the iPhone if Xcode requests it. A signed device build and its permission flow must be checked on the Mac; Windows cannot verify that build. The generated iOS project uses Flutter's Swift Package Manager integration. The permission descriptions cover guardian camera/location and local network access. Production connections require HTTPS; TLS checks and scoped bearer credentials remain enabled.

On iPhone choose **Join as guardian** and paste the link copied from the wearer's app Settings. The current iOS role is guardian; wearer background recording is implemented on Android for the designated Vivo, not claimed on iOS.

## Roles and disclosure

1. On the Vivo enter the PC URL and first name, choose timing, explicitly consent and start a safety session. Phone sensor permissions can be denied; no location will be invented.
2. Settings -> Copy guardian link. Share only with the consenting second-phone tester. No owner/watch credentials are in this link.
3. On the second phone paste that link into Join as guardian. Default disclosure opens only after nonresponse. Live sharing requires the wearer's separate opt-in.
4. Map / Activity / Settings are shared Flutter screens. The prominent Check in button confirms only a successful server response. Sensor uploads never reset the deadline.
5. Keep the guardian app open. There is no background push, SMS, call or emergency dispatch.
6. End, delete or revoke on the wearer. Guardian evidence is cleared after the next authorization check and is hidden whenever the server cannot confirm access. Previously viewed information/screenshots cannot be remotely erased.

Street-map tiles come from OpenStreetMap, which receives the viewed map area and IP. Disable **Load street map** in Settings if desired. Recorded coordinates and uncertainty work without tiles; an internet tile outage is not a location outage.

## Optional camera preview

Only a guardian in an authorized active assistance request can open Camera direction preview. Camera frames stay on that phone; there is no recording/upload. This is an experimental outdoor compass bearing to the last geographic point, not ARCore/ARKit shared spatial alignment. It requires current guardian position/heading and sufficiently fresh, accurate, non-mock wearer evidence. Missing or poor evidence falls back to the map. No floor/stair/room/obstacle path is fabricated.

Do not claim precise AR breadcrumbs or measured direction accuracy before a physical two-phone test. Permissions, app backgrounding, lost authorization and camera failure leave the server deadline independent.


## Real Vivo integration test

Use a disposable test session and the dedicated local server on 4174. Authorize the Vivo for USB debugging/installation, reverse port 4174, and grant the recording/notification permissions before starting this automated test (or handle their dialogs):

```powershell
flutter.bat test integration_test/app_flow_test.dart -d PHONE_SERIAL --dart-define=KAZE_BASE_URL=http://127.0.0.1:4174
```

This creates a real session, waits for actual native phone callbacks/uploads, checks in, verifies activity and ends/forgets the session. It sends no synthetic sensor/location events and makes no route-accuracy assertion. Rebuild/reinstall the normal APK afterward; the integration test target is not the user app entrypoint.

For phone Android lint, run `./gradlew :app:lintDebug` from `mobile/android` (Windows: `gradlew.bat`). The app build serializes the generated local.properties using Java Properties immediately before lint, correcting Flutter-generated Windows drive-colon escaping without disabling any lint checks.

## Automatic Galaxy Watch setup

After installing both debug apps and pairing the Watch4 with the Vivo in Galaxy Wearable:

1. Start a consented safety session in KAZE on the Vivo.
2. Open KAZE on the watch. It automatically requests the current session over Wear Data Layer, including through the phone's background listener.
3. When it says Phone connected, tap Start watch session and choose permissions. Discovery alone does not start recording.

There is no manual Pair Galaxy Watch button in the ordinary Flutter flow. The watch receives an allowlisted watch credential, never the owner's or guardian's credential. Discovery cannot replace a starting/active watch session. If there is no active phone session, the idle watch clears stale configuration and says to start on the phone. Foreground discovery retries when a connection is unavailable. ADB wireless pairing is a development installation step, separate from normal KAZE app pairing.
