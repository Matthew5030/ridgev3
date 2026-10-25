#!/usr/bin/env python3
"""Build the complete preinstalled UK map as native overhead terrain captures.

Reads retained semantic archives, UK elevation and the same illustrative ground
colour mosaics as 3D. No terrain download or running server is needed in the app.
"""
import argparse,base64,concurrent.futures,json,math,os,re,subprocess,tempfile,time
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw
import texture_overview as texture
from build import atomic_json,sha

texture.SIDE=2048
texture.AA=1

class NativeTextures(texture.Textures):
    reference_zoom=13
    maximum_capture_paths=500_000
    def __init__(self,args):
        self.mosaics=args.mosaics;self.renderer=args.renderer;self.world=args.world
        catalog=json.loads((args.world/'catalog.json').read_bytes())
        self.regions={}
        for region in catalog['sources']:
            parent=re.search(r'z10-x[0-9]+-y[0-9]+',region['id'])
            if parent:self.regions.setdefault(parent.group(),[]).append(region)
        self.extra_identity=dict(nativeRenderer=sha(args.renderer.read_bytes()),ground=list(map(str,args.mosaics)),catalogRevision=catalog['revision'],nativeVersion=3)
        super().__init__(args.base,args.background,args.atlas,args.style,args.archives,args.output)
    def height_grid(self,x,y,bounds):
        original=self.context.height(x,y)
        if original is None:raise ValueError('Missing UK elevation '+str((x,y)))
        original=np.where(original==-32768,0,original).astype(np.float32)*.1
        grid=np.asarray(Image.fromarray(original).resize((1025,1025),Image.Resampling.BILINEAR)).copy()
        baseline=grid.copy();available_grid=np.zeros(grid.shape,bool)
        latitude=np.linspace(bounds['maxLatitude'],bounds['minLatitude'],1025)
        longitude=np.linspace(bounds['minLongitude'],bounds['maxLongitude'],1025)
        for region in self.regions.get('z10-x%d-y%d'%(x,y),[]):
            file=self.world/region['path']
            if not file.exists():continue
            source=json.loads(file.read_bytes());asset=source['overview'];raw=(file.parent/asset['file']).read_bytes()
            if len(raw)!=asset['byteCount'] or sha(raw)!=asset['sha256']:raise ValueError('Damaged overview '+region['id'])
            overview=json.loads(raw);heights=np.asarray(overview['heights'],np.float32).reshape(overview['height'],overview['width']);b=source['bounds']
            columns=np.flatnonzero((longitude>=b['minLongitude']) & (longitude<=b['maxLongitude']))
            rows=np.flatnonzero((latitude>=b['minLatitude']) & (latitude<=b['maxLatitude']))
            if not len(columns) or not len(rows):continue
            u=(longitude[columns]-b['minLongitude'])/(b['maxLongitude']-b['minLongitude']);v=(b['maxLatitude']-latitude[rows])/(b['maxLatitude']-b['minLatitude'])
            sx=u*(heights.shape[1]-1);sy=v*(heights.shape[0]-1);ix=sx.astype(int);iy=sy.astype(int);jx=np.minimum(ix+1,heights.shape[1]-1);jy=np.minimum(iy+1,heights.shape[0]-1)
            fx=sx-ix;fy=sy-iy
            sampled=(heights[np.ix_(iy,ix)]*(1-fx)+heights[np.ix_(iy,jx)]*fx)*(1-fy[:,None])+(heights[np.ix_(jy,ix)]*(1-fx)+heights[np.ix_(jy,jx)]*fx)*fy[:,None]
            available=np.zeros((source['rows'],source['columns']),bool)
            for tile in source['tiles']:available[tile['row'],tile['column']]=True
            mask=available[np.ix_(np.minimum((v*source['rows']).astype(int),source['rows']-1),np.minimum((u*source['columns']).astype(int),source['columns']-1))]
            grid[np.ix_(rows,columns)]=np.where(mask,sampled,grid[np.ix_(rows,columns)])
            available_grid[np.ix_(rows,columns)] |= mask
        # Join measured local heights to the national background over 160 m;
        # an unavailable fine cell must not leave a rectangular lighting cliff.
        strength=np.zeros(grid.shape,np.float32);inside=available_grid
        for _ in range(8):
            strength+=inside.astype(np.float32)/8
            edge=np.pad(inside,1,constant_values=True)
            inside=inside & edge[1:-1,:-2] & edge[1:-1,2:] & edge[:-2,1:-1] & edge[2:,1:-1]
        return baseline+(grid-baseline)*strength
    def render(self,x,y,data):
        bounds=self.context.entries['z10-x%d-y%d'%(x,y)]['bounds'];b=bounds
        width=math.radians(b['maxLongitude']-b['minLongitude'])*6371008.8*math.cos(math.radians((b['minLatitude']+b['maxLatitude'])/2))
        depth=math.radians(b['maxLatitude']-b['minLatitude'])*6371008.8
        def coordinates(ring):return [[(p[0]-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*width,(b['maxLatitude']-p[1])/(b['maxLatitude']-b['minLatitude'])*depth] for p in ring]
        paths=[]
        for feature in data['features']:
            geometry=feature['geometry'];kind=feature['kind']
            if kind=='water' and feature.get('source',{}).get('tags',{}).get('natural')=='wetland':kind='openLand'
            if geometry['type'] in ['Polygon','MultiPolygon']:
                polygons=[geometry['coordinates']] if geometry['type']=='Polygon' else geometry['coordinates']
                for rings in polygons:paths.append(dict(kind=kind,closed=True,rings=[coordinates(r) for r in rings]))
            elif geometry['type'] in ['LineString','MultiLineString']:
                lines=[geometry['coordinates']] if geometry['type']=='LineString' else geometry['coordinates']
                for line in lines:paths.append(dict(kind=kind,closed=False,rings=[coordinates(line)]))
        grid=self.height_grid(x,y,b)
        side=2056;p=(np.arange(side,dtype=np.float32)-3.5)/2048
        lon,lat=np.meshgrid(b['minLongitude']+p*(b['maxLongitude']-b['minLongitude']),b['maxLatitude']-p*(b['maxLatitude']-b['minLatitude']))
        mask=Image.new('L',(side,side));paint=ImageDraw.Draw(mask)
        for kind,rings,box in self.context.features:
            if kind=='land' and texture.intersects(box,(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])):
                paint.polygon([((p[0]-b['minLongitude'])/(b['maxLongitude']-b['minLongitude'])*2048+4,(b['maxLatitude']-p[1])/(b['maxLatitude']-b['minLatitude'])*2048+4) for p in rings[0]],fill=255)
        positive=Image.fromarray(np.uint8(grid>0)*255).resize((2048,2048),Image.Resampling.NEAREST)
        expanded=Image.new('L',(side,side));expanded.paste(positive,(4,4));land=(np.asarray(mask)>0)|(np.asarray(expanded)>0)
        base=np.empty((side,side,4),np.uint8);base[:]=(*texture.SEA,255);base[land]=(*texture.LAND,255)
        vector=dict(width=width,height=depth,paths=paths)
        mosaic=next((root/('world-z10-x%d-y%d.tif'%(x,y)) for root in self.mosaics if (root/('world-z10-x%d-y%d.tif'%(x,y))).exists()),None)
        if mosaic:
            metadata=json.loads(mosaic.with_suffix('.json').read_bytes());west,south,east,north=metadata['bounds']
            with Image.open(mosaic) as source:rgba=np.asarray(source.convert('RGBA')).copy()
            h,w=rgba.shape[:2];sx=np.clip((lon-west)/(east-west)*w-.5,0,w-1);sy=np.clip((north-lat)/(north-south)*h-.5,0,h-1)
            ix=sx.astype(int);iy=sy.astype(int);jx=np.minimum(ix+1,w-1);jy=np.minimum(iy+1,h-1);fx=(sx-ix)[...,None];fy=(sy-iy)[...,None]
            sampled=np.zeros((side,side,4),np.float32)
            for xx,yy,weight in [(ix,iy,(1-fx)*(1-fy)),(jx,iy,fx*(1-fy)),(ix,jy,(1-fx)*fy),(jx,jy,fx*fy)]:sampled+=rgba[yy,xx]*weight
            sampled=np.uint8(np.clip(sampled+.5,0,255));sampled[...,3]*=land
            vector['groundColour']=dict(version=1,width=side,height=side,border=4,rgba=base64.b64encode(sampled.tobytes()).decode())
        with tempfile.TemporaryDirectory(prefix='ridge-native-atlas-') as temporary:
            folder=Path(temporary)
            (folder/'base.bin').write_bytes(base.tobytes());(folder/'heights.bin').write_bytes(grid.astype('<f4').tobytes())
            (folder/'surface.json').write_text(json.dumps(dict(bounds=b,side=grid.shape[0],pixels=2048)))
            # Dense cities can exceed a runtime tile's path-count limit. Keep
            # the full camera, heights, materials and ground in every pass;
            # crop disjoint image rectangles only after native rendering.
            # Whole crossing features and an AA margin preserve identical ink.
            boxes=None
            if len(paths)>self.maximum_capture_paths:
                boxes=[]
                for path in paths:
                    points=[p for ring in path['rings'] for p in ring]
                    boxes.append((min(p[0] for p in points),min(p[1] for p in points),max(p[0] for p in points),max(p[1] for p in points)) if points else (0,0,0,0))
            image=np.empty((2048,2048,3),np.uint8)
            pending=[(0,0,2048,2048,list(range(len(paths))))]
            while pending:
                left,top,right,bottom,selected=pending.pop()
                if len(selected)>self.maximum_capture_paths:
                    if right-left<16 or bottom-top<16:raise ValueError('Unbounded feature density')
                    midx=(left+right)//2;midy=(top+bottom)//2
                    for l,t,r,d in [(left,top,midx,midy),(midx,top,right,midy),(left,midy,midx,bottom),(midx,midy,right,bottom)]:
                        region=(l/2048*width-20,t/2048*depth-20,r/2048*width+20,d/2048*depth+20)
                        members=[i for i in selected if texture.intersects(boxes[i],region)]
                        pending.append((l,t,r,d,members))
                    continue
                vector['paths']=[paths[i] for i in selected]
                (folder/'map.json').write_text(json.dumps(vector,separators=(',',':')))
                result=subprocess.run([str(self.renderer),'--surface',str(folder),str(folder/'capture.png')],capture_output=True,text=True,timeout=120)
                if result.returncode:raise ValueError('Native capture failed: '+result.stderr[:1000]+result.stderr[-500:])
                with Image.open(folder/'capture.png') as capture:
                    image[top:bottom,left:right]=np.asarray(capture.convert('RGB'))[top:bottom,left:right]
        # Reproject the north-up geographic camera to the atlas Mercator grid.
        latitudes=np.degrees(np.arctan(np.sinh(math.pi*(1-2*(y+(np.arange(2048)+.5)/2048)/1024))))
        sy=np.clip((b['maxLatitude']-latitudes)/(b['maxLatitude']-b['minLatitude'])*2048-.5,0,2047);i=sy.astype(int);j=np.minimum(i+1,2047);f=(sy-i)[:,None,None]
        return Image.fromarray(np.uint8(image[i]*(1-f)+image[j]*f+.5))
    def publish(self,records):
        report=super().publish(records)
        file=self.output/'index.json';index=json.loads(file.read_bytes())
        index.update(quality='Preinstalled native overhead UK terrain map',renderer='WorldPreview',groundColourStrength=.66)
        index['sources'].append(dict(name='Copernicus Sentinel-2',attribution='Contains modified Copernicus Sentinel data 2025. Satellite-guided illustrative ground colours.',license='Copernicus Sentinel data terms',url='https://dataspace.copernicus.eu/explore-data/data-collections/sentinel-data/sentinel-2'))
        atomic_json(file,index);return report

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['base','background','atlas','style','archives','output','renderer','world']:parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--mosaics',type=Path,action='append',required=True);parser.add_argument('--section',action='append');parser.add_argument('--workers',type=int,default=2)
    args=parser.parse_args();builder=NativeTextures(args)
    paths=sorted(args.archives.glob('tiles/10/*/*/descriptor.json'))
    if args.section:paths=[p for p in paths if 'z10-x%s-y%s'%(p.parent.parent.name,p.parent.name) in args.section]
    started=time.monotonic();records=[]
    # Two in-flight sections bound semantic JSON and satellite sample memory.
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for future in concurrent.futures.as_completed([pool.submit(builder.section,path) for path in paths]):
            record=future.result()
            records.append(record)
            status=dict(state='rendering',completed=len(records),total=len(paths),section=record['id'],elapsedSeconds=round(time.monotonic()-started),pid=os.getpid())
            atomic_json(args.output/'status.json',status);print(json.dumps(status),flush=True)
    if args.section:
        atomic_json(args.output/'status.json',dict(state='sample-complete',completed=len(records),total=len(paths)))
        return
    report=builder.publish(sorted(records,key=lambda r:r['id']))
    atomic_json(args.output/'status.json',dict(state='complete',**report,elapsedSeconds=round(time.monotonic()-started)))

if __name__=='__main__':main()
