#!/usr/bin/env python3
"""Local GUI-session smoke test. All installed bundles live in a temp folder.
The --no-start option ensures these fixtures never start a server or write user data.
"""
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid
import sys

source = pathlib.Path(sys.argv[1]).resolve()
data_root = pathlib.Path.home() / 'Library/Application Support/WorkBuddy2API'
def snapshot():
    paths = [data_root / 'config.json', *sorted((data_root / 'auths').glob('*'))]
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()}
before = snapshot()
root = pathlib.Path(tempfile.mkdtemp(prefix='wb2api-handoff-')).resolve()
version = '2026.10.20.1700'
spawned = []
try:
    for case in ['success', 'rollback', 'revalidation']:
        parent = root / case
        parent.mkdir()
        target = parent / 'WorkBuddy2API.app'
        shutil.copytree(source, target)
        workspace = parent / ('.WorkBuddy2API-update-' + str(uuid.uuid4()))
        workspace.mkdir(mode=0o700)
        staged = workspace / 'WorkBuddy2API.app'
        shutil.copytree(source, staged)
        info = staged / 'Contents/Info.plist'
        with info.open('rb') as f:
            plist = plistlib.load(f)
        plist['CFBundleShortVersionString'] = version
        with info.open('wb') as f:
            plistlib.dump(plist, f)
        if case == 'rollback':
            bad_source = workspace / 'fail.swift'
            bad_source.write_text('import Foundation\nexit(1)\n')
            subprocess.run(['xcrun', 'swiftc', str(bad_source), '-o', str(staged / 'Contents/MacOS/WorkBuddy2API')], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(staged)], check=True, capture_output=True)
        # Simulate the old app staying alive until the helper acknowledges its plan.
        old = subprocess.Popen(['/bin/sleep', '30'])
        token = str(uuid.uuid4())
        plan = dict(target=str(target), workspace=str(workspace), version=version,
                    oldPID=old.pid, restartService=False, token=token)
        plan_file = workspace / 'plan.json'
        plan_file.write_text(json.dumps(plan))
        helper = subprocess.Popen([str(source / 'Contents/MacOS/WorkBuddy2API'), '--apply-update', str(plan_file)],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(100):
                if (workspace / 'helper-ready').exists():
                    assert (workspace / 'helper-ready').read_text() == token
                    break
                assert helper.poll() is None, 'Helper exited before readiness: ' + helper.stderr.read()
                time.sleep(.1)
            else:
                raise AssertionError('Helper did not acknowledge')
            assert target.exists() and not (workspace / 'backup/WorkBuddy2API.app').exists(), 'Replaced app before old process exited'
            if case == 'revalidation':
                (staged / 'Contents/Resources/wb2api').write_bytes(b'corrupted after helper readiness')
            old.terminate()
            old.wait(timeout=3)
            out, err = helper.communicate(timeout=55)
            if case == 'success':
                assert helper.returncode == 0, err
                receipt = json.loads((workspace / 'ready.json').read_text())
                assert receipt['token'] == token and receipt['version'] == version
                spawned.append(receipt['pid'])
                assert (workspace / 'backup/WorkBuddy2API.app').is_dir()
                assert (workspace / 'result.txt').is_file()
            else:
                assert helper.returncode == 1, err
                assert (workspace / 'rollback.txt').is_file()
                with (target / 'Contents/Info.plist').open('rb') as f:
                    assert plistlib.load(f)['CFBundleShortVersionString'] == 'dev'
                if case == 'rollback':
                    assert (workspace / 'failed/WorkBuddy2API.app').is_dir()
                else:
                    assert not (workspace / 'backup/WorkBuddy2API.app').exists()
            print('PASS: real helper ' + case + ', original app wait + replacement + relaunch verified', flush=True)
        finally:
            if old.poll() is None:
                old.terminate(); old.wait(timeout=3)
            if helper.poll() is None:
                helper.terminate(); helper.wait(timeout=3)
            # These are only test apps under this unique temporary directory.
            rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
            for row in rows:
                parts = row.strip().split(None, 1)
                if len(parts) == 2 and pathlib.Path(parts[1].split(' --', 1)[0]).resolve() == (target / 'Contents/MacOS/WorkBuddy2API').resolve():
                    os.kill(int(parts[0]), signal.SIGTERM)
                    spawned.append(int(parts[0]))
    assert before == snapshot(), 'User config/auth data changed'
    print('PASS: user configuration and account-file hashes unchanged', flush=True)
finally:
    for pid in set(spawned):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(50):
        alive = []
        for pid in set(spawned):
            try:
                os.kill(pid, 0)
                alive.append(pid)
            except ProcessLookupError:
                pass
        if not alive:
            break
        time.sleep(.1)
    for pid in alive:
        os.kill(pid, signal.SIGKILL)
    shutil.rmtree(root)
