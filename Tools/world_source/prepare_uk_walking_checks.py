"""Choose real A-road connections for native checks across the UK publication."""
import argparse, collections, heapq, json
from pathlib import Path

LOCATIONS = [('Wales',53.0685,-4.0763),('England north',54.600,-3.137),
    ('Scotland west',56.818,-5.105),('Northern Ireland',54.598,-5.930),
    ('England southwest',50.600,-3.900),('England southeast',51.270,1.070),
    ('Scotland north',58.160,-5.240),('London',51.50,-.06)]
PATHS = {'path','footway','footpath','bridleway','steps','pedestrian','track'}
ROADS = {'residential','service','living_street','unclassified','road','tertiary','tertiary_link',
    'secondary','secondary_link','primary','primary_link','trunk','trunk_link'}
AROADS = {'primary','primary_link','secondary','secondary_link','trunk','trunk_link'}
ACCESS = {'','unknown','public','yes','designated','permissive','official'}


def choose(graph):
    parent = {n['id']:n['id'] for n in graph['nodes']}; nodes={n['id']:n for n in graph['nodes']}
    def find(n):
        while parent[n]!=n: parent[n]=parent[parent[n]];n=parent[n]
        return n
    seeds=set();adj=collections.defaultdict(list)
    for e in graph['edges']:
        if e['access'] not in ACCESS:continue
        a,b=e['from'],e['to']
        if e['kind'] in PATHS:
            parent[find(a)]=find(b);seeds.update((a,b))
        elif e['kind'] in ROADS and e['bidirectional']:
            adj[a].append((b,e['distance']));adj[b].append((a,e['distance']))
    seeds &= adj.keys();dist={n:0 for n in seeds};origin={n:n for n in seeds};queue=[(0,n) for n in seeds];heapq.heapify(queue)
    while queue:
        d,n=heapq.heappop(queue)
        if d!=dist[n]:continue
        for nxt,cost in adj[n]:
            if d+cost<dist.get(nxt,float('inf')):
                dist[nxt]=d+cost;origin[nxt]=origin[n];heapq.heappush(queue,(d+cost,nxt))
    choices=[]
    for e in graph['edges']:
        a,b=e['from'],e['to']
        if e['kind'] in AROADS and e['access'] in ACCESS and e['bidirectional'] and a in origin and b in origin and find(origin[a])!=find(origin[b]):
            choices.append((dist[a]+dist[b]+e['distance'],origin[a],origin[b]))
    if not choices:raise ValueError('No road connection between distinct footpath components')
    distance,a,b=min(choices)
    return nodes[a]['coordinate'],nodes[b]['coordinate'],distance


def main():
    p=argparse.ArgumentParser();p.add_argument('stage',type=Path);p.add_argument('--output',type=Path,required=True);p.add_argument('--world',type=Path);a=p.parse_args()
    catalog=json.loads(((a.world/'catalog.json') if a.world else a.stage/'catalog.before.json').read_bytes());cases=[]
    for name,lat,lon in LOCATIONS:
        candidates=[s for s in catalog['sources'] if s['bounds']['minLatitude']<lat<s['bounds']['maxLatitude'] and s['bounds']['minLongitude']<lon<s['bounds']['maxLongitude']]
        if not candidates:raise ValueError('No source at '+name)
        source=candidates[0];parent=source['id'].split('-c')[0][6:]
        if a.world:
            row=source;folder=a.world/Path(source['path']).parent
        else:
            rows=json.loads((a.stage/'parents'/(parent+'.json')).read_bytes());row=next(r for r in rows if r['id']==source['id']);folder=Path(row['folder'])
        graph=json.loads((folder/row['routing']['file']).read_bytes());start,finish,distance=choose(graph)
        cases.append(dict(name=name,sourceID=source['id'],graphFile=str(folder/row['routing']['file']),
            packFile=str(folder/row['pack']['file']),graphAsset=row['routing'],packAsset=row['pack'],
            start=start,finish=finish,roadConnectionMeters=distance))
    a.output.write_text(json.dumps(cases,indent=2));print(json.dumps([dict(name=c['name'],source=c['sourceID'],roadConnectionMeters=c['roadConnectionMeters']) for c in cases],indent=2))


if __name__=='__main__':main()
