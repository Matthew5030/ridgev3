#!/usr/bin/env python3
"""Build an adaptive background from the original 1 m surface into a new directory.
Never changes the fine terrain, vectors, or a published source in place.
"""
import argparse, concurrent.futures, hashlib, json, struct, subprocess, tempfile, zlib
from pathlib import Path

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--pack',type=Path,required=True)
    p.add_argument('--world',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--tolerance',type=float,default=2)
    a=p.parse_args()
    if a.output.exists() and any(a.output.iterdir()): p.error('--output must be empty')
    if not .5<=a.tolerance<=8:p.error('background tolerance must be 0.5–8 m')
    a.output.mkdir(parents=True,exist_ok=True)
    pack=json.loads((a.pack/'pack.json').read_bytes());level=next(x for x in pack['levels'] if x['spacing']==1)
    raw=(a.pack/level['file']).read_bytes();sha=lambda b:hashlib.sha256(b).hexdigest()
    assert sha(raw)==level['sha256'] and pack['heightScale']==.1 and pack['noDataValue']==-32768
    world=json.loads((a.world/'world.json').read_bytes())
    assert world['sourceTerrainSHA256']==sha(raw)
    assert level['width']==world['columns']*512+1 and level['height']==world['rows']*512+1
    compiler=Path(__file__).resolve().parents[1]/'adaptive_terrain'
    with tempfile.TemporaryDirectory(prefix='ridge-background-') as tmp:
        tmp=Path(tmp)
        for name in ['park_mesh','compact_mesh']:
            subprocess.run(['clang++','-O3','-std=c++17',str(compiler/(name+'.cpp')),'-o',str(tmp/name)],check=True)
        def build(tile):
            ident=tile['id'];c=tile['column'];r=tile['row'];width=level['width']
            grid=b''.join(raw[((r*512+y)*width+c*512)*2:((r*512+y)*width+c*512+513)*2] for y in range(513))
            src=tmp/(ident+'.bin');src.write_bytes(grid)
            mesh=tmp/(ident+'.rmesh');top=tmp/(ident+'.rat')
            facts=json.loads(subprocess.check_output([str(tmp/'park_mesh'),str(src),str(mesh),str(a.tolerance),'adaptive-edges']))
            subprocess.run([str(tmp/'compact_mesh'),'encode',str(mesh),str(top)],stdout=subprocess.DEVNULL,check=True)
            decoded=mesh.read_bytes();topology=top.read_bytes();compressed=zlib.compress(topology,9)
            name=ident+'.background.rat.zlib';(a.output/name).write_bytes(compressed)
            chunk=dict(id=ident,path=name,bounds=tile['mesh']['bounds'],byteCount=len(compressed),sha256=sha(compressed),decodedByteCount=len(decoded),decodedSHA256=sha(decoded),vertices=facts['vertices'],triangles=facts['triangles'],indexWidth=facts['indexWidth'],topologyByteCount=len(topology),topologySHA256=sha(topology),maxErrorMetres=facts['maxErrorMetres'])
            points=[struct.unpack_from('<HHh',decoded,28+i*6) for i in range(facts['vertices'])]
            segments=sum(sum(1 for x,y,z in points if (x if e<2 else y)==(0 if e%2==0 else 512))-1 for e in range(4))
            # Native iOS vertex/normal/UV buffers plus UInt32 indices and seam skirts.
            geometry=facts['vertices']*32+facts['triangles']*12+segments*152
            return dict(chunk=chunk,geometryBytes=geometry,skirtSegments=segments)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(build,world['tiles']))
    report=dict(toleranceMetres=a.tolerance,sourceTerrainSHA256=sha(raw),tiles=results,downloadBytes=sum(x['chunk']['byteCount'] for x in results),geometryBytes=sum(x['geometryBytes'] for x in results),triangles=sum(x['chunk']['triangles'] for x in results),maxErrorMetres=max(x['chunk']['maxErrorMetres'] for x in results))
    (a.output/'background-index.json').write_text(json.dumps(report,separators=(',',':')))
    print(json.dumps({k:v for k,v in report.items() if k!='tiles'},indent=2))
if __name__=='__main__':main()
