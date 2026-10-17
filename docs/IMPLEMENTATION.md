# KAZE implementation and evidence boundaries

The phone app is Flutter for Android and iOS. The designated wearer is the Vivo Android phone, optionally with the Galaxy Watch4. A second iPhone or Android phone runs the same Flutter app as guardian. Wearer background recording on iOS is not implemented or claimed.

## Ownership and invariants

- `src/domain.js` owns source validation and the armed -> challenge -> alert state machine. Explicit check-in before escalation sets a new deadline; sensors never count as a response. After escalation, the owner must explicitly end the session.
- `src/store.js` owns SQLite persistence, atomic uploads, activity and idempotent retries. Existing session/event tables are preserved; the activity table is added without replacing data.
- `src/locations.js` retains timestamped geographic observations and separate source paths. It never averages phone/watch fixes or fills gaps from steps. Low accuracy, stale fixes, time overlap, large jumps and mock readings are separated/labelled.
- `src/server.js` owns authorization, disclosure, retention and independent deadlines. Default guardian disclosure begins after nonresponse. Session-long sharing requires a distinct opt-in. Ending stops sharing; guardian revocation invalidates its credential; deletion revokes every role; expiry clears evidence and activity. Acknowledgment and reported arrival do not resolve incidents.
- `mobile/lib/` owns the shared Flutter phone screens, scoped API client, secure token persistence and experimental guardian camera direction preview. No WebView is used. Redirects are disabled for authenticated requests. Guardian evidence is hidden when the server cannot confirm access or the app backgrounds. Earlier in-flight reads cannot overwrite later accepted state changes.
- `android/phone/src` is the Java Flutter host and native bridge, included by `mobile/android/app`. It starts the existing recorder only after voluntary session creation, permission choices and server verification.
- `android/shared` owns continuous location/sensor capture, durable SQLite outbox, clock synchronization, reminders and scoped watch relay. `android/watch` owns the Wear OS UI and service. Opening KAZE joins the phone's consented active session without a separate Start tap.
- `public/` remains a browser test/admin surface with a separately labelled synthetic demonstration. It is not embedded in the phone apps.

## Location, offline behavior and privacy

LocationManager requests GPS, network and available fused providers during the active foreground service. Collection can continue with the screen off, subject to permissions, OEM power management and actual device testing. Missing permissions/providers leave check-ins and the independent server deadline running. A reported watch fused/network fix is labelled possibly phone-derived; direct GPS provider fixes are labelled device GNSS. These labels describe reported provider provenance, not measured truth.

At the check-in deadline the watch requests a notification vibration waveform without sound, subject to notification and Do Not Disturb settings. The vibration-only channel migrates the old channel while preserving blocked importance and disabled vibration. A watch that is actively contacting the current phone session and reports enabled KAZE reminders is preferred over a second phone alert. If there is no active watch, or its contact becomes stale, the phone alerts instead (within 20 seconds of the last qualifying watch contact). Presence is process-local so a phone restart defaults to phone reminders until fresh watch contact arrives. Pairing alone, another session, or disabled watch notifications cannot indefinitely suppress the phone. Neither reminder delivery nor sensor uploads count as a check-in.

Fix time is derived from Android monotonic fix age plus synchronized server time. Cached fixes older than the session are skipped. Coordinates, accuracy, provider, provenance, mock status and available altitude/vertical accuracy are retained. Altitude/pressure are not floor, room or staircase identification. A stale marker is the last reported device position; the app cannot establish the person still carries that device.

Uploads use persistent UUIDs and per-source sequences. Unacknowledged batches remain local for retry. A running recorder checks authoritative session state before flushing evidence, so rejected legacy camera uploads cannot prevent shutdown. End/expiry/revocation/deletion confirmation stops capture and removes queued readings. SQLite is app-private; secure deletion/forensic resistance is not claimed. App backup/transfer is excluded. Phone Flutter credentials use platform secure storage; the native service retains its scoped configuration in app-private storage.

The server must already know the session and remain running to escalate while devices are disconnected. Restart recovers overdue deadlines with delayed delivery. The guardian app/page must remain open; no background push, SMS, phone call or emergency dispatch is configured. Offline queued evidence has not reached the guardian.

The native MapLibre SDK renders OpenFreeMap vector tiles using OpenStreetMap data. OpenFreeMap receives the viewed area and IP, as disclosed in setup/settings. The map uses Positron and Dark styles, keeps separate phone/watch vector paths and real gaps, and draws the reported accuracy radius geodesically. Turning Street map off uses an empty local style, with no external map sources. The PC still hosts the backend, SQLite and any future inference. No public tunnel is assumed running. Only debug private/local HTTP is supported; release connections require HTTPS.

Legacy `src/trail.js` relative step/camera reconstruction and its tests remain for existing stored sessions/queued evidence. The revised phone app does not collect wearer camera images or use that relative path as geographic location. No direction or destination entry is needed.

## Guardian camera and AI

The Flutter guardian camera preview is experimental, local and optional. It displays an approximate outdoor compass cue to a recorded point only when wearer and guardian location freshness/accuracy and current heading permit it. Permission denial, app backgrounding, camera failure or loss of authorization close/fall back without affecting recording or escalation.

This is not shared ARKit/ARCore spatial registration and does not draw an anchored stair-following route. Precise AR breadcrumbs, room/floor alignment and measured camera guidance remain unimplemented/unvalidated. No camera frames are saved/uploaded. A second phone is needed for the simultaneous pocket/guardian demo.

No custom learned motion estimator is integrated. RoNIN evaluation remains gated on core device verification, raw synchronized sensor capture, license/model-term review and held-out measured routes. Existing step/pressure events do not meet that input contract. No model can gate alerts or fabricate missing coordinates. Omit runtime AI claims until a measured improvement exists.

## Verification ledger

Automated server/browser checks cover role boundaries, default/live disclosure, revocation, idempotency, independent deadlines, restart recovery, retention, geographic source/time handling, no-location fallback and consumer flows. Shared Android tests cover queues, source-scoped pairing, monotonic location evidence and shutdown despite rejected uploads. Flutter tests cover private access parsing, no-location rendering, revocation/offline clearing, rejected check-ins and concurrent stale-response handling.

See `artifacts/` for local build/test outputs and `docs/FLUTTER_MOBILE.md` for build commands. Artifacts/data/local.properties are excluded from Git. Test counts and hardware observations must be reported from completed runs, not this target checklist.

Required physical checks still include: Vivo pocket/screen-off duration and battery behavior; measured route/turn error and GPS gaps; Watch4 connectivity/direct versus relayed upload and haptics; offline retry; iPhone signed build/permissions; two-phone guardian disclosure/revocation; camera permission/heading failure and measured outdoor alignment; Wi-Fi and mobile-data access through an explicitly configured HTTPS origin.

A compiled APK, mocked browser route or widget test is not evidence of physical route accuracy, screen-off reliability or assistance arriving.

### Initial physical observation — October 17, 2026

The connected Vivo identified itself as V2547A running Android 16 / API 36. The Flutter device integration test passed: create an explicitly consented device session, use the native recorder, receive actual uploads, accept a check-in, show Activity, and end the session. The PC database for that test contains two phone heartbeats and nine non-mock geographic fixes reported by network/GPS providers. No synthetic location events were sent. This verifies the phone/service/PC path; it does not measure route error or prove that a provider's reported accuracy matches real error.

The initial evidence is `artifacts/vivo-flutter-integration.txt` and `artifacts/vivo-evidence.json` (no tokens or coordinates in the summary). Its historical baseline was six Flutter tests, 30 Node tests, three browser flows and 10 shared Android tests. Later verification supersedes those counts and several initial hardware gaps; use [the verification ledger](VERIFICATION.md) for current results.

The production Flutter debug APK was rebuilt and restored on the Vivo after the integration run. Phone Android lint completed successfully, with zero errors (existing dependency/resource warnings remain). Local Flutter-generated Windows SDK paths needed standard Java-properties drive-colon escaping before a fresh lint analysis; the local.properties file is not included in the source bundle. No iOS build result is claimed.

Automatic Watch4 setup is now implemented: start on the Vivo, open KAZE on the paired watch, and tap Check in without a separate watch activation step. The real watch discovered the matching session and uploaded pressure/heartbeat through the paired phone. Detailed current results and remaining gates are in [the verification ledger](VERIFICATION.md).

Subsequent bounded physical checks verified vibration-only watch/phone reminders, a 610-second screen-off interval, both-device offline queue recovery without duplicate stored identities, and end propagation through the paired-phone relay. First-launch setup and actual Vivo upgrades retained granted permissions, background exemption and setup dismissal. Denied-location background shutdown failed under Vivo smart control and passed a bounded retest after background access was enabled. These observations do not establish measured walking accuracy, unrestricted battery endurance, an iPhone build, two-phone HTTPS/mobile-data operation or camera alignment.
