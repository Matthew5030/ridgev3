#!/usr/bin/env python3
"""Publish immutable routing sidecars; leave terrain/maps/manifests untouched.
Restore original graph edges crossing the smaller world-source boundaries.
Only exact shared parent-boundary endpoints on the same OSM feature are joined.
"""
import argparse, hashlib, json, math, re, zipfile, sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'global_source'))
from osm_semantics import MapFeatureTransformer

ROUTING_FILE = 'paths-connected-v2.json'

def walking_edges(graph, semantic):
    """Recover road and access evidence before the cartographic class loses it."""
    features={f['id']:f for f in semantic['features']}
    classify=MapFeatureTransformer();result=[]
    for original in graph['edges']:
        feature=features.get(original['sourceFeatureID'])
        if feature is None:raise ValueError('Missing source evidence for routing edge')
        tags=feature['source']['tags'];highway=tags.get('highway')
        if highway in {'motorway','motorway_link','construction','proposed','raceway'} or tags.get('area')=='yes':continue
        if tags.get('motorroad')=='yes' and tags.get('foot') not in {'yes','designated','official','permissive'}:continue
        edge=dict(original)
        edge['pathType']=highway or original['pathType']
        edge['access']=classify.classify_access(tags)
        # Preserve the original oriented topology and direction restrictions.
        result.append(edge)
    return result


def raw(v): return json.dumps(v,separators=(',',':'),allow_nan=False).encode()
def atomic(p,b):
    t=p.with_suffix(p.suffix+'.tmp');t.write_bytes(b);t.replace(p)
def inside(b,n): return b['minLongitude']<=n['longitude']<=b['maxLongitude'] and b['minLatitude']<=n['latitude']<=b['maxLatitude']
def uid(key): return int.from_bytes(hashlib.sha256(key.encode()).digest()[:8],'big') & ((1<<52)-1)
def connect(graph,bounds,parent):
    nodes={n['id']:n for n in graph['nodes']}; ways={k:set() for k in nodes}
    for e in graph['edges']:
        feature=e['sourceFeatureID'].split(':z10-')[0]
        ways[e['from']].add(feature);ways[e['to']].add(feature)
    ids={}
    for key,n in nodes.items():
        boundary=min(abs(n['longitude']-bounds[k]) for k in ['minLongitude','maxLongitude'])<1e-8 or min(abs(n['latitude']-bounds[k]) for k in ['minLatitude','maxLatitude'])<1e-8
        identity=(f"boundary:{n['latitude']:.7f}:{n['longitude']:.7f}:"+','.join(sorted(ways[key]))) if boundary else f'{parent}:{key}'
        ids[key]=uid(identity)
    return nodes,ids

def main():
    p=argparse.ArgumentParser();p.add_argument('--world',type=Path,required=True);p.add_argument('--archives',type=Path,required=True);p.add_argument('--parent',action='append');a=p.parse_args()
    catalog_path=a.world/'catalog.json';catalog=json.loads(catalog_path.read_bytes());groups={}
    for s in catalog['sources']:
        parent=s['id'].split('-c')[0][6:]
        if not a.parent or parent in a.parent:groups.setdefault(parent,[]).append(s)
    for parent,sources in sorted(groups.items()):
        if all(s.get('routing',{}).get('file')==ROUTING_FILE and (a.world/'sources'/s['id']/ROUTING_FILE).is_file() for s in sources):continue
        m=re.fullmatch(r'z10-x(\d+)-y(\d+)',parent);x,y=m.groups();folder=a.archives/'tiles'/'10'/x/y
        desc=json.loads((folder/'descriptor.json').read_bytes());archive=folder/Path(desc['archiveURL']).name
        payload=archive.read_bytes()
        if hashlib.sha256(payload).hexdigest()!=desc['archiveSHA256']:raise ValueError('Archive checksum mismatch')
        with zipfile.ZipFile(archive) as z:
            manifest=json.loads(z.read('manifest.json'));data=z.read('routing/graph.json')
            item=next(f for f in manifest['files'] if f['path']=='routing/graph.json')
            if hashlib.sha256(data).hexdigest()!=item['sha256']:raise ValueError('Graph checksum mismatch')
            graph=json.loads(data)
            semantic_data=z.read('map-data.ridgemap')
            semantic_item=next(f for f in manifest['files'] if f['path']=='map-data.ridgemap')
            if hashlib.sha256(semantic_data).hexdigest()!=semantic_item['sha256']:raise ValueError('Map evidence checksum mismatch')
            semantic=json.loads(semantic_data)
        nodes,ids=connect(graph,desc['bounds'],parent)
        prepared_edges=walking_edges(graph,semantic)
        for s in sources:
            selected={k for k,n in nodes.items() if inside(s['bounds'],n)}
            edges=[e for e in prepared_edges if e['from'] in selected or e['to'] in selected]
            used={e[k] for e in edges for k in ['from','to']}
            result=dict(nodes=[dict(id=ids[k],coordinate=dict(latitude=nodes[k]['latitude'],longitude=nodes[k]['longitude']),elevation=nodes[k]['elevationMeters']) for k in sorted(used)],edges=[dict(from_=ids[e['from']],to=ids[e['to']],distance=e['distanceMeters'],bidirectional=e['bidirectional'],access=e['access'],kind=e['pathType']) for e in edges])
            for e in result['edges']:e['from']=e.pop('from_')
            data=raw(result);file=ROUTING_FILE;out=a.world/'sources'/s['id']/file
            if out.exists() and out.read_bytes()!=data:raise ValueError('Refusing to overwrite published sidecar')
            if not out.exists():atomic(out,data)
            s['routing']=dict(file=file,byteCount=len(data),sha256=hashlib.sha256(data).hexdigest())
        atomic(catalog_path,raw(catalog));print(parent,len(sources),'regions connected',flush=True)
if __name__=='__main__':main()
