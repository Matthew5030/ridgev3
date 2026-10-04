#!/usr/bin/env python3
"""Resume-safe conversion of audited fine chunks into immutable world-v1 sources.
Only complete, validated sources enter catalog.json. Existing terrain is read-only.
"""
import argparse, concurrent.futures, fcntl, hashlib, io, json, math, os, re
import shutil, subprocess, sys, tempfile, time, zipfile, zlib, multiprocessing, signal
from pathlib import Path
from functools import lru_cache
import numpy as np
import contourpy
from shapely.geometry import shape, box, LineString
from shapely.ops import transform
from shapely.strtree import STRtree

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'adaptive_terrain'))
from compact_codec import CompactCodec

VERSION = 'world-v1-2026-10-04'
DATALESS = 0x40000000
sha = lambda b: hashlib.sha256(b).hexdigest()

@lru_cache(maxsize=4)
def codec(binaries):
    suffix = 'dylib' if sys.platform == 'darwin' else 'so'
    return CompactCodec(binaries / ('libridge_compact_mesh.' + suffix))

def rawjson(value):
    return json.dumps(value, separators=(',', ':'), allow_nan=False).encode()

def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_bytes(data)
    os.replace(temp, path)

def resident(path):
    return path.is_file() and not (getattr(path.stat(), 'st_flags', 0) & DATALESS)

def read_verified(path, expected, size=None):
    if not resident(path):
        raise FileNotFoundError(f'Unavailable or iCloud-only: {path}')
    data = path.read_bytes()
    if sha(data) != expected or (size is not None and len(data) != size):
        raise ValueError(f'Checksum/size mismatch: {path}')
    return data

def cell(chunk):
    m = re.search(r'-c(\d+)-(\d+)-p(\d+)-(\d+)$', chunk['id'])
    if not m: raise ValueError('Unknown native grid ID')
    x, y, px, py = map(int, m.groups())
    return x * 4 + px, y * 4 + py

def subbounds(bounds, x, y, size):
    dx = (bounds['maxLongitude'] - bounds['minLongitude']) / 48
    dy = (bounds['maxLatitude'] - bounds['minLatitude']) / 48
    return dict(minLongitude=bounds['minLongitude']+x*dx, maxLongitude=bounds['minLongitude']+(x+size)*dx,
                maxLatitude=bounds['maxLatitude']-y*dy, minLatitude=bounds['maxLatitude']-(y+size)*dy)

def contains(b, lon, lat):
    return b['minLongitude'] <= lon <= b['maxLongitude'] and b['minLatitude'] <= lat <= b['maxLatitude']

def load_map(public, selection):
    folder = public / 'tiles' / '10' / str(selection['x']) / str(selection['y'])
    descriptor = folder / 'descriptor.json'
    if not resident(descriptor): raise FileNotFoundError(f'iCloud-only/missing descriptor: {descriptor}')
    desc = json.loads(descriptor.read_bytes())
    archive = folder / Path(desc['archiveURL']).name
    payload = read_verified(archive, desc['archiveSHA256'], desc['archiveSizeBytes'])
    with zipfile.ZipFile(io.BytesIO(payload)) as z:
        manifest = json.loads(z.read('manifest.json'))
        def get(name):
            item = next(f for f in manifest['files'] if f['path'] == name)
            data = z.read(name)
            if len(data) != item['sizeBytes'] or sha(data) != item['sha256']: raise ValueError('Archive member mismatch')
            return json.loads(data)
        semantic, graph, credits = get('map-data.ridgemap'), get('routing/graph.json'), get('attribution.json')
    if semantic['bounds'] != selection['bounds']: raise ValueError('Semantic/terrain grid mismatch')
    return semantic, graph, credits, desc['archiveSHA256']

def source(a, section, selection, fine, semantic, graph, credits, archive_sha, sx, sy, chunks, binaries):
    size = a.source_cells
    ident = f"world-{selection['id']}-c{sx:02d}-r{sy:02d}"
    final = a.output / 'sources' / ident
    if (final / 'world.json').exists():
        validate(final, binaries)
        return final
    stage = a.output / '.work' / ident
    stage.mkdir(parents=True, exist_ok=True)
    b = subbounds(selection['bounds'], sx, sy, size)
    width = math.radians(b['maxLongitude']-b['minLongitude'])*6371008.8*math.cos(math.radians((b['minLatitude']+b['maxLatitude'])/2))
    depth = math.radians(b['maxLatitude']-b['minLatitude'])*6371008.8
    tw, th = width/size, depth/size
    def asset(name, data):
        atomic(stage/name, data)
        return dict(file=name, byteCount=len(data), sha256=sha(data))
    def project(x, y, z=None):
        return (np.asarray(x)-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*width, (b['maxLatitude']-np.asarray(y))/(b['maxLatitude']-b['minLatitude'])*depth
    features, kinds, places = [], [], []
    boundary = box(b['minLongitude'], b['minLatitude'], b['maxLongitude'], b['maxLatitude'])
    for f in semantic['features']:
        g = shape(f['geometry'])
        if not g.intersects(boundary): continue
        if g.geom_type == 'Point':
            props = f.get('properties', {})
            if props.get('name'):
                places.append(dict(id=f['id'], name=props['name'], coordinate=dict(latitude=g.y, longitude=g.x), kind=f['kind'], elevation=props.get('elevationMeters')))
            continue
        if not g.is_valid: g = g.buffer(0)
        if g.is_empty: continue
        features.append(transform(project, g)); kinds.append(f['kind'])
    tree = STRtree(features)
    grids = {}
    # A source is at most 16x16 tiles. Only 8 m samples are retained in memory.
    overview = np.full((size*64+1,size*64+1), np.nan)
    for c in chunks:
        raw = read_verified(Path(c['source']), c['sourceSHA256'], c['sourceByteCount'])
        h = np.frombuffer(raw, '<i2').reshape(513,513)
        if np.any(h == -32768): raise ValueError('NoData in selected complete tile')
        x,y=cell(c);x-=sx;y-=sy
        sample=h[::8,::8].astype(float)*.1
        target=overview[y*64:y*64+65,x*64:x*64+65]
        overlap=np.isfinite(target)
        if np.any(np.abs(target[overlap]-sample[overlap]) > .10001): raise ValueError('Source height seam mismatch')
        target[:]=sample
        grids[(x,y)]=sample
    def height(lon,lat):
        u=(lon-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*size
        v=(b['maxLatitude']-lat)/(b['maxLatitude']-b['minLatitude'])*size
        x,y=min(size-1,max(0,int(u))),min(size-1,max(0,int(v)))
        if (x,y) not in grids: return None
        return round(float(grids[(x,y)][min(64,max(0,round((v-y)*64))),min(64,max(0,round((u-x)*64)))]),1)
    nodes=[]
    for n in graph['nodes']:
        lon,lat=n['longitude'],n['latitude']
        if contains(b,lon,lat):
            h=height(lon,lat)
            if h is not None: nodes.append(dict(id=n['id'],coordinate=dict(longitude=lon,latitude=lat),elevation=h))
    allowed={n['id'] for n in nodes}
    edges=[dict(from_=e['from'],to=e['to'],distance=e['distanceMeters'],bidirectional=e['bidirectional'],access=e['access'],kind=e['pathType']) for e in graph['edges'] if e['from'] in allowed and e['to'] in allowed]
    for e in edges:e['from']=e.pop('from_')
    connected={e[k] for e in edges for k in ('from','to')}
    graph_asset=asset('paths.json',rawjson(dict(nodes=[n for n in nodes if n['id'] in connected],edges=edges)))
    coarse_asset=asset('overview-8m.json',rawjson(dict(width=overview.shape[1],height=overview.shape[0],heights=np.nan_to_num(overview,nan=0).round(1).ravel().tolist())))
    # Missing fine cells remain absent from tiles; zero overview values never grant coverage.
    def build(c):
        x,y=cell(c);x-=sx;y-=sy;tid=f'c{x:02d}-r{y:02d}'
        checkpoint=stage/(tid+'.checkpoint.json')
        if checkpoint.exists():
            old=json.loads(checkpoint.read_bytes())
            if old['sourceSHA256']==c['sourceSHA256']:
                try:
                    validate_tile(stage,old['tile'],binaries)
                    return old['tile']
                except (ValueError,FileNotFoundError,subprocess.CalledProcessError):pass
        raw=read_verified(Path(c['source']),c['sourceSHA256'],c['sourceByteCount'])
        original=fine[c['id']]
        if original['sourceSHA256']!=c['sourceSHA256'] or original['bounds']!=c['bounds']:raise ValueError('Fine/raw mismatch')
        with (section/original['path']).open('rb') as f:
            f.seek(original['byteOffset']);compressed=f.read(original['byteCount'])
        if sha(compressed)!=original['sha256']:raise ValueError('Fine range checksum mismatch')
        fmesh={k:original[k] for k in ('bounds','byteCount','sha256','decodedByteCount','decodedSHA256','vertices','triangles','indexWidth','topologyByteCount','topologySHA256','maxErrorMetres')}
        fmesh.update(id=tid,path=tid+'.rat.zlib');asset(fmesh['path'],compressed)
        with tempfile.TemporaryDirectory(prefix='ridge-world-chunk-') as tmp:
            tmp=Path(tmp);src=tmp/'height.bin';src.write_bytes(raw);mesh=tmp/'mesh'
            facts=json.loads(subprocess.check_output([str(binaries/'park_mesh'),str(src),str(mesh),'2','adaptive-edges']))
            decoded=mesh.read_bytes();topology=codec(binaries).encode(decoded);packed=zlib.compress(topology,9)
        name=tid+'.background.rat.zlib';asset(name,packed)
        background=dict(id=tid,path=name,bounds=c['bounds'],byteCount=len(packed),sha256=sha(packed),decodedByteCount=len(decoded),decodedSHA256=sha(decoded),topologyByteCount=len(topology),topologySHA256=sha(topology),**{k:facts[k] for k in ('vertices','triangles','indexWidth','maxErrorMetres')})
        paths=[];x0,y0=x*tw,y*th;clip=box(x0-4,y0-4,x0+tw+4,y0+th+4)
        def coords(cs):return [[round(px-x0,2),round(py-y0,2)] for px,py in cs]
        def append(kind,g):
            if g.is_empty:return
            if g.geom_type=='Polygon':paths.append(dict(kind=kind,closed=True,rings=[coords(g.exterior.coords)]+[coords(q.coords) for q in g.interiors]))
            elif g.geom_type in ('LineString','LinearRing'):paths.append(dict(kind=kind,closed=False,rings=[coords(g.coords)]))
            elif hasattr(g,'geoms'):
                for part in g.geoms:append(kind,part)
        for i in tree.query(clip,predicate='intersects'):append(kinds[i],features[i].intersection(clip))
        h=np.frombuffer(raw,'<i2').reshape(513,513)[::4,::4].astype(float)*.1
        cg=contourpy.contour_generator(x=np.linspace(x0,x0+tw,129),y=np.linspace(y0,y0+th,129),z=h)
        for level in range(math.ceil(h.min()/10)*10,math.ceil(h.max()/10)*10,10):
            for points in cg.lines(level):append('contourIndex' if level%50==0 else 'contour',LineString(points).simplify(.25))
        vector=rawjson(dict(width=tw,height=th,paths=paths))
        if len(vector)>8_000_000 or len(paths)>50_000:raise ValueError('Vector page exceeds app limits')
        v=asset(tid+'.map',zlib.compress(vector,9));v['decodedByteCount']=len(vector)
        result=dict(id=tid,column=x,row=y,mesh=fmesh,background=background,map=v)
        validate_tile(stage,result,binaries)
        atomic(checkpoint,rawjson(dict(sourceSHA256=c['sourceSHA256'],tile=result)))
        return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.workers) as pool:
        tiles=list(pool.map(build,chunks))
    source_credits=[dict(name=c['source'],attribution=c['text'],license=c['license'],url=c['url']) for c in credits['entries']]
    for sm in json.loads((section/'adaptive.json').read_bytes())['sourceManifests']:
        s=sm['source'];credit=dict(name=s['name'],attribution=s['attribution'],license=s['license'],url=s['sourcePage'])
        if credit not in source_credits:source_credits.append(credit)
    manifest=dict(schemaVersion=1,id=ident,name=selection['id']+f' ({sx//size+1}, {sy//size+1})',revision=VERSION,bounds=b,columns=size,rows=size,overview=coarse_asset,graph=graph_asset,tiles=tiles,places=places,sources=source_credits,backgroundToleranceMetres=2,sourceTerrainSHA256=sha(rawjson([(c['id'],c['sourceSHA256']) for c in chunks])),semanticArchiveSHA256=archive_sha)
    atomic(stage/'world.json',rawjson(manifest));validate(stage,binaries)
    for p in stage.glob('*.checkpoint.json'):p.unlink()
    final.parent.mkdir(parents=True,exist_ok=True);os.rename(stage,final)
    return final

def validate_tile(folder,t,binaries):
    for kind in ('mesh','background'):
        c=t[kind];data=read_verified(folder/c['path'],c['sha256'],c['byteCount']);top=zlib.decompress(data)
        if len(top)!=c['topologyByteCount'] or sha(top)!=c['topologySHA256']:raise ValueError('Topology checksum')
        if c['maxErrorMetres']>(.5 if kind=='mesh' else 2):raise ValueError('Surface tolerance')
        decoded=codec(binaries).decode(top)
        if len(decoded)!=c['decodedByteCount'] or sha(decoded)!=c['decodedSHA256']:raise ValueError('Decoded checksum')
    m=t['map'];data=read_verified(folder/m['file'],m['sha256'],m['byteCount'])
    if len(zlib.decompress(data))!=m['decodedByteCount']:raise ValueError('Map length')

def validate(folder,binaries):
    m=json.loads((folder/'world.json').read_bytes());tiles=m['tiles']
    if not 0<len(tiles)<=256 or len({t['id'] for t in tiles})!=len(tiles):raise ValueError('Tile count')
    memory=0
    for t in tiles:
        c=t['background'];memory+=c['vertices']*54+c['triangles']*(3*c['indexWidth']+32)+65536
        expected=subbounds(dict(minLongitude=m['bounds']['minLongitude'],maxLongitude=m['bounds']['minLongitude']+(m['bounds']['maxLongitude']-m['bounds']['minLongitude'])*48/m['columns'],maxLatitude=m['bounds']['maxLatitude'],minLatitude=m['bounds']['maxLatitude']-(m['bounds']['maxLatitude']-m['bounds']['minLatitude'])*48/m['rows']),t['column'],t['row'],1)
        if any(abs(expected[k]-t['mesh']['bounds'][k])>1e-8 for k in expected):raise ValueError('Bounds alignment')
        validate_tile(folder,t,binaries)
    if memory>256*1024*1024:raise ValueError('Background exceeds app budget: rerun with --source-cells 8 in a new output')
    for key in ('overview','graph'):
        q=m[key];read_verified(folder/q['file'],q['sha256'],q['byteCount'])
    return dict(id=m['id'],path='sources/'+m['id']+'/world.json',bounds=m['bounds'],tileCount=len(tiles),downloadBytes=sum(p.stat().st_size for p in folder.iterdir() if p.is_file() and not p.name.endswith('.checkpoint.json')),backgroundResidentBytes=memory)

# Each forked region owns separate staging files. Only the coordinator publishes
# the catalogue. The retained section JSON is shared copy-on-write across workers.
REGION_CONTEXT = None


def region_slots(requested, tile_workers, cpu_count, physical_bytes, parent_bytes):
    # Conservative reservation, not a claim that RSS equals private memory. Allow
    # a full copy of the parent's objects plus scratch space per region and leave
    # 35% of RAM for macOS, native allocations and the preview renderer.
    worker_estimate = max(512 * 1024**2, parent_bytes + 256 * 1024**2)
    memory_slots = max(1, int((physical_bytes * .65 - parent_bytes) // worker_estimate))
    return max(1, min(requested, max(1, cpu_count // tile_workers), memory_slots))


def region_result(job):
    a, section, selection, fine, semantic, graph, credits, archive_sha, binaries = REGION_CONTEXT
    x, y, chunks = job
    key = f"world-{selection['id']}-c{x:02d}-r{y:02d}"
    if a.deadline_unix and time.time() >= a.deadline_unix:
        return key, None, 'paused-time-limit'
    if shutil.disk_usage(a.output).free < a.reserve_gib * 1024**3:
        return key, None, 'paused-low-disk'
    try:
        final = source(a, section, selection, fine, semantic, graph, credits, archive_sha, x, y, chunks, binaries)
        return key, validate(final, binaries), None
    except Exception as error:
        return key, None, repr(error)


def region_results(jobs, slots):
    if slots == 1:
        yield from map(region_result, jobs)
    else:
        # macOS/Linux preparation tool: fork before any tile threads exist in
        # this coordinator. Recreate the pool per section to release map memory.
        with multiprocessing.get_context('fork').Pool(slots) as pool:
            yield from pool.imap_unordered(region_result, jobs, chunksize=1)


def main():
    p=argparse.ArgumentParser();p.add_argument('--selection',type=Path,required=True);p.add_argument('--fine',type=Path,required=True);p.add_argument('--public',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--staged-public',type=Path);p.add_argument('--workers',type=int,default=2);p.add_argument('--region-workers',type=int,default=1);p.add_argument('--source-cells',type=int,choices=(8,16),default=16);p.add_argument('--reserve-gib',type=int,default=35);p.add_argument('--section');p.add_argument('--limit-sources',type=int);p.add_argument('--deadline-unix',type=float);a=p.parse_args()
    if not 1<=a.workers<=4:p.error('Use 1–4 tile workers per region')
    if not 1<=a.region_workers<=16:p.error('Use 1–16 region workers')
    if a.limit_sources is not None and a.limit_sources < 1:p.error('Source limit must be positive')
    a.output.mkdir(parents=True,exist_ok=True)
    lock=(a.output/'.batch.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    lock.seek(0);lock.truncate();lock.write(str(os.getpid()));lock.flush()
    settings=dict(version=VERSION,sourceCells=a.source_cells,selection=str(a.selection.resolve()),fine=str(a.fine.resolve()),public=str(a.public.resolve()))
    config=a.output/'build-config.json'
    if config.exists() and json.loads(config.read_bytes())!=settings:raise ValueError('Output belongs to another build configuration')
    atomic(config,rawjson(settings));binaries=a.output/'.tools';binaries.mkdir(exist_ok=True)
    root=Path(__file__).resolve().parents[1]/'adaptive_terrain'
    for name in ('park_mesh','compact_mesh'):
        subprocess.run(['clang++','-O3','-std=c++17',str(root/(name+'.cpp')),'-o',str(binaries/name)],check=True)
    library_flags=['-dynamiclib'] if sys.platform=='darwin' else ['-shared','-fPIC']
    suffix='dylib' if sys.platform=='darwin' else 'so'
    subprocess.run(['clang++','-O3','-std=c++17',*library_flags,str(root/'compact_mesh.cpp'),'-o',str(binaries/('libridge_compact_mesh.'+suffix))],check=True)
    atomic(a.output/'toolchain.json',rawjson(dict(builderSHA256=sha(Path(__file__).read_bytes()),codecWrapperSHA256=sha((root/'compact_codec.py').read_bytes()),compilerSources={name:sha((root/(name+'.cpp')).read_bytes()) for name in ('park_mesh','compact_mesh')})))
    catalog_path=a.output/'catalog.json'
    catalog=json.loads(catalog_path.read_bytes()) if catalog_path.exists() else dict(schemaVersion=1,revision=VERSION,sources=[])
    entries={s['id']:s for s in catalog['sources']};deferred={};failures={};completed=0;started=time.time()
    active=[]; scheduling=dict(requestedRegions=a.region_workers,tileWorkers=a.workers)
    def status(state,current=None):
        atomic(a.output/'status.json',rawjson(dict(state=state,pid=os.getpid(),updatedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),elapsedSeconds=round(time.time()-started),current=current,activeSources=active,scheduling=scheduling,completedSources=len(entries),completedTiles=sum(s['tileCount'] for s in entries.values()),downloadBytes=sum(s['downloadBytes'] for s in entries.values()),deferred=deferred,failures=failures)))
    physical = int(subprocess.check_output(['sysctl','-n','hw.memsize'])) if sys.platform=='darwin' else os.sysconf('SC_PAGE_SIZE')*os.sysconf('SC_PHYS_PAGES')
    coordinator = os.getpid()
    def stop(signum, frame):
        if os.getpid() != coordinator:os._exit(128+signum)
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,stop)
    selections=sorted(a.selection.glob('*.json'),key=lambda f:(f.stem!='z10-x500-y333',f.name))
    global REGION_CONTEXT
    try:
        for selection_path in selections:
            if a.deadline_unix and time.time()>=a.deadline_unix:status('paused-time-limit');return
            if a.section and selection_path.stem!=a.section:continue
            s=json.loads(selection_path.read_bytes());section=a.fine/(s['id']+'-adaptive-0p5')
            if not s['chunks'] or not (section/'adaptive.json').exists():continue
            groups={}
            for c in s['chunks']:
                x,y=cell(c);groups.setdefault((x//a.source_cells*a.source_cells,y//a.source_cells*a.source_cells),[]).append(c)
            jobs=[(x,y,chunks) for (x,y),chunks in sorted(groups.items()) if f"world-{s['id']}-c{x:02d}-r{y:02d}" not in entries]
            if a.limit_sources:jobs=jobs[:a.limit_sources-completed]
            # Completed sections never reopen large semantic/routing archives.
            if not jobs:continue
            if shutil.disk_usage(a.output).free<a.reserve_gib*1024**3:status('paused-low-disk');return
            status('preparing-section',s['id'])
            try:
                map_root=a.public
                if a.staged_public and resident(a.staged_public/'tiles'/'10'/str(s['x'])/str(s['y'])/'descriptor.json'):map_root=a.staged_public
                semantic,graph,credits,archive_sha=load_map(map_root,s)
            except FileNotFoundError as e:deferred[s['id']]=str(e);status('running');continue
            except Exception as e:failures[s['id']]=str(e);status('running');continue
            fine={c['id']:c for c in json.loads((section/'adaptive.json').read_bytes())['chunks']}
            for _,_,chunks in jobs:
                if any(c['id'] not in fine for c in chunks):raise ValueError('Frozen selection has no corrected fine mesh')
            # Release the previous section context before measuring the next one.
            REGION_CONTEXT=None
            parent_bytes=int(subprocess.check_output(['ps','-o','rss=','-p',str(os.getpid())]))*1024
            slots=min(len(jobs),region_slots(a.region_workers,a.workers,os.cpu_count() or 1,physical,parent_bytes))
            scheduling.update(regions=slots,parentResidentBytes=parent_bytes,memoryReservationFraction=.65)
            REGION_CONTEXT=(a,section,s,fine,semantic,graph,credits,archive_sha,binaries)
            active=[f"world-{s['id']}-c{x:02d}-r{y:02d}" for x,y,_ in jobs]
            status('running',s['id']);print('SECTION',s['id'],'regions',slots,'pending',len(jobs),flush=True)
            results=region_results(jobs,slots)
            try:
                for key,entry,error in results:
                    if key in active:active.remove(key)
                    if error and error.startswith('paused-'):status(error,key);return
                    if error:
                        failures[key]=error;print('FAILED',key,error,flush=True)
                    else:
                        entries[key]=entry;catalog['sources']=list(entries.values());atomic(catalog_path,rawjson(catalog));completed+=1
                        print('READY',key,entry['downloadBytes'],flush=True)
                    status('running',key)
            finally:results.close()
            REGION_CONTEXT=None
            if a.limit_sources and completed>=a.limit_sources:status('sample-complete');return
        status('complete-with-gaps' if deferred or failures else 'complete')
    except KeyboardInterrupt:
        status('paused-interrupted')
    except Exception as error:
        failures['coordinator']=repr(error);status('failed');raise

if __name__=='__main__':main()
