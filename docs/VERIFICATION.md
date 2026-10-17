# KAZE verification ledger

Verification goal: `KAZE_VERIFY_GOAL.md`. Worktree: `C:\Users\ezras\.codex\worktrees\57e1\htv11`. Dates are October 17, 2026, America/Toronto. Reports omit bearer tokens, pairing codes and exact private coordinates.

| Check | Current evidence | Status |
| --- | --- | --- |
| Flutter Android/iOS shared UI | Flutter renders phone screens directly; no WebView | Implemented |
| Vivo phone/service/PC path | Real integration accepted a check-in, received two phone heartbeats and nine non-mock GPS/network fixes, and ended. `artifacts/vivo-flutter-integration.txt`, `artifacts/vivo-evidence.json` | Passed physical bounded test; route accuracy unmeasured |
| Automated checks | Fresh six Flutter tests, 30 Node tests and three browser flows; Flutter analyze reports no issues | Passed; artifacts/flutter-verification.txt, artifacts/node-verification.txt, artifacts/browser-verification.txt |
| Watch4 installation/ADB | Actual SM-R870, Android 16/API36; watch debug APK installed/launched | Passed installation; not yet reliability proof |
| Automatic watch discovery | Watch requested active phone session on open; app-private inspection confirmed only watch access, no owner/guardian secrets; screenshot `artifacts/watch-auto-pair.png` | Passed physical discovery |
| Pairing boundary regressions | 14 shared Android tests; late discovery cannot replace a starting/active session; allowlisted payload cannot persist owner/guardian secrets | Passed; `artifacts/watch-auto-pair-build.txt` |
| Watch build/shared and watch lint | Build and lint succeeded after discovery changes | Passed; `artifacts/watch-auto-pair-build.txt` |
| Phone/watch live relay | Combined real-device integration passed: automatic discovery, explicit watch Start, actual watch pressure/heartbeat through paired-phone relay; no manual configuration transfer | Passed; artifacts/vivo-watch-auto-pair-integration.txt and artifacts/watch-evidence.json |
| Watch/phone haptics | Still needs notification timing/system evidence and human felt-vibration confirmation | Pending hardware |
| At least ten minutes screen-off | Not established by compilation or the short phone integration | Pending physical run |
| Offline queue/recovery on actual devices | Existing automated queue tests; physical outage/reconnect test still needed | Automated passed; physical pending |
| Measured route accuracy | Nine real phone fixes do not establish route/turn error | Pending measured walk |
| iPhone signed build/guardian | Source and Mac/Xcode guide ready | Pending Mac/iPhone |
| Two-phone guardian + HTTPS Wi-Fi/mobile data | Local PC server + USB reverse verified; no public tunnel assumed running | Pending network/second phone |
| Guardian camera guidance | Approximate outdoor compass cue; no shared spatial registration or floor/stair path | Experimental; physical precision/alignment unverified |
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
- Physical combined test: `flutter.bat test integration_test/app_flow_test.dart -d PHONE_SERIAL --dart-define=KAZE_BASE_URL=http://127.0.0.1:4174 --dart-define=KAZE_VERIFY_WATCH=true`, with the disposable local backend, phone-only USB reverse, and the real watch opened/started after the log marker. Watch has no ADB reverse in the relay test. Rebuild/reinstall the normal phone APK after integration tests.

Do not mark the overall goal complete while required physical/Mac/network evidence is missing. Continue independent software work while waiting for actionable hardware input.

### Completed automatic watch flow

The real combined integration passed in 44 seconds after the host woke the watch immediately before its explicit Start tap. The server recorded three phone heartbeats, 19 non-mock phone GPS/network fixes, one watch heartbeat and one watch pressure reading, then the owner's end-session request. The watch had no ADB reverse during capture, and its localhost PC URL therefore used the paired-phone Wear Data Layer relay. Discovery payload inspection confirmed no owner/guardian credential was persisted on the watch.

The Flutter device-test runner removed the phone app immediately after ending. The watch then could not use that phone relay to learn the end, so its local capture remained armed/offline. For test cleanup, a temporary watch ADB reverse was added to let its authoritative poll see the resolved session and delete queued readings. Future combined tests now keep the relay alive for 20 seconds after end before runner cleanup. Normal end-through-relay shutdown is still a separate physical verification gate; the capture/discovery success does not by itself prove it.

The fresh Node run passed all 30 tests (`artifacts/node-verification.txt`); browser run passed all three (`artifacts/browser-verification.txt`); six Flutter tests passed (`artifacts/flutter-verification.txt`). No screen-off duration, felt vibration, measured route accuracy or iPhone build is inferred from these results.

The temporary cleanup connection was subsequently verified: the watch persisted phase `resolved`, active `false`, and "Session ended. Recording stopped; queued readings deleted." The watch ADB reverse was then removed. The production Flutter phone APK was rebuilt and reinstalled successfully; automatic discovery is the ordinary flow, with no manual phone pairing button.

Phone lint after the final automatic-pairing changes passed with zero errors and seven warnings (`artifacts/flutter-android-lint.txt`). A reproduced tooling issue was repaired in the app Gradle lint task: Flutter asset compilation can regenerate improperly escaped Windows SDK paths, so Java Properties serialization now normalizes the ignored local file immediately before lint reads it. Lint remains fully enabled. Final Flutter analyze reported no issues, and both current production debug apps are installed.
