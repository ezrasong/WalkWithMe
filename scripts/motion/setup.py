"""Install the local motion evaluation runtime; no app or service deployment."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import urllib.request
import venv
import zipfile

ROOT = Path.home() / '.cache' / 'kaze-motion'
UPSTREAM = '805b7f0f28bb164ce89ada9ac05a9470dbe3d715'
ARCHIVE = 'https://www.frdr-dfdr.ca/repo/files/8/published/publication_538/submitted_data/'
ASSETS = {
    'model_resnet1d.py': (
        f'https://raw.githubusercontent.com/Sachini/ronin/{UPSTREAM}/source/model_resnet1d.py',
        '24a4859272d2ee469ecaef192dddcaa287d40392de21f6c55b5b9b71c76d8e57'),
    'MODEL_LICENSE.txt': (ARCHIVE + 'LICENSE.txt',
        '683253758bc392e4d2b36bcac06d21ec3cfc3ce0a19b2e50839f1ac00f38ca5f'),
    'ronin_resnet.zip': (ARCHIVE + 'Pretrained_Models/ronin_resnet.zip',
        '7431ac4c87371d634f9eac355fbbf12ee0a346b38c01f7e1809c1953db580168'),
}


def python_path():
    return ROOT / 'venv' / ('Scripts/python.exe' if sys.platform == 'win32' else 'bin/python')


def download(name, url, digest=None):
    target = ROOT / name
    if target.exists() and digest and hashlib.sha256(target.read_bytes()).hexdigest() == digest:
        return target
    temporary = target.with_suffix(target.suffix + '.download')
    try:
        with urllib.request.urlopen(url, timeout=60) as response, temporary.open('wb') as out:
            if not response.url.startswith('https://'):
                raise ValueError('Secure download required')
            count = 0
            while chunk := response.read(1024 * 1024):
                count += len(chunk)
                if count > 100_000_000:
                    raise ValueError('Unexpectedly large motion asset')
                out.write(chunk)
        actual = hashlib.sha256(temporary.read_bytes()).hexdigest()
        if digest and actual != digest:
            raise ValueError(f'Integrity check failed for {name}')
        temporary.replace(target)
        return target
    finally:
        temporary.unlink(missing_ok=True)


def main():
    if sys.version_info < (3, 11):
        raise SystemExit('Python 3.11 or newer is required.')
    ROOT.mkdir(parents=True, exist_ok=True)
    print('Local non-commercial research evaluation only. Checkpoint terms:', ARCHIVE + 'LICENSE.txt')
    if not python_path().exists():
        venv.create(ROOT / 'venv', with_pip=True)
    subprocess.run([str(python_path()), '-m', 'pip', 'install', '--only-binary=:all:',
        'torch==2.14.1', 'numpy==2.3.5'], check=True)
    for name, (url, digest) in ASSETS.items():
        download(name, url, digest)
    # Retain upstream's full code license beside the pinned module.
    download('SOURCE_LICENSE.txt', f'https://raw.githubusercontent.com/Sachini/ronin/{UPSTREAM}/LICENSE')
    with zipfile.ZipFile(ROOT / 'ronin_resnet.zip') as archive:
        # Inspect names and extract only the checkpoint/config, never executable
        # archive files or paths chosen by the archive.
        entries = [{'name': i.filename, 'bytes': i.file_size} for i in archive.infolist()]
    (ROOT / 'assets.json').write_text(json.dumps({
        'upstreamCommit': UPSTREAM, 'archiveSha256': ASSETS['ronin_resnet.zip'][1],
        'entries': entries, 'researchOnly': True}, indent=2), encoding='utf-8')
    print('Verified local assets:', json.dumps(entries))
    print('Runtime:', python_path())


if __name__ == '__main__':
    main()
