#!/usr/bin/env python3
"""Private Ben Nevis Copernicus adaptive pilot; never changes live UK sources."""
import argparse, collections, hashlib, json, math, struct, sys, zlib
from pathlib import Path
import numpy as np
import matplotlib.tri as triangulation
from PIL import Image
from common import atomic, rawjson, digest, distance
from build import build, toolchain, subbounds
from terrain import Surface, quantize

TOOLS=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(TOOLS/'world_source'))
from batch_world import load_map
from compact_codec import CompactCodec

BOUNDS=dict(minLongitude=-5.15,maxLongitude=-4.93,minLatitude=56.76,maxLatitude=56.88)
IDENT='world-scotland-copdem30-ben-nevis'


def cached_osm(archives):
    descriptor=json.loads((archives/'tiles/10/497/314/descriptor.json').read_bytes())
    semantic,graph,_,checksum=load_map(archives,dict(x=497,y=314,bounds=descriptor['bounds']))
    for key in ['minLongitude','minLatitude']:assert descriptor['bounds'][key]<=BOUNDS[key]
    for key in ['maxLongitude','maxLatitude']:assert descriptor['bounds'][key]>=BOUNDS[key]
    nodes={n['id']:n for n in graph['nodes']};routes=[]
    for edge in graph['edges']:
        ends=[nodes[edge[k]] for k in ['from','to']]
        routes.append(dict(kind=edge['pathType'],properties=dict(access=edge['access']),
            route=dict(nodes=[n['id'] for n in ends],coordinates=[[n['longitude'],n['latitude']] for n in ends],
                       bidirectional=edge['bidirectional'],reverse=False)))
    return dict(sourceSHA256=checksum,features=semantic['features'],routingFeatures=routes)


def decode(folder,asset,codec):
    packed=(folder/asset['path']).read_bytes();assert hashlib.sha256(packed).hexdigest()==asset['sha256']
    data=codec.decode(zlib.decompress(packed));assert hashlib.sha256(data).hexdigest()==asset['decodedSHA256']
    magic,nv,nt,iw,grid,scale,offset=struct.unpack('<4s4I2f',data[:28]);assert magic==b'RME1' and grid==513
    v=np.frombuffer(data,dtype=[('x','<u2'),('y','<u2'),('h','<i2')],count=nv,offset=28)
    t=np.frombuffer(data,dtype=f'<u{iw}',count=nt*3,offset=28+nv*6).reshape(-1,3).astype(np.int64)
    return v,t,v['h'].astype(float)*scale+offset


def verify(folder,surface,binaries):
    manifest=json.loads((folder/'world.json').read_bytes());codec=CompactCodec(binaries/'libridge_compact_mesh.dylib')
    xx,yy=np.meshgrid(np.arange(513.),np.arange(513.));cx,cy=np.meshgrid(np.arange(512.)+.5,np.arange(512.)+.5)
    edges={};seams=0;results=[]
    for tile in manifest['tiles']:
        grid=surface.grid(tile['mesh']['bounds'],513);raw,offset=quantize(grid);source=raw.astype(float)*.1+offset
        v,t,z=decode(folder,tile['mesh'],codec)
        np.testing.assert_allclose(z,source[v['y'],v['x']],atol=1e-5,rtol=0)
        interp=triangulation.LinearTriInterpolator(triangulation.Triangulation(v['x'],v['y'],t),z)
        p,q=interp(xx,yy),interp(cx,cy);assert not np.ma.getmaskarray(p).any() and not np.ma.getmaskarray(q).any()
        error=max(float(np.max(np.abs(p-source))),float(np.max(np.abs(q-(source[:-1,1:]+source[1:,:-1])*.5))))
        assert error<=.50001
        for axis,side,coord in [('x',0,'minLongitude'),('x',512,'maxLongitude'),('y',0,'maxLatitude'),('y',512,'minLatitude')]:
            other='y' if axis=='x' else 'x';indices=np.where(v[axis]==side)[0];indices=indices[np.argsort(v[other][indices])]
            np.testing.assert_array_equal(v[other][indices],np.arange(513))
            b=tile['mesh']['bounds'];key=(axis,round(b[coord],10),round(b['minLatitude' if axis=='x' else 'minLongitude'],10),round(b['maxLatitude' if axis=='x' else 'maxLongitude'],10))
            heights=np.rint(z[indices]*10).astype(np.int32)
            if key in edges:np.testing.assert_array_equal(edges.pop(key),heights);seams+=1
            else:edges[key]=heights
        results.append(dict(id=tile['id'],triangles=len(t),vertices=len(v),independentMaxErrorMetres=error))
    assert seams==24
    report=dict(sourceID=manifest['id'],sourceKind='Copernicus GLO-30 DSM',nominalSpacingMetres=30,
        meshToleranceMetres=.5,accuracyNote='Error measured against the resampled DSM; not 0.5 m survey accuracy.',
        tiles=results,sharedEdgesVerified=seams,maxSharedEdgeDifferenceMetres=0,
        terrainTriangles=sum(t['triangles'] for t in results),routingNodes=len(json.loads((folder/manifest['graph']['file']).read_bytes())['nodes']),
        places=[p['name'] for p in manifest['places']],cachedInputs=manifest['provenance'],sources=manifest['sources'],liveUKPublicationChanged=False)
    atomic(folder.parent.parent/'validation.json',rawjson(report));return report


def export_viewer(folder,binaries,destination,report):
    destination.mkdir(parents=True,exist_ok=True);m=json.loads((folder/'world.json').read_bytes());b=m['bounds']
    codec=CompactCodec(binaries/'libridge_compact_mesh.dylib');keys=[];heights=[];triangles=[];count=0;vectors=[]
    for tile in m['tiles']:
        v,t,z=decode(folder,tile['mesh'],codec);x=v['x'].astype(np.int64)+tile['column']*512;y=v['y'].astype(np.int64)+tile['row']*512
        keys.append(y*2049+x);heights.append(z);triangles.append(t+count);count+=len(v)
        vector=json.loads(zlib.decompress((folder/tile['map']['file']).read_bytes()));vectors.append(dict(column=tile['column'],row=tile['row'],**vector))
    keys=np.concatenate(keys);heights=np.concatenate(heights);unique,first,inverse=np.unique(keys,return_index=True,return_inverse=True)
    assert np.max(np.abs(heights-heights[first][inverse]))<1e-5
    width=distance([b['minLongitude'],(b['minLatitude']+b['maxLatitude'])/2],[b['maxLongitude'],(b['minLatitude']+b['maxLatitude'])/2])
    depth=distance([b['minLongitude'],b['minLatitude']],[b['minLongitude'],b['maxLatitude']])
    u=(unique%2049)/2048;v=(unique//2049)/2048;pos=np.column_stack([(u-.5)*width,heights[first]-700,(v-.5)*depth]);t=inverse[np.concatenate(triangles)]
    faces=np.cross(pos[t[:,1]]-pos[t[:,0]],pos[t[:,2]]-pos[t[:,0]]);faces[faces[:,1]<0]*=-1;norm=np.zeros_like(pos)
    for i in range(3):np.add.at(norm,t[:,i],faces)
    norm/=np.linalg.norm(norm,axis=1,keepdims=True)
    np.column_stack([pos,norm,u,v]).astype('<f4').tofile(destination/'terrain.vertices');t.astype('<u4').tofile(destination/'terrain.indices')
    places=[dict(name=p['name'],u=(p['coordinate']['longitude']-b['minLongitude'])/(b['maxLongitude']-b['minLongitude']),v=(b['maxLatitude']-p['coordinate']['latitude'])/(b['maxLatitude']-b['minLatitude']),elevation=p['elevation']) for p in m['places']]
    atomic(destination/'vectors.json',rawjson(dict(tiles=vectors,places=places)))
    Image.new('RGB',(64,64),(190,186,170)).save(destination/'neutral.png')
    mesh=[dict(vertices='terrain.vertices',indices='terrain.indices',count=t.size)]
    profiles=[dict(id=key,label=label,texture='neutral.png',bytes=0,detail='30 m DSM · adaptive mesh',note=note,meshes=mesh) for key,label,note in [
        ('neutral','Plain adaptive relief','Free Copernicus elevation · unchanged adaptive triangles'),
        ('baseline','Ridge map + adaptive relief','Same mesh · cached paths, water and 20 m contours')]]
    peak=max(m['places'],key=lambda p:p['elevation'] or -10000);q=peak['coordinate']
    peak_position=[(q['longitude']-(b['minLongitude']+b['maxLongitude'])/2)/(b['maxLongitude']-b['minLongitude'])*width,peak['elevation']-700,((b['minLatitude']+b['maxLatitude'])/2-q['latitude'])/(b['maxLatitude']-b['minLatitude'])*depth]
    atomic(destination/'viewer.json',rawjson(dict(profiles=profiles,defaultLeft='neutral',defaultRight='baseline',tileWidthMetres=width,tileHeightMetres=depth/2,peak=peak_position)))
    template=destination.parent/'hybrid-test/index.html';html=template.read_text()
    html=html.replace('Crib Goch','Ben Nevis').replace('Real colour variation. All the map detail.','Scotland from free elevation data.')
    html=html.replace('fine adaptive LiDAR · shared paths, contours, water and labels','30 m Copernicus DSM · real adaptive mesh · cached paths and contours')
    html=html.replace('tile.column*size/3','tile.column*size/4').replace('tile.row*size/3','tile.row*size/4').replace('size/3/tile.','size/4/tile.')
    html=html.replace("state.distance=name==='ridge'?900:3300",f"state.distance=name==='ridge'?4500:{int(max(width,depth)*1.5)}")
    start=html.index('function drawLabels(vp)');end=html.index('let textureCache=',start)
    html=html[:start]+'''function drawLabels(vp){
 const root=$('placeLabels');root.replaceChildren();if(!state.labels)return;
 const occupied=[],width=canvas.clientWidth/2,height=canvas.clientHeight;
 const places=[...vectorData.places].sort((a,b)=>(b.name==='Ben Nevis')-(a.name==='Ben Nevis')||(b.elevation||0)-(a.elevation||0));
 for(const p of places){
  const pos=[(p.u-.5)*catalog.tileWidthMetres,p.elevation-700+2,(p.v-.5)*catalog.tileHeightMetres*2,1],clip=[0,0,0,0];
  for(let r=0;r<4;r++)for(let k=0;k<4;k++)clip[r]+=vp[k*4+r]*pos[k];
  if(clip[3]<=0)continue;const nx=clip[0]/clip[3],ny=clip[1]/clip[3];if(Math.abs(nx)>.88||Math.abs(ny)>.84)continue;
  const x=(nx+1)*width/2,y=(1-ny)*height/2,w=Math.min(220,p.name.length*7);
  if(occupied.some(q=>Math.abs(q.x-x)<(q.w+w)/2+10&&Math.abs(q.y-y)<24))continue;
  occupied.push({x,y,w});
  for(let panel=0;panel<2;panel++){const el=document.createElement('span');el.className='place-label';el.textContent=p.name;el.style.left=((panel+(nx+1)/2)*50)+'%';el.style.top=((1-ny)/2*100)+'%';root.appendChild(el);}
 }
}
''' +html[end:]
    # This pilot tests geometry and existing vector styling, not satellite colour.
    html=html.replace('<label>Colour strength ', '<label style="display:none">Colour strength ')
    html=html.replace('Contains modified Copernicus Sentinel data 2025 · public Earth Search archive','Copernicus GLO-30 · approximately 30 m source elevation · 0.5 m mesh tolerance')
    html=html.replace('© OpenStreetMap contributors · Welsh Government OGL v3','© OpenStreetMap contributors · Copernicus DEM attribution in source report')
    html=html.replace('Ridge / hybrid map experiment','Ridge / free Scottish terrain test')
    html=html.replace('Ben Nevis · Hybrid map test','Ben Nevis · Free adaptive terrain test')
    atomic(destination/'index.html',html.encode());atomic(destination/'report.json',rawjson(report))


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--archives',type=Path,required=True);p.add_argument('--viewer',type=Path,required=True);a=p.parse_args()
    a.root.mkdir(parents=True,exist_ok=True);binaries=toolchain(a.root/'bin');osm=cached_osm(a.archives)
    entry=build(IDENT,BOUNDS,'Ben Nevis · free Copernicus adaptive test',None,a.root/'world',a.root/'dem-originals',binaries,workers=4,reserve_gib=8,osm_input=osm)
    atomic(a.root/'world/catalog.json',rawjson(dict(schemaVersion=1,revision='scotland-copdem30-test-v1',sources=[entry])))
    folder=a.root/'world'/Path(entry['path']).parent;surface=Surface(BOUNDS,a.root/'dem-originals',reserve_gib=8)
    report=verify(folder,surface,binaries);export_viewer(folder,binaries,a.viewer,report)
    print(json.dumps(dict(source=str(folder),viewer=str(a.viewer),triangles=report['terrainTriangles'],seams=report['sharedEdgesVerified']),indent=2))


if __name__=='__main__':main()
