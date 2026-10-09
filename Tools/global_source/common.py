"""Shared bounded I/O for local-only international pack preparation."""
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import time
import requests

GIB = 1024**3
REVISION = 'global-copdem30-v1'


def rawjson(value):
    return json.dumps(value, separators=(',', ':'), allow_nan=False).encode()


def atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_bytes(data)
    os.replace(temporary, path)


def digest(path, algorithm='sha256'):
    h = hashlib.new(algorithm)
    with Path(path).open('rb') as f:
        for data in iter(lambda: f.read(1024*1024), b''): h.update(data)
    return h.hexdigest()


class DiskReserveError(OSError):
    pass


def reserve(root, gib=40, additional=0):
    if shutil.disk_usage(root).free < gib*GIB + additional:
        raise DiskReserveError('Free-space reserve reached; completed packs are preserved')


def download(url, path, reserve_gib=40, maximum=4*GIB):
    """Cache only completed checked transfers; no credentials or paid APIs."""
    path = Path(path)
    if path.exists(): return path
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + '.incoming')
    for attempt in range(3):
        try:
            with requests.get(url, stream=True, timeout=(20,90)) as response:
                response.raise_for_status()
                length = int(response.headers.get('Content-Length',0))
                if length > maximum: raise ValueError('Source exceeds configured download limit')
                reserve(path.parent,reserve_gib,length)
                count = 0
                with part.open('wb') as output:
                    for block in response.iter_content(1024*1024):
                        count += len(block)
                        if count > maximum: raise ValueError('Source exceeds configured download limit')
                        reserve(path.parent,reserve_gib)
                        output.write(block)
                if length and count != length: raise ValueError('Incomplete source download')
                if count == 0: raise ValueError('Empty source download')
                os.replace(part,path)
                return path
        except requests.RequestException as error:
            if isinstance(error,requests.HTTPError) and error.response.status_code == 404: raise
            if attempt == 2: raise
            time.sleep(2**attempt)
        finally:
            part.unlink(missing_ok=True)


def bounds(x,y,z=12):
    n=2**z
    lat=lambda y:math.degrees(math.atan(math.sinh(math.pi*(1-2*y/n))))
    return dict(minLongitude=x/n*360-180,maxLongitude=(x+1)/n*360-180,
                minLatitude=lat(y+1),maxLatitude=lat(y))


def xy(lon,lat,z=12):
    n=2**z
    latitude=max(-85,min(85,lat))
    tx=int((lon+180)/360*n)
    ty=int((1-math.asinh(math.tan(math.radians(latitude)))/math.pi)/2*n)
    return min(n-1,max(0,tx)),min(n-1,max(0,ty))


def distance(a,b):
    lat1,lat2=map(math.radians,[a[1],b[1]])
    dlat=lat2-lat1;dlon=math.radians(b[0]-a[0])
    q=math.sin(dlat/2)**2+math.cos(lat1)*math.cos(lat2)*math.sin(dlon/2)**2
    return 6371008.8*2*math.asin(min(1,math.sqrt(q)))
