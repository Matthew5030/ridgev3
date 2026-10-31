#!/usr/bin/env python3
"""Stage the prepared starter bundle into the built app, before code signing."""
import json, os, shutil, subprocess
from pathlib import Path
project=Path(os.environ['SRCROOT'])
source=Path(os.environ.get('RIDGE_OFFLINE_MAPS_BUNDLE',str(project.parent/'ReleaseBuilds/offline-starter/OfflineMaps.bundle')))
product=Path(os.environ['TARGET_BUILD_DIR'])/os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH']
if not (source/'index.json').is_file() or product.suffix!='.app':raise SystemExit('Prepare OfflineMaps.bundle with Tools/prepare_offline_starter.py; set RIDGE_OFFLINE_MAPS_BUNDLE to its path.')
index=json.loads((source/'index.json').read_text())
if index.get('schemaVersion')!=1 or len(index.get('sections',{}))!=282:raise SystemExit('Unexpected starter bundle selection')
destination=product/'OfflineMaps.bundle'
if destination.exists():shutil.rmtree(destination)
# APFS clones avoid duplicating gigabytes in every local archive/build.
result=subprocess.run(['cp','-cR',str(source),str(destination)],capture_output=True)
if result.returncode:
    if destination.exists():shutil.rmtree(destination)
    shutil.copytree(source,destination)
print(f'Staged offline starter maps: {len(index["sections"])} sections')
