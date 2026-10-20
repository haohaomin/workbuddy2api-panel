#!/usr/bin/env python3
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

script = pathlib.Path(__file__).resolve().parents[2] / 'scripts/macos/update-manifest.py'
version = '2026.10.20.1700'
with tempfile.TemporaryDirectory(prefix='wb2api-manifest-test-') as tmp:
    root = pathlib.Path(tmp)
    names = [f'wb2api-panel-{version}-darwin-{arch}-update.zip' for arch in ['arm64', 'amd64']]
    for name in names:
        (root / name).write_bytes(name.encode())
    def run(value=version):
        return subprocess.run([sys.executable, str(script), value, str(root)], capture_output=True)
    assert run().returncode == 0
    manifest = json.loads((root / 'macos-update.json').read_text())
    assert manifest['schema'] == 1 and manifest['release']['tag_name'] == 'v' + version
    for asset in manifest['release']['assets']:
        archive = root / asset['name']
        assert asset['digest'] == 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()
        assert asset['size'] == archive.stat().st_size
        assert asset['browser_download_url'].startswith('https://github.com/haohaomin/workbuddy2api-panel/releases/download/v' + version + '/')
    assert run('../bad-version').returncode != 0
    (root / names[1]).unlink()
    assert run().returncode != 0
    (root / names[1]).write_bytes(b'fixture')
    (root / 'duplicate').mkdir()
    (root / 'duplicate' / names[0]).write_bytes(b'fixture')
    assert run().returncode != 0
print('PASS: manifest hashes, URLs, architectures and invalid-input rejection')
