#!/usr/bin/env python3
"""Check the UK grid catalogue and actual chunk byte-range downloads."""
import argparse,hashlib,json,re,struct,zlib
from pathlib import Path
from urllib.request import urlopen,Request
from urllib.parse import urljoin
from urllib.error import HTTPError
from compact_codec import CompactCodec


def sha(data):return hashlib.sha256(data).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('server');p.add_argument('--output',type=Path,required=True);p.add_argument('--local',type=Path);p.add_argument('--require-complete',action='store_true');p.add_argument('--dataset',default='uk-adaptive-0p5-v3');a=p.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_-]+',a.dataset):p.error('Invalid dataset path')
    base=a.server.rstrip('/')+'/'+a.dataset+'/';codec=CompactCodec()
    def get(path,headers=None,limit=20*1024*1024):
        with urlopen(Request(base+path,headers=headers or {}),timeout=60) as response:
            data=response.read(limit+1)
            if len(data)>limit:raise ValueError('Response exceeds expected bounded size')
            return response.status,data,response.headers
    catalog=json.loads(get('catalog.json')[1]);ids=[c['id'] for c in catalog['partitions']]
    assert len(ids)==len(set(ids)) and catalog['requiredReader']=='rat1-zlib-range-v1'
    if a.require_complete:assert catalog['buildComplete']
    background=catalog['background']
    assert re.fullmatch(r'/[a-zA-Z0-9_-]+/background\.json',background['path'])
    with urlopen(urljoin(a.server+'/',background['path']),timeout=30) as response:
        raw=response.read(background['byteCount']+1)
    assert len(raw)==background['byteCount'] and sha(raw)==background['sha256']
    assert json.loads(raw)['requiredReader']==background['requiredReader']=='int16-heightfield-zlib-v1'
    assert catalog['officialSurveyCoverage']['featureCount']>0
    results=[];total_chunks=0
    for entry in catalog['partitions']:
        assert re.fullmatch(r'z10-x\d+-y\d+',entry['id'])
        expected=entry['id']+'-adaptive-0p5/adaptive.json';assert entry['path']==expected
        raw=get(expected)[1];assert len(raw)==entry['byteCount'] and sha(raw)==entry['sha256']
        assert b'/Volumes/' not in raw and b'/Users/' not in raw
        index=json.loads(raw);assert index['requiredReader']=='rat1-zlib-range-v1';container=index['container'];assert container['path']=='terrain.ratpack'
        chunks=index['chunks'];assert len(chunks)==entry['chunks'];offset=0;seen=set()
        for c in chunks:
            assert c['id'].startswith(entry['id']+'-') and c['id'] not in seen;seen.add(c['id'])
            assert c['path']=='terrain.ratpack' and c['byteOffset']==offset and c['byteCount']>0;offset+=c['byteCount']
        assert offset==container['byteCount']==index['byteCount']==entry['meshBytes']
        prefix=expected.rsplit('/',1)[0]+'/'
        chosen=sorted({0,len(chunks)//2,len(chunks)-1,max(range(len(chunks)),key=lambda i:chunks[i]['byteCount'])})
        for i in chosen:
            c=chunks[i];start=c['byteOffset'];end=start+c['byteCount']-1
            status,data,headers=get(prefix+c['path'],{'Range':f'bytes={start}-{end}'},c['byteCount'])
            assert status==206 and headers['Content-Range']==f"bytes {start}-{end}/{container['byteCount']}"
            assert len(data)==c['byteCount'] and sha(data)==c['sha256']
            payload=zlib.decompress(data);assert len(payload)==c['topologyByteCount'] and sha(payload)==c['topologySHA256']
            raw_mesh=codec.decode(payload);assert len(raw_mesh)==c['decodedByteCount'] and sha(raw_mesh)==c['decodedSHA256']
            magic,nv,nt,iw,grid,scale,height_offset=struct.unpack('<4s4I2f',raw_mesh[:28]);assert (magic,nv,nt,iw,grid)==(b'RME1',c['vertices'],c['triangles'],c['indexWidth'],513)
        if a.local:
            h=hashlib.sha256();path=a.local/prefix/container['path']
            assert path.stat().st_size==container['byteCount']
            with path.open('rb') as stream:
                for data in iter(lambda:stream.read(4*1024*1024),b''):h.update(data)
            assert h.hexdigest()==container['sha256']
        for name,meta in index['assets'].items():
            data=get(prefix+name)[1];assert len(data)==meta['byteCount'] and sha(data)==meta['sha256']
        try:get(prefix+'manifest.json');raise AssertionError('Private source manifest was served')
        except HTTPError as error:assert error.code==404
        results.append(dict(id=entry['id'],chunks=len(chunks),checkedRanges=len(chosen),meshBytes=index['byteCount'],withinSectionSeams=index['validation']['sharedEdgesChecked']));total_chunks+=len(chunks)
        if len(results)%25==0:print('Verified sections:',len(results),flush=True)
    assert total_chunks==catalog['chunkCount']
    assert sum(c['meshBytes'] for c in results)==catalog['meshBytes']
    try:urlopen(Request(base+'catalog.json',data=b'no',method='POST'));raise AssertionError('Server accepted a write')
    except HTTPError as error:assert error.code==403
    report=dict(backgroundDescriptorVerified=True,buildComplete=catalog['buildComplete'],sections=results,totalChunks=total_chunks,meshBytes=catalog['meshBytes'],actualRangeDelivery=True,allLocalContainersHashed=bool(a.local),privateFilesExcluded=True,writesRefused=True)
    a.output.write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='sections'}))


if __name__=='__main__':main()
