#!/usr/bin/env python3
"""Prepare Apple-hosted metadata and indexed terrain packs without source edits.

The native ba-package fileSource/fileDestination selectors read actual resolved
files, not symlinks. Only small metadata snapshots and completed .aar archives
are written to the output directory. Package the library manifest last.
"""
import argparse
import copy
import hashlib
import json
import math
import os
import re
import subprocess
from collections import defaultdict
from pathlib import Path

LIBRARY_ID = 'ridge-map-library'


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def group_for(source, x_stride, y_stride):
    bounds = source['bounds']
    longitude = (bounds['minLongitude'] + bounds['maxLongitude']) / 2
    latitude = (bounds['minLatitude'] + bounds['maxLatitude']) / 2
    x = int((longitude + 180) / 360 * 1024)
    y = int((1 - math.asinh(math.tan(math.radians(latitude))) / math.pi) / 2 * 1024)
    return f'{x // x_stride:03}-{y // y_stride:03}'


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, separators=(',', ':'), ensure_ascii=False) + '\n')


def manifest(output, pack_id, files, essential=False):
    policy = {'essential': {'installationEventTypes': ['firstInstallation', 'subsequentUpdate']}} if essential else {'onDemand': {}}
    value = {'assetPackID': pack_id, 'downloadPolicy': policy, 'platforms': ['iOS'],
             'sourceRoot': os.path.relpath('/', output / 'manifests'),
             'fileSelectors': [{'fileSource': str(Path(item['file']).relative_to('/')),
                                'fileDestination': item['path']} for item in files]}
    write_json(output / 'manifests' / (pack_id + '.json'), value)


def create_plan(args):
    output = args.output.resolve()
    library_id = args.library_pack_id
    if (output / 'plan.json').exists():
        raise SystemExit('Use --package-only to resume an existing plan, or choose a new output directory')
    root = args.root.resolve(strict=True)
    original = (root / 'catalog.json').read_bytes()
    catalog = json.loads(original)
    if args.section:
        selected = set(args.section)
        catalog['sources'] = [s for s in catalog['sources'] if s['id'] in selected]
        if selected != {s['id'] for s in catalog['sources']}:
            raise ValueError('One or more requested sections are absent from the catalogue')
    catalog['regionArchives'] = []
    catalog['regionArchiveGroups'] = []
    catalog['revision'] += '-apple-' + args.namespace
    snapshots = output / 'metadata'
    groups = defaultdict(list)
    sections = {}
    packed_bytes = metadata_bytes = 0
    for n, source in enumerate(catalog['sources'], 1):
        source_path = root / source['path']
        world = json.loads(source_path.read_bytes())
        if world['id'] != source['id']:
            raise ValueError('Section identity mismatch: ' + source['id'])
        # The section pack contains the current connected routing graph.
        # Make its source metadata agree instead of referencing the old graph.
        world['graph'] = source['routing']
        destination = 'world/' + source['path']
        metadata_file = snapshots / destination
        write_json(metadata_file, world)
        pack_file = (source_path.parent / source['pack']['file']).resolve(strict=True)
        if not pack_file.is_file() or pack_file.stat().st_size != source['pack']['byteCount']:
            raise ValueError('Section pack size mismatch: ' + source['id'])
        meta_id = f'ridge-{args.namespace}-metadata-{group_for(source, 6, 6)}'
        terrain_id = f'ridge-{args.namespace}-terrain-{group_for(source, 2, 3)}'
        pack_path = str(Path(destination).parent / source['pack']['file'])
        meta_hash = digest(metadata_file)
        groups[meta_id].append({'file': str(metadata_file), 'path': destination,
                               'bytes': metadata_file.stat().st_size, 'sha256': meta_hash})
        groups[terrain_id].append({'file': str(pack_file), 'path': pack_path,
                                  'bytes': source['pack']['byteCount'], 'sha256': source['pack']['sha256'],
                                  'sourceID': source['id'], 'required': [
                                      {'sha256': asset['sha256'], 'byteCount': asset['byteCount']}
                                      for asset in [world['overview'], world['graph']] + [
                                          tile[k] for tile in world['tiles'] for k in ('mesh', 'map', 'background') if k in tile]]})
        sections[source['id']] = {'metadataPack': meta_id, 'terrainPack': terrain_id,
                                 'metadataPath': destination, 'metadataSHA256': meta_hash,
                                 'packPath': pack_path, 'pack': source['pack']}
        packed_bytes += source['pack']['byteCount']
        metadata_bytes += metadata_file.stat().st_size
        if n % 50 == 0:
            print(json.dumps({'plannedSections': n, 'totalSections': len(catalog['sources'])}), flush=True)
    if len(groups) + 1 > 190 or packed_bytes + metadata_bytes > 180_000_000_000:
        raise ValueError('Publication exceeds reserved Apple pack-count/storage limits')
    catalog_file = snapshots / 'world/catalog.json'
    write_json(catalog_file, catalog)
    library = {'schemaVersion': 1, 'revision': catalog['revision'], 'catalogPath': 'world/catalog.json',
               'catalogSHA256': digest(catalog_file), 'sections': sections,
               'downloadBytes': {pack: sum(f['bytes'] for f in files) for pack, files in groups.items()}}
    library_file = snapshots / 'RidgeMaps/library.json'
    write_json(library_file, library)
    if library_id in groups:
        raise ValueError('Reserved library ID collides with a metadata or terrain group')
    groups[library_id] = [{'file': str(catalog_file), 'path': 'world/catalog.json',
                          'bytes': catalog_file.stat().st_size, 'sha256': digest(catalog_file)},
                         {'file': str(library_file), 'path': 'RidgeMaps/library.json',
                          'bytes': library_file.stat().st_size, 'sha256': digest(library_file)}]
    for pack, files in groups.items():
        manifest(output, pack, files, essential=pack == library_id)
    if (root / 'catalog.json').read_bytes() != original:
        raise ValueError('Source catalogue changed while preparing the publication')
    plan = {'schemaVersion': 1, 'sourceRoot': str(root), 'sourceCatalogSHA256': hashlib.sha256(original).hexdigest(),
            'libraryPackID': library_id, 'sections': len(sections), 'assetPackCount': len(groups), 'sectionPackBytes': packed_bytes,
            'metadataBytes': metadata_bytes, 'sourceModified': False, 'groups': dict(groups)}
    write_json(output / 'plan.json', plan)
    print(json.dumps({k: v for k, v in plan.items() if k != 'groups'}, indent=2), flush=True)


def package(output, selected):
    plan = json.loads((output / 'plan.json').read_text())
    state_file = output / 'packaged.json'
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    archives = output / 'archives'
    archives.mkdir(exist_ok=True)
    groups = plan['groups']
    library_id = plan.get('libraryPackID', LIBRARY_ID)
    keys = sorted(k for k in groups if k != library_id and (not selected or k in selected))
    if not selected or library_id in selected:
        keys.append(library_id)
    for pack_id in keys:
        if pack_id == library_id:
            # Freeze actual compressed download sizes after packaging payloads.
            library_file = output / 'metadata/RidgeMaps/library.json'
            library = json.loads(library_file.read_text())
            for key in library['downloadBytes']:
                if key in state:
                    library['downloadBytes'][key] = state[key]['bytes']
            write_json(library_file, library)
            groups[library_id][1].update(bytes=library_file.stat().st_size, sha256=digest(library_file))
            manifest(output, pack_id, groups[pack_id], essential=True)
        files = groups[pack_id]
        fingerprint = hashlib.sha256(json.dumps([(f['path'], f['sha256']) for f in files]).encode()).hexdigest()
        archive = archives / (pack_id + '.aar')
        if state.get(pack_id, {}).get('fingerprint') == fingerprint and archive.exists() and digest(archive) == state[pack_id]['sha256']:
            continue
        for item in files:
            path = Path(item['file'])
            if path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
                raise ValueError('File changed since publication plan: ' + item['path'])
            if 'required' in item:
                with path.open('rb') as stream:
                    if stream.read(8) != b'RIDGEPK1':
                        raise ValueError('Invalid section pack: ' + item['path'])
                    count = int.from_bytes(stream.read(4), 'little')
                    if not 0 < count <= 2_000_000:
                        raise ValueError('Invalid section index length')
                    index = json.loads(stream.read(count))
                entries = {(e['sha256'], e['byteCount']) for e in index['entries']}
                if index['sourceID'] != item['sourceID'] or any((a['sha256'], a['byteCount']) not in entries for a in item['required']):
                    raise ValueError('Section pack is missing current terrain/routing assets: ' + item['sourceID'])
        temporary = archives / (pack_id + '.partial.aar')
        subprocess.run(['xcrun', 'ba-package', 'package', str(output / 'manifests' / (pack_id + '.json')),
                        '--output-path', str(temporary), '--quiet'], check=True)
        temporary.replace(archive)
        state[pack_id] = {'fingerprint': fingerprint, 'bytes': archive.stat().st_size, 'sha256': digest(archive)}
        write_json(state_file, state)
        print(json.dumps({'packaged': pack_id, 'bytes': state[pack_id]['bytes'], 'completed': len(state), 'total': len(groups)}), flush=True)
    write_json(output / 'plan.json', plan)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('/Volumes/MLB_EXT_4TB/Ridge Sources/world-v1-2026-10-04'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--namespace', default='uk-v1')
    parser.add_argument('--library-pack-id', default=LIBRARY_ID)
    parser.add_argument('--section', action='append')
    parser.add_argument('--package', action='store_true')
    parser.add_argument('--package-only', action='store_true')
    parser.add_argument('--pack-id', action='append')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9-]{1,32}', args.namespace):
        parser.error('Invalid publication namespace')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    if not args.package_only:
        create_plan(args)
    if args.package or args.package_only:
        package(args.output, set(args.pack_id or []))


if __name__ == '__main__':
    main()
