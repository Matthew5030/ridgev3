"""Copernicus GLO-30 DSM sampling; missing source cells are errors, never flat fill."""
import math
from pathlib import Path
import numpy as np
import rasterio
from rasterio.merge import merge
from rasterio.enums import Resampling
from scipy.ndimage import map_coordinates
from common import download, digest, atomic, rawjson


def tile_name(lat,lon):
    return f'Copernicus_DSM_COG_10_{"N" if lat>=0 else "S"}{abs(lat):02d}_00_{"E" if lon>=0 else "W"}{abs(lon):03d}_00_DEM'


def quantize(heights):
    """Existing RAT1 supports a height offset. Keep 0.1 m quantisation at any altitude."""
    if not np.isfinite(heights).all():raise ValueError('Missing elevation samples')
    offset=float(round((float(heights.min())+float(heights.max()))/2))
    values=np.rint((heights-offset)*10)
    if values.min()<=-32768 or values.max()>32767:raise ValueError('Chunk relief exceeds 6,553 m; subdivide this source')
    return values.astype('<i2'),offset


class Surface:
    def __init__(self, bounds, cache, reserve_gib=40):
        b=bounds;pad=.001
        region=(b['minLongitude']-pad,b['minLatitude']-pad,b['maxLongitude']+pad,b['maxLatitude']+pad)
        step=1/3600
        region=(math.floor(region[0]/step)*step,math.floor(region[1]/step)*step,
                math.ceil(region[2]/step)*step,math.ceil(region[3]/step)*step)
        datasets=[];self.provenance=[]
        try:
            for lat in range(math.floor(region[1]),math.ceil(region[3])):
                for lon in range(math.floor(region[0]),math.ceil(region[2])):
                    name=tile_name(lat,lon)
                    url=f'https://copernicus-dem-30m.s3.amazonaws.com/{name}/{name}.tif'
                    path=download(url,Path(cache)/(name+'.tif'),reserve_gib,maximum=150*1024**2)
                    record=path.with_suffix('.provenance.json')
                    if not record.exists():atomic(record,rawjson(dict(url=url,sha256=digest(path),byteCount=path.stat().st_size)))
                    import json
                    self.provenance.append(json.loads(record.read_bytes()))
                    datasets.append(rasterio.open(path))
            raster,self.transform=merge(datasets,bounds=region,res=(1/3600,1/3600),nodata=float('nan'),dtype='float32',resampling=Resampling.bilinear)
            self.raster=raster[0]
        finally:
            for dataset in datasets:dataset.close()
    def sample(self, longitude, latitude):
        longitude,latitude=np.broadcast_arrays(longitude,latitude)
        x=(longitude-self.transform.c)/self.transform.a-.5
        y=(latitude-self.transform.f)/self.transform.e-.5
        result=map_coordinates(self.raster,[y.ravel(),x.ravel()],order=1,mode='constant',cval=float('nan'),prefilter=False).reshape(longitude.shape)
        if not np.isfinite(result).all():raise ValueError('Missing DEM coverage: source remains unpublished')
        return result.astype(float)
    def grid(self,bounds,size):
        b=bounds
        return self.sample(np.linspace(b['minLongitude'],b['maxLongitude'],size)[None,:],
                           np.linspace(b['maxLatitude'],b['minLatitude'],size)[:,None])
