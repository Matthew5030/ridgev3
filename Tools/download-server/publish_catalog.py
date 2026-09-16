#!/usr/bin/env python3
"""Publish only completed sources. Does not read or expose original LiDAR."""
import argparse
import hashlib
import json
from pathlib import Path
import re

p = argparse.ArgumentParser()
p.add_argument('directory', type=Path)
a = p.parse_args()
# Adaptive publication is explicit and immutable. Never accidentally replace it
# with a scan of legacy source folders retained for rollback.
current = a.directory / 'catalog.json'
if current.exists() and json.loads(current.read_bytes()).get('schemaVersion') == 2:
    raise SystemExit('Adaptive catalogue is active; use adaptive_terrain/publish_eryri_app.py.')
entries = []
for path in sorted(a.directory.glob('*/pack.json')):
    raw = path.read_bytes(); m = json.loads(raw)
    if not m.get('tiledTerrain'): continue
    if not re.fullmatch(r'[a-zA-Z0-9_-]+', m['id']) or m['id'] != path.parent.name:
        raise ValueError(f'Invalid source identifier: {path}')
    entries.append(dict(id=m['id'], name=m['name'], byteCount=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
next_path = a.directory / '.catalog-next.json'
next_path.write_text(json.dumps(dict(schemaVersion=1, sources=entries), separators=(',', ':')) + '\n')
next_path.replace(a.directory / 'catalog.json')
print(f'Published {len(entries)} sources')
