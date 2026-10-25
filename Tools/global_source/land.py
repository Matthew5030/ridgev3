"""Conservative planning mask, not a claim of detailed coastline accuracy."""
import io
from pathlib import Path
import zipfile
import shapefile
from shapely.geometry import shape
from shapely import prepare
from shapely.strtree import STRtree
from shapely.ops import unary_union
from common import download,atomic,rawjson,digest


class Land:
    def __init__(self, geometries):
        geometries=[part for g in geometries for part in (g.geoms if g.geom_type=='MultiPolygon' else [g])]
        prepare(geometries)
        self.geometries=geometries
        self.tree=STRtree(geometries)

    @classmethod
    def load(cls,inputs,reserve_gib):
        url='https://naciscdn.org/naturalearth/10m/physical/ne_10m_land.zip'
        path=download(url,Path(inputs)/'ne_10m_land.zip',reserve_gib,maximum=20*1024**2)
        atomic(path.with_suffix('.provenance.json'),rawjson(dict(url=url,sha256=digest(path),license='Public domain',purpose='Conservative job planning only; coasts and small islands require a later pass')))
        with zipfile.ZipFile(path) as z:
            with shapefile.Reader(shp=io.BytesIO(z.read('ne_10m_land.shp')),shx=io.BytesIO(z.read('ne_10m_land.shx')),dbf=io.BytesIO(z.read('ne_10m_land.dbf'))) as reader:
                geometries=[shape(s.__geo_interface__) for s in reader.shapes()]
        if any(not g.is_valid for g in geometries):raise ValueError('Invalid planning land mask')
        return cls(geometries)

    def intersects(self,rectangle):
        return any(self.geometries[i].intersects(rectangle) for i in self.tree.query(rectangle))

    def covers(self,rectangle):
        matches=self.tree.query(rectangle)
        if not len(matches):return False
        pieces=[self.geometries[i] for i in matches]
        if any(g.covers(rectangle) for g in pieces):return True
        return unary_union(pieces).covers(rectangle)
