# KAZE

A phone and watch app for timed safety check-ins. A trusted guardian can view the recorded trail after a missed check-in, or throughout a session when live sharing is enabled.

Built with Flutter for Android and iOS, plus a native Wear OS companion. Tested on a **Vivo X300 Ultra** and **Galaxy Watch4**.

## Run

Requires Node.js 22.13 or newer.

```powershell
npm.cmd install
powershell -ExecutionPolicy Bypass -File scripts/start-online.ps1
```

Enter the printed HTTPS address in the phone app. The launcher runs the backend and a Cloudflare tunnel; keep it running while using KAZE. The temporary address changes on restart.

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

Wearer recording runs on Android. The iPhone guardian build still needs device verification. Keep the guardian app open; background push and emergency dispatch are not implemented. Camera guidance is an experimental compass preview.
