# Guardian AR backend

The backend prepares recorded geographic evidence for the guardian's future AR renderer. Camera capture belongs only to the guardian device. The wearer phone/watch do not record or upload images. This first backend stage performs coordinate geometry on the PC; it does not run a learned model or improve the accuracy of the original fixes.

## API

`GET /api/sessions/:id/ar`, with the existing bearer credential, returns a version-1 geographic frame and separate source paths. It requires an active assistance request (`alert`) and guardian or owner access. Owner access is for inspecting their own evidence; it does not enable a wearer camera screen. Watch access is rejected. Before escalation and after resolution the endpoint returns 409; revoked/expired credentials return 401 and deleted sessions return 404. POST and other mutations are rejected. Reading AR evidence does not acknowledge, check in, resolve or extend a session.

The frame uses WGS84 and meters: `x` east, `y` up, `z` south, compatible with a right-handed camera world after an explicit registration. The earliest usable observed fix identifies the anchor. A late earlier fix can change `frame.anchor.id`: the client must clear its previous registration if that ID changes.

Paths retain phone/watch provenance and the existing time/disagreement gaps. Mock fixes and reported horizontal uncertainty above 25 m are excluded. Excluded observations break the line. The local frame is limited to 2 km from its anchor. The endpoint does not fill gaps, average correlated phone/watch locations or create coordinates from steps/pressure.

Height is `null` unless both anchor and observation report vertical accuracy within 10 m and come from the same source. Known height is only a relative altitude observation, with the sum of both reported vertical uncertainties. Horizontal uncertainty also includes the anchor's reported uncertainty. These sums are conservative allowances, not calibrated confidence intervals. No floor, wall, room or stair geometry is inferred.

## Registration and remaining work

Frames explicitly have `registrationRequired: true` and `cameraAligned: false`; every packet has `guidanceAllowed: false`. A current usable last fix yields `fallback: alignment-required`; absent, stale, poor or distant current evidence requires the map. An available historical path does not mean the wearer remains at its last point.

The guardian renderer still needs actual ARKit/ARCore tracking, a measured shared geographic/spatial registration, quality checks and physical route/alignment tests. It must preserve source/gap/uncertainty semantics and close on authorization loss. Until that is implemented and measured, the existing camera screen remains an experimental compass preview. Backend geometry tests are not AR alignment evidence.

## Verification

`npm test` includes cardinal directions, WGS84 distance, high latitudes/antimeridian, source separation, unknown height, uncertainty filtering, late-anchor changes, gaps, stale/distant fallback and endpoint authorization/lifecycle checks. No guardian camera frames or wearer geographic artifacts are committed to Git.
