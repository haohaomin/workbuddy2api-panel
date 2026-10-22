#!/usr/bin/env python3
"""Exercise real helper rollback after launcher crashes, without user data or GUI."""
import json
import itertools
import os
from pathlib import Path
import plistlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

repository = Path(__file__).resolve().parents[2]
sources = [str(repository / 'cmd/macosapp' / name)
           for name in ('UpdateCore.swift', 'UpdateInstaller.swift')]


def compile_swift(source, output, legacy=False):
    inputs = [sources[0], str(repository / 'tests/macos/fixtures/LegacyUpdateInstaller.swift')] if legacy else sources
    subprocess.run(['xcrun', 'swiftc', *inputs, str(source), '-o', str(output)],
                   check=True, capture_output=True)


with tempfile.TemporaryDirectory(prefix='wb2api-process-cleanup-') as temporary:
    root = Path(temporary).resolve()
    entry = root / 'main.swift'
    entry.write_text('import Foundation\nimport Darwin\nexit(UpdateInstaller.apply(CommandLine.arguments[1]))\n')
    compile_swift(entry, root / 'helper')
    compile_swift(entry, root / 'legacy-helper', legacy=True)
    entry.write_text('''import Foundation
import Darwin
if CommandLine.arguments.dropFirst().first == "--run-update-server" {
    UpdateInstaller.runUpdateServer(Array(CommandLine.arguments.dropFirst(2)))
}
if let index = CommandLine.arguments.firstIndex(of: "--update-session") {
    if !CommandLine.arguments.contains("--update-child") {
        exit(UpdateInstaller.supervise(CommandLine.arguments[index + 1]))
    }
    let plan = try UpdateInstaller.load(CommandLine.arguments[index + 1])
    let env = ProcessInfo.processInfo.environment
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--run-update-server", env["WB_AUDIT_PYTHON"]!, "-c",
                       env["WB_AUDIT_BACKEND"]!, plan.directory.path]
    try child.run()
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: plan.directory.appendingPathComponent("backend.json").path) {
        if Date() > deadline { exit(3) }
        Thread.sleep(forTimeInterval: 0.05)
    }
    if !["before-receipt", "timeout"].contains(env["WB_AUDIT_CASE"]!) {
        try UpdateInstaller.writeReceipt(plan, serverPID: child.processIdentifier)
        // Ensure the supervisor forwarded the receipt before simulating a crash.
        while !FileManager.default.fileExists(atPath: plan.receipt.path) {
            if Date() > deadline { exit(4) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
    if ["success", "timeout"].contains(env["WB_AUDIT_CASE"]!) { Thread.sleep(forTimeInterval: 60) }
    _exit(1)
}
exit(0)
''')
    compile_swift(entry, root / 'stub')
    # Hold a real listening socket. The second case also exercises forced cleanup.
    backend = '''import json, os, pathlib, signal, socket, sys, time
if os.environ['WB_AUDIT_CASE'] in ('after-receipt', 'timeout'): signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket(); s.bind(('127.0.0.1', 0)); s.listen()
pathlib.Path(sys.argv[1], 'backend.json').write_text(json.dumps(dict(pid=os.getpid(), port=s.getsockname()[1])))
while True: time.sleep(1)
'''
    cases = list(itertools.product(('helper', 'legacy-helper'), ('before-receipt', 'after-receipt', 'success')))
    cases.append(('legacy-helper', 'timeout'))
    for helper_name, case in cases:
        parent = root / 'cases' / helper_name / case
        target = parent / 'WorkBuddy2API.app'
        workspace = parent / ('.WorkBuddy2API-update-' + str(uuid.uuid4()))
        staged = workspace / 'WorkBuddy2API.app'
        for app, version in ((target, '2026.10.20.100'), (staged, '2026.10.22.100')):
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Resources').mkdir()
            for path in ('Contents/MacOS/WorkBuddy2API', 'Contents/Resources/wb2api'):
                shutil.copy2(root / 'stub', app / path)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
                CFBundleIdentifier='com.workbuddy2api.panel', CFBundleExecutable='WorkBuddy2API',
                CFBundleShortVersionString=version, CFBundlePackageType='APPL', WBUpdaterProtocol=1)))
            subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
        old = subprocess.Popen(['/bin/sleep', '60'])
        # An independent process must survive cleanup of the failed update.
        unrelated = subprocess.Popen(['/bin/sleep', '60'])
        helper = None
        try:
            plan = dict(target=str(target), workspace=str(workspace), version='2026.10.22.100',
                        oldPID=old.pid, restartService=True, token=str(uuid.uuid4()))
            plan_file = workspace / 'plan.json'
            plan_file.write_text(json.dumps(plan))
            env = dict(os.environ, WB_AUDIT_PYTHON=sys.executable,
                       WB_AUDIT_BACKEND=backend, WB_AUDIT_CASE=case)
            helper = subprocess.Popen([str(root / helper_name), str(plan_file)], env=env,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 10
            while not (workspace / 'helper-ready').exists():
                assert helper.poll() is None, helper.communicate()[1]
                assert time.monotonic() < deadline, 'Helper readiness timed out'
                time.sleep(.05)
            old.terminate()
            old.wait(timeout=3)
            _, error = helper.communicate(timeout=55)
            child = json.loads((workspace / 'backend.json').read_text())
            if case == 'success':
                assert helper.returncode == 0, error
                assert (workspace / 'result.txt').exists()
                os.kill(child['pid'], 0)
                assert unrelated.poll() is None
                print('PASS: ' + helper_name + ' successful update keeps its backend alive', flush=True)
                continue
            assert helper.returncode == 1 and '已恢复旧应用' in error, error
            assert plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'] == '2026.10.20.100'
            deadline = time.monotonic() + 3
            while True:
                try:
                    os.kill(child['pid'], 0)
                except ProcessLookupError:
                    break
                assert time.monotonic() < deadline, 'Backend still alive after rollback'
                time.sleep(.05)
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', child['port']))
            assert unrelated.poll() is None, 'Cleanup stopped an unrelated process'
            print('PASS: ' + helper_name + ' crash ' + case + ' releases backend and port; unrelated process survives', flush=True)
        finally:
            for process in (helper, old, unrelated):
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait()
            # The supervisor and GUI have separate process groups.
            receipt = workspace / 'launcher-ready.json'
            if receipt.exists():
                try:
                    os.killpg(json.loads(receipt.read_text())['pid'], signal.SIGKILL)
                except ProcessLookupError:
                    pass
            receipt = workspace / 'ready.json'
            if receipt.exists():
                try:
                    os.kill(json.loads(receipt.read_text())['pid'], signal.SIGTERM)
                except ProcessLookupError:
                    pass
            record = workspace / 'backend.json'
            if record.exists():
                try:
                    os.kill(json.loads(record.read_text())['pid'], signal.SIGKILL)
                except ProcessLookupError:
                    pass
