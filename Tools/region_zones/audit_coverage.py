#!/usr/bin/env python3
"""Read-only coverage audit against the finished block layout and frozen inputs.

Checks metadata, not every mesh payload or current external survey availability.
Never changes the publication, app resources, or availability flags.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import math
from pathlib import Path
import re
import sys

from shapely.geometry import Polygon, box
from shapely.ops import unary_union
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'world_source'))
from terrain_coverage import missing_terrain

ROOT=Path(__file__).resolve().parents[2]

def read(path):
    raw=path.read_bytes()
    return json.loads(raw),hashlib.sha256(raw).hexdigest()

def evidence(row, manifests):
    flags=[]
    if not manifests:flags.append('no_prepared_manifest')
    if manifests and row['chunkCount']==0:flags.append('prepared_but_no_selected_chunks')
    if row.get('rejectedWithoutFallback',0):flags.append('outside_recorded_ea_survey_footprint')
    if row.get('suppressedFallbackCandidates',0):flags.append('fallback_excluded_by_seam_policy')
    names=sorted({m['sourceName'] for m in manifests})
    if row['chunkCount']==0 and names==['Welsh Government 1 m LiDAR DTM']:
        flags.append('welsh_only_empty_input_review_source_choice')
    if not flags:flags.append('partial_or_complete_prepared_input')
    return flags

def inspect_partition(row):
    manifests=[];problems=[]
    for ref in row['sourceManifests']:
        path=Path(ref['path'])
        if not path.is_file():
            problems.append(dict(path=str(path),problem='manifest_missing'));continue
        m,sha=read(path)
        if sha!=ref['sha256']:problems.append(dict(path=str(path),problem='manifest_hash_changed'))
        reasons=Counter(p.get('reasonCode','unspecified') for p in m['parents'] if p.get('status')!='available')
        manifests.append(dict(path=str(path),sha256=sha,sourceName=m.get('source',{}).get('name','unknown'),
            unavailableParentReasons=dict(reasons),
            nativeCandidates=sum(any(l['nominalSpacingMetres']==1 for l in c.get('lods',[])) for p in m['parents'] for c in p.get('precisionChildren',[]))))
    return dict(id=row['id'],selectedChunks=row['chunkCount'],bounds=row['bounds'],
        rejectedWithoutFallback=row.get('rejectedWithoutFallback',0),
        suppressedFallbackCandidates=row.get('suppressedFallbackCandidates',0),
        flags=evidence(row,manifests) if not problems else ['source_evidence_unverified'],
        manifests=manifests,problems=problems)

def inspect_world(args):
    world,entry=args
    m,_=read(world/entry['path'])
    errors=[]
    if m['id']!=entry['id']:errors.append('manifest_id_mismatch')
    if len(m['tiles'])!=entry['tileCount']:errors.append('tile_count_mismatch')
    if missing_terrain(m)!=entry.get('missingTerrain'):errors.append('coverage_mask_mismatch')
    pack=entry.get('pack')
    if not pack:errors.append('section_pack_missing_from_catalogue')
    else:
        f=world/entry['path'];f=f.parent/pack['file']
        if not f.is_file():errors.append('section_pack_missing_on_disk')
        elif f.stat().st_size!=pack['byteCount']:errors.append('section_pack_size_mismatch')
    return dict(id=entry['id'],tiles=len(m['tiles']),problems=errors)

def geometry(shapes):
    return unary_union([Polygon(s['rings'][0],s['rings'][1:]) for s in shapes])

def km2(geom):
    # Approximate small regional polygons; never use the UK administrative
    # polygon's territorial-water area as a land denominator.
    if geom.is_empty:return 0
    polys=[geom] if geom.geom_type=='Polygon' else list(geom.geoms)
    return sum(p.area*111.32**2*math.cos(math.radians(p.centroid.y)) for p in polys)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root',type=Path,required=True)
    p.add_argument('--plan',type=Path,required=True)
    p.add_argument('--regions',type=Path,default=ROOT/'Artifacts/larger-regions-preview/regions.json')
    p.add_argument('--output',type=Path,default=ROOT/'Artifacts/region-coverage-audit')
    a=p.parse_args();world=a.source_root/'world-v1-2026-10-04'
    regions,region_sha=read(a.regions);plan,plan_sha=read(a.plan)
    catalog,catalog_sha=read(world/'catalog.json');status,_=read(world/'status.json')
    with ThreadPoolExecutor(max_workers=4) as pool:
        partitions=list(pool.map(inspect_partition,plan['partitions']))
        print('Checked prepared source manifests for',len(partitions),'parent sections',flush=True)
        published=list(pool.map(inspect_world,[(world,s) for s in catalog['sources']]))
    by_parent={r['id']:r for r in partitions};rows=[]
    for g in regions['regions']:
        missing=geometry(g['missingShapes']);land=geometry(g['mapShapes'])
        parent_ids=sorted({re.sub(r'^world-|\-c\d+-r\d+$','',c['id']) for c in g['cells']})
        gap_parents=[]
        for ident in parent_ids:
            parent=by_parent[ident];b=parent['bounds']
            if missing.intersection(box(b['minLongitude'],b['minLatitude'],b['maxLongitude'],b['maxLatitude'])).area>1e-10:
                gap_parents.append(ident)
        rows.append(dict(id=g['id'],name=g['name'],kind=g['kind'],availability=g['stats']['availability'],
            landKm2=round(km2(land),2),missingLandKm2=round(km2(missing),2),
            detailedLandPercent=round(100*(1-km2(missing)/km2(land)),2) if not land.is_empty else None,
            gapParentIDs=gap_parents,
            upstreamEvidence=dict(Counter(flag for i in gap_parents for flag in by_parent[i]['flags']))))
    flags=Counter(flag for r in partitions for flag in r['flags'])
    selected=sum(r['selectedChunks'] for r in partitions);emitted=sum(r['tiles'] for r in published)
    summary=dict(regions=len(rows),availability=dict(Counter(r['availability'] for r in rows)),
        parentSections=len(partitions),emptyParentSections=sum(r['selectedChunks']==0 for r in partitions),
        selectedChunks=selected,publishedChunks=emitted,publishedSources=len(published),
        tileTotalsMatch=selected==emitted==plan['chunkCount']==status['completedTiles'],
        metadataProblems=[r for r in published if r['problems']],
        sourceManifestProblems=[r['id'] for r in partitions if r['problems']],
        catalogueMatchesBlockSnapshot=catalog_sha==regions['catalogueSnapshot']['sha256'],
        conversionState=status['state'],conversionFailures=status['failures'],conversionDeferred=status['deferred'],
        upstreamEvidence=dict(flags),rejectedWithoutFallback=plan['rejectedWithoutFallback'],
        suppressedFallbackCandidates=plan['sourceSelectionPolicy']['suppressedFallbackCandidates'])
    result=dict(schemaVersion=1,layoutSHA256=region_sha,planSHA256=plan_sha,catalogueSHA256=catalog_sha,
        scope='Local prepared-source and publication metadata audit. Does not revalidate full mesh payloads or establish whether additional public surveys exist.',
        evidenceNote='Flags describe whole upstream parent sections and may overlap. They do not allocate each missing square metre to an exact cause. Welsh-only empty sections are review candidates, not proof of absent LiDAR or of a source-selection bug.',
        summary=summary,regions=rows,partitions=partitions)
    a.output.mkdir(parents=True,exist_ok=True)
    (a.output/'audit.json').write_text(json.dumps(result,indent=2)+'\n')
    lines=['REGION COVERAGE AUDIT — 18 October 2026',result['scope'],'',json.dumps(summary,indent=2),'',
        'Coverage below is approximate land-only coverage of proposed download blocks, not legal park polygons.',result['evidenceNote'],'']
    for r in sorted(rows,key=lambda r:(r['detailedLandPercent'],r['name'])):
        lines.append(f"{r['name']}: {r['detailedLandPercent']:.2f}% detailed; {r['missingLandKm2']:,.2f} km² missing; {r['availability']}")
    lines+=['','NEXT ACTIONS',
        '1. Investigate Welsh-only empty input sections first, including Leominster and Ludlow. Check source selection and eligible English input; do not assume data is recoverable until sampled.',
        '2. Audit broader Scottish and Northern Irish acquisition beyond the prepared collection; missing local manifests are not evidence that no survey exists.',
        '3. Keep footprint-rejected and seam-policy-excluded chunks blocked until a verified replacement is available. Do not re-enable rejected flat data.',
        '4. Build and seam-test an explicit standard-terrain fallback with vector maps and routable paths where high-detail input remains unavailable.',
        '5. Recut regional archive parts only after coverage and quality metadata are settled. Existing published packs remain untouched.']
    (a.output/'REPORT.txt').write_text('\n'.join(lines)+'\n')
    print(json.dumps(summary,indent=2),flush=True)

if __name__=='__main__':main()
