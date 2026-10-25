"""Compact missing-tile rectangles for catalogue-only coverage checks."""
import json
from pathlib import Path


def missing_terrain(manifest):
    columns, rows = manifest['columns'], manifest['rows']
    if not (1 <= columns <= 16 and 1 <= rows <= 16):
        raise ValueError('Invalid coverage dimensions')
    present = {(tile['column'], tile['row']) for tile in manifest['tiles']}
    if len(present) != len(manifest['tiles']) or any(
            not (0 <= x < columns and 0 <= y < rows) for x, y in present):
        raise ValueError('Invalid coverage grid')
    rectangles, active = [], {}
    for y in range(rows):
        runs = []
        x = 0
        while x < columns:
            if (x, y) in present:
                x += 1
                continue
            start = x
            while x < columns and (x, y) not in present:
                x += 1
            runs.append((start, x))
        next_active = {}
        for run in runs:
            rect = active.pop(run, [run[0], y, run[1], y])
            rect[3] = y + 1
            next_active[run] = rect
        rectangles.extend(active.values())
        active = next_active
    rectangles.extend(active.values())
    b = manifest['bounds']
    dx = (b['maxLongitude'] - b['minLongitude']) / columns
    dy = (b['maxLatitude'] - b['minLatitude']) / rows
    return [dict(minLongitude=b['minLongitude'] + x0*dx,
                 maxLongitude=b['minLongitude'] + x1*dx,
                 minLatitude=b['maxLatitude'] - y1*dy,
                 maxLatitude=b['maxLatitude'] - y0*dy)
            for x0, y0, x1, y1 in rectangles]


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('world', type=Path)
    args = parser.parse_args()
    path = args.world / 'catalog.json'
    original = path.read_bytes()
    catalog = json.loads(original)
    for entry in catalog['sources']:
        manifest = json.loads((args.world / entry['path']).read_bytes())
        if manifest['id'] != entry['id'] or len(manifest['tiles']) != entry['tileCount']:
            raise ValueError('Catalogue does not match manifest')
        entry['missingTerrain'] = missing_terrain(manifest)
    data = json.dumps(catalog, separators=(',', ':'), allow_nan=False).encode()
    if len(data) >= 16_000_000:
        raise ValueError('Catalogue exceeds app limit')
    backup = path.with_name('catalog.before-coverage.json')
    if not backup.exists():
        backup.write_bytes(original)
    temporary = path.with_suffix('.coverage.tmp')
    temporary.write_bytes(data)
    temporary.replace(path)
    print(f"Updated {len(catalog['sources'])} coverage entries; {len(data):,} bytes. Terrain assets unchanged.")
