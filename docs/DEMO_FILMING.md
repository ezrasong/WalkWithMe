# WalkWithMe outdoor filming and house tests

This scenario uses a virtual wearer and generated positions. An actor can walk the same route for the video; the actor's sensors do not drive this mode. The PC serves the same simulated trail to the map and guardian camera. Describe the generated trail as simulated in the video. No emergency service is contacted.

## Update the iPhone guardian

On the Mac, from the existing repository checkout on `main`:

```sh
git pull --ff-only origin main
cd mobile
flutter pub get
open ios/Runner.xcworkspace
flutter devices
flutter run --release -d YOUR_IPHONE_DEVICE_ID
```

Replace `YOUR_IPHONE_DEVICE_ID` with the connected iPhone ID from `flutter devices`. Configure Runner's automatic signing and your Apple Account's Personal Team in Xcode before the first install, then rerun the release command. Keep `KAZE_PUSH_ENABLED=NO`. A free Apple Account is sufficient for local testing, with a limited provisioning lifetime. Release mode allows launching from the app icon. Debug mode requires launching through Flutter/Xcode with the development tooling attached. `--no-codesign` works with `flutter build ios`, not `flutter run`, and cannot install an unsigned app on the phone.

The default backend address is compiled from `mobile/lib/backend.dart`; both phones must use the same reachable service. If necessary add `--dart-define=KAZE_BASE_URL=https://your-service.example` to the release command. For the preset route on a new iPhone build, supply the private build-defines file with `--dart-define-from-file=/path/to/private-build.json`; it is not included in a repository pull. Without the preset, **Start shared walk** generates a nearby route from a fresh outdoor location. Keep the private file and its coordinates out of source control. The PC and HTTPS tunnel must remain running. Pulling the repository alone does not update an already installed iPhone app. Windows cannot perform or verify the signed iPhone build.

## Enable or disable Presentation mode

On the welcome screen, tap **Settings**, enable **Presentation mode**, then tap **Done**. During a session, the same switch is under **Settings → Presentation → Presentation mode**. It defaults off on a new installation; an explicitly saved choice is remembered.

Turning it off hides all presentation launch/playback controls, closes an open preview camera, hides the simulated session's map, activity, pairing and session tools, and stops that phone's simulated guardian notifications. The generic Settings entry remains available to enable it again. The server session, pairing and deadlines are not changed; re-enabling reveals the same session if it is still available. **Return to setup** on the hidden-session screen removes only this phone's saved access. Live sessions and their guardian notifications remain available with presentation mode off. Limitation notices remain visible.

On-screen controls use **Presentation mode**, **Camera walk preview** and **Start shared walk**, without the word "demo". Generated trails remain labelled simulated; approximation and indoor-tracking notices remain visible. Older generated sessions display **Virtual wearer**.

To film a shared simulated walk, keep presentation mode enabled on both phones. Turning it off also hides the generated trail, rather than presenting generated positions as live tracking.

## Practice on the guardian phone alone

Enable presentation mode, then choose **Camera walk preview** from the welcome screen or **Settings → Device setup** during a guardian session. Allow camera access, point toward a well-lit open space and press **Start walk**. Pause/resume, restart and 1x/2x speed controls operate a virtual walker. This needs no wearer phone, missed check-in, backend route, GPS or outdoor registration walk. It does not change your existing guardian session. On devices without native AR, the camera animation does not track real phone movement or locate a person. Return from the camera and disable presentation mode in Settings to hide it.

## Prepare one take

1. Enable presentation mode on both phones. For a Vivo guardian take, use the iPhone as the simulated-session owner and the Vivo as guardian; the roles can also be reversed. With no active session, choose **Start shared walk** on the owner phone. The local private build preset chooses the route; no address or private coordinates belong in source control.
2. Pause the initial walk under **Settings → Shared walk** while preparing. In Settings show the guardian QR/code; join on the guardian phone (the Vivo for this take). The guardian can select **Open shared walk camera** on the map before an alert; this opens approximate outdoor GPS/compass placement without the spatial AR registration walk. Keep WalkWithMe open for live alert status. This demo enables live sharing, so setup evidence is visible before the missed check-in.
3. Check the map and intended walking area in person. The preset is a presentation route; it does not establish a passable sidewalk, crossing, entrance or destination. Use a short visible section with the actor and guardian on foot.
4. For the recorded take, the owner presses **Start 40-second alert take**. The virtual wearer restarts from the route's beginning at 1x. The actor can start walking along that route at approximately 1.2 m/s.
5. At 30 seconds WalkWithMe requests a check-in. Leave it unanswered. At 40 seconds the server enters the alert phase and automatically pauses virtual movement, normally 48 m along the route (or at its end if shorter). The final point stays current while paused. The guardian opens the camera and approaches that recorded simulated position. Acknowledgment is optional and does not end the scenario.
6. To film another take, return from the camera and press **Start 40-second alert take** again. This explicitly clears the previous simulated acknowledgment/arrival state and restarts the virtual route and countdown. It keeps pairing and the session expiry. Existing camera registration must be reopened because the recorded frame changes. An expired or ended simulated walk requires a new session.

Normal **Pause walk**, **Resume walk**, speed and **Restart walk** controls change movement only; they do not reset a deadline. The filming control is the explicit exception, restricted to active simulated walking sessions with confirmation. Real wearer alerts cannot be re-armed through it.

## Camera behavior on iPhone

**Outdoor spatial AR (experimental)** uses local ARKit tracking and currently requires precise outdoor locations plus a 30–100 m walking baseline and later validation. Successful signed iPhone compilation, physical registration and field accuracy remain unverified from the Windows development machine. It is not instant universal camera localization.

**Outdoor direction preview (approximate)**, available in the alerted guardian's session details when a recorded point exists, uses GPS and compass. It opens without the spatial registration walk, and labels its approximate placement. It shows a direction cue and map; it does not guarantee a ground-anchored trail. Camera permission, precise location and compass observations are still required.

The standalone **Camera walk preview** is a separate presentation mode. It does not demonstrate the shared missed check-in flow. Explain simulation and approximation in the video. iPhone remote push is not configured for the free-only setup; an open app receives current server status. Use iOS Screen Recording or a separate camera for the video; WalkWithMe does not record the camera footage itself.

## Test real pocket motion inside the house

This tests sensor transport and a relative movement estimate. It cannot validate indoor floor alignment, room recognition or navigation. No advance mapping or calibration is required; an optional measured route is only a reference for evaluating accuracy. Diagnostics support manual analysis and do not automatically fine-tune the model.

1. On the Vivo, end the simulated session under **Settings → End session and stop sharing**, then **Return to setup**. On the iPhone remove the old guardian access before joining the new session.
2. On the Vivo start a normal wearer session with **2 minutes** between check-ins and **30 seconds** to respond. Accept the motion/retention consent. For immediate viewing during this test, explicitly enable **Also share my location throughout this session**. No doorway or calibration walk is required. Open WalkWithMe on the paired watch if using it; the updated watch companion is needed for timed native step provenance.
3. Pair the iPhone with the new guardian QR/code. Keep both phones connected to the PC's running service and keep WalkWithMe open on the iPhone.
4. On the Vivo open **Settings → Motion trail evaluation**. Confirm **Retain and share relative research trail** is on and the upload status eventually says the backend processed a batch. The first result normally follows about ten seconds of supported sensor sampling. No extra manual capture is needed.
5. Put the Vivo freely in a pocket. Walk a short indoor loop, turn, pause, and return. The iPhone's session details show the relative diagram when the sharing rules permit it. It is an uncalibrated movement estimate with unknown north, room and floor, not a floor plan. Watch evidence may remain unavailable if the companion is old, not collecting or poorly synchronized.
6. To test nonresponse, stop checking in. After two minutes plus the thirty-second grace, open the alerted guardian's session details and select **Camera + motion diagram (no indoor AR)**. The local camera and relative diagram remain visibly separate; this does not place a trail on the floor or guide between rooms. GPS/compass direction preview and geographic spatial AR are outdoor modes, not a substitute for indoor localization.
7. Before ending, open **Settings → Motion trail evaluation**, confirm **Keep owner-only motion diagnostics** is on, then press **Copy motion diagnostics**. Paste the JSON with notes about when you walked, turned, paused or moved the phone in its pocket. Logs help diagnose behavior; they do not measure accuracy by themselves.
8. End the test from the Vivo when finished. This stops recording/sharing; no emergency service is contacted.
