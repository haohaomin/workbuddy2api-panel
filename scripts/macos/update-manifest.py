#!/usr/bin/env python3
"""Publish fixed-repository update metadata without using GitHub API quotas."""
import hashlib
import json
import pathlib
import re
import sys

version, root_name = sys.argv[1:]
if not re.fullmatch(r'\d{4}\.\d{1,2}\.\d{1,2}\.\d{3,4}', version):
    raise SystemExit('Invalid timestamp release version')
root = pathlib.Path(root_name)
assets = []
for arch in ('arm64', 'amd64'):
    name = f'wb2api-panel-{version}-darwin-{arch}-update.zip'
    matches = list(root.rglob(name))
    if len(matches) != 1:
        raise SystemExit(f'Expected exactly one {name}, found {len(matches)}')
    archive = matches[0]
    assets.append(dict(name=name, size=archive.stat().st_size, state='uploaded',
                       digest='sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest(),
                       browser_download_url=f'https://github.com/haohaomin/workbuddy2api-panel/releases/download/v{version}/{name}'))
manifest = dict(schema=1, release=dict(tag_name='v' + version, draft=False, prerelease=False, assets=assets))
(root / 'macos-update.json').write_text(json.dumps(manifest, indent=2) + '\n')
