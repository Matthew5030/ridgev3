#!/usr/bin/env python3
"""Upgrade every UK routing graph and section download, then switch the catalogue.

Preserve current terrain, graph elevations and topology. Recover road semantics
from the verified original OSM archives. Checkpoint by parent; keep old assets.
"""
import argparse, collections, concurrent.futures, fcntl, hashlib, json, math
import os, re, shutil, struct, tempfile, threading, time, zipfile, zlib
from pathlib import Path
from publish_connected_paths import connect, walking_edges, ROUTING_FILE, raw

GIB = 1024**3


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(1024*1024), b''): h.update(data)
    return h.hexdigest()


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_bytes(data); temporary.replace(path)


def asset(path):
    return dict(file=path.name, byteCount=path.stat().st_size, sha256=digest(path))


def read_parent(archive, descriptor):
    """Verify once sequentially, spooling only the two required JSON members.

    The retained archives use ZIP_STORED. Hashing them and subsequently rereading
    their large JSON members doubles external-disk traffic. One sequential pass
    verifies the complete archive and both member hashes without retaining raw
    archive bytes in RAM. Dense semantic maps are parsed one feature at a time.
    """
    names = ['routing/graph.json', 'map-data.ridgemap']
    with zipfile.ZipFile(archive) as zipped, tempfile.TemporaryDirectory(prefix='ridge-routing-input-') as temp:
        manifest = json.loads(zipped.read('manifest.json'))
        records = {f['path']:f for f in manifest['files']}
        paths = {name:Path(temp)/str(i) for i,name in enumerate(names)}
        infos = [zipped.getinfo(name) for name in names]
        if all(i.compress_type == zipfile.ZIP_STORED for i in infos):
            ranges = []
            with archive.open('rb') as source:
                for info in infos:
                    source.seek(info.header_offset); header = source.read(30)
                    if header[:4] != b'PK\x03\x04': raise ValueError('Invalid original ZIP member header')
                    lengths = struct.unpack('<HH', header[26:30])
                    start = info.header_offset + 30 + sum(lengths)
                    ranges.append((info.filename, start, start+info.file_size))
                source.seek(0); archive_hash = hashlib.sha256(); offset = 0
                streams = {name:paths[name].open('wb') for name in names}
                hashes = {name:hashlib.sha256() for name in names}
                try:
                    while chunk := source.read(16*1024*1024):
                        archive_hash.update(chunk)
                        for name,start,end in ranges:
                            lo,hi=max(start,offset),min(end,offset+len(chunk))
                            if hi>lo:
                                data=chunk[lo-offset:hi-offset];streams[name].write(data);hashes[name].update(data)
                        offset += len(chunk)
                finally:
                    for stream in streams.values(): stream.close()
            if archive_hash.hexdigest()!=descriptor['archiveSHA256']:
                raise ValueError('Original archive checksum mismatch')
            for name in names:
                if hashes[name].hexdigest()!=records[name]['sha256'] or paths[name].stat().st_size!=records[name].get('sizeBytes',records[name].get('byteCount')):
                    raise ValueError('Original archive member checksum mismatch')
        else:
            if digest(archive)!=descriptor['archiveSHA256']:raise ValueError('Original archive checksum mismatch')
            for name in names:
                data=zipped.read(name)
                if hashlib.sha256(data).hexdigest()!=records[name]['sha256']:raise ValueError('Original archive member checksum mismatch')
                paths[name].write_bytes(data)
        with paths[names[0]].open('rb') as stream: original=json.load(stream)
        needed={e['sourceFeatureID'] for e in original['edges']}
        with paths[names[1]].open('rb') as stream:
            try: import ijson
            except ImportError: features=json.load(stream)['features']
            else: features=ijson.items(stream,'features.item',use_float=True)
            semantic=dict(features=[dict(id=f['id'],source=dict(tags=f['source']['tags']))
                                    for f in features if f['id'] in needed])
    return original, semantic


def source_evidence(original, semantic, bounds, parent):
    _, ids = connect(original, bounds, parent)
    prepared = {e['id']: e for e in walking_edges(original, semantic)}
    by_pair = collections.defaultdict(list)
    for edge in original['edges']:
        by_pair[ids[edge['from']], ids[edge['to']]].append(edge)
    return by_pair, prepared


def upgrade_graph(current, original, semantic, bounds, parent, evidence=None):
    """Match source identities, never spatial proximity; retain live elevations."""
    by_pair, prepared = evidence or source_evidence(original, semantic, bounds, parent)
    edges = []; changed = 0; excluded = 0
    for edge in current['edges']:
        candidates = [e for e in by_pair[edge['from'], edge['to']]
                      if e['pathType'] == edge['kind'] and e['access'] == edge['access']
                      and e['bidirectional'] == edge['bidirectional']]
        if not candidates: raise ValueError('Current edge has no exact original OSM identity')
        if len(candidates)>1:
            distance_matches=[e for e in candidates if abs(e['distanceMeters']-edge['distance'])<0.000001]
            if distance_matches: candidates=distance_matches
        replacements = [prepared.get(e['id']) for e in candidates]
        meanings = {None if e is None else (e['pathType'], e['access']) for e in replacements}
        if len(meanings) != 1:
            # Parallel OSM ways can share the exact same retained edge. Keep
            # their common class only when every source agrees on foot access
            # and walking eligibility. Never guess between allowed/prohibited.
            paths={'path','footway','footpath','steps','pedestrian','track','bridleway'}
            roads={'road','residential','living_street','service','unclassified','tertiary','tertiary_link','secondary','secondary_link','primary','primary_link','trunk','trunk_link'}
            kinds={m[0] for m in meanings if m is not None}
            accesses={m[1] for m in meanings if m is not None}
            if None not in meanings and len(accesses)==1 and edge['kind'] in paths and kinds<=paths:
                meanings={(edge['kind'],next(iter(accesses)))}
            elif None not in meanings and len(accesses)==1 and edge['kind'] in {'minorRoad','majorRoad'} and kinds<=roads:
                meanings={('road',next(iter(accesses)))}
            else:
                raise ValueError('Ambiguous original road evidence: '+str(dict(edge=edge,candidates=[dict(id=e['id'],distance=e['distanceMeters'],source=e['sourceFeatureID'],meaning=None if prepared.get(e['id']) is None else (prepared[e['id']]['pathType'],prepared[e['id']]['access'])) for e in candidates])))
        meaning = meanings.pop()
        if meaning is None: excluded += 1; continue
        kind, access = meaning
        if kind in {'majorRoad', 'minorRoad'}: raise ValueError('Road class remains ambiguous')
        copy = dict(edge, kind=kind, access=access)
        changed += copy != edge; edges.append(copy)
    used = {e[k] for e in edges for k in ('from', 'to')}
    nodes = [n for n in current['nodes'] if n['id'] in used]
    if len({n['id'] for n in nodes}) != len(nodes) or len(nodes) != len(used):
        raise ValueError('Invalid current graph node identities')
    for n in nodes:
        p = n['coordinate']
        if not (-90 <= p['latitude'] <= 90 and -180 <= p['longitude'] <= 180 and math.isfinite(n['elevation'])):
            raise ValueError('Invalid retained graph node')
    return dict(nodes=nodes, edges=edges), dict(changed=changed, excluded=excluded,
        nodes=len(nodes), edges=len(edges), aRoadEdges=sum(e['kind'] in {'primary','primary_link','secondary','secondary_link','trunk','trunk_link'} for e in edges))


def repack_routing(path, expected, source_id, old_graph, new_graph, graph_data, output):
    """Copy immutable terrain chunks byte-for-byte; replace only the graph chunk.

    Validate the entire original pack hash while copying. The new pack hash is
    computed over every output byte. No million-file terrain reread is needed.
    """
    if path.stat().st_size != expected['byteCount']: raise ValueError('Original pack size mismatch')
    compressed = zlib.compress(graph_data, 6)
    use_compressed = len(compressed) < len(graph_data)
    replacement = compressed if use_compressed else graph_data
    temporary = output / '.routing-pack.tmp'
    try:
        with path.open('rb') as source:
            header = source.read(12)
            if len(header) != 12 or header[:8] != b'RIDGEPK1': raise ValueError('Invalid original pack header')
            size = struct.unpack('<I', header[8:])[0]
            if not 1 <= size <= 2_000_000: raise ValueError('Oversized original pack index')
            index_data = source.read(size); index = json.loads(index_data)
            if index['schemaVersion'] != 1 or index['sourceID'] != source_id: raise ValueError('Wrong source pack')
            old_entries = index['entries']
            if sum(e['sha256'] == old_graph['sha256'] for e in old_entries) != 1:
                raise ValueError('Original pack does not contain current routing graph')
            entries = []; offset = 0; original_offset = 0
            for entry in old_entries:
                if entry['offset'] != original_offset or entry['storedByteCount'] < 1:
                    raise ValueError('Non-contiguous original pack payload')
                original_offset += entry['storedByteCount']
                copy = dict(entry, offset=offset)
                if entry['sha256'] == old_graph['sha256']:
                    copy.update(sha256=new_graph['sha256'], byteCount=len(graph_data),
                                storedByteCount=len(replacement), compressed=use_compressed)
                entries.append(copy); offset += copy['storedByteCount']
            if 12 + size + original_offset != expected['byteCount']: raise ValueError('Original pack payload size mismatch')
            encoded = raw(dict(index, entries=entries))
            new_header = b'RIDGEPK1' + struct.pack('<I', len(encoded)) + encoded
            old_hash = hashlib.sha256(header + index_data); new_hash = hashlib.sha256(new_header)
            with temporary.open('wb') as target:
                target.write(new_header)
                for entry in old_entries:
                    replacing = entry['sha256'] == old_graph['sha256']
                    remaining = entry['storedByteCount']
                    while remaining:
                        data = source.read(min(1024*1024, remaining))
                        if not data: raise ValueError('Truncated original pack')
                        old_hash.update(data); remaining -= len(data)
                        if not replacing: target.write(data); new_hash.update(data)
                    if replacing: target.write(replacement); new_hash.update(replacement)
            if old_hash.hexdigest() != expected['sha256']: raise ValueError('Original pack checksum mismatch')
        checksum = new_hash.hexdigest()
        result = dict(file='section-' + checksum + '.ridgepack', byteCount=temporary.stat().st_size, sha256=checksum)
        if result['byteCount'] > 256*1024*1024: raise ValueError('Oversized rebuilt pack')
        final = output / result['file']
        if final.exists():
            if asset(final) != result: raise ValueError('Immutable rebuilt pack collision')
            temporary.unlink()
        else: temporary.replace(final)
        return result
    finally: temporary.unlink(missing_ok=True)


class Storage:
    def __init__(self, paths):
        self.paths = paths; self.lock = threading.Lock(); self.reserved = collections.Counter()
        for path in paths: path.mkdir(parents=True, exist_ok=True)

    def reserve(self, source_id, need):
        with self.lock:
            root = max(self.paths, key=lambda p: shutil.disk_usage(p).free - self.reserved[p])
            if shutil.disk_usage(root).free - self.reserved[root] < need + 4*GIB:
                raise RuntimeError('Insufficient staging space; completed parents are preserved')
            self.reserved[root] += need
        folder = root / source_id; folder.mkdir(exist_ok=True)
        return root, folder

    def release(self, root, need):
        with self.lock: self.reserved[root] -= need


def build_parent(job):
    args, parent, sources = job
    storage = Storage(args.storage)
    checkpoint = args.stage/'parents'/(parent+'.json')
    if checkpoint.exists():
        saved = json.loads(checkpoint.read_bytes())
        for row in saved:
            for name in ['routing','pack']:
                path = Path(row['folder'])/row[name]['file']
                if not path.is_file() or path.stat().st_size != row[name]['byteCount']: raise ValueError('Missing checkpoint output')
        return saved
    x,y = re.fullmatch(r'z10-x(\d+)-y(\d+)', parent).groups()
    folder = args.archives/'tiles'/'10'/x/y
    descriptor = json.loads((folder/'descriptor.json').read_bytes())
    archive = folder/Path(descriptor['archiveURL']).name
    original, semantic = read_parent(archive, descriptor)
    # Source evidence is shared by up to nine sections. Build the lookup once.
    evidence = source_evidence(original, semantic, descriptor['bounds'], parent)
    def prepare(source):
        source_folder = args.world/Path(source['path']).parent
        old_routing = source['routing']; data = (source_folder/old_routing['file']).read_bytes()
        if len(data)!=old_routing['byteCount'] or hashlib.sha256(data).hexdigest()!=old_routing['sha256']:
            raise ValueError('Current routing checksum mismatch: '+source['id'])
        
        try: graph, audit = upgrade_graph(json.loads(data), original, semantic, descriptor['bounds'], parent, evidence)
        except ValueError as error: raise ValueError(source['id']+': '+str(error)) from error
        data = raw(graph); need = len(data)*3 + source['pack']['byteCount']*2 + 32*1024**2
        root, output = storage.reserve(source['id'], need)
        try:
            graph_path = output/ROUTING_FILE
            if graph_path.exists() and graph_path.read_bytes()!=data: raise ValueError('Immutable routing collision')
            if not graph_path.exists(): atomic(graph_path, data)
            routing = dict(file=ROUTING_FILE, byteCount=len(data), sha256=hashlib.sha256(data).hexdigest())
            pack = repack_routing(source_folder/source['pack']['file'], source['pack'], source['id'], old_routing, routing, data, output)
            return dict(id=source['id'], folder=str(output), routing=routing, pack=pack, audit=audit)
        finally: storage.release(root, need)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        rows = list(pool.map(prepare, sources))
    atomic(checkpoint, raw(rows))
    return rows


def run(args):
    args.stage.mkdir(parents=True, exist_ok=True); locks = []
    for name in ['.walking-routing.lock', '.batch.lock', '.section-pack.lock']:
        lock = (args.world / name).open('a'); fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); locks.append(lock)
    (args.stage/'error.json').unlink(missing_ok=True)
    backup = args.stage / 'catalog.before.json'; current_data = (args.world/'catalog.json').read_bytes()
    receipt = args.stage/'publication.json'
    if receipt.exists():
        proof = json.loads(receipt.read_bytes())
        if digest(args.world/'catalog.json') != proof['catalogSHA256']: raise ValueError('Published catalogue has since changed')
        print(json.dumps(proof), flush=True); return
    intent = args.stage/'publication-intent.json'
    if intent.exists() and hashlib.sha256(current_data).hexdigest()==json.loads(intent.read_bytes())['catalogSHA256']:
        atomic(receipt, intent.read_bytes()); print(intent.read_text(), flush=True); return
    if backup.exists() and backup.read_bytes() != current_data: raise ValueError('Catalogue changed since routing rollout started')
    if not backup.exists(): atomic(backup, current_data)
    catalog = json.loads(current_data); groups = collections.defaultdict(list)
    for source in catalog['sources']: groups[source['id'].split('-c')[0][6:]].append(source)
    results = {}; totals = collections.Counter(); began = time.time()
    def status(state, **extra):
        proof = dict(state=state, parents=len(list((args.stage/'parents').glob('*.json'))),
            totalParents=len(groups), sections=len(results), totalSections=len(catalog['sources']),
            seconds=round(time.time()-began), totals=dict(totals), updated=time.time(), **extra)
        atomic(args.stage/'status.json', raw(proof)); print(json.dumps(proof), flush=True)
    (args.stage/'parents').mkdir(exist_ok=True)
    work = iter(sorted(groups.items()))
    with concurrent.futures.ProcessPoolExecutor(max_workers=args.parent_workers) as pool:
        jobs = {}
        def enqueue():
            item = next(work, None)
            if item is not None: jobs[pool.submit(build_parent, (args, *item))] = item[0]
        for _ in range(args.parent_workers): enqueue()
        while jobs:
            done, _ = concurrent.futures.wait(jobs, return_when=concurrent.futures.FIRST_COMPLETED)
            for future in done:
                parent = jobs.pop(future)
                try: rows = future.result()
                except BaseException:
                    for pending in jobs: pending.cancel()
                    raise
                for row in rows: results[row['id']] = row; totals.update(row['audit'])
                status('building', parent=parent)
                enqueue()
    if len(results) != len(catalog['sources']): raise ValueError('Incomplete UK routing rollout')
    status('installing')
    for source in catalog['sources']:
        row = results[source['id']]; folder = args.world/Path(source['path']).parent
        for name in ['routing','pack']:
            target = folder/row[name]['file']; prepared = Path(row['folder'])/row[name]['file']
            if target.exists():
                if asset(target)!=row[name]: raise ValueError('Published immutable asset collision')
            else:
                temporary = target.with_name(target.name+'.walking-link'); temporary.unlink(missing_ok=True)
                temporary.symlink_to(prepared.resolve()); temporary.replace(target)
        source.update(routing=row['routing'], pack=row['pack'])
    # Old regional files remain available; outdated bundles leave the catalogue.
    catalog['regionArchives'] = []
    catalog.pop('regionArchiveGroups', None)
    catalog['revision'] += '-walking-v2'; catalog['routingVersion'] = 2
    data = raw(catalog)
    if len(data)>=16_000_000: raise ValueError('Oversized catalogue')
    if (args.world/'catalog.json').read_bytes()!=current_data: raise ValueError('Catalogue changed during routing rollout')
    atomic(args.stage/'catalog.after.json', data)
    proof = dict(published=True, sources=len(results), parents=len(groups), totals=dict(totals),
        catalogSHA256=hashlib.sha256(data).hexdigest(), previousCatalogSHA256=hashlib.sha256(current_data).hexdigest(),
        storage=[str(p) for p in args.storage], publishedAt=time.time())
    atomic(args.stage/'publication-intent.json', raw(proof))
    atomic(args.world/'catalog.json', data); atomic(receipt, raw(proof)); status('complete', publication=proof)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['world','archives','stage']: parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--storage', type=Path, action='append', required=True)
    parser.add_argument('--workers', type=int, default=2)
    parser.add_argument('--parent-workers', type=int, default=2)
    args = parser.parse_args()
    try: run(args)
    except Exception as error:
        atomic(args.stage/'error.json', raw(dict(error=repr(error), updated=time.time())))
        raise


if __name__=='__main__': main()
