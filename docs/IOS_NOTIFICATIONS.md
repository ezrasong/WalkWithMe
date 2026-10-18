# WalkWithMe iPhone guardian notifications

## Free Apple Account: local review reminders

Use a Mac with Xcode and sign the Runner target with your Personal Team, as described in [iPhone setup](FLUTTER_MOBILE.md#iphone). A signed development build means Apple development credentials authorize installation on a physical iPhone; it does not mean an App Store release. Free-account provisioning generally expires after seven days, requiring another Xcode install. Local notifications do not require paid membership.

Join a guardian session and explicitly enable **Guardian notifications**. Allow notifications when iOS asks. WalkWithMe schedules one local reminder at the last server-confirmed deadline plus grace, using the server-relative remaining time. It contains no wearer name, location or private link. Its text asks you to open WalkWithMe and says that background status has not been verified.

A reminder can still appear after the wearer checks in, resolves the session or revokes access while the guardian app is closed. It is not a confirmed safety alert. Reopening WalkWithMe refreshes the deadline or removes the reminder on acknowledgment, resolution, deletion, expiry or revoked access. Removing the link or disabling notifications cancels the local reminder. iOS Focus, notification settings and operating-system delivery behavior can suppress notifications. No critical-alert entitlement is requested.

## Paid Apple Developer membership: optional server-confirmed push

The native registration and backend Apple Push Notification service (APNs) path are implemented. They are **not configured, built with Xcode or physically verified in this change**. A free Personal Team cannot enable the Push Notifications capability. Do not switch on this path unless you have a paid team and Apple credentials.

1. Register an explicit App ID matching the Runner bundle identifier (default `app.kaze.trail`) with Push Notifications enabled in the paid Apple Developer team.
2. In Xcode, choose the paid signing team and enable Push Notifications for Runner. For the configuration you will run, set user-defined build settings `KAZE_PUSH_ENABLED=YES`, `KAZE_APNS_ENVIRONMENT=development`, and `CODE_SIGN_ENTITLEMENTS=Runner/KazePush.entitlements`. The default entitlements remain suitable for a free account. Xcode must produce a provisioning profile with the matching `aps-environment` entitlement.
3. On the backend machine, store the Apple APNs `.p8` key outside the repository. Never paste it into Devpost, source code, the app or a guardian link. Set these environment variables before `npm start`:

| Setting | Value |
| --- | --- |
| `KAZE_APNS_KEY_FILE` | Absolute path to the server's `.p8` key |
| `KAZE_APNS_KEY_ID` | Apple's ten-character key ID |
| `KAZE_APNS_TEAM_ID` | Apple's ten-character paid team ID |
| `KAZE_APNS_TOPIC` | Runner's exact bundle identifier |
| `KAZE_APNS_ENVIRONMENT` | `development` for Xcode development signing, `production` for distribution |

For TestFlight or App Store builds, both the app entitlement/build setting and server environment must be `production`. Incomplete server configuration fails startup; an unconfigured server rejects enrollment rather than pretending push is active. Keep key files, SQLite data and backup copies private; device tokens are stored in the server's private SQLite database until removal or session expiry. `.p8` files are ignored by Git.

4. Install the signed build, join a guardian session and explicitly enable notifications. WalkWithMe asks Apple for a device token, registers it with guardian-only authorization, and reports Apple push registered only after server enrollment succeeds. A failed enrollment retains the local reminder. On success, the local reminder is canceled to avoid duplicate notifications. After an app update, signing/environment change or Apple registration failure, turn notifications off and on while connected to refresh enrollment.

The server advances deadlines independently of the wearer connection. It sends only for an active, unacknowledged alert, using a generic payload without names, locations or access credentials. A push never marks the guardian as connected, as having opened the alert or as having acknowledged it. Accepted APNs submissions are persisted to avoid repeats across backend restarts. Temporary failures retry after 30 seconds; invalid device tokens are removed. At most five devices can enroll per session.

APNs acceptance is not proof of delivery or a human response. Pushes are sent with expiry zero so Apple does not queue them for later offline delivery. This deliberately limits stale alerts and can lose notifications to offline devices. Already submitted notifications cannot reliably be retracted after acknowledgment or access revocation; always open WalkWithMe to confirm current state. No delivery guarantee is made.

Disabling notifications stops local reminders and requests remote deregistration. If that request fails, WalkWithMe retains session access and enrollment metadata so removal can be retried. Revocation, deletion, resolution and expiry remove server registrations. If local app data is lost before deregistration, the old enrollment lasts until the session ends or expires. The backend and its network must remain available.

## Verification still needed on the Mac and iPhone

Run `flutter analyze`, `flutter test`, and the Runner XCTest target in Xcode. The XCTest cases cover server-relative reminder timing, acknowledged/ended sessions, invalid dates and known expiry. This Windows workspace cannot compile UIKit/UserNotifications code; source presence is not an iOS build result.

On a physical iPhone, verify permission denial, foreground/background and locked-screen reminders, refreshed check-ins, acknowledgment, link removal and expiry. With a paid team, additionally test sandbox enrollment, server-confirmed nonresponse with the app backgrounded, an offline guardian, backend restart, APNs rejection, device-token refresh and deregistration failure. Use simulated safety scenarios only. Existing simulator guardian tests do not establish that these new native notification paths work on hardware.
