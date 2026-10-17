# KAZE — revised build goal

This records the user's updated product direction. Implementation has been authorized. It replaces the earlier concept of using the wearer's camera to record a rescue route. It is a target specification, not a claim that every item already exists.

## Objective

Build a simple Android and Galaxy Watch safety app inspired by Life360's familiar map and check-in experience. During an explicitly armed safety session, record the person's past journey using existing phone/watch location services and useful motion/pressure readings. Offer quick check-ins and automatically open an assistance request to authorized guardians after an unanswered response window. Let a guardian view the recorded trail on a map and optionally use their own phone camera for an AR view of that evidence. Host the backend, database and any evaluated AI inference on Ezra's PC, reachable from the apps over HTTPS.

The wearer does not need to enter a destination, film their surroundings, or press SOS at the critical moment. Setup and arming happen voluntarily beforehand. No camera footage from the wearer is required or collected for tracking. The guardian's optional AR camera view serves a different purpose: aligning their display to their surroundings.

## Product behavior

1. Start an opt-in, time-limited safety session and select a check-in interval and response window. Use authorized, session-scoped guardian links for the initial prototype rather than building a full account/social network first.
2. Make the default screen a real geographic map with the available person/device location, its age, reported accuracy, and recorded trail. Location fixes establish the geographic starting point; normal use must not require manually entering a compass direction or destination.
3. Use phone and watch location services first. Keep source and fix timestamps. A watch's fused location may come from its paired phone; do not treat it as an independent second GPS observation or blindly average the coordinates.
4. Use motion sensors for approximate movement context or a tested short-gap estimator. Use pressure as relative height evidence. Neither provides a room number, staircase, absolute floor or diagnosis by itself. Label gaps, disagreement, stale readings, uncertain height and approximate segments.
5. Provide a clear Check in button on the phone and watch, haptic reminders, response confirmation and an activity history. Sensor activity is never a check-in. Distinguish a locally attempted response from one the server accepted.
6. Default guardian disclosure to after nonresponse. If session-long live sharing is offered, require a distinct explicit choice and make it visible while active. Ending or deleting a session stops sharing. Do not turn a Life360-like interface into permanent hidden tracking.
7. After nonresponse, give guardians the last available location, the recorded trail, source freshness, available height context and simple acknowledgment controls. Acknowledgment and reported arrival are different from independently verified assistance.
8. Keep the server deadline independent of all GPS, motion, camera, AR and AI processing. It can progress after device disconnection only if the session was already registered with a running server. Offline devices buffer readings for retry and display that those readings have not reached the guardian yet.
9. Use Google Maps directions to a last reported geographic point where useful. This is different from replaying a person's historical journey and does not supply a route through an unknown building.

## Guardian AR

- The guardian can open an optional camera-based AR view. The wearer can keep their phone in a pocket.
- The guardian view should show recorded breadcrumbs, last-known direction and height cues only at the precision supported by the data and the current alignment.
- Establish a shared geographic/spatial reference between the recorded trail and the guardian's AR session. A local AR coordinate origin alone does not identify a real building location.
- Start with outdoor trails or one explicitly calibrated indoor demonstration. Exact room/stair alignment requires mapped geometry/shared references and measured accuracy; do not manufacture it from GPS or a pressure change.
- If registration, heading or elevation quality is inadequate, fall back to the normal map or an approximate directional/height display. Do not show a precise floor-following line through unknown walls or stairs.
- Keep AR optional. Permission denial, unsupported hardware, lost tracking or closing the camera cannot interrupt recording, check-ins or escalation.
- KAZE does not need to store guardian camera photos/video for a local AR preview. If a cloud visual-positioning service is selected, disclose its processing and obtain the necessary consent; do not claim all processing remains on the PC or on-device in that configuration.
- Confirm a second AR-capable phone for the guardian demonstration. One phone cannot simultaneously remain in the wearer's pocket and act as the guardian's handheld camera.

## AI: a measurable experiment, not invented coordinates

The current prototype has no custom learned motion model. Do not describe existing deterministic step counting or the AR overlay as a new trained KAZE model.

The proposed AI task is short-window inertial motion estimation when location quality degrades. Evaluate an existing pretrained research model such as RoNIN rather than training a large model during the weekend. First verify its license, required input sensors, units, orientation conventions, sampling rate and deployment requirements. The existing step/pressure event stream is not automatically sufficient input for that model.

Collect consenting, time-aligned motion recordings and compare the model with the existing step-and-heading baseline on held-out measured routes. Include turns, phone handling, short GPS gaps, stairs and nonwalking motion. Report endpoint error, wrong-turn behavior, drift over gap duration and inference latency. Keep the learned estimator only if it improves those measured outcomes without introducing unacceptable failure cases. Run inference on the PC initially, with a working deterministic bypass when the PC/model/network is unavailable.

An LLM must not invent missing route geometry, certify a floor or decide the wearer is safe. ARCore performs visual-inertial tracking for the guardian display; that does not make the wearer's GPS history more accurate. AI is not allowed to gate alerts. If the model is not integrated and evaluated, omit that AI claim from the submission.

Research foundation: https://github.com/Sachini/ronin (code and pretrained-model links; GPL-3.0 code license, model/data terms must also be checked).

## PC backend and connectivity

- Run the application server and persistent database on Ezra's PC. Keep credentials and model/API secrets out of the mobile client.
- Use one configurable HTTPS base URL for the phone, watch and guardian UI. The watch may use direct networking or relay through its paired phone, subject to real connectivity.
- For the hackathon, use an HTTPS reverse proxy or Cloudflare Tunnel to the local server. A temporary Quick Tunnel is suitable for testing; use a stable named tunnel/domain for stable installations.
- Keep per-session owner/guardian/watch authorization, validation, idempotent uploads, expiry and revocation. A public tunnel URL is not authentication.
- For local debug only, a shared Wi-Fi/hotspot and the PC's LAN address can be used. A phone's localhost address points to itself, not the PC.
- The PC, backend process, tunnel and internet must remain available for remote access. Do not promise notifications while the PC is asleep or the backend is stopped.
- See `docs/PC_BACKEND.md` for concrete connection instructions.

## Design direction

Use familiar consumer safety-app patterns. Life360 is a reference for usability, not branding or a claim of equivalent coverage/features.

- Main screen: a map, person marker, small location-accuracy circle, simple person/status card and one prominent Check in button.
- Person card: first name, last update, last accepted check-in and device connection state in plain language.
- Bottom navigation: Map, Activity, Settings. Put the initial authorized-contact link in the appropriate person/settings view; add a dedicated People tab only when a real multi-person feature exists.
- Activity: meaningful check-ins, assistance requests and acknowledgments with times.
- Settings: appearance (remember System/Light/Dark), sharing consent, chosen guardian access, interval, grouped end/delete controls and connection setup.
- Follow Apple Human Interface Guidelines for hierarchy, scalable text, safe areas, contrast, generous targets and platform conventions. Keep the map dominant, use matching light/dark basemaps, and move detailed readings into a dismissible sheet.
- The paired watch joins the phone’s consented session on open with no separate Start/enable action; request first-use OS permissions, then expose Check in. Prefer Wear Data Layer through the phone so watch Wi-Fi is optional.
- Find person: available after an assistance request, opening the map and optional AR mode.
- Use ordinary text, readable typography, familiar icons, generous touch targets and restrained colors. Use color and text together for status.
- Avoid chat bubbles, AI assistants, decorative gradients, glowing effects, marketing slogans, excessive metric cards, and raw sensor/AI terminology in normal user flows. Put diagnostic details in a developer view.
- AR uncertainty must be understandable, but the user should not have to learn sensor-fusion vocabulary to use the app.

## Implementation order and proof

1. Update the prototype to this direction without losing existing authorization, queue, deadline and privacy behavior.
2. Implement and test continuous, permission-aware phone/watch location collection, source-aware geographic trail display and ordinary check-ins. Preserve the no-location fallback.
3. Connect the actual Vivo and Watch4, test the PC URL over Wi-Fi and mobile data, and verify screen-off behavior. Do not substitute successful compilation for device evidence.
4. Simplify the phone and guardian interfaces around the map and check-in flow.
5. Add guardian-side AR, starting with a measured outdoor route or explicitly calibrated demonstration. Test failed alignment, poor lighting, denied camera permission and height uncertainty.
6. Run the bounded AI experiment and integrate only an improvement supported by measured results. Otherwise ship the tested baseline and state that runtime AI was not included.
7. Rehearse a simulation-only demonstration: arm -> record -> miss response -> guardian receives available evidence -> guardian follows map/optional AR -> acknowledge -> end/revoke sharing.

Completion requires the current code, build outputs, tests and real-device results to support every claimed feature. Separate implemented, simulated, experimental and unavailable behavior throughout the app, documentation and pitch. No actual emergency dispatch is configured or used in demonstrations.

## Phone platform update (October 17, 2026)

The user selected Flutter for a shared installed Android/iOS phone app, replacing the interim WebView approach. Use the Vivo as wearer and an iPhone or other second phone as guardian. Keep the existing native Android recorder and Wear OS app behind the Flutter UI. iPhone guardian source/build instructions are required; signed iOS build/device evidence must come from the user's available Mac/Xcode, not Windows. The revised safety/privacy/deadline and hardware-proof requirements above still apply. See docs/FLUTTER_MOBILE.md.
