"""Export one completed app-private capture from a development phone build."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--serial', required=True, help='Wearer phone ADB serial')
parser.add_argument('--out', type=Path, default=Path('artifacts/motion') / ('capture-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '.csv'))
args = parser.parse_args()
adb = shutil.which('adb') or str(Path.home() / '.cache/kaze-android-sdk/platform-tools/adb.exe')
if args.out.exists():
    parser.exit(2, 'Choose a new export path; existing evidence is preserved.\n')
args.out.parent.mkdir(parents=True, exist_ok=True)
temporary = args.out.with_suffix('.partial')
if temporary.exists():
    parser.exit(2, 'A previous incomplete export exists; choose a new path.\n')
try:
    with temporary.open('xb') as stream:
        result = subprocess.run([adb, '-s', args.serial, 'exec-out', 'run-as', 'app.kaze.trail',
            'cat', 'files/motion-evaluation/motion.csv'], stdout=stream, stderr=subprocess.PIPE, timeout=60)
    if result.returncode or temporary.stat().st_size == 0:
        parser.exit(2, 'No completed capture available. Stop capture before exporting; keep the safety session active.\n')
    temporary.replace(args.out)
    print('Private motion capture exported. Keep this file outside version control.')
finally:
    temporary.unlink(missing_ok=True)
