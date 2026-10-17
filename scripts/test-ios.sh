#!/usr/bin/env bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
command -v flutter >/dev/null || { echo 'Install Flutter and add its bin directory to PATH.' >&2; exit 1; }
command -v node >/dev/null
if lsof -nP -iTCP:4174 -sTCP:LISTEN >/dev/null 2>&1; then
  echo 'Port 4174 is in use. Stop the previous iOS test service before running this suite.' >&2
  exit 1
fi

device="${1:-}"
if [ -z "$device" ]; then
  device="$(xcrun simctl list devices available -j | node --input-type=module -e '
    let raw = ""; for await (const chunk of process.stdin) raw += chunk;
    const devices = Object.entries(JSON.parse(raw).devices).flatMap(([runtime, list]) =>
      list.filter(d => d.isAvailable && d.name.startsWith("iPhone")).map(d => ({...d, runtime})));
    devices.sort((a, b) => (b.state === "Booted") - (a.state === "Booted") || b.runtime.localeCompare(a.runtime, undefined, {numeric: true}));
    if (devices[0]) process.stdout.write(devices[0].udid);
  ')"
fi
[ -n "$device" ] || { echo 'Install an iOS simulator runtime in Xcode > Settings > Components.' >&2; exit 1; }
state="$(xcrun simctl list devices -j | node --input-type=module -e '
  let raw = ""; for await (const chunk of process.stdin) raw += chunk;
  process.stdout.write(Object.values(JSON.parse(raw).devices).flat().find(d => d.udid === process.argv[1])?.state ?? "");
' "$device")"
if [ "$state" != 'Booted' ]; then xcrun simctl boot "$device"; fi
xcrun simctl bootstatus "$device" -b
open -a Simulator
mkdir -p artifacts/ios
node scripts/ios-test-backend.mjs > artifacts/ios/test-backend.log 2>&1 &
service_pid=$!
trap 'kill "$service_pid" 2>/dev/null || true; wait "$service_pid" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
  if curl --silent --fail http://127.0.0.1:4174/api/health >/dev/null; then break; fi
  kill -0 "$service_pid" 2>/dev/null || { cat artifacts/ios/test-backend.log >&2; exit 1; }
  sleep 1
done
curl --silent --fail http://127.0.0.1:4174/api/health >/dev/null
cd mobile
flutter pub get
flutter drive --driver=test_driver/ios_guardian.dart \
  --target=integration_test/ios_guardian_test.dart \
  --dart-define=KAZE_BASE_URL=http://127.0.0.1:4174 -d "$device"
