#!/usr/bin/env python3
"""Check required bundle metadata without launching an app."""
import pathlib
import plistlib
import sys

plist_path = pathlib.Path(sys.argv[1])
resources = pathlib.Path(sys.argv[2])
metadata = plistlib.loads(plist_path.read_bytes())
errors = []
icon = metadata.get('CFBundleIconFile', '')
if not icon or not (resources / icon).is_file():
    errors.append('DALI icon is absent or its resource is missing')
if not metadata.get('NSAudioCaptureUsageDescription', '').strip():
    errors.append('System Audio Recording permission description is missing')
if errors:
    for error in errors:
        print('FAIL:', error)
    sys.exit(1)
print('PASS: icon resource and audio-capture permission metadata')
