# Guardian spatial AR

The backend prepares recorded geographic evidence for a local guardian renderer. Camera processing belongs only to the guardian device. The wearer phone/watch do not record or upload images. The PC performs coordinate geometry and preserves the accuracy limits of the original observations.

## API

`GET /api/sessions/:id/ar`, with the existing bearer credential, returns a version-1 geographic frame and separate source paths. It requires an active assistance request (`alert`) and guardian or owner access. Owner access is for inspecting their own evidence; it does not enable a wearer camera screen. Watch access is rejected. Before escalation and after resolution the endpoint returns 409; revoked/expired credentials return 401 and deleted sessions return 404. POST and other mutations are rejected. Reading AR evidence does not acknowledge, check in, resolve or extend a session.

The frame uses WGS84 and meters: `x` east, `y` up, `z` south, compatible with a right-handed camera world after an explicit registration. The earliest usable observed fix identifies the anchor. A late earlier fix can change `frame.anchor.id`: the client must clear its previous registration if that ID changes.

Paths retain phone/watch provenance and the existing time/disagreement gaps. Mock fixes and reported horizontal uncertainty above 25 m are excluded. Excluded observations break the line. The local frame is limited to 2 km from its anchor. The endpoint does not fill gaps, average correlated phone/watch locations or create coordinates from steps/pressure.

Height is `null` unless both anchor and observation report vertical accuracy within 10 m and come from the same source. Known height is only a relative altitude observation, with the sum of both reported vertical uncertainties. Horizontal uncertainty also includes the anchor's reported uncertainty. These sums are conservative allowances, not calibrated confidence intervals. No floor, wall, room or stair geometry is inferred.

New Android phone/watch altitude observations explicitly declare `altitudeDatum: WGS84-ellipsoid` (Android `Location.getAltitude`). The API preserves missing datum on legacy observations so queued retries remain idempotent. AR points declare a compatible datum only when both heights declare it. Relative legacy height alone cannot support camera placement.

## Local registration and rendering

Frames explicitly have `registrationRequired: true` and `cameraAligned: false`; every packet has `guidanceAllowed: false`. A current usable last fix yields `fallback: alignment-required`; absent, stale, poor or distant current evidence requires the map. An available historical path does not mean the wearer remains at its last point.

The Flutter guardian screen hosts native **ARKit with RealityKit** on iPhone, and **ARCore 1.57** on Android. Android AR is optional, so unsupported phones retain the map. No cloud/geospatial/image-recognition session, image extraction, recording or frame upload is configured. Guardian location and pose samples remain in memory on that phone. Wearer recording, queues, check-ins, escalation and haptics have no dependency on AR.

Registration pairs a fresh guardian geographic fix with the camera pose at the same instant (maximum 200 ms difference). It projects guardian fixes into the API's identical WGS84 tangent frame, fits a gravity-preserving horizontal rigid transform from an outdoor walking baseline, and freezes that transform for checks against later fixes. This derives yaw from measured movement, without compass heading. The endpoints must span at least 30 m and eight times their summed reported horizontal accuracy; guardian fixes must report 5 m accuracy or better. Three later checks, separated by at least two seconds and two meters of camera movement, must agree within 5 m and the registration allowances. They are withheld checks from the same location system, **not an independent reference or field accuracy proof**.

Vertical registration requires guardian ellipsoid altitude with reported vertical accuracy within 5 m and a compatible recorded anchor. The renderer omits unknown/incompatible heights. It never substitutes camera height, ground/terrain estimates, pressure-derived floors or stairs. New sessions recorded with the updated Android apps are needed when an old anchor lacks a datum.

Rendering is restricted to observations within 50 m with combined horizontal and vertical allowances no greater than 10 m. Cyan marks phone evidence; orange marks watch evidence, which may come from the paired phone. Horizontal rings and vertical bars depict uncertainty allowances; individual markers have no connecting route lines, including within a source. Geometry has no validated wall/obstacle occlusion and supplies no directions through buildings or stairs. A registration with no supported points returns to the map.

Allowances include recorded relative uncertainty, guardian endpoint uncertainty, endpoint length disagreement, angular uncertainty, worst later residual and an engineering drift allowance of 2% of cumulative camera travel. These are experimental thresholds, not calibrated confidence intervals or a guarantee of physical error. Registration expires after 120 seconds or 100 m of further camera travel; acquisition is bounded to 180 seconds/200 m. Any camera tracking loss after tracking starts, backgrounding, permission/access loss, changed frame anchor, stale/poor location or failed check closes AR and requires reopening and re-registration. Native render leases also expire after 2.5 seconds without Flutter updates. Startup without usable synchronized location times out after 15 seconds.

The backend cannot observe or validate a particular camera session, so its `cameraAligned: false`, `registrationRequired: true` and `guidanceAllowed: false` remain unchanged. A successful local consistency check enables only that device's experimental observation renderer. The separate camera compass preview is still unregistered.

## Verification

For device diagnostics, run the updated app from `mobile/` with `flutter run -d DEVICE_ID` on the connected phone's development machine (a Mac for iPhone). Preserve any `--dart-define=KAZE_BASE_URL=...` used for that build. Keep the terminal attached and reopen **Guardian spatial AR**. Lines prefixed `[KAZE AR]` report startup stages and the first closure reason. They omit session credentials, server addresses, geographic observations and camera images. The iPhone renderer forwards specific location, tracking, interruption and timeout failures to that same log; numeric native error codes are included without raw error descriptions. The closure reason also remains visible on the AR screen. These diagnostics require rebuilding and installing the updated app; older builds do not emit them.

`npm test` covers geographic geometry, provenance, datum validation/legacy retries, gaps and endpoint authorization/lifecycle. `cd mobile; flutter test` covers registration geometry, uncertainty rejection, privacy and screen lifecycle with simulated native channels. Android APK compilation/lint checks native API integration. These tests do **not** prove real camera alignment.

Remaining gates: signed Mac/Xcode build and permission testing on the iPhone 17 (reported iOS 26.6.2); simultaneous Vivo/watch/iPhone guardian operation; a consenting outdoor route with an independent surveyed/reference measurement, measured marker error and uncertainty coverage; physical tracking/registration/failure checks; stable HTTPS deployment before normal distribution. The current temporary tunnel is not a stable production host. Keep geographic/device artifacts ignored and never commit credentials or exact private coordinates.
