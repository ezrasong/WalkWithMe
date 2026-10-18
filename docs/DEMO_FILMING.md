# KAZE outdoor filming demo

This scenario uses a labelled virtual wearer and generated positions. An actor can walk the same route for the video; the actor's sensors do not drive this mode. The PC serves the same simulated trail to the map and guardian camera. No emergency service is contacted.

## Update the iPhone guardian

On the Mac, from the existing repository checkout on `main`:

```sh
git pull --ff-only origin main
cd mobile
flutter pub get
flutter build ios --debug --no-codesign
open ios/Runner.xcworkspace
```

In Xcode select Runner, the connected iPhone and your Apple Account's Personal Team under Signing & Capabilities, then Run. Keep `KAZE_PUSH_ENABLED=NO`. A free Apple Account is sufficient for this development install. The default backend address is compiled from `mobile/lib/backend.dart`; both phones must use the same reachable service. The PC and HTTPS tunnel must remain running. Pulling the repository alone does not update an already installed iPhone app. Windows cannot perform the signed iPhone build.

## Hide presentation controls

On each phone open **Settings → Presentation → Show demo tools** and turn it off. This hides demo launch/playback shortcuts from the welcome screen, map and session details and remembers the preference on that phone. Filming controls remain in **Settings → Shared walking demo**, so the owner can start another take. Generated positions still display DEMO labels. On the welcome screen, **Show demo tools** reveals the launcher again.

## Prepare one take

1. Use the Android phone as demo owner and the iPhone as guardian. With no active wearer recording, choose **Start shared walking demo** on the Android phone. The local private build preset chooses the route; no address or private coordinates belong in source control.
2. Open **Demo walk controls & camera** and pause the initial walk while preparing. In Settings show the guardian QR/code; join on the iPhone. Keep KAZE open on the guardian for live alert status. This demo enables live sharing, so setup evidence is visible before the missed check-in.
3. Check the map and intended walking area in person. The preset is a presentation route; it does not establish a passable sidewalk, crossing, entrance or destination. Use a short visible section with the actor and guardian on foot.
4. For the recorded take, the owner presses **Start 40-second alert take**. The virtual wearer restarts from the route's beginning at 1x. The actor can start walking along that route at approximately 1.2 m/s.
5. At 30 seconds KAZE requests a check-in. Leave it unanswered. At 40 seconds the server enters the alert phase and automatically pauses virtual movement, normally 48 m along the route (or at its end if shorter). The final point stays current while paused. The guardian opens the camera and approaches that recorded demo position. Acknowledgment is optional and does not end the scenario.
6. To film another take, return from the camera and press **Start 40-second alert take** again. This explicitly clears the previous simulated acknowledgment/arrival state and restarts the virtual route and countdown. It keeps pairing and the session expiry. Existing camera registration must be reopened because the recorded frame changes. An expired or ended demo requires a new session.

Normal **Pause walk**, **Resume walk**, speed and **Restart walk** controls change movement only; they do not reset a deadline. The filming control is the explicit exception, restricted to active simulated walking sessions with confirmation. Real wearer alerts cannot be re-armed through it.

## Camera behavior on iPhone

**Guardian spatial AR** uses local ARKit tracking and currently requires precise outdoor locations plus a 30–100 m walking baseline and later validation. Successful signed iPhone compilation, physical registration and field accuracy remain unverified from the Windows development machine. It is not instant universal camera localization.

**Camera direction preview**, available in the alerted guardian's session details when a recorded point exists, uses GPS and compass. It opens without the spatial registration walk, and labels its approximate placement. It shows a direction cue and map; it does not guarantee a ground-anchored trail. Camera permission, precise location and compass observations are still required.

The standalone **Local camera animation** is a separate presentation mode. It does not demonstrate the shared missed check-in flow. Keep DEMO and approximation labels visible in the video. iPhone remote push is not configured for the free-only setup; an open app receives current server status. Use iOS Screen Recording or a separate camera for the video; KAZE does not record the camera footage itself.

## Test real pocket motion inside the house

1. On the Vivo, end the simulated session under **Settings → End session and stop sharing**, then **Return to setup**. On the iPhone remove the old guardian access before joining the new session.
2. On the Vivo start a normal wearer session with **2 minutes** between check-ins and **30 seconds** to respond. Accept the motion/retention consent. For immediate viewing during this test, explicitly enable **Also share my location throughout this session**. No doorway or calibration walk is required. Open KAZE on the paired watch if using it; the updated watch companion is needed for timed native step provenance.
3. Pair the iPhone with the new guardian QR/code. Keep both phones connected to the PC's running service and keep KAZE open on the iPhone.
4. On the Vivo open **Settings → Motion trail evaluation**. Confirm **Retain and share relative research trail** is on and the upload status eventually says the backend processed a batch. The first result normally follows about ten seconds of supported sensor sampling. No extra manual capture is needed.
5. Put the Vivo freely in a pocket. Walk a short indoor loop, turn, pause, and return. The iPhone's session details show the relative diagram when the sharing rules permit it. It is an uncalibrated movement estimate with unknown north, room and floor, not a floor plan. Watch evidence may remain unavailable if the companion is old, not collecting or poorly synchronized.
6. To test nonresponse, stop checking in. After two minutes plus the thirty-second grace, open the alerted guardian's session details and select **Pocket motion camera preview**. The local camera and relative diagram remain visibly separate; this does not place a trail on the floor or guide between rooms. GPS/compass direction preview and geographic spatial AR are outdoor modes, not a substitute for indoor localization.
7. Before ending, open **Settings → Motion trail evaluation**, confirm **Keep owner-only motion diagnostics** is on, then press **Copy motion diagnostics**. Paste the JSON with notes about when you walked, turned, paused or moved the phone in its pocket. Logs help diagnose behavior; they do not measure accuracy by themselves.
8. End the test from the Vivo when finished. This stops recording/sharing; no emergency service is contacted.
