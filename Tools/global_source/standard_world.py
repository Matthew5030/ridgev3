"""Fill only planned missing UK tiles; preserve every retained published asset."""
import collections, concurrent.futures, fcntl, hashlib, json, math, os, sqlite3, struct, sys, time, zlib
from pathlib import Path
import numpy as np
import contourpy
from shapely.geometry import shape,box,LineString
from shapely.ops import transform
from shapely.strtree import STRtree
from common import atomic,rawjson,digest,reserve
from standard_terrain import Surface,Boundaries,Compiler,bounds,tile_key,parse,key,decode
TOOLS=Path(__file__).resolve().parents[1];sys.path.insert(0,str(TOOLS/'world_source'))
from batch_world import load_map
from terrain_coverage import missing_terrain
from publish_connected_paths import connect,inside
from pack_sections import build as pack_section,assets as section_assets

def emit(**fields):print(json.dumps(dict(time=time.time(),**fields)),flush=True)
def resident(c):return c['vertices']*54+c['triangles']*(3*c['indexWidth']+32)+65536
def asset(folder,name,data,path=False):
    sha=hashlib.sha256(data).hexdigest();atomic(folder/name,data)
    return {('path' if path else 'file'):name,'byteCount':len(data),'sha256':sha}
def link(source,target):
    if target.is_symlink() or target.exists():
        if target.resolve()==source.resolve():return
        raise ValueError('Private staging filename collision: '+str(target))
    target.symlink_to(source.resolve())
def quality_rectangles(manifest,standard):
    dummy=dict(manifest,tiles=[dict(column=c,row=r) for r in range(16) for c in range(16) if (c,r) not in standard])
    return missing_terrain(dummy)

class Parent:
    def __init__(self,root,world,archives,row):
        self.root,self.world,self.archives,self.row=root,world,archives,row
        self.output=root/'world';self.output.mkdir(exist_ok=True);self.surface=Surface(root);self.boundaries=Boundaries(root,row);self.compiler=Compiler(root)
        self.before={s['id']:s for s in json.loads((root/'catalog.before.json').read_bytes())['sources']}
        self.b=bounds(row['x'],row['y']);semantic,self.original_graph,self.credits,self.archive_sha=load_map(archives,dict(x=row['x'],y=row['y'],bounds=self.b))
        self.width=math.radians(self.b['maxLongitude']-self.b['minLongitude'])*6371008.8*math.cos(math.radians((self.b['maxLatitude']+self.b['minLatitude'])/2));self.depth=math.radians(self.b['maxLatitude']-self.b['minLatitude'])*6371008.8
        self.tw,self.th=self.width/48,self.depth/48
        def project(x,y,z=None):return (np.asarray(x)-self.b['minLongitude'])/(self.b['maxLongitude']-self.b['minLongitude'])*self.width,(self.b['maxLatitude']-np.asarray(y))/(self.b['maxLatitude']-self.b['minLatitude'])*self.depth
        self.features=[];self.kinds=[];self.places=[]
        for f in semantic['features']:
            g=shape(f['geometry'])
            if g.geom_type=='Point':self.places.append(f);continue
            if not g.is_valid:g=g.buffer(0)
            if not g.is_empty:self.features.append(transform(project,g));self.kinds.append(f['kind'])
        self.tree=STRtree(self.features);self.graph_nodes,self.graph_ids=connect(self.original_graph,self.b,row['id']);self.edge_records=[];self.deferred=[];self.validated=False
    def grid(self,s,c,r):
        x,y,sx,sy=parse(s['id']);b=bounds(x,y,sx+c,sy+r,1);grid=self.surface.grid(b)
        return self.boundaries.constrain(grid,tile_key(s['id'],c,r))
    def graph(self,s,old):
        if old:
            original=json.loads((self.world/'sources'/s['id']/old.get('routing',old['graph'])['file']).read_bytes());return original
        selected={k for k,n in self.graph_nodes.items() if inside(s['bounds'],n)};edges=[e for e in self.original_graph['edges'] if e['from'] in selected or e['to'] in selected];used={e[k] for e in edges for k in ['from','to']}
        return dict(nodes=[dict(id=self.graph_ids[k],coordinate=dict(latitude=self.graph_nodes[k]['latitude'],longitude=self.graph_nodes[k]['longitude']),elevation=self.graph_nodes[k]['elevationMeters']) for k in sorted(used)],edges=[dict(**{'from':self.graph_ids[e['from']],'to':self.graph_ids[e['to']]},distance=e['distanceMeters'],bidirectional=e['bidirectional'],access=e['access'],kind=e['pathType']) for e in edges])
    def vectors(self,grid,c,r,sx,sy):
        x0,y0=(sx+c)*self.tw,(sy+r)*self.th;clip=box(x0-4,y0-4,x0+self.tw+4,y0+self.th+4);paths=[]
        def coords(a):return [[round(x-x0,2),round(y-y0,2)] for x,y in a]
        def append(kind,g):
            if g.is_empty:return
            if g.geom_type=='Polygon':paths.append(dict(kind=kind,closed=True,rings=[coords(g.exterior.coords)]+[coords(i.coords) for i in g.interiors]))
            elif g.geom_type in ('LineString','LinearRing'):paths.append(dict(kind=kind,closed=False,rings=[coords(g.coords)]))
            elif hasattr(g,'geoms'):
                for part in g.geoms:append(kind,part)
        for i in self.tree.query(clip,predicate='intersects'):append(self.kinds[i],self.features[i].intersection(clip))
        h=grid[::4,::4].astype(float)*.1;cg=contourpy.contour_generator(x=np.linspace(x0,x0+self.tw,129),y=np.linspace(y0,y0+self.th,129),z=h)
        for level in range(math.ceil(h.min()/20)*20,math.ceil(h.max()/20)*20,20):
            for points in cg.lines(level):append('contourIndex' if level%100==0 else 'contour',LineString(points).simplify(.25))
        data=rawjson(dict(width=self.tw,height=self.th,paths=paths))
        if len(data)>8_000_000 or len(paths)>50000:raise ValueError('Map page exceeds app limit')
        return data
    def audit_mesh(self,s,c,r,packed,grid):
        b,v,h=decode(packed,self.compiler.codec);np.testing.assert_array_equal(h,grid[v['y'],v['x']]);gx,gy=tile_key(s['id'],c,r)&65535,tile_key(s['id'],c,r)>>16
        for axis,side,identity in [('x',0,('v',gx,gy)),('x',512,('v',gx+1,gy)),('y',0,('h',gx,gy)),('y',512,('h',gx,gy+1))]:
            other='y' if axis=='x' else 'x';i=np.where(v[axis]==side)[0];i=i[np.argsort(v[other][i])];np.testing.assert_array_equal(v[other][i],np.arange(513));a=h[i].astype('<i2');self.edge_records.append(dict(key=identity,sha256=hashlib.sha256(a.tobytes()).hexdigest(),first=int(a[0]),last=int(a[-1])))
        if not self.validated:
            import matplotlib.tri as tri
            _,nv,nt,iw,_,_,_=struct.unpack('<4s4I2f',b[:28]);t=np.frombuffer(b,dtype=f'<u{iw}',count=nt*3,offset=28+nv*6).reshape(-1,3).astype(np.int64)
            interp=tri.LinearTriInterpolator(tri.Triangulation(v['x'],v['y'],t),h.astype(float)*.1);xx,yy=np.meshgrid(np.arange(513.),np.arange(513.));cx,cy=np.meshgrid(np.arange(512.)+.5,np.arange(512.)+.5)
            p,q=interp(xx,yy),interp(cx,cy);assert not np.ma.getmaskarray(p).any() and not np.ma.getmaskarray(q).any();source=grid.astype(float)*.1
            error=max(float(np.max(np.abs(p-source))),float(np.max(np.abs(q-(source[:-1,1:]+source[1:,:-1])*.5))));assert error<=.500001
            self.validated=True;emit(event='independent-surface-verified',parent=self.row['id'],tile=f'{s["id"]}/{c}/{r}',maximumErrorMetres=error)
    def source(self,s):
        reserve(self.root,3);folder=self.output/'sources'/s['id'];folder.mkdir(parents=True,exist_ok=True);complete=folder/'standard-complete.json'
        if complete.exists():
            proof=json.loads((folder/'standard-validation.json').read_bytes());self.edge_records.extend(proof['edges']);self.deferred.extend(proof['deferred']);self.validated=self.validated or proof['independentSurfaceChecked'];return json.loads(complete.read_bytes())
        edge_start=len(self.edge_records);deferred_start=len(self.deferred)
        old_entry=self.before.get(s['id']);old=json.loads((self.world/old_entry['path']).read_bytes()) if old_entry else None
        if old:
            atomic(folder/'world.before.json',(self.world/old_entry['path']).read_bytes())
            for tile in old['tiles']:
                for kind in ['mesh','background','map']:
                    a=tile[kind];name=a.get('path',a.get('file'));link(self.world/'sources'/s['id']/name,folder/name)
            tiles=list(old['tiles']);raw_overview=json.loads((self.world/'sources'/s['id']/old['overview']['file']).read_bytes());a=np.array(raw_overview['heights']).reshape(raw_overview['height'],raw_overview['width']);stride=(a.shape[0]-1)//256;assert stride>=1 and (a.shape[0]-1)%256==0;overview=a[::stride,::stride].copy()
        else:tiles=[];overview=np.full((257,257),np.nan)
        _,_,sx,sy=parse(s['id']);graph=self.graph(s,dict(old or {},routing=old_entry['routing']) if old and old_entry.get('routing') else old)
        grouped=collections.defaultdict(list)
        for node in graph['nodes']:
            p=node['coordinate'];b=s['bounds'];u=(p['longitude']-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*16;v=(b['maxLatitude']-p['latitude'])/(b['maxLatitude']-b['minLatitude'])*16
            if 0<=u<=16 and 0<=v<=16:grouped[(min(15,int(u)),min(15,int(v)))].append((node,u,v))
        standard=set();corrections=[];local_edges=[]
        for c,r in s['newCells']:
            tid=f'c{c:02d}-r{r:02d}';checkpoint=folder/(tid+'.standard-checkpoint.json')
            try:grid,correction=self.grid(s,c,r)
            except ValueError as e:self.deferred.append(dict(source=s['id'],column=c,row=r,error=str(e)));continue
            if checkpoint.exists():
                result=json.loads(checkpoint.read_bytes());assert result['preparedHeightSHA256']==hashlib.sha256(grid.tobytes()).hexdigest();tile=result['tile'];packed=(folder/tile['mesh']['path']).read_bytes();assert hashlib.sha256(packed).hexdigest()==tile['mesh']['sha256']
            else:
                packed,meta=self.compiler.compile(grid,.5,True);name=tid+'-terrain-'+meta['sha256'][:16]+'.rat.zlib';atomic(folder/name,packed);mesh=dict(meta,id=tid,path=name,bounds=bounds(self.row['x'],self.row['y'],sx+c,sy+r,1))
                vector=self.vectors(grid,c,r,sx,sy);compressed=zlib.compress(vector,6);sha=hashlib.sha256(compressed).hexdigest();map_asset=asset(folder,tid+'-ground-'+sha[:16]+'.map',compressed);map_asset['decodedByteCount']=len(vector)
                tile=dict(id=tid,column=c,row=r,mesh=mesh,background=dict(mesh),map=map_asset,terrainQuality='standard');atomic(checkpoint,rawjson(dict(tile=tile,preparedHeightSHA256=hashlib.sha256(grid.tobytes()).hexdigest())))
            self.audit_mesh(s,c,r,packed,grid);tiles.append(tile);standard.add((c,r));corrections.append(correction)
            overview[r*16:r*16+17,c*16:c*16+17]=grid[::32,::32].astype(float)*.1
            for node,u,v in grouped[(c,r)]:
                px,py=(u-c)*512,(v-r)*512;ix,iy=min(511,int(px)),min(511,int(py));fx,fy=px-ix,py-iy
                node['elevation']=round(float((grid[iy,ix]*(1-fx)*(1-fy)+grid[iy,ix+1]*fx*(1-fy)+grid[iy+1,ix]*(1-fx)*fy+grid[iy+1,ix+1]*fx*fy)*.1),1)
        if not tiles:return None
        # Reusing the fine mesh as a standard background avoids duplicate files;
        # only unusually large tiles need a separate 2 m background.
        memory=sum(resident(t['background']) for t in tiles)
        for tile in sorted((t for t in tiles if (t['column'],t['row']) in standard),key=lambda t:resident(t['background']),reverse=True):
            if memory<=250*1024**2:break
            grid,_=self.grid(s,tile['column'],tile['row']);packed,meta=self.compiler.compile(grid,2,False);name=tile['id']+'-terrain-'+meta['sha256'][:16]+'.background.rat.zlib';atomic(folder/name,packed);old_mem=resident(tile['background']);tile['background']=dict(meta,id=tile['id'],path=name,bounds=tile['mesh']['bounds']);memory+=resident(tile['background'])-old_mem
        if memory>256*1024**2:raise ValueError('Source exceeds app background memory limit')
        tiles.sort(key=lambda t:(t['row'],t['column']));overview=np.nan_to_num(overview,nan=0).round(1);data=rawjson(dict(width=257,height=257,heights=overview.ravel().tolist()));sha=hashlib.sha256(data).hexdigest();overview_asset=asset(folder,'overview-32m-'+sha[:16]+'.json',data)
        data=rawjson(graph);sha=hashlib.sha256(data).hexdigest();graph_asset=asset(folder,'paths-'+sha[:16]+'.json',data)
        places=list(old['places']) if old else []
        if not old:
            for f in self.places:
                p=f['properties'];lon,lat=f['geometry']['coordinates'];b=s['bounds']
                if p.get('name') and b['minLongitude']<=lon<=b['maxLongitude'] and b['minLatitude']<=lat<=b['maxLatitude']:
                    places.append(dict(id=f['id'],name=p['name'],coordinate=dict(longitude=lon,latitude=lat),kind=f['kind'],elevation=p.get('elevationMeters')))
        credits=list(old['sources']) if old else [dict(name=e['source'],attribution=e['text'],license=e['license'],url=e['url']) for e in self.credits['entries'] if e['source']=='OpenStreetMap']
        credits.append(dict(name='Copernicus DEM GLO-30',attribution='Produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all rights reserved.',license='Copernicus DEM Free & Open licence',url='https://registry.opendata.aws/copernicus-dem/'))
        manifest=dict(schemaVersion=1,id=s['id'],name=old['name'] if old else s['name'],revision=(old['revision'] if old else 'world-v1')+'-uk-standard-v1',bounds=s['bounds'],columns=16,rows=16,overview=overview_asset,graph=graph_asset,tiles=tiles,places=places,sources=credits,backgroundToleranceMetres=2,semanticArchiveSHA256=self.archive_sha,
            terrainSource=dict(kind='mixed' if old else 'DSM',standardNominalSpacingMetres=30,verticalDatum='EGM96',originalVerticalDatum='EGM2008',meshToleranceMetres=.5,quantisationMetres=.1,transition='Only new cells adjusted to exact retained LiDAR edges; fourth-power boundary decay',maximumTransitionCorrectionMetres=max(corrections,default=0)))
        atomic(folder/'world.json',rawjson(manifest));entry=dict(id=s['id'],path='sources/'+s['id']+'/world.json',bounds=s['bounds'],tileCount=len(tiles),routing=graph_asset,backgroundResidentBytes=memory,missingTerrain=missing_terrain(manifest),standardTileCount=len(standard),standardTerrain=quality_rectangles(manifest,standard))
        entry['pack']=pack_section(self.output,entry);entry['downloadBytes']=sum(a['byteCount'] for a in section_assets(manifest,entry));atomic(folder/'standard-validation.json',rawjson(dict(edges=self.edge_records[edge_start:],deferred=self.deferred[deferred_start:],independentSurfaceChecked=self.validated)));atomic(complete,rawjson(entry));emit(event='standard-source-complete',source=s['id'],addedTiles=len(standard),existingTiles=len(old['tiles']) if old else 0,packBytes=entry['pack']['byteCount'])
        for file in folder.glob('*.standard-checkpoint.json'):file.unlink()
        return entry
    def run(self):
        entries=[]
        for s in self.row['sources']:
            entry=self.source(s)
            if entry:entries.append(entry)
        atomic(self.root/'seams'/(self.row['id']+'.json'),rawjson(dict(parent=self.row['id'],edges=self.edge_records,deferred=self.deferred,independentSurfaceChecked=self.validated)))
        atomic(self.root/'completed'/(self.row['id']+'.json'),rawjson(entries));return entries

def parent_job(arguments):
    root,world,archives,row=arguments
    try:
        Parent(Path(root),Path(world),Path(archives),row).run();return row['id'],None
    except Exception as error:
        import traceback
        emit(event='standard-parent-failed',parent=row['id'],error=str(error),traceback=traceback.format_exc());return row['id'],str(error)

def run(root,world,archives,workers=6,limit=0):
    root=Path(root);lock=(root/'.build.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    if not (root/'INPUTS-COMPLETE.json').exists():raise ValueError('Finish verified source preparation first')
    plan=json.loads((root/'plan.json').read_bytes());rows=[r for r in plan['parents'] if not (root/'completed'/(r['id']+'.json')).exists()]
    if limit:rows=rows[:limit]
    started=time.time();done=0;failures={}
    def status():atomic(root/'status.json',rawjson(dict(state='building',parentsCompleted=len(list((root/'completed').glob('*.json'))) if (root/'completed').exists() else 0,totalParents=len(plan['parents']),elapsedSeconds=round(time.time()-started),failures=failures)))
    status()
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as pool:
        jobs=[pool.submit(parent_job,(str(root),str(world),str(archives),r)) for r in rows]
        for job in concurrent.futures.as_completed(jobs):
            ident,error=job.result()
            if error:failures[ident]=error
            else:done+=1
            status();emit(event='standard-parent-finished',parent=ident,completedThisRun=done,failures=len(failures))
    status()
    if failures:raise RuntimeError('Some parent builds failed; see status.json')

if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['root','world','archives']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--workers',type=int,default=8);parser.add_argument('--limit',type=int,default=0);args=parser.parse_args()
    files=[Path(__file__),Path(__file__).with_name('standard_terrain.py'),TOOLS/'adaptive_terrain/park_mesh.cpp']
    identity=dict(builderSHA256=hashlib.sha256(b''.join(f.read_bytes() for f in files)).hexdigest(),inputsSHA256=digest(args.root/'inputs.json'),planSHA256=digest(args.root/'plan.json'))
    record=args.root/'builder.json'
    if record.exists() and json.loads(record.read_bytes())!=identity:raise ValueError('Builder/input changed; review checkpoints before resuming')
    atomic(record,rawjson(identity));run(args.root,args.world,args.archives,args.workers,args.limit)
    print('ALL STANDARD TERRAIN STAGED',flush=True)
