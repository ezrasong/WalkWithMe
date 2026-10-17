# Motion trail evaluation

KAZE can record a bounded raw motion capture on the wearer Android phone and automatically send compressed batches to its backend for evaluation with the published RoNIN ResNet checkpoint. Private manual export remains available. This is a development research workflow. It does not alter geographic observations, guardian AR, check-ins, escalation or watch collection. No wearer camera is used.

## Local setup

Requires Python 3.11 or newer and a development Android build with ADB access. From the repository root:

```powershell
python scripts/motion/setup.py
```

This creates an isolated runtime under your home directory at `.cache/kaze-motion/venv`, installs pinned CPU dependencies, and downloads a pinned upstream architecture and checkpoint archive. The executable architecture and checkpoint archive are SHA-256 checked before use. Checkpoint loading uses restricted tensor-only loading. No checkpoint, research dataset or upstream implementation is bundled into the phone app or committed to this repository.

On Windows the evaluation Python is `$env:USERPROFILE\.cache\kaze-motion\venv\Scripts\python.exe`; on macOS/Linux it is `~/.cache/kaze-motion/venv/bin/python`. CPU inference is the verified default; no GPU driver or existing Python environment is modified.

## Capture on the Vivo

1. Start a normal wearer safety session. Its check-in deadlines still apply.
2. Open **Settings → Motion trail evaluation**. **Automatic backend evaluation** starts enabled, with **Allow cellular data** off. Press **Start 3-minute capture** to consent to recording and the displayed streaming settings. Turn off backend evaluation first for a local-only capture.
3. For a repeatable test, stand still briefly, walk a consenting route with independently measured waypoints, and record waypoint times. Keep phone placement consistent for the first experiment.
4. Press **Stop capture**, or let the three-minute limit finish. Export while the safety session is still active.

Capture requests acceleration, gyroscope and game-rotation quaternions at 200 Hz on a separate sensor thread. It records actual monotonic sensor timestamps, SI units, sensor type and Android-reported bias estimates. It is limited to three minutes and 32 MiB. Actual sampling is measured by the evaluator; a requested rate is not proof of the delivered rate.

The raw file is app-private, excluded from backups, and never enters the safety network outbox. An existing completed capture cannot be overwritten: export it and explicitly delete it before starting another. Ending, revoking or expiring the wearer session deletes local evaluation files and the latest evaluation summary when the service processes that state; interrupted processes clean up on reopening. Exported PC copies remain under your control. Close capture and export before ending a test session.

## Automatic streaming and data use

Run setup on the machine hosting the existing Node backend, then start the backend normally with `npm start`. The backend automatically finds the isolated runtime under `.cache/kaze-motion/venv`; `KAZE_MOTION_PYTHON` can select its Python executable when deployed elsewhere. The published weights remain on that machine. The phone sends motion to the configured KAZE server, which evaluates it and returns an estimate; nothing is sent to a chat. The server and, when used, its HTTPS tunnel must stay running.

- Uploads use gzip binary bodies every ten seconds, avoiding text/base64 expansion on the network. Inputs retain the checkpoint's required 200 Hz sampling; reducing the sensor rate would invalidate its input. Responses include at most about five trail points per second.
- By default uploads require validated, unmetered Wi-Fi or Ethernet. Requests bind to that network, so Wi-Fi loss cannot silently move an in-flight upload onto cellular. Cellular must be enabled before capture starts.
- One batch can be in flight. Offline, busy, oversized or failed batches are skipped, with no retry loop or upload backlog. Each batch is at most 180,000 compressed bytes, with a 1,000,000-byte expanded limit. The normal ten-second schedule bounds motion upload payload to 1.08 MB/minute, plus HTTP/TLS overhead. The page reports attempted payload bytes, including failed attempts; this is not a carrier billing meter.
- Stopping capture cancels its request and discards the unfinished batch. The three-minute limit, session expiry or session end also stops streaming. Closing the page allows the bounded capture to continue. Streaming never automatically restarts after process interruption.
- The authenticated `POST /api/sessions/:id/motion` endpoint requires owner access, `Content-Type: application/gzip`, and `X-Kaze-Motion-Consent: 1`. Guardian/watch credentials cannot submit raw phone motion. The server rechecks session state after body parsing and inference; ended, deleted or expired sessions cannot receive a result. No raw batch or estimated trail is written to the backend database or logs. The phone keeps only the latest summary alongside its separately bounded local capture.

The backend caches one CPU model and processes one request at a time without a queue. Invalid sampling, missing observations and resource limits fail independently of safety control. Each ten-second batch has a **separate relative origin** and loses its first second to the model window. Batches are not stitched into a continuous or geographic route. The returned estimates are for evaluation; shared maps and guardian AR do not consume them.

## Private export and evaluation

```powershell
python scripts/motion/export.py --serial PHONE_SERIAL --out artifacts/motion/walk.csv
& "$env:USERPROFILE\.cache\kaze-motion\venv\Scripts\python.exe" scripts/motion/evaluate.py artifacts/motion/walk.csv --out artifacts/motion/walk-result
```

The export uses development-build app-private access through ADB, without copying raw data to shared phone storage. Existing export/result paths are preserved. Keep captures and reports under the ignored `artifacts/` directory.

The result directory contains `report.json` and `estimated-trail.csv`. Coordinates are **relative horizontal motion in the phone's game-rotation frame**, with unknown geographic position and north. Height and calibrated uncertainty remain unknown; `guidanceAllowed` stays false. The first second is unsupported. Missing observations, inadequate sampling and outputs exceeding the walking evaluation limit break segments; no model window spans a missing-data interval. Every later segment starts with a separate relative origin.

The checkpoint does not make old step/pressure records into raw inertial samples. Android bias compensation is preserved, but no laboratory calibration or phone-placement adaptation is claimed. Wrist motion requires separate evaluation; this workflow does not apply the phone checkpoint to watch data.

## Measured comparison

Supply an independently measured reference CSV with these columns:

```csv
t_s,x_m,y_m
```

Times are seconds since capture started, measured with the capture's monotonic clock. Use at least four chronological waypoint measurements, all within one supported estimated segment. The first two must span at least 5 m and establish yaw and translation. Later points evaluate error; scale is never fitted. Reference measurement accuracy and timestamp uncertainty must be recorded alongside the test. The timestamps in the raw capture are nanoseconds relative to `startedNs` in its header.

```powershell
& "$env:USERPROFILE\.cache\kaze-motion\venv\Scripts\python.exe" scripts/motion/evaluate.py artifacts/motion/walk.csv --reference artifacts/motion/reference.csv --out artifacts/motion/walk-measured
```

Reports include sampling/gap statistics, measured CPU inference latency, and (when supplied) error against later reference points. Compare the same walking route with the current geographic/step trail before claiming improvement. Merely running the checkpoint or comparing synthetic fixtures does not prove field accuracy or uncertainty calibration. No estimated path is promoted into shared geographic evidence or AR.

## Tests and provenance

```powershell
& "$env:USERPROFILE\.cache\kaze-motion\venv\Scripts\python.exe" -m unittest discover -s scripts/motion -p "test_*.py" -v
```

Native and Flutter tests cover bounded capture, the metered/cellular policy, privacy, explicit actions, retention and session-control isolation. Python tests cover preprocessing, bias/quaternion conventions, sparse and mixed-rate input rejection, gaps, compressed expansion limits, withheld reference errors and actual checkpoint execution on synthetic input. Backend tests cover owner-only access, consent, body/rate limits, stale batches and ending a session during processing. When the runtime is installed, they also exercise the real cached model and reject concurrent work.

Physical verification on the Vivo delivered approximately 200 Hz for all three streams with no gaps over 25 ms during a stationary 28-second capture. The final binary-upload build sent two ten-second batches totaling 140,652 payload bytes (about 0.42 MB/minute for this stationary input, excluding network overhead) through the configured HTTPS backend and received estimates while its check-in deadline remained unchanged and camera permission remained denied. Its installed APK matched the built APK. Stopping capture stopped streaming; ending the dedicated test session deleted its local capture and summary. This confirms transport and execution; it provides no measured walking-route accuracy result. Data usage depends on motion and compression and is displayed on the capture page.

Upstream: [RoNIN source](https://github.com/Sachini/ronin), pinned commit `805b7f0f28bb164ce89ada9ac05a9470dbe3d715`; [published checkpoint archive and terms](https://doi.org/10.20383/102.0543). The code is GPL-3.0; the pretrained checkpoint has separate **non-commercial research/education/artistic-use terms**. The runtime retains both licenses. This setup is for non-commercial research evaluation, including the development backend, not a grant to ship the checkpoint in a commercial product or service. See the publisher's full terms before other use.

Citation: Sachini Herath, Hang Yan and Yasutaka Furukawa, *RoNIN: Robust Neural Inertial Navigation in the Wild*, ICRA 2020. No improvement on the Vivo has been established until an independent measured route comparison is completed.
