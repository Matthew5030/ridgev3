#!/usr/bin/env python3
"""Render exact app-style overheads, one complete immutable world source at a time."""
import argparse, fcntl, hashlib, json, os, shutil, subprocess, time
from pathlib import Path

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def atomic(path,value):
    tmp=path.with_name(path.name+'.tmp');tmp.write_text(json.dumps(value,separators=(',',':')));os.replace(tmp,path)

def main():
    p=argparse.ArgumentParser();p.add_argument('--world-root',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--renderer',type=Path,required=True);p.add_argument('--hours',type=float,default=48);p.add_argument('--reserve-gib',type=int,default=35);p.add_argument('--once',action='store_true');a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True)
    lock=(a.output/'.preview.lock').open('a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    style_root=Path(__file__).resolve().parents[2]/'ridge v3'/'World'
    style={name:digest(style_root/name) for name in ('WorldPreview.swift','WorldCartography.swift','WorldGeometry.swift')}
    config=dict(schemaVersion=1,worldRoot=str(a.world_root.resolve()),rendererSHA256=digest(a.renderer),style=style,pixels=2048,jpegQuality=.9)
    if (a.output/'build-config.json').exists() and json.loads((a.output/'build-config.json').read_bytes())!=config:raise ValueError('Preview output belongs to a different style/renderer; use a new output')
    atomic(a.output/'build-config.json',config)
    path=a.output/'catalog.json'
    catalog=json.loads(path.read_bytes()) if path.exists() else dict(schemaVersion=1,kind='world-overhead-previews',pixels=2048,style=style,previews=[])
    entries={x['id']:x for x in catalog['previews']};failures={};deadline=time.monotonic()+a.hours*3600
    def status(state,current=None):
        atomic(a.output/'status.json',dict(state=state,pid=os.getpid(),updatedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),current=current,completedPreviews=len(entries),downloadBytes=sum(x['byteCount'] for x in entries.values()),failures=failures))
    while time.monotonic()<deadline:
        source_catalog=a.world_root/'catalog.json'
        sources=json.loads(source_catalog.read_bytes())['sources'] if source_catalog.exists() else []
        for item in sources:
            ident=item['id']
            if ident in failures:continue
            source=a.world_root/item['path'];source_sha=digest(source)
            if ident in entries:
                entry=entries[ident];image=a.output/entry['file']
                if entry['sourceManifestSHA256']!=source_sha:raise ValueError('Published world source changed')
                if image.exists() and digest(image)==entry['sha256']:continue
            if time.monotonic()>=deadline:status('paused-time-limit');return
            if shutil.disk_usage(a.output).free<a.reserve_gib*1024**3:status('paused-low-disk');return
            status('rendering',ident);temp=a.output/(ident+'.partial.jpg');final=a.output/(ident+'.jpg')
            try:
                result=subprocess.run([str(a.renderer),str(source.parent),str(temp)],check=True,capture_output=True,text=True,timeout=180)
                metadata=json.loads(result.stdout.strip().splitlines()[-1])
                if metadata['height']!=2048 or metadata['sourceID']!=ident:raise ValueError('Renderer metadata mismatch')
                if not temp.exists() or temp.stat().st_size<1000:raise ValueError('Empty preview')
                checksum=digest(temp);os.replace(temp,final)
                entries[ident]=dict(id=ident,bounds=item['bounds'],file=final.name,byteCount=final.stat().st_size,sha256=checksum,sourceManifestSHA256=source_sha,width=metadata['width'],height=metadata['height'],sourcePath=item['path'])
                catalog['previews']=list(entries.values());atomic(path,catalog)
                print('READY',ident,entries[ident]['byteCount'],flush=True)
            except Exception as e:
                failures[ident]=str(e);print('FAILED',ident,repr(e),flush=True)
            status('rendering',ident)
        if a.once:status('complete-with-errors' if failures else 'complete');return
        supervisor=a.world_root/'supervisor.json'
        upstream=json.loads(supervisor.read_bytes()) if supervisor.exists() else dict(state='unknown')
        if upstream['state'] in ('finished','failed','paused-time-limit','paused-low-disk'):
            status('complete-with-errors' if failures else 'complete');return
        status('waiting-for-world-sources');time.sleep(20)
    status('paused-time-limit')

if __name__=='__main__':main()
