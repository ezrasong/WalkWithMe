# KAZE verification goal

Use this objective for the persistent goal in the current chat. It replaces implementation-first iteration with evidence-led verification and repairs. The existing product/privacy requirements in KAZE_BUILD_GOAL.md still apply.

## Objective

Test, repair and verify KAZE in `C:\Users\ezras\.codex\worktrees\57e1\htv11` using the Flutter phone app, Vivo wearer, native Galaxy Watch4 companion, PC Node/SQLite backend and iPhone/second Android guardian. Preserve uncommitted work and `.codex` files. Prioritize reproducible verification and root-cause repairs over new features. No token budget is requested.

## Completion evidence

1. Node/browser, Flutter analyze/tests, Android shared tests/lint and phone/watch debug APKs pass. Reinstall current production APKs after device integration runs.
2. Actual phone/watch pairing, direct/relay uploads, explicit check-ins, server confirmations and haptic reminders work. Test denied permissions and absent/stale location.
3. Run at least ten minutes of screen-off collection/reminders, bounded disconnection/reconnection, queue retry/idempotency and a measured consenting walking route. Record observed accuracy and failures; compilation or a few GPS fixes is insufficient.
4. Prove independent persisted server deadlines, escalation after nonresponse, restart recovery, guardian privacy/role boundaries, explicit live-sharing choice, acknowledgement without resolution, and end/delete/revoke/expiry shutdown.
5. Test two-phone guardian use and PC HTTPS reachability over Wi-Fi/mobile data. Obtain Mac/Xcode build/signing and actual iPhone guardian/permission evidence. Never assume a tunnel exists or bypass TLS/auth.
6. Test optional guardian camera denial/closure/precision/alignment/access loss. Label the existing compass cue experimental; no anchored indoor AR, exact floor/stair route, custom motion AI or emergency dispatch claim without supporting implementation and measurement.
7. Keep dated, redacted evidence in `docs/VERIFICATION.md` with command output/artifact references, device versions and passed/failed/simulated/experimental/pending labels. Update demo, setup and Mac instructions. No tokens, pairing codes or precise private coordinates in shared reports.

## Iteration

Inspect the next unverified invariant, run its smallest meaningful proof, fix a reproduced root cause, rerun affected checks, update evidence and continue. Use disposable consented test sessions. No paid services, real dispatch or unrequested messages. Ask concise hardware/Mac/network questions while continuing independent checks. Do not mark complete while required verification remains. Use the goal-tool repeated-blocker rules if all remaining progress genuinely needs external input; do not repeatedly poll unchanged blockers.

## Current baseline to recheck when affected

Six Flutter tests, 30 Node tests, three browser flows, ten shared Android tests and Android builds/lint previously passed. A Vivo Android 16/API36 test accepted a check-in and uploaded two heartbeats/nine non-mock GPS/network fixes, then ended. These are historical results, not a claim that screen-off accuracy, Watch4 behavior or iPhone builds were verified.

Watch setup must be automatic from the watch: on opening KAZE it discovers and requests the active session from the already paired phone. Do not require manually sending configuration from phone Settings. Keep explicit watch recording consent and prevent background discovery from replacing an active or starting session.
