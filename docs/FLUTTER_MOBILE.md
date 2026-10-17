# KAZE mobile (Flutter)

The phone app is Flutter for Android and iOS. It renders Flutter widgets and a native MapLibre vector map; it does not embed the browser dashboard or a WebView. The Vivo is the wearer recorder; an iPhone or second Android phone joins as guardian. Wear OS stays native Java.

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

If you already cloned the repository, run `git fetch origin`, `git switch codex/kaze-flutter-verification`, then `git pull --ff-only origin codex/kaze-flutter-verification` from that checkout before entering `mobile/`.

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

The map uses native MapLibre rendering with OpenFreeMap vector tiles and light Positron/dark styles. OpenFreeMap receives the viewed map area and IP; geographic data comes from OpenStreetMap. Streets and labels render at device resolution instead of scaling bitmap tiles. Disable **Street map** in Settings if desired. Recorded coordinates and uncertainty work without tiles; an internet tile outage is not a location outage. OpenFreeMap, OpenMapTiles and OpenStreetMap are attributed in the map.

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
3. KAZE joins the consented phone session automatically. Approve first-use OS permissions if requested, then tap **Check in**. There is no separate Start/enable button.

There is no manual Pair Galaxy Watch button in the ordinary Flutter flow. The watch receives an allowlisted watch credential, never the owner's or guardian's credential. Discovery cannot replace a starting/active watch session. If there is no active phone session, the idle watch clears stale configuration and says to start on the phone. Foreground discovery retries when a connection is unavailable. ADB wireless pairing is a development installation step, separate from normal KAZE app pairing.

The watch prefers Wear Data Layer through the paired phone, including Bluetooth. It does not require its own Wi-Fi while connected to the phone. The phone still needs a working route to the backend to confirm check-ins. If the phone relay is unavailable, the watch can attempt a direct backend connection over its own network. Offline sensor readings queue locally; an offline check-in is never presented as server-confirmed.

Reminders use vibration only, preferring the active watch. KAZE does not request reminder sounds. Without an active watch, the phone vibrates and posts its reminder instead. If watch contact stops, phone fallback occurs within 20 seconds of the last contact; pairing hardware without running KAZE does not suppress phone alerts. Disabled watch notifications or channel vibration also allow phone fallback. Notification permissions, mute and Do Not Disturb affect delivery; KAZE does not override them. Only an explicit server-accepted Check in resets the deadline.

To verify felt vibration, use a disposable two-minute session, keep the watch worn and wait for its check-in deadline without tapping Check in. Confirm the physical buzz separately from notification diagnostics. End the session and wait for both recorders to stop. To exercise phone fallback, force-stop only KAZE on the idle watch (`adb -s WATCH_CONNECTION_ADDRESS shell am force-stop app.kaze.trail`), then create another two-minute session on the Vivo. Keep the phone close enough to feel the reminder. End that session afterward; reopening KAZE on the watch restores automatic discovery for the next session. Merely closing the watch screen leaves background recording active and does not simulate an unavailable watch.

### Background verification using normal apps

Install both normal debug APKs, add the phone's USB reverse for 4174, and end any existing disposable session. With port 4174 free, run from the repository root:

```powershell
python scripts/verify-device-flow.py --phone PHONE_SERIAL --watch WATCH_CONNECTION_ADDRESS --normal-app --managed-backend --long-run
```

The helper starts the dedicated local backend using `data/device-test.sqlite`. When it prints ready, create a new consented session in the normal Vivo UI within three minutes. Use the watch's ADB connection address, not its pairing-code endpoint. Keep both devices untouched, including when reminders appear. The host opens KAZE on the watch, verifies automatic joining and taps Check in once. Its test backend then closes existing/new device sockets for a bounded outage while keeping the persisted deadline timer running. It requires native offline status and unreceived queued IDs on both devices, checks their delivery after reconnection, and samples screen-off/recording state for 610 seconds. Removing USB forwarding alone is insufficient because existing sockets can survive it. The watch must have no ADB reverse for relay proof. Reports are redacted in `artifacts/device-long-run.json`; failures are not a reliability pass. This mode attempts to end its fresh disposable session and stop its child backend on exit, leaving the ordinary tappable app installed. It does not prove measured walking accuracy, felt/audible alerts, or untethered battery/Doze behavior.

## Appearance and layout

Settings → Appearance offers System, Light and Dark; the choice is remembered. The native vector map uses matching light/dark styles with sharp street labels. The bundled Dark adaptation increases label, road and building contrast; upstream notices are available under Licenses & map credits. Check-in stays prominent above the map; detailed readings and guardian response actions are available from the location card. Map controls recenter, show the complete recorded trail, and zoom. Blue solid phone paths and purple dashed watch paths retain separate sources and real gaps. Panning pauses automatic following until recenter.

The layout follows Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/), especially layout, typography, accessibility and maps: safe areas, scalable text, clear hierarchy, generous touch targets, labeled controls, restrained surfaces and grouped destructive actions. iOS uses Cupertino navigation/tab bars and adaptive dialogs; Android keeps platform navigation. Verify actual iOS rendering and signing on the Mac before treating it as iPhone-tested.
