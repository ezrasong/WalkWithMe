# Motion trail evaluation

KAZE automatically streams compressed motion batches from active wearer Android sessions to its backend for evaluation with the published RoNIN ResNet checkpoint. Wi-Fi and cellular data are allowed by default. Automatic streaming saves no raw capture on the phone or backend. Optional three-minute private captures support manual export. This is a non-commercial research preview. With explicit retention consent, supported phone windows form a bounded relative trail visible under the session’s existing guardian sharing rules. Geographic observations and check-in deadlines remain separate. The preview never supplies indoor directions or a fabricated camera registration. No wearer camera is used.

## Local setup

Requires Python 3.11 or newer and a development Android build with ADB access. From the repository root:

```powershell
python src/motion/setup.py
```

This creates an isolated runtime under your home directory at `.cache/kaze-motion/venv`, installs pinned CPU dependencies, and downloads a pinned upstream architecture and checkpoint archive. The executable architecture and checkpoint archive are SHA-256 checked before use. Checkpoint loading uses restricted tensor-only loading. No checkpoint, research dataset or upstream implementation is bundled into the phone app or committed to this repository.

On Windows the evaluation Python is `$env:USERPROFILE\.cache\kaze-motion\venv\Scripts\python.exe`; on macOS/Linux it is `~/.cache/kaze-motion/venv/bin/python`. CPU inference is the verified default; no GPU driver or existing Python environment is modified.

## Capture on the Vivo

1. Start a normal wearer safety session. Its consent explains motion uploads. Streaming starts after the backend confirms the session, with cellular data allowed. Its check-in deadlines still apply.
2. Open **Settings → Motion trail evaluation** to see upload status and the latest estimate. **Stop streaming for this session** disables streaming for the rest of this session, including service restarts. For an optional saved capture, stop automatic streaming, select **Evaluate a manual capture on the backend** and **Allow cellular data** as desired, then press **Start 3-minute capture**. Both switches start on; turn off evaluation for a local-only capture or cellular for unmetered Wi-Fi only.
3. For a repeatable test, stand still briefly, walk a consenting route with independently measured waypoints, and record waypoint times. Carry the phone freely in a pocket; note posture changes and stop times for the comparison. No doorway, fixed-phone or straight-walking calibration is required to start recording.
4. Press **Stop capture**, or let the three-minute limit finish. Export while the safety session is still active.

Both modes request acceleration, gyroscope and game-rotation quaternions at 200 Hz on a separate sensor thread, preserving actual monotonic timestamps, SI units, sensor type and Android-reported bias estimates. Automatic streaming continues until the session ends or expires, without a raw disk file. Optional saved captures are limited to three minutes and 32 MiB. Actual sampling is measured by the evaluator; a requested rate is not proof of the delivered rate.

The raw file is app-private, excluded from backups, and never enters the safety network outbox. An existing completed capture cannot be overwritten: export it and explicitly delete it before starting another. Ending, revoking or expiring the wearer session deletes local evaluation files and the latest evaluation summary when the service processes that state; interrupted processes clean up on reopening. Exported PC copies remain under your control. Close capture and export before ending a test session.

## Automatic streaming and data use

Run setup on the machine hosting the existing Node backend, then start the backend normally with `npm start`. The backend automatically finds the isolated runtime under `.cache/kaze-motion/venv`; `KAZE_MOTION_PYTHON` can select its Python executable when deployed elsewhere. The published weights remain on that machine. The phone sends motion to the configured KAZE server, which evaluates it and returns an estimate; nothing is sent to a chat. The server and, when used, its HTTPS tunnel must stay running.

- Uploads use gzip binary bodies every ten seconds, avoiding text/base64 expansion on the network. Each batch after the first includes up to 1.3 seconds of overlapping context. Inputs retain the checkpoint's required 200 Hz sampling; reducing the sensor rate would invalidate its input. Responses include at most about five trail points per second.
- By default uploads allow any validated connection, including cellular. Requests bind to the selected network for that batch. Turning cellular off for a manual capture restricts it to validated, unmetered Wi-Fi or Ethernet, with no in-flight fallback to cellular. KAZE does not change the phone's system network settings.
- One batch can be in flight. Offline, busy, oversized or failed batches are skipped, with no retry loop or upload backlog. Each batch is at most 180,000 compressed bytes, with a 1,000,000-byte expanded limit. The normal ten-second schedule bounds motion upload payload to 1.08 MB/minute, plus HTTP/TLS overhead. The page reports attempted payload bytes, including failed attempts; this is not a carrier billing meter.
- Stopping streaming cancels its request and discards the unfinished batch. Session expiry or session end also stops streaming. Closing the page leaves streaming running. After process interruption, automatic streaming resumes only after the backend confirms the active session, unless stopped for that session. Optional saved captures stop after three minutes and do not resume after interruption. Every new wearer session enables automatic streaming again.
- The authenticated `POST /api/sessions/:id/motion` endpoint requires owner access, `Content-Type: application/gzip`, and `X-Kaze-Motion-Consent: 1`. Guardian/watch credentials cannot submit raw phone motion. The server rechecks session state after body parsing and inference; ended, deleted or expired sessions cannot receive a result. Raw batches are never written to the backend database or logs. If the wearer explicitly enables relative trail retention, at most 4096 derived points in 128 sections are stored in SQLite until session expiry or deletion. Withdrawing retention deletes them immediately. The phone keeps only the latest summary and, when explicitly started, its separately bounded private capture.

The backend caches one CPU model and processes one request at a time without a queue. The inspected PC has a Ryzen 9 9950X3D2 (16 cores / 32 threads), about 64 GB RAM, and an RTX 5090 with 32 GB VRAM. The installed Python runtime uses PyTorch 2.14.1 CPU and NumPy 2.3.5. On this PC, three synthetic 11.3-second batches took 39–52 ms of model inference each (207 windows). CPU is retained because this workload already has ample headroom; no GPU package or driver changes are required. This measures execution only.

## Continuous relative trail and guardian preview

New session consent describes retention and sharing of relative research estimates. Older sessions remain evaluation-only until the wearer enables **Settings → Motion trail evaluation → Retain and share relative research trail**. Web session settings expose the same control. Upload consent alone does not authorize retention. Withdrawal during inference invalidates that request’s retention even if consent is subsequently enabled again.

Each Android recorder instance gets a random stream ID, a fixed monotonic origin, a fixed server-time mapping and increasing batch sequence numbers, including skipped batches. Up to 1.3 seconds of raw overlap stays in bounded phone memory. The evaluator rotates acceleration and gyroscope observations with Android game-rotation quaternions; it does not use device azimuth as walking heading. Prediction windows share the stream’s 200 Hz grid and 20 Hz stride. This compensates for measured phone posture, but does not establish placement robustness or field accuracy.

The server integrates velocity only once for each new supported timestamp. It ignores batch-local positions. Adjacent supported windows continue the same section; missing samples, rejected speeds, failed uploads and recorder restarts break continuity. A new section has its own unknown origin. It never joins positions across missing data or tries to align restarted game-rotation yaw. One unsupported initial second remains at each true sensor start or gap, rather than at every upload. Stream replay or changing an existing stream’s clock/origin is rejected. Derived history survives a backend restart; raw data does not.

A conservative still-phone heuristic suppresses model velocity when the preceding second has low world-frame acceleration variation and angular motion near gravity. This is an activity heuristic, not proof of wearer stillness. Time-matched native phone/watch steps are checked in ten-second intervals, with explicit timestamp uncertainty and sensor provenance. Wrist orientation is never body heading. Matching activity does not reduce position uncertainty or add displacement. Conflicting step activity, including a still phone with moving watch observations, withholds those intervals from diagrams and increases the displayed engineering drift budget. Missing, fallback-threshold or poorly synchronized watch data remains unavailable. Delayed observations are re-evaluated when shared snapshots are read. Pressure trends remain relative height evidence in session details; no floor or stair is inferred.

Owner and authorized guardian snapshots expose `relativeMotion`; the alert-scoped `/ar` response includes the same preview even when its geographic AR packet is unavailable. Watch access and private guardian snapshots do not expose it. The mobile session details and web map page show the latest continuous section; independently restarted sections are never overlaid. Truncated history is recorded with `omittedPoints`. The guardian’s **Pocket motion camera preview** shows a local camera view and a separately labelled diagram. It draws no projected arrows or indoor route. The existing geographic camera view can also show the relative preview beside its independently sourced map.

Starting room, floor, geographic origin and north remain unknown. Absolute uncertainty is uncalibrated; a growing time/distance drift budget is explicitly an engineering indicator rather than a probabilistic bound. Existing device geographic observations and optional Android Geospatial localization can supply outdoor environmental references where usable. They do not register arbitrary indoor motion to a room or a guardian’s camera. An unmapped indoor scene remains unavailable for spatial guidance. All motion estimates remain `researchOnly: true`, `guidanceAllowed: false`, with no claim of measured pocket-walking accuracy.

## Owner-only tuning diagnostics

New-session consent includes technical motion diagnostics. Older sessions can enable **Settings → Motion trail evaluation → Keep owner-only motion diagnostics**. At most 120 received-batch summaries are kept in SQLite until session expiry/deletion or diagnostic consent withdrawal. They include delivered sensor rates/gaps, input counts, model and total processing time, stationary-window counts, speed statistics, stream sequence/clock uncertainty, retained section counts and time-matched watch activity checks. Batch distance includes overlapping context and must not be summed as wearer distance. Failure records use fixed reason codes rather than exception text. No raw samples, camera images, names, coordinates or credentials are included. These records support debugging; they do not constitute reference measurements or train/change the model automatically.

Only the owner can read `GET /api/sessions/:id/motion-diagnostics` or change consent with confirmed `POST {enabled, confirm:true}`. Guardian/watch access is rejected. Withdrawal during inference prevents the pending result from restoring diagnostic records. Diagnostics cannot extend check-in timing or block model results. Batches lost before reaching the server have no backend diagnostic record; the phone's streaming status and attempted upload byte counter help identify those failures.

After a house test, before ending the session, select **Copy motion diagnostics** on the Vivo and paste the JSON for analysis. For guardian AR registration, run the iPhone build attached to Xcode/Flutter and retain the existing `[KAZE AR]` startup and closure lines. Camera logs omit credentials and coordinates; successful indoor alignment is not inferred from them.

## Private export and evaluation

```powershell
& "$env:USERPROFILE\.cache\kaze-motion\venv\Scripts\python.exe" src/motion/evaluate.py artifacts/motion/walk.csv --out artifacts/motion/walk-result
```

For a development build, export the completed app-private `files/motion-evaluation/motion.csv` using `adb -s PHONE_SERIAL exec-out run-as app.kaze.trail cat files/motion-evaluation/motion.csv`. Save the output as UTF-8 CSV under a new path such as `artifacts/motion/walk.csv` before evaluating. This does not require shared phone storage. Preserve previous captures and results; keep them under the ignored `artifacts/` directory.

The result directory contains `report.json` and `estimated-trail.csv`. Coordinates are **relative horizontal motion in the phone's game-rotation frame**, with unknown geographic position and north. Height and calibrated uncertainty remain unknown; `guidanceAllowed` stays false. The first second is unsupported. Missing observations, inadequate sampling and outputs exceeding the walking evaluation limit break segments; no model window spans a missing-data interval. Every later segment starts with a separate relative origin.

The checkpoint does not make old step/pressure records into raw inertial samples. Android bias compensation is preserved, but no laboratory calibration or phone-placement adaptation is claimed. Wrist motion requires separate evaluation; this workflow does not apply the phone checkpoint to watch data.

## Measured comparison

Supply an independently measured reference CSV with these columns:

```csv
t_s,x_m,y_m
```

Times are seconds since capture started, measured with the capture's monotonic clock. Use at least four chronological waypoint measurements, all within one supported estimated segment. The first two must span at least 5 m and establish yaw and translation. Later points evaluate error; scale is never fitted. Reference measurement accuracy and timestamp uncertainty must be recorded alongside the test. The timestamps in the raw capture are nanoseconds relative to `startedNs` in its header.

```powershell
& "$env:USERPROFILE\.cache\kaze-motion\venv\Scripts\python.exe" src/motion/evaluate.py artifacts/motion/walk.csv --reference artifacts/motion/reference.csv --out artifacts/motion/walk-measured
```

Reports include sampling/gap statistics, measured CPU inference latency, and (when supplied) error against later reference points. Compare the same walking route with the current geographic/step trail before claiming improvement. Merely running the checkpoint or comparing synthetic fixtures does not prove field accuracy or uncertainty calibration. No estimated path is promoted into geographic evidence or spatial camera guidance; the consented relative diagram stays separate.

## Tests and provenance

```powershell
& "$env:USERPROFILE\.cache\kaze-motion\venv\Scripts\python.exe" -m unittest discover -s test/motion -p "test_*.py" -v
```

Native and Flutter tests cover automatic session startup with cellular allowed, streaming beyond the manual three-minute limit without a raw file, expiry, stop persistence across recorder restarts, bounded private capture, the metered/cellular policy, privacy and session-control isolation. Python tests cover preprocessing, bias/quaternion conventions, sparse and mixed-rate input rejection, gaps, compressed expansion limits, withheld reference errors and actual checkpoint execution on synthetic input. Backend tests cover owner-only access, consent, body/rate limits, stale batches and ending a session during processing. When the runtime is installed, they also exercise the real cached model and reject concurrent work.

Before continuous stitching was added, physical verification on the Vivo delivered approximately 200 Hz for all three streams with no gaps over 25 ms during a stationary 28-second capture. The final binary-upload build sent two ten-second batches totaling 140,652 payload bytes (about 0.42 MB/minute for this stationary input, excluding network overhead) through the configured HTTPS backend and received estimates while its check-in deadline remained unchanged and camera permission remained denied. Its installed APK matched the built APK. Stopping capture stopped streaming; ending the dedicated test session deleted its local capture and summary. This confirms transport and execution; it provides no measured walking-route accuracy result. Data usage depends on motion and compression and is displayed on the capture page.

Before continuous stitching was added, a later physical run verified automatic startup directly from a new wearer session, cellular allowed by default, successful backend estimates and no raw files saved. Ending that dedicated test stopped streaming and removed its summary; check-in timing and the camera denial were preserved. That run used the available connection; a separate cellular-network transfer was not measured.

The continuous build was installed over the existing Vivo app with its data preserved. A separate stationary transport session sent three compressed batches (226,933 payload bytes total) from real phone sensors to the PC. Its shared derived preview contained one continuous section with 147 retained points through monotonic second 30, a zero stationary endpoint, unknown room/floor/yaw and `guidanceAllowed: false`. Its check-in deadline was unchanged, and its private raw-capture directory stayed empty. The dedicated test was resolved and deleted, and the prior native preferences/session selection were restored. This verifies real transport and stitching, not pocket walking accuracy, heading robustness, watch-device fusion or indoor localization. No measured walking-route comparison has been completed for this update.

Validation for this update: 72 backend tests, 11 Python motion tests, 103 Flutter tests, Flutter analysis, Android shared unit tests, Android build and lint. Backend tests include actual checkpoint output reaching authorized HTTP snapshots, consent withdrawal during inference, gap/replay handling and SQLite continuation after reopening. Synthetic posture transforms and stationary fixtures prove implementation behavior only. iOS compilation/device testing and successful physical Google Geospatial localization remain unverified.

Upstream: [RoNIN source](https://github.com/Sachini/ronin), pinned commit `805b7f0f28bb164ce89ada9ac05a9470dbe3d715`; [published checkpoint archive and terms](https://doi.org/10.20383/102.0543). The code is GPL-3.0; the pretrained checkpoint has separate **non-commercial research/education/artistic-use terms**. The runtime retains both licenses. This setup is for non-commercial research evaluation, including the development backend, not a grant to ship the checkpoint in a commercial product or service. See the publisher's full terms before other use.

Citation: Sachini Herath, Hang Yan and Yasutaka Furukawa, *RoNIN: Robust Neural Inertial Navigation in the Wild*, ICRA 2020. No improvement on the Vivo has been established until an independent measured route comparison is completed.
