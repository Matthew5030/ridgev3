#!/usr/bin/env python3
"""Start a detached local read-only service with the caller's folder access."""
import argparse,json,os,shutil,signal,subprocess,sys,time,urllib.request
from pathlib import Path


def ready(port):
    try:
        with urllib.request.urlopen('http://127.0.0.1:%d/world/catalog.json'%port,timeout=2) as response:
            return response.status==200 and isinstance(json.load(response),dict)
    except (OSError,ValueError):return False


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode',choices=['start','stop'])
    parser.add_argument('--root',type=Path,default=Path('/Volumes/MLB_EXT_4TB/Ridge Sources'))
    parser.add_argument('--port',type=int,default=8787);a=parser.parse_args()
    runtime=Path.home()/'Library/Application Support/Ridge Download Server'
    runtime.mkdir(parents=True,exist_ok=True);pidfile=runtime/'native-server.pid'
    # A LaunchAgent has different removable-volume permissions on macOS. Remove
    # the obsolete agent and inherit the invoking app/Terminal's access instead.
    label='com.bilella.ridge-downloads'
    subprocess.run(['launchctl','bootout','gui/%d/%s'%(os.getuid(),label)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    (Path.home()/'Library/LaunchAgents'/Path(label+'.plist')).unlink(missing_ok=True)
    if a.mode=='start' and ready(a.port):
        print('Ridge downloads ready on port',a.port);return
    if pidfile.exists():
        pid=int(pidfile.read_text())
        command=subprocess.run(['/bin/ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
        if str(runtime/'native_server.py') in command:
            try:os.kill(pid,signal.SIGTERM)
            except ProcessLookupError:pass
        pidfile.unlink()
    if a.mode=='stop':return
    shutil.copyfile(Path(__file__).with_name('native_server.py'),runtime/'native_server.py')
    with (runtime/'native-server.log').open('ab') as log:
        child=subprocess.Popen([sys.executable,'-u',str(runtime/'native_server.py'),'--root',str(a.root),'--port',str(a.port)],stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
    pidfile.write_text(str(child.pid))
    for _ in range(30):
        if ready(a.port):print('Ridge downloads ready on port',a.port);return
        if child.poll() is not None:break
        time.sleep(.5)
    raise RuntimeError('Download catalog unavailable; inspect '+str(runtime/'native-server.log'))

if __name__=='__main__':main()
