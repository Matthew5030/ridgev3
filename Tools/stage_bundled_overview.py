#!/usr/bin/env python3
"""Build a compact overview inside the app product; preserve original assets."""
import json
import os
import shutil
import tempfile
from pathlib import Path

project = Path(os.environ['SRCROOT'])
source = project / 'ridge v3/Resources/WorldAtlas.bundle'
product = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']
destination = product / 'WorldAtlas.bundle'
maximum = int(os.environ.get('RIDGE_BUNDLED_ATLAS_MAX_ZOOM', '11'))
if not 5 <= maximum <= 13 or not product.name.endswith('.app'):
    raise SystemExit('Invalid bundled overview build configuration')
index = json.loads((source / 'index.json').read_text())
tiles = [name for name in index['tiles'] if int(name.split('-')[0][1:]) <= maximum]
if any('/' in name or not name.endswith('.jpg') for name in tiles):
    raise SystemExit('Invalid bundled overview filename')
product.mkdir(parents=True, exist_ok=True)
staging = Path(os.environ['DERIVED_FILE_DIR']) / 'RidgeBundledOverview'
staging.mkdir(parents=True, exist_ok=True)
temporary = Path(tempfile.mkdtemp(prefix='overview-', dir=staging))
try:
    for name in tiles:
        shutil.copyfile(source / name, temporary / name)
    index['tiles'] = tiles
    index['maxZoom'] = maximum
    index['quality'] = 'Preinstalled UK overview'
    (temporary / 'index.json').write_text(json.dumps(index, separators=(',', ':')) + '\n')
    if destination.exists():
        shutil.rmtree(destination)
    temporary.rename(destination)
except BaseException:
    shutil.rmtree(temporary, ignore_errors=True)
    raise
print(f'Bundled UK overview: {len(tiles)} tiles, maximum zoom {maximum}; original source assets preserved')
