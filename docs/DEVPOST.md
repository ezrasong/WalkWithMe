# WalkWithMe

Public project: [WalkWithMe on Devpost](https://devpost.com/software/kaze).

## Inspiration
An SOS button assumes someone can recognize danger and use their phone. WalkWithMe explores a different trigger: a check-in that never comes. The goal is to give a trusted person useful recorded evidence when the wearer cannot respond, while making consent and uncertainty visible.

## What it does
WalkWithMe is a phone and Wear OS app for timed safety sessions. The wearer starts a session, chooses check-in timing, and pairs a trusted guardian through a short-lived, single-use code or QR. Check-ins can come from the phone or watch and require server confirmation. After the deadline and grace period pass without a confirmed response, the guardian can view the recorded trail, acknowledge the request and report arrival. Evidence stays private before nonresponse unless the wearer separately enables live sharing. Sessions have an eight-hour lifetime, with revocation, ending and deletion controls.

The guardian sees geographic observations with source, age and reported accuracy. With explicit retention consent, Android pocket-motion batches also form a separate continuous relative research diagram. Recording can start anywhere with the phone freely pocketed, without advance mapping or a manual calibration walk. Room, floor, geographic origin and north remain unknown. Missing data and recorder restarts start separate sections with unknown origins. Watch steps provide time-matched activity checks, not a second displacement path or body heading.

Camera + motion diagram (no indoor AR) shows a local camera beside that relative diagram. It does not place the trail on the floor or navigate between rooms. Experimental outdoor spatial AR uses ARKit/RealityKit or ARCore with accurate locations and a 30–100 m registration walk. Android also offers optional Google Geospatial alignment after explicit disclosure and project authorization. A separate GPS/compass camera direction preview is approximate. Unknown altitude uses a labelled floating horizontal guide, not detected ground.

For filming, a simulated wearer follows one server-generated route shared by the map and camera. Start 40-second alert take restarts the virtual walk at 1x, requests a check-in at 30 seconds and pauses movement when the alert begins at 40 seconds. Only the owner can reset simulated response state for another take; real alerts cannot be reset this way. The paired guardian can open the shared walk camera before an alert using approximate outdoor GPS/compass placement. An actor's movement does not drive this simulation.

Presentation mode is an explicit setting that defaults off. Enable it to use Camera walk preview for camera practice with a virtual walker, without a wearer phone, GPS or a missed check-in. Turning it off closes demo cameras, hides all demo controls and simulated session data, and stops simulated guardian notifications on that phone. The server session and deadlines are preserved; live sessions and their notifications remain available.

Android guardians can opt into background server polling with a persistent notification. Network failure is reported separately from confirmed nonresponse. On a free Apple Account build, iPhone local reminders ask the guardian to reopen WalkWithMe to verify status; they cannot confirm a missed check-in while closed and may become stale. Optional Apple remote push is implemented but disabled in the free setup, and requires paid-team signing and server credentials.

## How we built it
Flutter and Dart provide the phone interface, with native Android recording and a Java Wear OS companion. The watch relays through the paired phone using the Wear OS Data Layer. A Node.js service stores sessions and events in SQLite and owns deadlines, authorization and sharing rules. Maps use MapLibre on mobile and Leaflet in the browser. The prototype uses HTTPS connectivity through a Cloudflare tunnel; the backend computer and network must remain available.

Phone acceleration, gyroscope and game-rotation observations are requested at 200 Hz. Bounded gzip batches go over Wi-Fi or cellular about every ten seconds to a cached Python/PyTorch RoNIN ResNet research checkpoint on the backend. Overlapping windows supply context without integrating the same timestamps twice. A still-phone heuristic suppresses apparent movement; it does not prove wearer stillness. Offline or failed batches are skipped without a raw-data backlog. Motion never changes check-in deadlines or becomes geographic evidence.

Automatic streaming saves no raw capture. Explicit retention consent permits at most 4096 derived points across 128 sections, shared under existing session access rules. Separately consented owner-only diagnostics retain the latest 120 batch summaries: sampling, gaps, model timing, stationary decisions and watch checks, excluding raw samples, coordinates and credentials. Withdrawal, expiry and deletion clear the relevant retained records. Owners can copy diagnostics before ending a test. These logs support manual analysis; they do not automatically train or tune the model. Optional private raw captures are separately limited to three minutes.

## Challenges
The hard parts are keeping phone, watch and server state consistent through disconnections, preserving deadlines across restarts, avoiding duplicate movement, and enforcing consent during asynchronous processing. Notification delivery is different from human acknowledgment, and an uncertain estimate must not look like a verified position.

Pocket-only indoor alignment has a missing-reference problem. A covered camera observes no room landmarks. Inertial motion can estimate relative movement but cannot identify an arbitrary starting room or match its path to another phone's camera. Simply walking around does not create a visual indoor map in this build. More model execution does not supply that missing observation.

## Accomplishments and validation
The prototype implements the session-to-guardian workflow, native Android phone/watch recording, access controls, Android background monitoring, continuous consented relative motion, tuning diagnostics and repeatable simulated alert takes. The latest implementation passed 76 backend tests, 109 Flutter tests and 11 Python motion tests, plus Flutter analysis and an Android build. The Python checks include actual checkpoint execution on synthetic input; automated checks do not prove field accuracy.

Vivo development checks verified approximately 200 Hz collection, compressed transport and backend execution. A stationary continuous run produced one section across three uploads with no raw capture saved. Android wearer testing has used a Vivo X300 Ultra and Galaxy Watch4. Existing iPhone guardian flows have simulator coverage. Signed iPhone builds, physical notification delivery, successful Google Geospatial localization and simultaneous device operation still require verification. No independently measured pocket-walking accuracy improvement has been established.

## What we learned
Reliable behavior depends on explicit state and honest uncertainty. A button press is not a successful check-in until accepted by the server. Multiple sensors can observe the same movement. Missing location, height and camera alignment must remain unknown rather than being filled with plausible geometry.

## Current limitations and next steps
WalkWithMe is a prototype, not an emergency service or medical detector. It does not detect drink spiking or diagnose unconsciousness. Calls, SMS, backup-contact escalation and emergency dispatch are not connected. Wearer recording currently runs on Android. Indoor floor-anchored navigation, room/floor recognition and universal pocket-only localization are not implemented. Outdoor camera guidance has no verified ground or obstacle detection and still needs physical accuracy testing. Simulated trails demonstrate presentation and session behavior, not real tracking accuracy.

Free Apple provisioning generally expires after seven days and does not enable Apple remote push or TestFlight/App Store distribution. Rebuild and install on a Mac after pulling updates; a signed release build can launch from the app icon, while debug builds require Flutter/Xcode tooling. Android background polling needs connectivity, notification permission and background battery access, and can be interrupted by force-stop, reboot or OS restrictions. Reopen WalkWithMe and enable monitoring after force-stop or reboot.

RoNIN is an external research checkpoint, not a newly trained WalkWithMe model. Its source is GPL-3.0 and its weights have separate non-commercial research/education/artistic-use terms; commercial deployment rights are not established by this prototype. Motion uploads can consume cellular data. Next steps are measured pocket-walking comparisons, analysis of consented diagnostics, physical iPhone and guardian notification checks, outdoor registration validation and a stable HTTPS deployment. Measured waypoints are evaluation references, not required wearer calibration.
