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
names = [f'wb2api-panel-{version}-darwin-{arch}-update.zip' for arch in ('arm64', 'amd64')]
names += [f'wb2api-panel-{version}-{platform}-{arch}.zip' for platform in ('linux', 'windows') for arch in ('arm64', 'amd64')]
for name in names:
    matches = list(root.rglob(name))
    if len(matches) != 1:
        raise SystemExit(f'Expected exactly one {name}, found {len(matches)}')
    archive = matches[0]
    assets.append(dict(name=name, size=archive.stat().st_size, state='uploaded',
                       digest='sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest(),
                       browser_download_url=f'https://github.com/haohaomin/workbuddy2api-panel/releases/download/v{version}/{name}'))
manifest = dict(schema=1, release=dict(tag_name='v' + version, draft=False, prerelease=False,
                html_url=f'https://github.com/haohaomin/workbuddy2api-panel/releases/tag/v{version}', assets=assets))
(root / 'update.json').write_text(json.dumps(manifest, indent=2) + '\n')
# Keep the legacy filename and Mac-only assets for already-installed clients.
manifest['release']['assets'] = [asset for asset in assets if '-darwin-' in asset['name']]
(root / 'macos-update.json').write_text(json.dumps(manifest, indent=2) + '\n')
