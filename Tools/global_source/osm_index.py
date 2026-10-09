"""Stream an OSM extract into a disk spatial index, retaining true node identities."""
import json
from pathlib import Path
import sqlite3
import shutil
import tempfile
import osmium
from shapely.geometry import Point, LineString, Polygon, mapping
from common import atomic, rawjson, digest, reserve
from osm_semantics import MapFeatureTransformer

LINEAR={'footpath','bridleway','track','minorRoad','majorRoad','unknownPath','boundary'}
ROUTABLE={'footpath','bridleway','track','minorRoad','majorRoad'}


def _make_index(pbf, target, reserve_gib=40):
    target=Path(target)
    source_sha=digest(pbf)
    receipt=target.with_suffix('.json')
    if target.exists() and receipt.exists() and json.loads(receipt.read_bytes())['sourceSHA256']==source_sha:
        return json.loads(receipt.read_bytes())
    temp=target.with_suffix('.building.sqlite');temp.unlink(missing_ok=True)
    db=sqlite3.connect(temp)
    db.executescript('PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; '
        'PRAGMA cache_size=-262144; '
        'CREATE TABLE features(id INTEGER PRIMARY KEY, kind TEXT, payload TEXT); '
        'CREATE VIRTUAL TABLE boxes USING rtree(id,minx,maxx,miny,maxy);')
    classify=MapFeatureTransformer(); stats={'features':0,'invalidGeometries':0,'objects':0}
    def insert(kind, geometry, ident, properties, route=None):
        if geometry.is_empty: return
        if not geometry.is_valid:
            # Invalid multipolygons are reported rather than silently repaired.
            stats['invalidGeometries']+=1;return
        stats['features']+=1;i=stats['features'];x0,y0,x1,y1=geometry.bounds
        payload=dict(id=ident,kind=kind,geometry=mapping(geometry),properties=properties)
        if route is not None:payload['route']=route
        db.execute('INSERT INTO features VALUES(?,?,?)',(i,kind,rawjson(payload).decode()))
        db.execute('INSERT INTO boxes VALUES(?,?,?,?,?)',(i,x0,x1,y0,y1))
        if i%10000==0:db.commit();reserve(temp.parent,reserve_gib)
    # Area assembler joins relation members and assigns inner rings correctly.
    processor=osmium.FileProcessor(str(pbf)).with_locations('flex_mem').with_areas()
    processor=processor.with_filter(osmium.filter.KeyFilter('highway','building','natural','place','waterway','landuse','landcover','boundary','designation'))
    for obj in processor:
        stats['objects']+=1
        if stats['objects']%500000==0:
            print(json.dumps(dict(stage='indexing-osm',**stats)),flush=True)
            reserve(temp.parent,reserve_gib)
        tags=dict(obj.tags);kind=classify.classify_kind(tags)
        if kind is None:continue
        props=dict(name=tags.get('name',''),access=classify.classify_access(tags),surface=classify.classify_surface(tags))
        try:
            if obj.is_node() and kind in {'peak','settlement'}:
                if obj.location.valid():insert(kind,Point(obj.lon,obj.lat),f'osm:node:{obj.id}',props)
            elif obj.is_way() and (kind in LINEAR or (kind=='water' and not obj.is_closed())):
                if len(obj.nodes)<2 or any(not n.location.valid() for n in obj.nodes):
                    stats['invalidGeometries']+=1;continue
                coords=[(n.lon,n.lat) for n in obj.nodes]
                route=None
                if kind in ROUTABLE and tags.get('highway') not in {'motorway','motorway_link','trunk','trunk_link'} and tags.get('area')!='yes':
                    # Only explicit pedestrian one-way restrictions affect walking.
                    direction=tags.get('oneway:foot','no')
                    route=dict(nodes=[n.ref for n in obj.nodes],coordinates=coords,bidirectional=direction not in {'yes','1','-1'},reverse=direction=='-1')
                insert(kind,LineString(coords),f'osm:way:{obj.id}',props,route)
            elif obj.is_area() and kind not in LINEAR and kind not in {'peak','settlement'}:
                for index,outer in enumerate(obj.outer_rings()):
                    geometry=Polygon([(n.lon,n.lat) for n in outer],
                        [[(n.lon,n.lat) for n in ring] for ring in obj.inner_rings(outer)])
                    insert(kind,geometry,f'osm:{"way" if obj.from_way() else "relation"}:{obj.orig_id()}:{index}',props)
        except (osmium.InvalidLocationError,ValueError):stats['invalidGeometries']+=1
    db.commit();db.close();temp.replace(target)
    result=dict(sourceSHA256=source_sha,**stats)
    atomic(receipt,rawjson(result));return result


def make_index(pbf,target,reserve_gib=40):
    target=Path(target);receipt=target.with_suffix('.json')
    if target.exists() and receipt.exists():
        record=json.loads(receipt.read_bytes())
        if record['sourceSHA256']==digest(pbf):return record
    # SQLite's random index writes are expensive on the nearly full external HDD.
    # Stage only this replaceable intermediate on the SSD, keeping 8 GiB free.
    with tempfile.TemporaryDirectory(prefix='ridge-global-index-') as directory:
        local=Path(directory)/'index.sqlite'
        reserve(directory,8)
        record=_make_index(pbf,local,reserve_gib=8)
        reserve(target.parent,reserve_gib,local.stat().st_size)
        incoming=target.with_suffix('.building.sqlite')
        shutil.copyfile(local,incoming);incoming.replace(target)
        atomic(receipt,rawjson(record))
        return record


def query(db_path, bounds, halo=.003):
    b=bounds
    with sqlite3.connect(f'file:{db_path}?mode=ro',uri=True) as db:
        return [json.loads(x[0]) for x in db.execute(
            'SELECT payload FROM features JOIN boxes USING(id) WHERE maxx>=? AND minx<=? AND maxy>=? AND miny<=?',
            (b['minLongitude']-halo,b['maxLongitude']+halo,b['minLatitude']-halo,b['maxLatitude']+halo))]
