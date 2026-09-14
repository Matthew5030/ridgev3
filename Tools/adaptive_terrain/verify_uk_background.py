#!/usr/bin/env python3
"""Verify every coarse UK section as delivered by the download server."""
import argparse
import hashlib
import json
import re
import zlib
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import numpy as np


def sha(data):return hashlib.sha256(data).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('server');parser.add_argument('--dataset',default='uk-coarse-background-v2')
    parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_-]+',args.dataset):parser.error('Invalid dataset path')
    base=args.server.rstrip('/')+'/'+args.dataset+'/'
    def get(path,limit):
        with urlopen(base+path,timeout=30) as response:
            if response.status!=200:raise ValueError('Unexpected HTTP status')
            data=response.read(limit+1)
            if len(data)>limit:raise ValueError('Oversized response')
            return data
    descriptor_raw=get('background.json',4*1024*1024);d=json.loads(descriptor_raw)
    assert d['requiredReader']=='int16-heightfield-zlib-v1'
    assert (d['width'],d['height'],d['scaleMetres'],d['noDataValue'])==(513,513,.1,-32768)
    assert b'/Volumes/' not in descriptor_raw and b'/Users/' not in descriptor_raw
    edges={};seen=set();seams=0;size=0;valid=0
    for tile in d['partitions']:
        assert re.fullmatch(r'z10-x\d+-y\d+',tile['id']) and tile['id'] not in seen;seen.add(tile['id'])
        assert tile['path']==tile['id']+'.height.zlib'
        compressed=get(tile['path'],tile['byteCount'])
        assert len(compressed)==tile['byteCount'] and sha(compressed)==tile['sha256']
        raw=zlib.decompress(compressed)
        assert len(raw)==tile['decodedByteCount']==513*513*2 and sha(raw)==tile['decodedSHA256']
        h=np.frombuffer(raw,dtype='<i2').reshape(513,513)
        count=int(np.count_nonzero(h!=-32768));assert count==tile['validSampleCount'];valid+=count;size+=len(compressed)
        b=tile['bounds']
        for axis,coordinate,start,end,values in [
            ('x',b['minLongitude'],b['minLatitude'],b['maxLatitude'],h[:,0]),
            ('x',b['maxLongitude'],b['minLatitude'],b['maxLatitude'],h[:,-1]),
            ('y',b['maxLatitude'],b['minLongitude'],b['maxLongitude'],h[0,:]),
            ('y',b['minLatitude'],b['minLongitude'],b['maxLongitude'],h[-1,:])]:
            key=(axis,round(coordinate,10),round(start,10),round(end,10));data=values.tobytes()
            if key in edges:assert edges.pop(key)==data;seams+=1
            else:edges[key]=data
        if len(seen)%100==0:print('Verified background sections:',len(seen),flush=True)
    assert size==d['byteCount'] and valid==d['validSampleCount'] and seams==d['sharedEdgesChecked']
    for name in ['inputs.json','.build.lock']:
        try:get(name,1024);raise AssertionError('Private file served')
        except HTTPError as error:assert error.code==404
    try:urlopen(Request(base+'background.json',data=b'no',method='POST'));raise AssertionError('Server accepted write')
    except HTTPError as error:assert error.code==403
    report=dict(descriptorSHA256=sha(descriptor_raw),sections=len(seen),byteCount=size,validSampleCount=valid,
                sharedEdgesChecked=seams,maxSharedEdgeDifferenceMetres=0,allFilesDownloadedAndHashed=True,privateFilesExcluded=True,writesRefused=True)
    args.output.write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)


if __name__=='__main__':main()
