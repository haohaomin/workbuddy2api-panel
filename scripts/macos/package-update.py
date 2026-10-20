#!/usr/bin/env python3
"""Create the restricted ZIP format accepted by the macOS updater."""
import pathlib
import sys
import zipfile

app = pathlib.Path(sys.argv[1])
archive = pathlib.Path(sys.argv[2])
if app.name != "WorkBuddy2API.app" or not app.is_dir():
    raise SystemExit("Expected WorkBuddy2API.app")
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            raise SystemExit(f"Symlinks are not supported: {path}")
        if path.is_file():
            output.write(path, pathlib.Path(app.name) / path.relative_to(app))
