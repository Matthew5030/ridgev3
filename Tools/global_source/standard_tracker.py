"""Read-only live progress API and study server; never changes terrain assets."""
import argparse,collections,http.server,json,subprocess,threading,time,urllib.parse
from pathlib import Path

class Tracker:
    def __init__(self,root,clock=time.time):
        self.root=Path(root);self.clock=clock;self.files={};self.lock=threading.Lock();self.cached=None;self.cached_at=0
        plan=json.loads((self.root/'plan.json').read_bytes());self.plan=plan
        self.parents={p['id']:p for p in plan['parents']}
        self.source_parents={s['id']:p['id'] for p in plan['parents'] for s in p['sources']}
        self.errors=[]

    def read(self,path,default=None,required=False):
        path=Path(path)
        try:
            stat=path.stat();identity=(stat.st_ino,stat.st_mtime_ns,stat.st_size)
            previous=self.files.get(path)
            if previous and previous[0]==identity:return previous[1]
            value=json.loads(path.read_bytes());self.files[path]=(identity,value);return value
        except (OSError,ValueError) as error:
            if required or path.exists():self.errors.append(path.name+': '+type(error).__name__)
            return default

    def marked_parents(self,name):
        return {p.stem for p in (self.root/name).glob('*.json') if p.stem in self.parents}

    def entries(self,parents):
        result={}
        for ident in sorted(parents):
            entries=self.read(self.root/'completed'/(ident+'.json'),[],required=True)
            for entry in entries:
                if entry['id'] in self.source_parents:result[entry['id']]=entry
        return result

    def geometry_activity(self,completed):
        path=self.root/'terrain-resume.log';recent=[];latest=0
        try:
            with path.open('rb') as stream:
                stream.seek(0,2);size=stream.tell();stream.seek(max(0,size-262144))
                lines=stream.read().splitlines()
            for line in reversed(lines):
                try:item=json.loads(line)
                except (ValueError,UnicodeError):continue
                if item.get('event') not in {'standard-source-complete','independent-surface-verified'}:continue
                latest=max(latest,item.get('time',0))
                ident=item.get('parent') or self.source_parents.get(item.get('source'))
                if ident in self.parents and ident not in completed and ident not in recent:recent.append(ident)
                if len(recent)>=8:break
        except OSError:pass
        return recent,latest

    def active_sources(self,ident,kind):
        result={};latest=0;row=self.parents[ident]
        marker='standard-colour-complete.json' if kind=='colour' else 'standard-complete.json'
        for source in row['sources']:
            folder=self.root/'world/sources'/source['id'];proof=folder/marker
            if not proof.exists():continue
            entry=self.read(folder/'standard-complete.json')
            if entry is not None:
                result[source['id']]=entry
                try:latest=max(latest,proof.stat().st_mtime)
                except OSError:pass
        names=list(dict.fromkeys(s['name'] for s in row['sources']))
        return result,dict(kind=kind,name=' / '.join(names),ready=len(result),total=len(row['sources'])),latest

    def workers(self):
        roles={'coordinator':'standard_rollout.py','terrain':'standard_world.py','colour':'standard_colour.py','storage':'standard_storage.py'}
        ids={}
        for role in roles:
            file=self.root/(('rollout' if role=='coordinator' else role)+'-worker.pid')
            try:ids[role]=int(file.read_text())
            except (OSError,ValueError):pass
        if not ids:return {}
        try:
            result=subprocess.run(['/bin/ps','-p',','.join(str(p) for p in ids.values()),'-o','pid=,stat=,command='],capture_output=True,text=True,timeout=2)
        except (OSError,subprocess.TimeoutExpired):return {}
        if result.returncode not in [0,1]:return {}
        alive={role:False for role in ids}
        for line in result.stdout.splitlines():
            fields=line.split(None,2)
            if len(fields)!=3:continue
            pid,stat,command=fields
            for role,expected in ids.items():
                if pid==str(expected) and not stat.startswith('Z') and roles[role] in command and str(self.root) in command:alive[role]=True
        return alive

    def snapshot(self,force=False):
        with self.lock:
            now=self.clock()
            if not force and self.cached is not None and now-self.cached_at<3:return self.cached
            self.errors=[]
            state=self.read(self.root/'rollout-status.json',{},required=True)
            colour=self.read(self.root/'colour-status.json',{},required=True)
            terrain=self.read(self.root/'status.json',{},required=True)
            prepared=self.marked_parents('completed');coloured=self.marked_parents('coloured')
            built=self.entries(prepared);painted=self.entries(coloured);activity=[]
            recent,last_activity=self.geometry_activity(prepared)
            for ident in recent:
                extra,detail,stamp=self.active_sources(ident,'terrain');built.update(extra)
                if detail['ready']<detail['total']:activity.append(detail)
                last_activity=max(last_activity,stamp)
            for ident in colour.get('active',[]):
                if ident not in self.parents or ident in coloured:continue
                extra,detail,stamp=self.active_sources(ident,'colour');painted.update(extra);activity.append(detail);last_activity=max(last_activity,stamp)
            try:last_activity=max(last_activity,(self.root/'colour-worker.log').stat().st_mtime)
            except OSError:pass
            grouped={}
            for item in activity:
                key=(item['kind'],item['name'])
                if key not in grouped:grouped[key]=dict(item,ready=0,total=0)
                grouped[key]['ready']+=item['ready'];grouped[key]['total']+=item['total']
            activity=list(grouped.values())
            failures=[str(v) for stage in [terrain,colour] for v in stage.get('failures',{}).values()]
            error=self.read(self.root/'rollout-error.json')
            if error:failures.append(error.get('error','Rollout error'))
            updated=state.get('updated');age=max(0,now-updated) if isinstance(updated,(float,int)) else None
            stale=age is None or age>90
            def tiles(entries):return sum(e.get('standardTileCount',0) for e in entries.values())
            result=dict(observedAt=now,workerUpdatedAt=updated,workerAgeSeconds=age,stale=stale,state=state.get('state','unknown'),workersAlive=self.workers(),livenessCheckedAt=self.clock(),totalTiles=self.plan['newNativeCells'],terrainTiles=tiles(built),colourTiles=tiles(painted),totalBatches=len(self.parents),terrainBatches=len(prepared),colourBatches=len(coloured),packsReady=len(painted),totalPacks=sum(len(p['sources']) for p in self.parents.values()),lastActivityAt=last_activity or None,activity=activity,failures=failures,readErrors=list(dict.fromkeys(self.errors)))
            if result['state']=='complete':
                report=self.read(self.root/'reports/coverage.json')
                publication=self.read(self.root/'publication.json')
                if report and publication and report.get('catalogSHA256')==publication.get('catalogSHA256'):
                    result['coverage']=dict(standardTiles=report['standardTiles'],missingKm2=report['totals']['missingKm2'])
            self.cached=result;self.cached_at=now;return result

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if urllib.parse.urlsplit(self.path).path=='/uk-coverage/live.json':
            try:body=json.dumps(self.server.tracker.snapshot(),allow_nan=False).encode();status=200
            except Exception as error:body=json.dumps(dict(error='Tracker could not read job progress: '+type(error).__name__)).encode();status=503
            self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body)
        else:super().do_GET()
    def end_headers(self):
        if urllib.parse.urlsplit(self.path).path.startswith('/uk-coverage/'):
            self.send_header('Cache-Control','no-store')
        super().end_headers()
    def log_message(self,*args):pass

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);p.add_argument('--study',type=Path,required=True);p.add_argument('--port',type=int,default=8786);a=p.parse_args()
    from functools import partial
    server=http.server.ThreadingHTTPServer(('0.0.0.0',a.port),partial(Handler,directory=str(a.study)));server.daemon_threads=True;server.tracker=Tracker(a.root)
    print('Study server with live terrain progress on port',a.port,flush=True);server.serve_forever()

if __name__=='__main__':main()
