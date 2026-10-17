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

Start a session on the phone, open KAZE on the paired watch, and share the guardian link from Settings. The watch uses the phone's Bluetooth connection; the phone can use Wi-Fi or cellular data.

Wearer recording runs on Android. iPhone guardian flows are tested in the iOS Simulator; signed builds and physical-device verification are still needed. See the [iPhone regression instructions](docs/FLUTTER_MOBILE.md) for testing on a configured Mac. Keep the guardian app open; background push and emergency dispatch are not implemented.

Experimental [guardian spatial AR](docs/AR_BACKEND.md) uses native ARKit/RealityKit or ARCore and a measured outdoor walking baseline to register supported recorded observations. Unknown heights, poor registration and excessive uncertainty require the map. Physical accuracy and two-phone operation still need verification. The separate compass preview remains unregistered.

[Motion trail evaluation](docs/MOTION_EVALUATION.md) starts automatically with wearer sessions and sends compressed batches over Wi-Fi or cellular. It saves no raw capture by default; optional private captures support measured comparisons. It does not change shared trails or check-in behavior.
