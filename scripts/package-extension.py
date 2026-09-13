#!/usr/bin/env python3
"""Package runtime files only, keeping the Chrome extension ID stable."""
import json
import pathlib
import shutil
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parents[1] / 'chrome-extension'
manifest = json.loads((root / 'manifest.json').read_text())
files = {'manifest.json', 'beacon.js', manifest['background']['service_worker']}
for script in manifest.get('content_scripts', []):
    files.update(script.get('js', [])); files.update(script.get('css', []))
files.update(manifest.get('icons', {}).values())
for resource in manifest.get('web_accessible_resources', []):
    files.update(resource.get('resources', []))
action = manifest.get('action', {})
if action.get('default_popup'): files.add(action['default_popup'])
# Popup assets, when present, are all first-party top-level files.
files.update(p.name for p in root.glob('popup.*'))
output = pathlib.Path(sys.argv[1])
if output.suffix == '.zip':
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(files): archive.write(root / name, name)
else:
    output.mkdir(parents=True, exist_ok=True)
    for name in files:
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
print(f'Packaged {len(files)} runtime files in {output}')
