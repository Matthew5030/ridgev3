"""Canonical free UK surface, exact retained LiDAR boundaries and mesh compilation."""
import collections, concurrent.futures, ctypes, hashlib, json, math, re, sqlite3, struct, subprocess, sys, zlib
import xml.etree.ElementTree as ET
from pathlib import Path
import numpy as np
import rasterio
from rasterio.windows import Window
from scipy.ndimage import map_coordinates
from shapely.geometry import Polygon, box
from shapely.ops import unary_union
from shapely import prepare
from common import atomic, rawjson, digest, download
from terrain import tile_name
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'adaptive_terrain'))
from compact_codec import CompactCodec

def key(x,y):return (y<<16)|x
def parse(ident):return tuple(map(int,re.fullmatch(r'world-z10-x(\d+)-y(\d+)-c(\d+)-r(\d+)',ident).groups()))
def tile_key(ident,c,r):
    x,y,sx,sy=parse(ident);return key(x*48+sx+c,y*48+sy+r)
def bounds(x,y,c=0,r=0,size=48):
    west=x/1024*360-180;east=(x+1)/1024*360-180
    lat=lambda n:math.degrees(math.atan(math.sinh(math.pi*(1-2*n/1024))))
    north,south=lat(y),lat(y+1);dx=(east-west)/48;dy=(north-south)/48
    return dict(minLongitude=west+c*dx,maxLongitude=west+(c+size)*dx,minLatitude=north-(r+size)*dy,maxLatitude=north-r*dy)

def plan(world,zones,root):
    root.mkdir(parents=True,exist_ok=True);snapshot=root/'catalog.before.json';before=(world/'catalog.json').read_bytes()
    if snapshot.exists() and snapshot.read_bytes()!=before:raise ValueError('Live catalogue changed since baseline planning')
    atomic(snapshot,before);catalog=json.loads(before);sources={s['id']:s for s in catalog['sources']};rows={};new_keys=[]
    for region in json.loads(zones.read_bytes())['regions']:
        land=unary_union([Polygon(s['rings'][0],s['rings'][1:]) for s in region['mapShapes']]);prepare(land)
        for cell in region['cells']:
            ident=cell['id'];old=sources.get(ident);gaps=old.get('missingTerrain',[]) if old else [cell['bounds']]
            if not gaps:continue
            x,y,sx,sy=parse(ident);accepted=[]
            for r in range(16):
                for c in range(16):
                    b=bounds(x,y,sx+c,sy+r,1);lon=(b['minLongitude']+b['maxLongitude'])/2;lat=(b['minLatitude']+b['maxLatitude'])/2
                    if not any(g['minLongitude']<=lon<=g['maxLongitude'] and g['minLatitude']<=lat<=g['maxLatitude'] for g in gaps):continue
                    if land.intersection(box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])).area<=1e-14:continue
                    accepted.append([c,r]);new_keys.append(tile_key(ident,c,r))
            if accepted:
                parent=f'z10-x{x}-y{y}';row=rows.setdefault(parent,dict(id=parent,x=x,y=y,sources=[]))
                row['sources'].append(dict(id=ident,bounds=cell['bounds'],newCells=accepted,name=region['name'],existing=old is not None))
        print('Planned',region['name'],len(new_keys),'native cells',flush=True)
    ordered=sorted(rows.values(),key=lambda r:((r['x']-497)**2+(r['y']-314)**2,r['y'],r['x']))
    result=dict(version='uk-standard-v1',sourceCatalogSHA256=digest(snapshot),zonesSHA256=digest(zones),parents=ordered,
        newNativeCells=len(new_keys),changedSources=sum(len(r['sources']) for r in ordered),newKeys=new_keys)
    atomic(root/'plan.json',rawjson(result));return result

def decode(data,codec):
    b=codec.decode(zlib.decompress(data));magic,nv,nt,iw,grid,scale,offset=struct.unpack('<4s4I2f',b[:28]);assert magic==b'RME1' and grid==513
    v=np.frombuffer(b,dtype=[('x','<u2'),('y','<u2'),('h','<i2')],count=nv,offset=28)
    return b,v,np.rint((v['h'].astype(float)*scale+offset)*10).astype(np.int32)

def constraints(world,root,plan,codec):
    destination=root/'boundaries.sqlite'
    if destination.exists():return
    new=set(plan['newKeys']);candidates=set()
    for k in new:
        x,y=k&65535,k>>16
        for dx,dy in [(1,0),(-1,0),(0,1),(0,-1),(1,1),(1,-1),(-1,1),(-1,-1)]:candidates.add(key(x+dx,y+dy))
    candidates-=new;db=sqlite3.connect(destination.with_suffix('.tmp.sqlite'));db.executescript('CREATE TABLE edges(k INTEGER PRIMARY KEY, payload BLOB); CREATE TABLE corners(k INTEGER PRIMARY KEY,h INTEGER); CREATE TABLE conflicts(k INTEGER PRIMARY KEY,values_json TEXT);')
    count=0;corners={};conflicts={}
    for entry in json.loads((root/'catalog.before.json').read_bytes())['sources']:
        x,y,sx,sy=parse(entry['id'])
        if not any(key(x*48+sx+c,y*48+sy+r) in candidates for r in range(16) for c in range(16)):continue
        folder=world/Path(entry['path']).parent;m=json.loads((folder/'world.json').read_bytes())
        for t in m['tiles']:
            k=tile_key(entry['id'],t['column'],t['row'])
            if k not in candidates:continue
            data=(folder/t['mesh']['path']).read_bytes();assert hashlib.sha256(data).hexdigest()==t['mesh']['sha256']
            _,v,h=decode(data,codec);edges=[]
            for axis,side in [('x',0),('x',512),('y',0),('y',512)]:
                other='y' if axis=='x' else 'x';indices=np.where(v[axis]==side)[0];indices=indices[np.argsort(v[other][indices])];np.testing.assert_array_equal(v[other][indices],np.arange(513));edges.append(h[indices])
            a=np.array(edges,dtype='<i2');db.execute('INSERT INTO edges VALUES(?,?)',(k,zlib.compress(a.tobytes(),6)));count+=1
            gx,gy=k&65535,k>>16
            for dx,dy,value in [(0,0,a[2,0]),(1,0,a[2,-1]),(0,1,a[3,0]),(1,1,a[3,-1])]:
                ck=key(gx+dx,gy+dy);value=int(value)
                if ck in corners and corners[ck]!=value:conflicts.setdefault(ck,{corners[ck]}).add(value)
                else:corners[ck]=value
        if count%1000<256:print('Retained boundary meshes checked',count,flush=True)
    db.executemany('INSERT INTO corners VALUES(?,?)',corners.items());db.executemany('INSERT INTO conflicts VALUES(?,?)',[(k,json.dumps(sorted(v))) for k,v in conflicts.items()]);db.commit();db.close();destination.with_suffix('.tmp.sqlite').replace(destination)
    atomic(root/'boundary-audit.json',rawjson(dict(retainedMeshes=count,corners=len(corners),conflictingCorners={str(k):sorted(v) for k,v in conflicts.items()})))

def inputs(root,plan,workers=4):
    folder=root/'dem-originals';folder.mkdir(exist_ok=True);tiles=set()
    for row in plan['parents']:
        for s in row['sources']:
            b=s['bounds']
            for lat in range(math.floor(b['minLatitude']-.002),math.ceil(b['maxLatitude']+.002)):
                for lon in range(math.floor(b['minLongitude']-.002),math.ceil(b['maxLongitude']+.002)):tiles.add((lat,lon))
    def fetch(pair):
        lat,lon=pair;name=tile_name(lat,lon);path=folder/(name+'.tif');url=f'https://copernicus-dem-30m.s3.amazonaws.com/{name}/{name}.tif';receipt=path.with_suffix('.json')
        cached=root.parent/'scotland-copdem30-test-v1/dem-originals'/path.name
        if not path.exists() and cached.exists():path.symlink_to(cached)
        try:download(url,path,reserve_gib=5,maximum=150*1024**2)
        except Exception as error:
            if getattr(getattr(error,'response',None),'status_code',None)==404:return dict(missing=True,lat=lat,lon=lon,url=url)
            raise
        sha=digest(path)
        if receipt.exists():
            old=json.loads(receipt.read_bytes())
            if old['sha256']!=sha or old['byteCount']!=path.stat().st_size:raise ValueError('Original DEM cache changed')
        with rasterio.open(path) as ds:
            assert ds.count==1 and ds.crs.to_epsg()==4326
            # Full decode catches incomplete TIFF payloads before any mesh build.
            for _,window in ds.block_windows(1):ds.read(1,window=window)
            result=dict(path=str(path.resolve()),url=url,sha256=sha,byteCount=path.stat().st_size,bounds=list(ds.bounds),width=ds.width,height=ds.height,nodata=ds.nodata)
        atomic(receipt,rawjson(result));print('Cached original DEM',lat,lon,result['byteCount'],flush=True);return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:records=list(pool.map(fetch,sorted(tiles)))
    grids=root/'geoid-grids';grids.mkdir(exist_ok=True);geoids=[]
    for name in ['us_nga_egm08_25.tif','us_nga_egm96_15.tif']:
        path=download('https://cdn.proj.org/'+name,grids/name,reserve_gib=5,maximum=100*1024**2);geoids.append(dict(path=str(path.resolve()),sha256=digest(path),byteCount=path.stat().st_size,url='https://cdn.proj.org/'+name))
    atomic(root/'inputs.json',rawjson(dict(dem=records,geoids=geoids)))
    west,south,east,north=-12,48,4,64;step=1/3600
    vrt=ET.Element('VRTDataset',rasterXSize=str((east-west)*3600),rasterYSize=str((north-south)*3600));ET.SubElement(vrt,'SRS').text='EPSG:4326';ET.SubElement(vrt,'GeoTransform').text=f'{west},{step},0,{north},0,{-step}'
    band=ET.SubElement(vrt,'VRTRasterBand',dataType='Float32',band='1');ET.SubElement(band,'NoDataValue').text='nan'
    for r in records:
        if r.get('missing'):continue
        left,bottom,right,top=r['bounds'];s=ET.SubElement(band,'ComplexSource',resampling='bilinear');ET.SubElement(s,'SourceFilename',relativeToVRT='0').text=r['path'];ET.SubElement(s,'SourceBand').text='1'
        ET.SubElement(s,'SrcRect',xOff='0',yOff='0',xSize=str(r['width']),ySize=str(r['height']));ET.SubElement(s,'DstRect',xOff=str((left-west)*3600),yOff=str((north-top)*3600),xSize=str((right-left)*3600),ySize=str((top-bottom)*3600));ET.SubElement(s,'UseMaskBand').text='true'
        if r['nodata'] is not None:ET.SubElement(s,'NODATA').text=str(r['nodata'])
    ET.ElementTree(vrt).write(root/'dem.vrt',encoding='utf-8',xml_declaration=True)
    return records

class Surface:
    def __init__(self,root):
        self.ds=rasterio.open(root/'dem.vrt');self.cache=collections.OrderedDict();self.geoids=[]
        for name in ['us_nga_egm08_25.tif','us_nga_egm96_15.tif']:
            with rasterio.open(root/'geoid-grids'/name) as ds:self.geoids.append((ds.read(1),ds.transform))
    def block(self,bx,by):
        k=(bx,by)
        if k not in self.cache:
            data=self.ds.read(1,window=Window(bx*512,by*512,512,512),boundless=True,masked=True).filled(np.nan).astype(float)
            lon=-12+(bx*512+np.arange(512)[None,:]+.5)/3600;lat=64-(by*512+np.arange(512)[:,None]+.5)/3600;lon,lat=np.broadcast_arrays(lon,lat)
            for sign,(geoid,t) in zip([1,-1],self.geoids):
                values=map_coordinates(geoid,[(lat.ravel()-t.f)/t.e-.5,(lon.ravel()-t.c)/t.a-.5],order=1,mode='nearest',prefilter=False).reshape(512,512)
                data+=sign*values
            self.cache[k]=data
            if len(self.cache)>64:self.cache.popitem(last=False)
        self.cache.move_to_end(k);return self.cache[k]
    def sample(self,lon,lat):
        lon,lat=np.broadcast_arrays(np.round(lon,11),np.round(lat,11));px=(lon+12)*3600-.5;py=(64-lat)*3600-.5
        ix=np.floor(px).astype(np.int64);iy=np.floor(py).astype(np.int64);x0=int(ix.min());y0=int(iy.min());x1=int(ix.max())+2;y1=int(iy.max())+2
        window=np.empty((y1-y0,x1-x0))
        for by in range(y0//512,(y1-1)//512+1):
            for bx in range(x0//512,(x1-1)//512+1):
                left,top=max(x0,bx*512),max(y0,by*512);right,bottom=min(x1,(bx+1)*512),min(y1,(by+1)*512);window[top-y0:bottom-y0,left-x0:right-x0]=self.block(bx,by)[top-by*512:bottom-by*512,left-bx*512:right-bx*512]
        x,y=ix-x0,iy-y0;fx,fy=px-ix,py-iy
        values=window[y,x]*(1-fx)*(1-fy)+window[y,x+1]*fx*(1-fy)+window[y+1,x]*(1-fx)*fy+window[y+1,x+1]*fx*fy
        if not np.isfinite(values).all():raise ValueError('Missing actual DEM coverage')
        return values
    def grid(self,b,n=513):return self.sample(np.linspace(b['minLongitude'],b['maxLongitude'],n)[None,:],np.linspace(b['maxLatitude'],b['minLatitude'],n)[:,None])

class Boundaries:
    def __init__(self,root,row):
        x,y=row['x']*48,row['y']*48;self.edges={};self.corners={};self.conflicts=set()
        with sqlite3.connect(root/'boundaries.sqlite') as db:
            lo,hi=key(x-1,y-1),key(x+49,y+49)
            for k,p in db.execute('SELECT k,payload FROM edges WHERE k BETWEEN ? AND ?',(lo,hi)):
                if x-1<=k&65535<=x+49:self.edges[k]=np.frombuffer(zlib.decompress(p),'<i2').astype(np.int32).reshape(4,513)
            for k,h in db.execute('SELECT k,h FROM corners WHERE k BETWEEN ? AND ?',(lo,hi)):
                if x-1<=k&65535<=x+49:self.corners[k]=h
            self.conflicts={k for k, in db.execute('SELECT k FROM conflicts WHERE k BETWEEN ? AND ?',(lo,hi))}
    def constrain(self,grid,k):
        gx,gy=k&65535,k>>16;corner_keys=[key(gx,gy),key(gx+1,gy),key(gx,gy+1),key(gx+1,gy+1)]
        if self.conflicts.intersection(corner_keys):raise ValueError('Existing LiDAR corner heights conflict')
        source=np.rint(grid*10).astype(np.int32);corner=np.array([source[0,0],source[0,-1],source[-1,0],source[-1,-1]])
        delta=np.array([self.corners.get(ck,int(h))-int(h) for ck,h in zip(corner_keys,corner)],dtype=float)
        t=np.linspace(0,1,513);top=np.rint(source[0,:]+delta[0]*(1-t)+delta[1]*t);bottom=np.rint(source[-1,:]+delta[2]*(1-t)+delta[3]*t);left=np.rint(source[:,0]+delta[0]*(1-t)+delta[2]*t);right=np.rint(source[:,-1]+delta[1]*(1-t)+delta[3]*t)
        for neighbour,edge,name in [(key(gx-1,gy),1,'left'),(key(gx+1,gy),0,'right'),(key(gx,gy-1),3,'top'),(key(gx,gy+1),2,'bottom')]:
            if neighbour in self.edges:
                value=self.edges[neighbour][edge]
                if name=='left':left=value
                elif name=='right':right=value
                elif name=='top':top=value
                else:bottom=value
        u=t[None,:];v=t[:,None];wl=(1-u)**4;wr=u**4;wt=(1-v)**4;wb=v**4
        correction=wl*(left-source[:,0])[:,None]+wr*(right-source[:,-1])[:,None]+wt*(top-source[0,:])[None,:]+wb*(bottom-source[-1,:])[None,:]
        correction-=wl*wt*delta[0]+wr*wt*delta[1]+wl*wb*delta[2]+wr*wb*delta[3]
        output=np.rint(source+correction).astype(np.int32);output[0,:]=top;output[-1,:]=bottom;output[:,0]=left;output[:,-1]=right
        if output.min()<=-32768 or output.max()>32767:raise ValueError('Height range exceeds UK codec')
        return output.astype('<i2'),float(np.max(np.abs(correction))/10)

class Compiler:
    def __init__(self,root):
        self.lib=ctypes.CDLL(str(root/'bin/libstandard_mesh.dylib'));self.call=self.lib.ridge_compile_mesh
        self.call.argtypes=[ctypes.c_void_p,ctypes.c_double,ctypes.c_int,ctypes.c_void_p,ctypes.c_size_t,ctypes.POINTER(ctypes.c_size_t),ctypes.POINTER(ctypes.c_double),ctypes.c_void_p,ctypes.c_size_t];self.call.restype=ctypes.c_int
        self.output=ctypes.create_string_buffer(10_000_000);self.codec=CompactCodec(root/'bin/libridge_compact_mesh.dylib')
    def compile(self,grid,tolerance,native_edges=True):
        size=ctypes.c_size_t();error=ctypes.c_double();message=ctypes.create_string_buffer(512)
        code=self.call(grid.ctypes.data,tolerance,int(native_edges),self.output,len(self.output),ctypes.byref(size),ctypes.byref(error),message,len(message))
        if code:raise ValueError(message.value.decode())
        decoded=self.output.raw[:size.value];topology=self.codec.encode(decoded);assert self.codec.decode(topology)==decoded
        _,nv,nt,iw,_,_,_=struct.unpack('<4s4I2f',decoded[:28]);packed=zlib.compress(topology,6)
        return packed,dict(byteCount=len(packed),sha256=hashlib.sha256(packed).hexdigest(),decodedByteCount=len(decoded),decodedSHA256=hashlib.sha256(decoded).hexdigest(),topologyByteCount=len(topology),topologySHA256=hashlib.sha256(topology).hexdigest(),vertices=nv,triangles=nt,indexWidth=iw,maxErrorMetres=error.value)

def build_compiler(root):
    root.mkdir(parents=True,exist_ok=True);native=Path(__file__).resolve().parents[1]/'adaptive_terrain';folder=root/'bin';folder.mkdir(exist_ok=True)
    subprocess.run(['clang++','-O3','-std=c++17','-DRIDGE_MESH_LIBRARY','-dynamiclib',str(native/'park_mesh.cpp'),'-o',str(folder/'libstandard_mesh.dylib')],check=True)
    subprocess.run(['clang++','-O3','-std=c++17','-dynamiclib',str(native/'compact_mesh.cpp'),'-o',str(folder/'libridge_compact_mesh.dylib')],check=True)
