#!/usr/bin/env python3
"""Prepare bounded 1 m park inputs from official Scottish DTM rasters.
Only sources at 1 m or finer are accepted. A virtual 1 m BNG mosaic joins
adjacent rasters before sampling the existing Ridge geographic chunk grid.
Missing samples reject a whole native chunk; they are never invented.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import time
import xml.etree.ElementTree as ET
import fcntl
from collections import OrderedDict
import numpy as np
import rasterio
from rasterio.windows import Window
from pyproj import datadir
from pyproj.transformer import TransformerGroup
from shapely.geometry import shape, box
from shapely.ops import unary_union
from shapely.strtree import STRtree

NO_DATA=-32768


def digest_file(path):
    sha=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(4*1024*1024),b''):sha.update(block)
    return sha.hexdigest()


def atomic_json(path,value):
    temporary=path.with_suffix('.next.json')
    temporary.write_text(json.dumps(value,separators=(',',':'))+'\n');temporary.replace(path)


def inspect_sources(records):
    result=[]
    for i,record in enumerate(records):
        path=Path(record['path'])
        if path.stat().st_size!=record['byteCount'] or digest_file(path)!=record['sha256']:
            raise ValueError(f'DTM checksum: {path.name}')
        with rasterio.open(path) as ds:
            if ds.count!=1 or ds.crs.to_epsg()!=27700 or ds.transform.b!=0 or ds.transform.d!=0:
                raise ValueError(f'Expected one north-up British National Grid DTM band: {path.name}')
            # Historic 1 m GeoTIFF georeferencing differs by a few micrometres
            # per pixel. Allow 10 ppm, not a coarser source resolution.
            if not (0<ds.res[0]<=1.00001 and 0<ds.res[1]<=1.00001):
                raise ValueError(f'Source is coarser than 1 m: {path.name}')
            if ds.units[0] not in (None,'','m','metre','meter','metres','meters'):
                raise ValueError('Unexpected elevation units')
            item=dict(record,width=ds.width,height=ds.height,bounds=list(ds.bounds),
                      spacing=max(ds.res),nodata=ds.nodata,scale=ds.scales[0],offset=ds.offsets[0],
                      block=list(ds.block_shapes[0]))
            result.append(item)
        print(f'Checked official DTM {i+1}/{len(records)}',flush=True)
    return result


def make_mosaic(records,path):
    # Later sources win where valid: finer resolution, then later phase/key.
    records=sorted(records,key=lambda r:(-round(r['spacing'],4),100 if 'national-lidar-programme' in r['key'] else int(r['key'].split('phase-')[1].split('/')[0]),r['key']))
    west=math.floor(min(r['bounds'][0] for r in records));south=math.floor(min(r['bounds'][1] for r in records))
    east=math.ceil(max(r['bounds'][2] for r in records));north=math.ceil(max(r['bounds'][3] for r in records))
    root=ET.Element('VRTDataset',rasterXSize=str(east-west),rasterYSize=str(north-south))
    ET.SubElement(root,'SRS').text='EPSG:27700'
    ET.SubElement(root,'GeoTransform').text=f'{west}, 1, 0, {north}, 0, -1'
    band=ET.SubElement(root,'VRTRasterBand',dataType='Float32',band='1')
    ET.SubElement(band,'NoDataValue').text='nan'
    for r in records:
        left,bottom,right,top=r['bounds']
        source=ET.SubElement(band,'ComplexSource',resampling='bilinear')
        ET.SubElement(source,'SourceFilename',relativeToVRT='0').text=str(Path(r['path']).resolve())
        ET.SubElement(source,'SourceBand').text='1'
        ET.SubElement(source,'SrcRect',xOff='0',yOff='0',xSize=str(r['width']),ySize=str(r['height']))
        ET.SubElement(source,'DstRect',xOff=str(left-west),yOff=str(north-top),xSize=str(right-left),ySize=str(top-bottom))
        ET.SubElement(source,'UseMaskBand').text='true'
        if r['nodata'] is not None:ET.SubElement(source,'NODATA').text=str(r['nodata'])
        ET.SubElement(source,'ScaleRatio').text=str(r['scale'])
        ET.SubElement(source,'ScaleOffset').text=str(r['offset'])
    ET.ElementTree(root).write(path,encoding='utf-8',xml_declaration=True)


class CanonicalMosaic:
    """Read VRT pixels on fixed blocks, independent of the requesting chunk.

    GDAL bilinear VRT reads can differ slightly with the request window. Even
    sub-millimetre differences can cross a 0.1 m quantisation threshold. Every
    source pixel must therefore come from the same globally aligned read.
    """
    def __init__(self,ds):
        self.ds=ds;self.transform=ds.transform;self.cache=OrderedDict()

    def window(self,x0,y0,width,height):
        size=512;out=np.empty((height,width),dtype=np.float32)
        for by in range(y0//size,(y0+height-1)//size+1):
            for bx in range(x0//size,(x0+width-1)//size+1):
                key=(bx,by)
                if key not in self.cache:
                    self.cache[key]=self.ds.read(1,window=Window(bx*size,by*size,size,size),boundless=True,masked=True).filled(np.nan)
                    if len(self.cache)>64:self.cache.popitem(last=False)
                self.cache.move_to_end(key);block=self.cache[key]
                left=max(x0,bx*size);top=max(y0,by*size)
                right=min(x0+width,(bx+1)*size);bottom=min(y0+height,(by+1)*size)
                out[top-y0:bottom-y0,left-x0:right-x0]=block[top-by*size:bottom-by*size,left-bx*size:right-bx*size]
        return out


def sample_projected(ds,x,y):
    # Four-neighbour interpolation on a single continuous 1 m mosaic. Do not
    # independently clamp each input TIFF at its border: that creates seams.
    px=(x-ds.transform.c)/ds.transform.a-.5;py=(y-ds.transform.f)/ds.transform.e-.5
    ix=np.floor(px).astype(np.int64);iy=np.floor(py).astype(np.int64)
    x0=int(ix.min());y0=int(iy.min());width=int(ix.max()-x0+2);height=int(iy.max()-y0+2)
    if width>2048 or height>2048:raise ValueError('Unexpected sampling-window size')
    sampler=ds if isinstance(ds,CanonicalMosaic) else CanonicalMosaic(ds)
    window=sampler.window(x0,y0,width,height)
    xx=ix-x0;yy=iy-y0;fx=px-ix;fy=py-iy
    a=window[yy,xx];b=window[yy,xx+1];c=window[yy+1,xx];d=window[yy+1,xx+1]
    valid=np.isfinite(a)&np.isfinite(b)&np.isfinite(c)&np.isfinite(d)
    values=a*(1-fx)*(1-fy)+b*fx*(1-fy)+c*(1-fx)*fy+d*fx*fy
    return values,valid


def bounds(x,y,column,row):
    west=x/1024*360-180;east=(x+1)/1024*360-180
    lat=lambda n:math.degrees(math.atan(math.sinh(math.pi*(1-2*n/1024))))
    north=lat(y);south=lat(y+1)
    return dict(minLongitude=west+column/48*(east-west),maxLongitude=west+(column+1)/48*(east-west),
                minLatitude=north-(row+1)/48*(north-south),maxLatitude=north-row/48*(north-south))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sources',type=Path,required=True);p.add_argument('--boundaries',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);p.add_argument('--coordinate-grids',type=Path,required=True)
    args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    lock=(args.output/'.prepare.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    datadir.append_data_dir(str(args.coordinate_grids))
    transforms=TransformerGroup(4326,27700,always_xy=True)
    if not transforms.best_available:raise ValueError('Install the official OSTN15 transformation grid first')
    transformer=transforms.transformers[0]
    features=[json.loads((args.boundaries/f'{key}.geojson').read_text()) for key in ['cairngorms','loch-lomond-and-the-trossachs']]
    park=unary_union([shape(f['geometry']) for f in features])
    fingerprint=hashlib.sha256(args.sources.read_bytes()+json.dumps(features,sort_keys=True).encode()+Path(__file__).read_bytes()+digest_file(args.coordinate_grids/'uk_os_OSTN15_NTv2_OSGBtoETRS.tif').encode()).hexdigest()
    identity=args.output/'source-inputs.json'
    if identity.exists() and json.loads(identity.read_text())['fingerprint']!=fingerprint:
        raise ValueError('Prepared input folder is immutable: use a new version for changed inputs')
    original=json.loads(args.sources.read_text())
    records=inspect_sources(original['files'])
    atomic_json(identity,dict(fingerprint=fingerprint,sourceSnapshotSHA256=digest_file(args.sources),
                coordinateGridSHA256=digest_file(args.coordinate_grids/'uk_os_OSTN15_NTv2_OSGBtoETRS.tif'),
                transformation=transformer.description,files=records))
    vrt=args.output/'mosaic-1m.vrt';make_mosaic(records,vrt)
    footprints=STRtree([box(*r['bounds']) for r in records])
    west,south,east,north=park.bounds
    tile_y=lambda lat:math.floor((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*1024)
    xs=range(math.floor((west+180)/360*1024),math.floor((east+180)/360*1024)+1)
    ys=range(tile_y(north),tile_y(south)+1)
    public_source=dict(name='Scottish public sector LiDAR DTM',sourcePage=original['source'],
        license='Open Government Licence v3.0',licenseURL='https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/',
        attribution='Contains Scottish Government and Scottish Remote Sensing Portal information licensed under the Open Government Licence v3.0.',
        preparation='Sources at 1 m or finer; continuous 1 m BNG mosaic, canonical 512-pixel read blocks, bilinear geographic sampling, 0.1 m quantisation. No NoData filling.',
        coordinateTransformation=transformer.description,
        sourceSnapshotSHA256=digest_file(args.sources),
        files=[dict(url=r['url'],sha256=r['sha256'],sourceSpacingMetres=r['spacing']) for r in records])
    total=0;tested=0;started=time.monotonic()
    with rasterio.Env(GDAL_CACHEMAX=256*1024*1024,GDAL_NUM_THREADS='1'),rasterio.open(vrt) as ds:
        sampler=CanonicalMosaic(ds)
        for x in xs:
            for y in ys:
                b0=bounds(x,y,0,0);b1=bounds(x,y,47,47)
                tile_bounds=dict(minLongitude=b0['minLongitude'],maxLongitude=b1['maxLongitude'],minLatitude=b1['minLatitude'],maxLatitude=b0['maxLatitude'])
                tile_box=box(tile_bounds['minLongitude'],tile_bounds['minLatitude'],tile_bounds['maxLongitude'],tile_bounds['maxLatitude'])
                if not park.intersects(tile_box):continue
                directory=args.output/f'tiles/10/{x}/{y}';directory.mkdir(parents=True,exist_ok=True)
                target=directory/'manifest.json';complete=directory/'COMPLETE.json'
                if target.exists() and complete.exists() and digest_file(target)==json.loads(complete.read_text())['manifestSHA256']:
                    old=json.loads(target.read_text());total+=sum(len(p['precisionChildren']) for p in old['parents']);continue
                parents={}
                for row in range(48):
                    for column in range(48):
                        b=bounds(x,y,column,row);cell=box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])
                        if not park.intersects(cell):continue
                        px,py=transformer.transform([b['minLongitude'],b['maxLongitude'],b['minLongitude'],b['maxLongitude']],
                                                    [b['minLatitude'],b['minLatitude'],b['maxLatitude'],b['maxLatitude']])
                        if not len(footprints.query(box(min(px)-2,min(py)-2,max(px)+2,max(py)+2))):continue
                        lon=np.round(np.linspace(b['minLongitude'],b['maxLongitude'],513),12)
                        lat=np.round(np.linspace(b['maxLatitude'],b['minLatitude'],513),12)
                        xx,yy=np.meshgrid(lon,lat);ex,ny=transformer.transform(xx,yy)
                        values,valid=sample_projected(sampler,ex,ny);tested+=1
                        if not valid.all():continue
                        quantized=np.rint(np.round(values*10,6))
                        if quantized.min()<=-32768 or quantized.max()>32767:raise ValueError('DTM elevations exceed the native format')
                        data=quantized.astype('<i2').tobytes();parent_id=f'c{column//4:02d}-{row//4:02d}';child_id=f'p{column%4:02d}-{row%4:02d}'
                        file=directory/f'parents/{parent_id}/precision/{child_id}/lod-1m.bin';file.parent.mkdir(parents=True,exist_ok=True)
                        tmp=file.with_suffix('.tmp');tmp.write_bytes(data);tmp.replace(file)
                        level=dict(nominalSpacingMetres=1,path=f'precision/{child_id}/lod-1m.bin',byteCount=len(data),sha256=hashlib.sha256(data).hexdigest(),
                            terrain=dict(width=513,height=513,scaleMetres=.1,sampleFormat='int16',byteOrder='little-endian',noDataValue=-32768))
                        if parent_id not in parents:
                            pb0=bounds(x,y,column//4*4,row//4*4);pb1=bounds(x,y,column//4*4+3,row//4*4+3)
                            parents[parent_id]=dict(id=parent_id,status='partial',reasonCode='park-window-or-missing-source',bounds=dict(minLongitude=pb0['minLongitude'],maxLongitude=pb1['maxLongitude'],minLatitude=pb1['minLatitude'],maxLatitude=pb0['maxLatitude']),precisionChildren=[])
                        parents[parent_id]['precisionChildren'].append(dict(id=child_id,bounds=b,lods=[level]));total+=1
                        if total%100==0:print(json.dumps(dict(prepared=total,tested=tested,seconds=round(time.monotonic()-started,1))),flush=True)
                for parent in parents.values():
                    if len(parent['precisionChildren'])==16:
                        parent['status']='available';parent.pop('reasonCode',None)
                manifest=dict(schemaVersion=1,productID='scottish-park-precision',productVersion=args.output.name,tileID=f'z10-x{x}-y{y}',
                    bounds=tile_bounds,source=public_source,parents=list(parents.values()),status='partial-native-park-coverage')
                atomic_json(target,manifest);atomic_json(complete,dict(manifestSHA256=digest_file(target)))
                print(f'Completed native source tile 10/{x}/{y}; {total} complete chunks so far',flush=True)
    atomic_json(args.output/'preparation-result.json',dict(completeChunks=total,candidateChunksTested=tested,seconds=time.monotonic()-started))
    print('Prepared complete native chunks:',total,flush=True)


if __name__=='__main__':main()
