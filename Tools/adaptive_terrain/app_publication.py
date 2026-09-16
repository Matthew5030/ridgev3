"""Verified immutable assets and native-grid helpers for app publication."""
import hashlib, json, os

def digest(raw): return hashlib.sha256(raw).hexdigest()
def read(p): return json.loads(p.read_bytes())
def write(p,d):
 raw=(json.dumps(d,separators=(',',':'))+'\n').encode(); tmp=p.with_name('.'+p.name+'.tmp');tmp.write_bytes(raw);tmp.replace(p);return raw
def intersects(a,b): return a['minLongitude']<b['maxLongitude'] and a['maxLongitude']>b['minLongitude'] and a['minLatitude']<b['maxLatitude'] and a['maxLatitude']>b['minLatitude']
def contains(a,b): return a['minLongitude']<=b['minLongitude']+1e-10 and a['maxLongitude']>=b['maxLongitude']-1e-10 and a['minLatitude']<=b['minLatitude']+1e-10 and a['maxLatitude']>=b['maxLatitude']-1e-10
def bounds_at(b,x,y,w=1,h=1):
 dx=(b['maxLongitude']-b['minLongitude'])/48;dy=(b['maxLatitude']-b['minLatitude'])/48
 return dict(minLongitude=b['minLongitude']+x*dx,maxLongitude=b['minLongitude']+(x+w)*dx,maxLatitude=b['maxLatitude']-y*dy,minLatitude=b['maxLatitude']-(y+h)*dy)
def linked(src,dst,meta):
 if dst.exists():
  if dst.stat().st_size != meta['byteCount']:raise ValueError(f'Existing asset size mismatch: {dst}')
  return
 if src.stat().st_size!=meta['byteCount'] or digest(src.read_bytes())!=meta['sha256']:raise ValueError(f'Bad source asset: {src}')
 os.link(src,dst)
