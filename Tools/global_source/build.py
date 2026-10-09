"""Publish source-compatible adaptive/vector packs from a global DEM and OSM index."""
import concurrent.futures
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib
import numpy as np
import contourpy
from shapely.geometry import shape,box,LineString,Point
from shapely.ops import transform
from shapely.strtree import STRtree
from common import atomic,rawjson,digest,reserve,distance,REVISION
from terrain import Surface,quantize
from osm_index import query

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'adaptive_terrain'))
from compact_codec import CompactCodec


def toolchain(root):
    root=Path(root);root.mkdir(parents=True,exist_ok=True)
    native=Path(__file__).resolve().parents[1]/'adaptive_terrain'
    sources=[native/'park_mesh.cpp',native/'compact_mesh.cpp']
    signature=hashlib.sha256(b''.join(x.read_bytes() for x in sources)).hexdigest()
    receipt=root/'toolchain.json'
    if not receipt.exists() or json.loads(receipt.read_bytes())['sha256']!=signature:
        subprocess.run(['clang++','-O3','-std=c++17',str(sources[0]),'-o',str(root/'park_mesh')],check=True)
        subprocess.run(['clang++','-O3','-std=c++17','-dynamiclib',str(sources[1]),'-o',str(root/'libridge_compact_mesh.dylib')],check=True)
        atomic(receipt,rawjson(dict(sha256=signature)))
    return root


def subbounds(b,c,r,n=4):
    dx=(b['maxLongitude']-b['minLongitude'])/n;dy=(b['maxLatitude']-b['minLatitude'])/n
    return dict(minLongitude=b['minLongitude']+c*dx,maxLongitude=b['minLongitude']+(c+1)*dx,
                maxLatitude=b['maxLatitude']-r*dy,minLatitude=b['maxLatitude']-(r+1)*dy)


def node_id(key):
    # Keep OSM identities exact; synthetic border junctions use a separate namespace.
    if key.startswith('node:'):return int(key[5:])
    return -1-int(hashlib.sha256(key.encode()).hexdigest()[:13],16)


def routing(features,b,surface):
    """Clip real OSM segments with shared deterministic boundary junction IDs."""
    boundary=box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])
    nodes={};edges=[];seen=set()
    for f in features:
        route=f.get('route')
        if not route:continue
        coords=route['coordinates'];ids=route['nodes']
        for index,(a,z) in enumerate(zip(coords,coords[1:])):
            if a==z:continue
            clipped=LineString([a,z]).intersection(boundary)
            if clipped.is_empty or clipped.geom_type!='LineString' or clipped.length==0:continue
            ends=[list(clipped.coords[0]),list(clipped.coords[-1])];made=[]
            for point in ends:
                if distance(point,a)<.001:key=f'node:{ids[index]}'
                elif distance(point,z)<.001:key=f'node:{ids[index+1]}'
                else:key=f'edge:{min(ids[index],ids[index+1])}:{max(ids[index],ids[index+1])}:{point[0]:.8f}:{point[1]:.8f}'
                ident=node_id(key);lon,lat=point
                node=dict(id=ident,coordinate=dict(longitude=lon,latitude=lat),elevation=round(float(surface.sample(lon,lat)),1))
                if ident in nodes and distance(point,[nodes[ident]['coordinate']['longitude'],nodes[ident]['coordinate']['latitude']])>.05:raise ValueError('Routing identity collision')
                nodes[ident]=node;made.append(ident)
            if made[0]==made[1]:continue
            if route['reverse']:made.reverse()
            key=(*made,route['bidirectional'],f['properties']['access'],f['kind'])
            if key in seen:continue
            seen.add(key)
            edges.append(dict(zip(('from','to'),made),distance=distance(*ends),bidirectional=route['bidirectional'],access=f['properties']['access'],kind=f['kind']))
    return dict(nodes=list(nodes.values()),edges=edges)


def build(source_id,b,region_name,index,output,dem_cache,binaries,workers=4,reserve_gib=40):
    output=Path(output);final=output/'sources'/source_id
    if (final/'world.json').exists():return validate(final,binaries)
    stage=output/'.work'/source_id;stage.mkdir(parents=True,exist_ok=True)
    reserve(output,reserve_gib)
    source_sha=json.loads(Path(index).with_suffix('.json').read_bytes())['sourceSHA256']
    surface=Surface(b,dem_cache,reserve_gib)
    osm=query(index,b)
    width=distance([b['minLongitude'],(b['minLatitude']+b['maxLatitude'])/2],[b['maxLongitude'],(b['minLatitude']+b['maxLatitude'])/2])
    depth=distance([b['minLongitude'],b['minLatitude']],[b['minLongitude'],b['maxLatitude']])
    def project(x,y,z=None):return (np.asarray(x)-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*width,(b['maxLatitude']-np.asarray(y))/(b['maxLatitude']-b['minLatitude'])*depth
    features=[];kinds=[];places=[]
    for f in osm:
        geometry=shape(f['geometry'])
        if geometry.geom_type=='Point':
            p=f['properties'];lon,lat=geometry.x,geometry.y
            if p.get('name') and b['minLongitude']<=lon<=b['maxLongitude'] and b['minLatitude']<=lat<=b['maxLatitude']:
                places.append(dict(id=f['id'],name=p['name'],coordinate=dict(longitude=lon,latitude=lat),kind=f['kind'],elevation=round(float(surface.sample(lon,lat)),1)))
        else:features.append(transform(project,geometry));kinds.append(f['kind'])
    tree=STRtree(features)
    def asset(name,data):
        atomic(stage/name,data)
        return dict(file=name,byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())
    graph=routing(osm,b,surface)
    if len(graph['nodes'])>250000 or len(graph['edges'])>750000:raise ValueError('Routing exceeds app limits')
    graph_asset=asset('paths.json',rawjson(graph))
    overview=surface.grid(b,257).round(1)
    overview_asset=asset('overview.json',rawjson(dict(width=257,height=257,heights=overview.ravel().tolist())))
    codec=CompactCodec(binaries/'libridge_compact_mesh.dylib')
    # Geographic cells stay ~1–2 km wide. 513 is the existing codec grid, not
    # an assertion of new source detail. It samples the bilinear ~30 m DSM.
    grids={(c,r):surface.grid(subbounds(b,c,r),513) for r in range(4) for c in range(4)}
    def tile(cr):
        reserve(output,reserve_gib)
        c,r=cr;ident=f'c{c:02d}-r{r:02d}';tb=subbounds(b,c,r);grid=grids[cr]
        raw,offset=quantize(grid)
        signature=hashlib.sha256(raw.tobytes()+struct.pack('<f',offset)+source_sha.encode()).hexdigest()
        checkpoint=stage/(ident+'.checkpoint.json')
        if checkpoint.exists():
            old=json.loads(checkpoint.read_bytes())
            if old['signature']==signature:
                try:validate_tile(stage,old['tile'],codec);return old['tile']
                except (ValueError,FileNotFoundError,zlib.error):pass
        result=dict(id=ident,column=c,row=r)
        with tempfile.TemporaryDirectory(dir=stage,prefix='mesh-') as tmp:
            tmp=Path(tmp);(tmp/'height').write_bytes(raw.tobytes())
            for name,tolerance in [('mesh',.5),('background',2)]:
                command=[str(binaries/'park_mesh'),str(tmp/'height'),str(tmp/'mesh'),str(tolerance)]
                if name=='background':command.append('adaptive-edges')
                facts=json.loads(subprocess.check_output(command))
                decoded=bytearray((tmp/'mesh').read_bytes());struct.pack_into('<f',decoded,24,offset);decoded=bytes(decoded)
                topology=codec.encode(decoded)
                if codec.decode(topology)!=decoded:raise ValueError('Lossless terrain round trip failed')
                path=ident+('.background' if name=='background' else '')+'.rat.zlib'
                packed=asset(path,zlib.compress(topology,9))
                result[name]=dict(id=ident,path=path,bounds=tb,byteCount=packed['byteCount'],sha256=packed['sha256'],
                    decodedByteCount=len(decoded),decodedSHA256=hashlib.sha256(decoded).hexdigest(),topologyByteCount=len(topology),topologySHA256=hashlib.sha256(topology).hexdigest(),
                    **{key:facts[key] for key in ('vertices','triangles','indexWidth','maxErrorMetres')})
        tw,th=width/4,depth/4;x0,y0=c*tw,r*th;clip=box(x0-4,y0-4,x0+tw+4,y0+th+4);paths=[]
        def coords(values):return [[round(x-x0,2),round(y-y0,2)] for x,y in values]
        def append(kind,g):
            if g.is_empty:return
            if g.geom_type=='Polygon':paths.append(dict(kind=kind,closed=True,rings=[coords(g.exterior.coords)]+[coords(i.coords) for i in g.interiors]))
            elif g.geom_type in ('LineString','LinearRing'):paths.append(dict(kind=kind,closed=False,rings=[coords(g.coords)]))
            elif hasattr(g,'geoms'):
                for p in g.geoms:append(kind,p)
        for i in tree.query(clip,predicate='intersects'):append(kinds[i],features[i].intersection(clip))
        cg=contourpy.contour_generator(x=np.linspace(x0,x0+tw,129),y=np.linspace(y0,y0+th,129),z=grid[::4,::4])
        for level in range(math.ceil(grid.min()/20)*20,math.ceil(grid.max()/20)*20,20):
            for points in cg.lines(level):append('contourIndex' if level%100==0 else 'contour',LineString(points).simplify(.5))
        vector=rawjson(dict(width=tw,height=th,paths=paths))
        if len(vector)>8_000_000 or len(paths)>50000:raise ValueError('Vector exceeds app limits')
        result['map']=asset(ident+'.map',zlib.compress(vector,9));result['map']['decodedByteCount']=len(vector)
        validate_tile(stage,result,codec)
        atomic(checkpoint,rawjson(dict(signature=signature,tile=result)))
        return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:tiles=list(pool.map(tile,grids))
    sources=[dict(name='Copernicus DEM GLO-30',attribution='Produced using Copernicus WorldDEM-30. © DLR e.V. 2010–2014 and © Airbus Defence and Space GmbH 2014–2018.',license='Copernicus DEM Free & Open licence',url='https://registry.opendata.aws/copernicus-dem/'),dict(name='OpenStreetMap',attribution='© OpenStreetMap contributors; regional extract by Geofabrik',license='ODbL 1.0',url='https://www.openstreetmap.org/copyright')]
    manifest=dict(schemaVersion=1,id=source_id,name=region_name,revision=REVISION,bounds=b,columns=4,rows=4,overview=overview_asset,graph=graph_asset,tiles=tiles,places=places,sources=sources,backgroundToleranceMetres=2,
        terrainSource=dict(kind='DSM',nominalSpacingMetres=30,verticalDatum='EGM2008',meshToleranceMetres=.5,quantisationMetres=.1,interpolation='bilinear; codec grid does not add source detail'),
        provenance=dict(osmSHA256=source_sha,elevation=surface.provenance),contourIntervalMetres=20)
    atomic(stage/'world.json',rawjson(manifest));record=validate(stage,binaries)
    for checkpoint in stage.glob('*.checkpoint.json'):checkpoint.unlink()
    final.parent.mkdir(parents=True,exist_ok=True);stage.rename(final)
    return record


def validate_tile(folder,tile,codec):
    for name in ('mesh','background'):
        c=tile[name];data=(folder/c['path']).read_bytes()
        if len(data)!=c['byteCount'] or hashlib.sha256(data).hexdigest()!=c['sha256']:raise ValueError('Terrain checksum')
        topology=zlib.decompress(data);decoded=codec.decode(topology)
        if len(topology)!=c['topologyByteCount'] or hashlib.sha256(topology).hexdigest()!=c['topologySHA256']:raise ValueError('Topology checksum')
        if len(decoded)!=c['decodedByteCount'] or hashlib.sha256(decoded).hexdigest()!=c['decodedSHA256']:raise ValueError('Decoded checksum')
        if c['maxErrorMetres']>(.5 if name=='mesh' else 2):raise ValueError('Surface error')
    a=tile['map'];data=(folder/a['file']).read_bytes()
    if len(data)!=a['byteCount'] or hashlib.sha256(data).hexdigest()!=a['sha256'] or len(zlib.decompress(data))!=a['decodedByteCount']:raise ValueError('Vector checksum')


def validate(folder,binaries):
    m=json.loads((folder/'world.json').read_bytes());codec=CompactCodec(binaries/'libridge_compact_mesh.dylib');memory=0
    if len(m['tiles'])!=16:raise ValueError('Incomplete landscape')
    for t in m['tiles']:
        validate_tile(folder,t,codec)
        c=t['background'];memory+=c['vertices']*54+c['triangles']*(3*c['indexWidth']+32)+65536
    if memory>256*1024**2:raise ValueError('Background memory limit')
    for key in ('overview','graph'):
        a=m[key];data=(folder/a['file']).read_bytes()
        if len(data)!=a['byteCount'] or hashlib.sha256(data).hexdigest()!=a['sha256']:raise ValueError('Metadata checksum')
    return dict(id=m['id'],path='sources/'+m['id']+'/world.json',bounds=m['bounds'],tileCount=len(m['tiles']),routing=m['graph'],downloadBytes=sum(p.stat().st_size for p in folder.iterdir() if p.is_file() and not p.name.endswith('.checkpoint.json')),backgroundResidentBytes=memory,terrainSource=m['terrainSource'])
