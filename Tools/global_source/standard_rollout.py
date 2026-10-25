"""Resume the authorized UK rollout; publish only after all stages and checks pass."""
import argparse,fcntl,hashlib,json,os,shutil,subprocess,sys,time,urllib.request
from pathlib import Path
from common import atomic,rawjson


def run(a):
    lock=(a.root/'.rollout.lock').open('a')
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:
        print('The UK rollout coordinator is already running.',flush=True);return
    atomic(a.root/'rollout-worker.pid',str(os.getpid()).encode())
    (a.root/'rollout-error.json').unlink(missing_ok=True)
    plan=json.loads((a.root/'plan.json').read_bytes());total=len(plan['parents']);repo=Path(__file__).resolve().parents[2]
    phase=['starting'];restarts={}
    def count(name):return len(list((a.root/name).glob('*.json')))
    def status(state=None,**extra):
        if state:phase[0]=state
        report=dict(state=phase[0],terrainParents=count('completed'),colourParents=count('coloured'),totalParents=total,internalFreeBytes=shutil.disk_usage(a.root).free,externalFreeBytes=shutil.disk_usage(a.world).free,updated=time.time(),**extra)
        atomic(a.root/'rollout-status.json',rawjson(report));print(json.dumps(report),flush=True)
    def owned_pid(name,token):
        record=a.root/(name+'-worker.pid')
        if not record.exists():return None
        try:pid=int(record.read_text())
        except ValueError:return None
        process=subprocess.run(['/bin/ps','-p',str(pid),'-o','stat=,command='],capture_output=True,text=True).stdout.strip()
        return pid if process and not process.startswith('Z') and token in process and str(a.root) in process else None
    def ensure_workers():
        jobs=[('colour',count('coloured')<total,['Tools/global_source/standard_colour.py','--root',str(a.root),'--originals',str(a.originals),'--workers','4']),('storage',not (a.root/'STORAGE-COMPLETE.json').exists(),['Tools/global_source/standard_storage.py','--root',str(a.root),'--destination',str(a.destination)])]
        for name,needed,args in jobs:
            if not needed or owned_pid(name,Path(args[0]).name):continue
            restarts[name]=restarts.get(name,0)+1
            if restarts[name]>3:raise RuntimeError(name+' worker repeatedly exited; inspect '+name+'-worker.log')
            with (a.root/(name+'-worker.log')).open('ab') as log:
                child=subprocess.Popen([sys.executable,'-u',*args],cwd=repo,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
            atomic(a.root/(name+'-worker.pid'),str(child.pid).encode())
    def command(args,name,env=None):
        with (a.root/(name+'.log')).open('ab') as log:
            child=subprocess.Popen(args,cwd=repo,env=env,stdout=log,stderr=log)
            if name=='terrain-resume':atomic(a.root/'terrain-worker.pid',str(child.pid).encode())
            while True:
                try:return child.wait(timeout=30)
                except subprocess.TimeoutExpired:ensure_workers();status()
    env=dict(os.environ,OPENBLAS_NUM_THREADS='1',VECLIB_MAXIMUM_THREADS='1',RIDGE_RESERVE_WAIT='1',RIDGE_BUILD_WORK_ROOT=str(a.root),RIDGE_BUILD_SPACE_TARGET=str(a.world),GDAL_CACHEMAX='64',GDAL_NUM_THREADS='1')
    ensure_workers()
    # An existing build can outlive a restarted coordinator. Adopt it without
    # interrupting its source checkpoints or starting a competing compiler.
    while owned_pid('terrain','standard_world.py'):
        status('building');ensure_workers();time.sleep(30)
    while count('completed')<total:
        ensure_workers()
        if shutil.disk_usage(a.root).free<1.6*1024**3 or shutil.disk_usage(a.world).free<3*1024**3:
            status('waiting-for-storage');time.sleep(30);continue
        status('building')
        result=command([sys.executable,'-u','Tools/global_source/standard_world.py','--root',str(a.root),'--world',str(a.world),'--archives',str(a.archives),'--workers',str(a.workers)],'terrain-resume',env)
        if result:
            state=json.loads((a.root/'status.json').read_bytes());failures=state.get('failures',{})
            if not failures or any('Free-space reserve reached' not in reason for reason in failures.values()):raise RuntimeError('Terrain error requires inspection; see terrain-resume.log')
        time.sleep(5)
    while count('coloured')<total or not (a.root/'STORAGE-COMPLETE.json').exists():
        colour=json.loads((a.root/'colour-status.json').read_bytes())
        permanent={k:v for k,v in colour.get('failures',{}).items() if 'GiB free' not in v}
        if permanent:raise RuntimeError('Colour error requires inspection: '+str(permanent))
        ensure_workers();status('finishing-colour-and-storage');time.sleep(30)
    status('validating')
    checks=[['sh','Tools/test_world_batch.sh',str(a.root/'world/sources'/ident)] for ident in ['world-z10-x497-y314-c32-r32','world-z10-x503-y334-c00-r00']]
    entries=[e for p in (a.root/'completed').glob('*.json') for e in json.loads(p.read_bytes())]
    ni=next((e for e in entries if e['bounds']['minLongitude']<-6 and 54<e['bounds']['minLatitude']<55.5 and e.get('standardTileCount')==256),None)
    if ni is None:raise RuntimeError('No complete Northern Ireland section prepared')
    checks.append(['sh','Tools/test_world_batch.sh',str(a.root/'world'/Path(ni['path']).parent)])
    checks.extend([[sys.executable,p] for p in ['Tools/global_source/test_standard.py','Tools/global_source/test_standard_window.py','Tools/download-server/test_native_server.py','Tools/world_source/test_pack_output.py']])
    for index,check in enumerate(checks):
        if command(check,'final-native-check-%d'%index):raise RuntimeError('Native validation failed: '+str(check))
    if command([sys.executable,'Tools/download-server/native_control.py','start','--root',str(a.world.parent)],'origin-ready'):raise RuntimeError('Local download origin unavailable')
    from standard_publish import publish
    status('auditing-and-publishing');receipt=publish(a.root,a.world)
    with urllib.request.urlopen('http://127.0.0.1:8787/world/catalog.json',timeout=30) as response:served=response.read()
    if hashlib.sha256(served).hexdigest()!=receipt['catalogSHA256']:raise RuntimeError('Served catalog differs from publication')
    for source in [ni,entries[0]]:
        url='http://127.0.0.1:8787/world/'+str(Path(source['path']).parent/source['pack']['file'])
        with urllib.request.urlopen(url,timeout=120) as response:payload=response.read()
        if hashlib.sha256(payload).hexdigest()!=source['pack']['sha256']:raise RuntimeError('Served pack checksum differs')
    if command([sys.executable,'Tools/global_source/standard_report.py','--root',str(a.root),'--world',str(a.world)],'coverage-report'):raise RuntimeError('Coverage report failed')
    if command(['sh','Tools/test_world_region_packs.sh'],'published-region-tests'):raise RuntimeError('Published region regression failed')
    if command([sys.executable,'Tools/download-server/audit_origin.py','--catalog-sha',receipt['catalogSHA256'],'--report',str(a.root/'published-origin-audit.json')],'published-origin-audit'):raise RuntimeError('Some published map packs are unavailable from the download server')
    status('complete',publication=receipt,coverageReport=str(a.root/'reports/coverage.json'))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for field in ['root','world','archives']:p.add_argument('--'+field,type=Path,required=True)
    p.add_argument('--workers',type=int,default=2)
    p.add_argument('--originals',type=Path,default=Path('/Users/matthewbilella/Documents/Ridge Satellite Cache/uk-2025'))
    p.add_argument('--destination',type=Path,default=Path('/Volumes/MLB_EXT_4TB/Ridge Sources/uk-standard-cache-v1'));a=p.parse_args()
    try:run(a)
    except Exception as error:
        record=dict(error=repr(error),time=time.time());atomic(a.root/'rollout-error.json',rawjson(record))
        existing=a.root/'rollout-status.json';state=json.loads(existing.read_bytes()) if existing.exists() else {}
        state.update(state='failed',error=repr(error),published=(a.root/'publication.json').exists(),updated=time.time());atomic(existing,rawjson(state));raise

if __name__=='__main__':main()
