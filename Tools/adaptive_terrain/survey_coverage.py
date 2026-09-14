"""Conservative acceptance against checksum-locked official survey footprints.

The projected envelope of the entire chunk, with 2 m support on all sides,
 must be covered by the union of survey polygons. This deliberately sacrifices
some boundary chunks rather than accepting interpolated samples beyond a survey.
"""
import hashlib
import json
from pathlib import Path
from pyproj import Transformer
from shapely import prepare, make_valid
from shapely.geometry import shape, box
from shapely.ops import unary_union
from shapely.strtree import STRtree

EA_METADATA_ID = '13787b9a-26a4-4775-8523-806d13af58fc'


def requires_ea_coverage(manifest):
    source = manifest.get('source', {})
    return (source.get('metadataID') == EA_METADATA_ID
            or source.get('coverageID', '').startswith(EA_METADATA_ID + '__')
            or manifest.get('sourceKey') == 'england')


class SurveyCoverage:
    margin_metres = 2

    def __init__(self, root):
        root = Path(root)
        raw_index = (root / 'index.json').read_bytes()
        index = json.loads(raw_index)
        if index['crs'] != 'EPSG:27700':
            raise ValueError('Expected British National Grid survey footprints')
        polygons, ids = [], set()
        repaired = 0
        for part in index['parts']:
            path = Path(part['path'])
            if path.name != str(path):
                raise ValueError('Invalid footprint part path')
            raw = (root / path).read_bytes()
            if len(raw) != part['byteCount'] or hashlib.sha256(raw).hexdigest() != part['sha256']:
                raise ValueError('Survey footprint checksum mismatch')
            data = json.loads(raw)
            if data['crs']['properties']['name'] != 'EPSG:27700' or len(data['features']) != part['count']:
                raise ValueError('Incomplete or misprojected footprint part')
            for feature in data['features']:
                if feature['id'] in ids:
                    raise ValueError('Duplicate footprint feature')
                ids.add(feature['id'])
                geometry = shape(feature['geometry'])
                if geometry.is_empty or geometry.geom_type not in ('Polygon', 'MultiPolygon'):
                    raise ValueError('Invalid survey polygon')
                if not geometry.is_valid:
                    geometry = make_valid(geometry)
                    if geometry.geom_type == 'GeometryCollection':
                        geometry = unary_union([g for g in geometry.geoms if g.geom_type in ('Polygon','MultiPolygon')])
                    if geometry.is_empty or not geometry.is_valid:
                        raise ValueError('Cannot repair survey polygon')
                    repaired += 1
                polygons.append(geometry)
        if len(ids) != index['featureCount']:
            raise ValueError('Incomplete survey catalogue')
        self.polygons = polygons
        self.tree = STRtree(polygons)
        self.project = Transformer.from_crs(4326, 27700, always_xy=True)
        self.provenance = dict(source=index['source'], indexSHA256=hashlib.sha256(raw_index).hexdigest(),
                               featureCount=len(ids), repairedGeometries=repaired, geometryPolicy='GEOS make_valid linework; preserve original edges and even-odd holes, no outward buffering.', editingInfo=index['editingInfo'],
                               attribution=index['attribution'], license=index['license'],
                               policy='Full projected chunk envelope plus 2 m interpolation support must lie inside the union of official 2022 1 m DTM footprints.')

    def envelope(self, bounds):
        west, south, east, north = self.project.transform_bounds(
            bounds['minLongitude'], bounds['minLatitude'],
            bounds['maxLongitude'], bounds['maxLatitude'], densify_pts=21)
        margin = self.margin_metres
        return box(west-margin, south-margin, east+margin, north+margin)

    def for_bounds(self, bounds):
        envelope = self.envelope(bounds)
        indices = self.tree.query(envelope)
        coverage = unary_union([self.polygons[i] for i in indices])
        prepare(coverage)
        return coverage

    def accepts(self, coverage, bounds):
        return bool(coverage.covers(self.envelope(bounds)))
