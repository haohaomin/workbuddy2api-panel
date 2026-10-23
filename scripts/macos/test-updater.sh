#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Test copies only: never replace the user's installed app or data.
app="${1:-dist/WorkBuddy2API.app}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/wb2api-updater-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
ditto "$app" "$test_dir/WorkBuddy2API.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 2026.10.20.1700' "$test_dir/WorkBuddy2API.app/Contents/Info.plist"
codesign --force --sign - "$test_dir/WorkBuddy2API.app"
python3 scripts/macos/package-update.py "$test_dir/WorkBuddy2API.app" "$test_dir/update.zip"
python3 - "$test_dir" <<'PY'
import pathlib, struct, sys, zipfile, warnings
root = pathlib.Path(sys.argv[1])
for case, name in [('traversal', 'WorkBuddy2API.app/../../outside'), ('absolute', '/tmp/outside'), ('foreign', 'Other.app/file')]:
    with zipfile.ZipFile(root / (case + '.zip'), 'w') as z:
        z.writestr(name, b'bad')
with zipfile.ZipFile(root / 'symlink.zip', 'w') as z:
    entry = zipfile.ZipInfo('WorkBuddy2API.app/link')
    entry.create_system = 3
    entry.external_attr = 0o120777 << 16
    z.writestr(entry, b'/tmp')
with warnings.catch_warnings():
    warnings.simplefilter('ignore')
    with zipfile.ZipFile(root / 'duplicate.zip', 'w') as z:
        z.writestr('WorkBuddy2API.app/file', b'a')
        z.writestr('WorkBuddy2API.app/FILE', b'b')
with zipfile.ZipFile(root / 'local-header.zip', 'w') as z:
    z.writestr('WorkBuddy2API.app/file', b'a')
p = root / 'local-header.zip'
b = bytearray(p.read_bytes())
b[30] = ord('X')
p.write_bytes(b)
PY
xcrun swiftc -swift-version 5 cmd/macosapp/UpdateCore.swift cmd/macosapp/UpdateInstaller.swift \
  tests/macos/UpdateTests.swift -o "$test_dir/tests"
"$test_dir/tests" "$test_dir/WorkBuddy2API.app" "$test_dir/update.zip"

xcrun swiftc -swift-version 5 -framework AppKit cmd/macosapp/UpdateCore.swift \
  cmd/macosapp/UpdateInstaller.swift cmd/macosapp/UpdateController.swift tests/macos/ControllerTests.swift -o "$test_dir/controller-tests"
"$test_dir/controller-tests"

python3 tests/macos/test-manifest.py
python3 tests/macos/test-process-cleanup.py
