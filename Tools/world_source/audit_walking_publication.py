"""Verify the complete UK routing catalogue and every served graph reference."""
import argparse, concurrent.futures, hashlib, json, time, urllib.request
from pathlib import Path


def main():
    p=argparse.ArgumentParser();p.add_argument('stage',type=Path);p.add_argument('--base',default='http://127.0.0.1:8787/world/');a=p.parse_args()
    base=a.base.rstrip('/')+'/'
    before=json.loads((a.stage/'catalog.before.json').read_bytes());receipt=json.loads((a.stage/'publication.json').read_bytes())
    with urllib.request.urlopen(base+'catalog.json',timeout=30) as response:data=response.read()
    sha=hashlib.sha256(data).hexdigest();catalog=json.loads(data)
    if sha!=receipt['catalogSHA256'] or catalog.get('routingVersion')!=2:raise ValueError('Wrong served routing catalogue')
    previous={s['id']:s for s in before['sources']}
    if set(previous)!={s['id'] for s in catalog['sources']}:raise ValueError('UK sections were lost or added unexpectedly')
    for source in catalog['sources']:
        unchanged=lambda s:{k:v for k,v in s.items() if k not in {'routing','pack'}}
        if unchanged(source)!=unchanged(previous[source['id']]):raise ValueError('Terrain metadata changed')
        if source['routing']['file']!='paths-connected-v2.json':raise ValueError('Legacy graph remains in catalogue')
    def check(source):
        path=str(Path(source['path']).parent/source['routing']['file'])
        for attempt in range(3):
            try:
                request=urllib.request.Request(base+path,method='HEAD')
                with urllib.request.urlopen(request,timeout=30) as response:
                    if response.status!=200 or int(response.headers.get('Content-Length',-1))!=source['routing']['byteCount']:
                        return dict(source=source['id'],error='Wrong response size')
                return None
            except OSError as error:
                if attempt==2:return dict(source=source['id'],error=str(error))
                time.sleep(.2)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:errors=[e for e in pool.map(check,catalog['sources']) if e]
    report=dict(passed=not errors,sections=len(catalog['sources']),graphsChecked=len(catalog['sources']),
        allTerrainMetadataRetained=True,catalogSHA256=sha,errors=errors,updated=time.time())
    (a.stage/'served-graphs-audit.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)
    if errors:raise SystemExit(1)


if __name__=='__main__':main()
