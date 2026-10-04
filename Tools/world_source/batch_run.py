#!/usr/bin/env python3
"""Keep one bounded conversion run alive while verified archive staging progresses.
Run via caffeinate/nohup; no scheduled automation and no changes to source archives.
"""
import argparse, fcntl, json, os, subprocess, sys, time
from pathlib import Path


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--staging-status', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--hours', type=float, default=12)
    p.add_argument('builder_args', nargs=argparse.REMAINDER)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    lock = (a.output / '.supervisor.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    deadline = time.monotonic() + a.hours * 3600
    builder = Path(__file__).with_name('batch_world.py')
    args = a.builder_args[1:] if a.builder_args[:1] == ['--'] else a.builder_args
    previous = None
    def status(state, **extra):
        data = dict(state=state,pid=os.getpid(),updatedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),**extra)
        temp=a.output/'supervisor.json.tmp';temp.write_text(json.dumps(data));os.replace(temp,a.output/'supervisor.json')
    while time.monotonic() < deadline:
        try: stage=json.loads(a.staging_status.read_bytes())
        except FileNotFoundError: stage={'running':True,'ready':0}
        marker=stage.get('ready',0)
        if previous is None or marker != previous:
            status('converting',stagedArchives=marker)
            result=subprocess.run([sys.executable,str(builder),'--output',str(a.output),*args])
            if result.returncode:
                status('failed',exitCode=result.returncode);return result.returncode
            previous=marker
            state=json.loads((a.output/'status.json').read_bytes())['state']
            if state=='paused-low-disk':status(state);return 0
            # Read again after potentially hours of work so newly staged inputs get a pass.
            try:stage=json.loads(a.staging_status.read_bytes())
            except FileNotFoundError:pass
            if stage.get('ready',0)!=previous:continue
        if not stage.get('running',False):
            status('finished',stagedArchives=stage.get('ready',0));return 0
        status('waiting-for-archives',stagedArchives=marker)
        time.sleep(30)
    status('paused-time-limit');return 0

if __name__=='__main__':sys.exit(main())
