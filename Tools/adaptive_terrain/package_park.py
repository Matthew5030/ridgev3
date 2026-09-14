#!/usr/bin/env python3
"""Combine checked chunks into one transfer file; GPU residency is unchanged."""
import hashlib,json,pathlib,sys,shutil,os
root=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
m=json.loads((root/'manifest.json').read_text())
with (out/'terrain.rmeshpack.tmp').open('wb') as f:
 for c in m['chunks']:
  b=(root/c['path']).read_bytes()
  if len(b)!=c['compactBytes'] or hashlib.sha256(b).hexdigest()!=c['sha256']:raise ValueError(c['id'])
  c['byteOffset']=f.tell();c['path']='terrain.rmeshpack';f.write(b)
  # Device needs provenance hashes, not local source paths or compiler cache keys.
  c.pop('source',None);c.pop('compilerSHA256',None)
 f.flush();os.fsync(f.fileno())
(out/'terrain.rmeshpack.tmp').replace(out/'terrain.rmeshpack')
m['storage']='concatenated-rme1';(out/'manifest.json').write_text(json.dumps(m,indent=2))
for name in ['boundary.geojson','coverage-gaps.geojson','coverage.png','validation.json','REPORT.md']:
 if (root/name).exists():shutil.copyfile(root/name,out/name)
print('Packaged',len(m['chunks']),'chunks',m['compactBytes'],'bytes',flush=True)
