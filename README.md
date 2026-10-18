# KAZE

A phone and watch app for timed safety check-ins. A trusted guardian can view the recorded trail after a missed check-in, or throughout a session when live sharing is enabled.

Built with Flutter for Android and iOS, plus a native Wear OS companion. Tested on a **Vivo X300 Ultra** and **Galaxy Watch4**.

## Run

Requires Node.js 22.13 or newer.

```powershell
npm.cmd install
npm.cmd start
```

The app contains its HTTPS service address; users do not enter a backend URL. Keep the backend running while using KAZE. For access from another phone, expose it through an HTTPS tunnel or host it behind HTTPS. A temporary tunnel address changes when restarted. For developer builds, set `KAZE_BASE_URL` at build time to match that address; use a stable named HTTPS hostname before distributing the app.

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

Start a session on the phone and open KAZE on the paired watch. In Settings, choose **Show guardian QR code**. Your guardian chooses **Scan QR code** on their iPhone or Android, or enters the short pairing code. Codes work once for five minutes; both phones must use the same KAZE service. The watch uses the phone's Bluetooth connection; the phone can use Wi-Fi or cellular data. See [guardian pairing](docs/GUARDIAN_PAIRING.md).

Wearer recording runs on Android. Android guardians can opt into **Background guardian alerts** after joining: a visible native service checks server status and posts a notification after confirmed nonresponse, even while the Flutter screen is closed. Allow notifications and background battery use. Network loss is reported separately; it never becomes a presumed safety alert. Force-stop, reboot, restricted battery use or blocked notifications can interrupt delivery. Reopen KAZE and re-enable monitoring after force-stop or reboot. This is background polling, not remote push.

iPhone guardians can opt into local review reminders using a free Apple Account signed build. These reminders use the last known deadline and cannot confirm nonresponse or notice a later check-in while KAZE is closed. Reopen KAZE to verify current status. Native Apple push registration and server delivery are implemented as an optional path requiring paid Apple Developer membership, push-capable signing and server credentials; they are disabled by default. The new native iOS notification code still needs an Xcode build and physical-device verification. See [iPhone setup](docs/FLUTTER_MOBILE.md#iphone), [Apple push setup](docs/IOS_NOTIFICATIONS.md) and the [iPhone regression instructions](docs/FLUTTER_MOBILE.md#ios-simulator-regression-suite). Calls, SMS, backup-contact escalation and emergency dispatch are not implemented.

Experimental [guardian spatial AR](docs/AR_BACKEND.md) uses native ARKit/RealityKit or ARCore and a measured outdoor walking baseline to align a recorded trail with the camera. It draws continuous trail sections with live direction and distance cues; unknown heights use a labeled floating horizontal guide. Poor registration and excessive horizontal uncertainty require the map. Ground, floors and obstacles are not detected. Physical accuracy and two-phone operation still need verification. The separate compass preview remains unregistered.

[Motion trail evaluation](docs/MOTION_EVALUATION.md) starts automatically with wearer sessions and sends compressed batches over Wi-Fi or cellular. It saves no raw capture by default; optional private captures support measured comparisons. It does not change shared trails or check-in behavior.
