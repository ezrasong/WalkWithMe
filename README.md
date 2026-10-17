# KAZE

A phone and watch app for timed safety check-ins. A trusted guardian can view the recorded trail after a missed check-in, or throughout a session when live sharing is enabled.

Built with Flutter for Android and iOS, plus a native Wear OS companion. Tested on a **Vivo X300 Ultra** and **Galaxy Watch4**.

## Run

Requires Node.js 22.13 or newer.

```powershell
npm.cmd install
powershell -ExecutionPolicy Bypass -File scripts/start-online.ps1
```

The app contains its HTTPS service address; users do not enter a backend URL. The launcher runs the backend and a Cloudflare tunnel; keep it running while using KAZE. Its temporary address changes when the tunnel restarts. For developer builds, set `KAZE_BASE_URL` at build time to match that address; use a stable named HTTPS hostname before distributing the app.

For local development, use `npm.cmd start` at `http://127.0.0.1:4173`. See [network setup](docs/PC_BACKEND.md).

## Build

```powershell
cd mobile
flutter pub get
flutter build apk --debug
cd ..
.\android\gradlew.bat -p android :watch:assembleDebug
```

[Phone, watch and iPhone setup](docs/FLUTTER_MOBILE.md).

## Use

Start a session on the phone, open KAZE on the paired watch, and share the guardian link from Settings. The watch uses the phone's Bluetooth connection; the phone can use Wi-Fi or cellular data.

Wearer recording runs on Android. Android guardians can opt into **Background guardian alerts** after joining: a visible native service checks server status and posts a notification after confirmed nonresponse, even while the Flutter screen is closed. Allow notifications and background battery use. Network loss is reported separately; it never becomes a presumed safety alert. Force-stop, reboot, restricted battery use or blocked notifications can interrupt delivery. Reopen KAZE and re-enable monitoring after force-stop or reboot. This is background polling, not remote push.

iPhone guardians can opt into local review reminders using a free Apple Account signed build. These reminders use the last known deadline and cannot confirm nonresponse or notice a later check-in while KAZE is closed. Reopen KAZE to verify current status. Native Apple push registration and server delivery are implemented as an optional path requiring paid Apple Developer membership, push-capable signing and server credentials; they are disabled by default. The new native iOS notification code still needs an Xcode build and physical-device verification. See [iPhone setup](docs/FLUTTER_MOBILE.md#iphone) and [Apple push setup](docs/IOS_NOTIFICATIONS.md). Calls, SMS, backup-contact escalation and emergency dispatch are not implemented. Run `npm run test:ios` on a configured Mac for the guardian regression suite.

Experimental [guardian spatial AR](docs/AR_BACKEND.md) uses native ARKit/RealityKit or ARCore and a measured outdoor walking baseline to register supported recorded observations. Unknown heights, poor registration and excessive uncertainty require the map. Physical accuracy and two-phone operation still need verification. The separate compass preview remains unregistered.
