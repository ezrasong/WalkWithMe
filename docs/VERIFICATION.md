# KAZE verification ledger

Verification goal: `KAZE_VERIFY_GOAL.md`. Worktree: `C:\Users\ezras\.codex\worktrees\57e1\htv11`. Dates are October 17, 2026, America/Toronto. Reports omit bearer tokens, pairing codes and exact private coordinates.

| Check | Current evidence | Status |
| --- | --- | --- |
| Flutter Android/iOS shared UI | Flutter renders phone screens directly; no WebView | Implemented |
| Vivo phone/service/PC path | Real integration accepted a check-in, received two phone heartbeats and nine non-mock GPS/network fixes, and ended. `artifacts/vivo-flutter-integration.txt`, `artifacts/vivo-evidence.json` | Passed physical bounded test; route accuracy unmeasured |
| Automated checks | 14 Flutter tests and clean analyze; fresh 30 Node tests and three browser flows | Passed; artifacts/flutter-current-tests.txt, artifacts/flutter-current-analyze.txt, artifacts/node-current-verification.txt, artifacts/browser-current-verification.txt |
| Native vector map / appearance | Native MapLibre renders OpenFreeMap vector streets and labels; light and bundled high-contrast dark styles visually inspected on Vivo; map controls/details and appearance switching exercised | Passed Android device UI; iOS rendering pending |
| Watch4 installation/ADB | Actual SM-R870, Android 16/API36; watch debug APK installed/launched | Passed installation; not yet reliability proof |
| Automatic watch discovery | Watch requested active phone session on open; app-private inspection confirmed only watch access, no owner/guardian secrets; screenshot `artifacts/watch-auto-pair.png` | Passed physical discovery |
| Pairing / reminder regressions | 19 shared Android tests; active/starting session guard, allowlisted watch credentials, watch preference, stale/other-session fallback, blocked notification policy and quiet-setting migration | Passed; `artifacts/watch-reminder-channel-build.txt` |
| Watch build/shared and watch lint | Build and lint succeeded after discovery changes | Passed; `artifacts/watch-auto-pair-build.txt` |
| Phone/watch live relay | Combined real-device integration passed: automatic discovery and joining without an activation tap, server-confirmed watch check-in, phone end and watch resolved state through paired-phone relay | Passed bounded run; artifacts/vivo-watch-vector-flow5.txt; latest repeat interrupted by watch ADB loss |
| Current Android builds/lint | Final channel-based phone/watch APKs and lint passed; final watch APK installed, phone update awaiting unlocked installer | Build/lint passed; phone install pending; artifacts/flutter-reminder-channel-build.txt, artifacts/flutter-reminder-channel-lint.txt, artifacts/watch-reminder-channel-build.txt |
| Empty queues after end | After the interrupted managed run, both native recorders were resolved/inactive and both SQLite queues held zero readings for the ended session | Passed physical cleanup; artifacts/managed-run-cleanup-evidence.json |
| Watch/phone haptics | Watch-first routing suppressed the phone; Watch4 rejected direct notification-usage vibration. Final system-channel implementation built and tested, hardware repeat pending | Repair implemented; felt/audible delivery pending |
| At least ten minutes screen-off | Phone Asleep / watch Dozing through 314 s; watch Awake at 345 s, with motion wake-ups in system logs | Ten-minute gate pending; artifacts/device-long-run-motion-wake.json |
| Offline queue/recovery on actual devices | Actual socket outage with native offline status; 29 phone and 58 watch unreceived queue IDs delivered once after reconnection; independent server alert | Passed bounded physical outage; artifacts/device-long-run-motion-wake.json |
| Measured route accuracy | Nine real phone fixes do not establish route/turn error | Pending measured walk |
| iPhone signed build/guardian | Source and Mac/Xcode guide ready | Pending Mac/iPhone |
| Two-phone guardian + HTTPS Wi-Fi/mobile data | Local PC server + USB reverse verified; no public tunnel assumed running | Pending network/second phone |
| Guardian camera guidance | Approximate outdoor compass cue; no shared spatial registration or floor/stair path | Experimental; physical precision/alignment unverified |
| Camera fallback / access race | Five simulated platform tests cover unshared access, location denial, absent camera, camera permission failure and authorization loss during pending permission | Passed simulated tests; no physical iPhone camera claim |
| Learned motion AI | Not integrated; no accuracy claim | Not shipped |
| Emergency delivery | No push/SMS/calls/dispatch; guardian must keep app open | Explicit limitation |

## Failure / repair / retest history

- Initial combined watch test proved configuration arrival but failed its watch-upload assertion: the host UI harness tried reading preferences before first creation, then attempted UI automation while the watch display was asleep (`null root node`). This is not a passed recording test. Harness now retries missing preferences, wakes the watch, uses `/data/local/tmp`, and checks that watch and phone session IDs match before the explicit Start tap.
- Discovery now blocks Start until the current phone response arrives, and configuration cannot change while Start/server verification is in flight or recording is active. The old manual phone pairing button/path has been removed from the Flutter ordinary flow.
- The device integration now ends/deletes its local saved owner access during teardown even if a later hardware assertion fails, preventing a failed test from leaving its new session armed indefinitely.

## Repeatable checks

- Server: `npm.cmd test`; browser: `npm.cmd run test:browser`.
- Watch/shared: `android\gradlew.bat -p android :shared:testDebugUnitTest :watch:assembleDebug :shared:lintDebug :watch:lintDebug`.
- Flutter from `mobile`: `flutter.bat analyze`, `flutter.bat test`, `flutter.bat build apk --debug`.
- Physical combined test: `flutter.bat test integration_test/app_flow_test.dart -d PHONE_SERIAL --dart-define=KAZE_BASE_URL=http://127.0.0.1:4174 --dart-define=KAZE_VERIFY_WATCH=true`, with the disposable local backend, phone-only USB reverse, and the real watch opened after the log marker. The watch joins automatically; the host only taps Check in. Watch has no ADB reverse in the relay test. Rebuild/reinstall the normal phone APK after integration tests; the test target intercepts ordinary user taps.

Do not mark the overall goal complete while required physical/Mac/network evidence is missing. Continue independent software work while waiting for actionable hardware input.

### Earlier discovery flow (explicit Start, since replaced)

The real combined integration passed in 44 seconds after the host woke the watch immediately before its explicit Start tap. The server recorded three phone heartbeats, 19 non-mock phone GPS/network fixes, one watch heartbeat and one watch pressure reading, then the owner's end-session request. The watch had no ADB reverse during capture, and its localhost PC URL therefore used the paired-phone Wear Data Layer relay. Discovery payload inspection confirmed no owner/guardian credential was persisted on the watch.

The Flutter device-test runner removed the phone app immediately after ending. The watch then could not use that phone relay to learn the end, so its local capture remained armed/offline. For test cleanup, a temporary watch ADB reverse was added to let its authoritative poll see the resolved session and delete queued readings. Future combined tests now keep the relay alive for 20 seconds after end before runner cleanup. Normal end-through-relay shutdown is still a separate physical verification gate; the capture/discovery success does not by itself prove it.

The fresh Node run passed all 30 tests (`artifacts/node-verification.txt`); browser run passed all three (`artifacts/browser-verification.txt`); six Flutter tests passed (`artifacts/flutter-verification.txt`). No screen-off duration, felt vibration, measured route accuracy or iPhone build is inferred from these results.

The temporary cleanup connection was subsequently verified: the watch persisted phase `resolved`, active `false`, and "Session ended. Recording stopped; queued readings deleted." The watch ADB reverse was then removed. The production Flutter phone APK was rebuilt and reinstalled successfully; automatic discovery is the ordinary flow, with no manual phone pairing button.

Phone lint after the final automatic-pairing changes passed with zero errors and seven warnings (`artifacts/flutter-android-lint.txt`). A reproduced tooling issue was repaired in the app Gradle lint task: Flutter asset compilation can regenerate improperly escaped Windows SDK paths, so Java Properties serialization now normalizes the ignored local file immediately before lint reads it. Lint remains fully enabled. Final Flutter analyze reported no issues, and both current production debug apps are installed.

### Current UI, vector maps and automatic watch joining

The watch now joins the phone's consented active session on opening KAZE, with only first-use OS permission prompts. There is no separate Start/enable control. Its preferred transport is the paired-phone Wear Data Layer relay, including Bluetooth; phone backend connectivity is still required for confirmation. Phone and watch interfaces now provide clearer priorities, large controls and explicit pending/accepted check-in states. Phone System/Light/Dark appearance is remembered, with grouped settings and adaptive iOS navigation/dialogs.

The map now uses native MapLibre vector rendering instead of scaled raster tiles. Light uses OpenFreeMap Positron; the bundled Dark adaptation increases road/label/building contrast and includes upstream notices in the app license page. Blue solid phone and purple dashed watch paths remain separate and preserve recorded gaps. Screenshots with private geographic context remain ignored artifacts.

`artifacts/vivo-watch-vector-flow5.txt` exited successfully and verified automatic watch joining without activation, a server-accepted watch check-in, and authoritative end propagation to the watch through the phone. This preceded the final contrast-only dark asset revision. The companion then encountered Windows file locking during SQLite snapshot cleanup; both snapshot/server reads now explicitly close their connections. This repair is not recorded as proof of empty device queues.

The final contrast revision rendered successfully on Vivo, including light/dark/settings captures, before the latest combined repeat lost its watch ADB connection (`artifacts/vivo-watch-vector-final.txt`). The resulting failed repeat is a development-link interruption, not a passed final combined run. The normal `lib/main.dart` phone APK was subsequently rebuilt, installed and launched at setup; a physical input tap switched the role selector successfully. It is no longer the integration-test target.

Nine Flutter tests and clean analyze, the phone APK/lint, and watch/shared tests/build/lint passed. No signed iPhone build, long screen-off reliability, physical outage recovery, felt haptics or measured walking accuracy is inferred. Those gates remain open.

### Normal-app verification and reminder routing repairs

Fresh checks passed 30 Node tests, three browser flows and 14 Flutter tests with clean analyze. Five new simulated platform tests cover unauthorized preview access, location denial, absent camera, camera permission failure and authorization loss while permission is pending. The last test reproduced a race that could overwrite the access-loss message after an awaited permission result; the preview now rechecks access before requesting more permission or enumerating cameras. During real wearer recording, the Vivo package reported camera permission denied, consistent with camera-free wearer capture.

The host helper now supports `--normal-app`, keeping the ordinary tappable Flutter entrypoint installed. Two bounded trials received additional watch check-ins after reminders; the user confirmed tapping Check in. Those trials are not unattended reliability passes. Their redacted reports are `artifacts/device-long-run-interrupted-checkin.json` and `artifacts/device-long-run-user-checkin-retry.json`.

A later trial reached the independent server alert but did not prove offline delivery: removing USB forwarding left existing connections usable. The helper now requires actual native offline status and queue IDs absent from the server. Its optional `--managed-backend` owns a dedicated loopback-only fixture (`scripts/device-test-backend.mjs`) that destroys existing/new device sockets on private stdin commands while retaining the deadline timer and SQLite store. No network-accessible test-control endpoint was added. The inconclusive forwarding-only report is `artifacts/device-long-run-forwarding-inconclusive.json`.

Reminders now prefer a recently active current-session watch with enabled notifications, falling back to the phone when no qualifying watch contact arrives for 20 seconds. Another session or merely paired hardware cannot suppress phone reminders. Watch4 diagnostics rejected a direct notification-usage vibration with `ignored_app_ops`; the fix delegates the waveform and sound to a vibration-enabled system notification channel. Migration retains an older channel's blocked importance and muted sound. Nineteen shared tests and watch build/lint passed after this repair; real haptic delivery on the final channel still requires device verification. Felt vibration/audible sound remain human observations, not inferred from a build.

The managed physical run (`artifacts/normal-app-managed-long-run.txt`, redacted report `artifacts/device-long-run-motion-wake.json`) confirmed native offline status on both devices, 29 phone and 58 watch queued event IDs absent from the PC, independent escalation to alert, then delivery of every captured ID without duplicate event identities. Screen-off sampling showed phone Asleep/watch Dozing through 314 seconds; at 345 seconds the watch was Awake. Watch power logs show motion-triggered wake-ups. This interrupted the contiguous ten-minute gate and the overall run correctly failed. No battery/Doze or walking-accuracy claim follows.

An independent three-minute source audit during that screen-off interval found 70 phone geographic fixes/11 heartbeats and 72 watch geographic fixes/89 pressure readings/11 heartbeats, with maximum heartbeat gaps of 15.3 seconds (phone) and 17.1 seconds (watch). These are actual reported observations, not a measured route or proof of independent watch GNSS; provider provenance still applies (`artifacts/screen-off-source-progress.json`). After host cleanup, physical app-private inspection confirmed resolved/inactive state and zero queued readings on both devices (`artifacts/managed-run-cleanup-evidence.json`).
