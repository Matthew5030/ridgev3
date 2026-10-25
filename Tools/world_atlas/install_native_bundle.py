#!/usr/bin/env python3
"""Verify a completed UK atlas and atomically replace a recoverable app bundle."""
import argparse,concurrent.futures,hashlib,json,os,re,shutil,tempfile
from pathlib import Path
from PIL import Image

def install(atlas,bundle,backup):
    index_raw=(atlas/'index.json').read_bytes();index=json.loads(index_raw)
    status=json.loads((atlas/'status.json').read_bytes())
    if status.get('state')!='complete' or status.get('sections')!=674 or index.get('renderer')!='WorldPreview' or index.get('semanticSectionCount')!=674 or len(index.get('semanticSections',[]))!=674 or index.get('maxZoom')!=13:
        raise ValueError('Only the completed native UK map can replace the bundled atlas')
    names=index['tiles'];inventory=set(names)
    if len(names)!=len(inventory) or not names or any(not re.fullmatch(r'z(?:[5-9]|1[0-3])-x[0-9]+-y[0-9]+\.jpg',n) for n in names):raise ValueError('Invalid native inventory')
    for section in index['semanticSections']:
        match=re.fullmatch(r'z10-x([0-9]+)-y([0-9]+)',section)
        if not match:raise ValueError('Invalid section identity')
        x,y=map(int,match.groups())
        if any('z13-x%d-y%d.jpg'%(a,b) not in inventory for a in range(x*8,x*8+8) for b in range(y*8,y*8+8)):
            raise ValueError('Missing native reference coverage: '+section)
    if backup.exists():raise ValueError('Backup must be a new path')
    expected={}
    for receipt in (atlas/'sections').glob('*.json'):expected.update(json.loads(receipt.read_bytes())['pages'])
    # Read neighbouring captures together on a spinning source drive. Lexical
    # x/y order otherwise seeks between thousands of small files unnecessarily.
    with os.scandir(atlas) as entries:
        ordered=sorted((entry.inode(),entry.name) for entry in entries if entry.name in inventory)
    names=[name for _,name in ordered]
    if len(names)!=len(inventory):raise ValueError('Incomplete atlas files')
    stage=Path(tempfile.mkdtemp(prefix='ridge-native-atlas-stage-'))/'WorldAtlas.bundle';stage.mkdir()
    def copy(name):
        raw=(atlas/name).read_bytes()
        if name in expected and hashlib.sha256(raw).hexdigest()!=expected[name]:raise ValueError('Screenshot checksum mismatch: '+name)
        target=stage/name;target.write_bytes(raw)
        with Image.open(target) as image:
            if image.size!=(256,256) or image.format!='JPEG':raise ValueError('Invalid screenshot: '+name)
            image.load()
        return len(raw)
    try:
        size=0
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            for count in range(0,len(names),256):size+=sum(pool.map(copy,names[count:count+256]))
        (stage/'index.json').write_bytes(index_raw)
        backup.parent.mkdir(parents=True,exist_ok=True)
        bundle.rename(backup)
        try:stage.rename(bundle)
        except BaseException:backup.rename(bundle);raise
        return dict(renderer=index['renderer'],sections=index['semanticSectionCount'],pages=len(names),bytes=size+len(index_raw),backup=str(backup),bundle=str(bundle))
    finally:shutil.rmtree(stage.parent,ignore_errors=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['atlas','bundle','backup']:p.add_argument('--'+name,type=Path,required=True)
    a=p.parse_args();print(json.dumps(install(a.atlas,a.bundle,a.backup)),flush=True)
