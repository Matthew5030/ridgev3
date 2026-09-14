#!/usr/bin/env python3
"""Summarise a completed, independently download-verified UK terrain build."""
import argparse
import hashlib
import json
from pathlib import Path


def sha(raw):return hashlib.sha256(raw).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--build',type=Path,required=True);p.add_argument('--downloads',type=Path,required=True);a=p.parse_args()
    plan=json.loads((a.build/'plan.json').read_bytes());status=json.loads((a.build/'status.json').read_bytes());catalog=json.loads((a.downloads/'catalog.json').read_bytes())
    http=json.loads((a.build/'http-validation.json').read_bytes());background=json.loads((a.build/'background-http-validation.json').read_bytes())
    assert catalog['buildComplete'] and status['complete'] and http['buildComplete'] and http['allLocalContainersHashed']
    assert http['backgroundDescriptorVerified'] and http['actualRangeDelivery']
    assert background['allFilesDownloadedAndHashed'] and background['maxSharedEdgeDifferenceMetres']==0
    assert background['descriptorSHA256']==catalog['background']['sha256']
    assert len(catalog['partitions'])==sum(t['chunkCount']>0 for t in plan['partitions'])
    totals=dict(chunks=0,triangles=0,vertices=0,meshBytes=0,sourceZlibBytes=0,sourceBytes=0,decodedBytes=0,expandedGeometryBytes=0,withinSectionSeams=0,indexBytes=0)
    sections=[];maximum_error=0;source_counts={}
    for entry in catalog['partitions']:
        raw=(a.downloads/entry['path']).read_bytes();assert sha(raw)==entry['sha256'];index=json.loads(raw)
        private=a.build/'partitions'/entry['id'];manifest_raw=(private/'manifest.json').read_bytes();assert sha(manifest_raw)==index['sourceManifestSHA256']
        manifest=json.loads(manifest_raw);validation=json.loads((private/'validation.json').read_bytes())
        assert validation['manifestSHA256']==sha(manifest_raw) and validation['maxSeamHeightDifferenceMetres']==0
        assert manifest['maximumMeasuredErrorMetres']<=.5
        maximum_error=max(maximum_error,manifest['maximumMeasuredErrorMetres'])
        t=dict(id=entry['id'],chunks=len(index['chunks']),triangles=index['triangles'],vertices=index['vertices'],meshBytes=index['byteCount'],sourceZlibBytes=sum(c['sourceZlibBytes'] for c in index['chunks']),sourceBytes=manifest['sourceHeightfieldBytes'],decodedBytes=index['decodedByteCount'],expandedGeometryBytes=index['expandedGeometryBytes'],withinSectionSeams=validation['sharedEdgesChecked'],indexBytes=len(raw))
        sections.append(t)
        for key in totals:totals[key]+=t[key]
    for tile in plan['partitions']:
        for source,count in tile['selectedBySource'].items():source_counts[source]=source_counts.get(source,0)+count
    assert totals['chunks']==plan['chunkCount']==catalog['chunkCount']==http['totalChunks']
    assert totals['meshBytes']==catalog['meshBytes']==http['meshBytes']
    savings=100*(1-totals['meshBytes']/totals['sourceZlibBytes'])
    report=dict(complete=True,id=catalog['id'],totals=totals,sections=sections,sourceCounts=source_counts,
                maximumMeasuredErrorMetres=maximum_error,compressedSourceSavingsPercent=savings,
                withinSectionSeams=totals['withinSectionSeams'],crossSectionSeams=status['crossSectionSeams'],
                background=background,officialSurveyCoverage=plan['officialSurveyCoverage'],sourceSelectionPolicy=plan['sourceSelectionPolicy'],coastalSourceValidation=json.loads((a.build/'coast-source-validation.json').read_bytes()),
                rejectedUnsupportedEACandidates=plan['rejectedEACandidates'],
                coveredPolygonKm2=plan['coveredPolygonKm2'],
                coverageNote='The UK administrative polygon includes territorial water. Detailed coverage is not nationwide. Coarse background fills context only; it is not 1 m LiDAR.',
                appIntegration='Terrain assets only. The normal iOS app does not yet consume rat1-zlib-range-v1; cartography and routing data remain separate.')
    (a.build/'UK-TERRAIN.json').write_text(json.dumps(report,indent=2))
    text=f'''# UK terrain build

Completed corrected revision: `{catalog['id']}`.

| Layer | Sections | Compressed terrain |
|---|---:|---:|
| Adaptive detail, measured 0.5 m surface tolerance | {len(sections):,} | {totals['meshBytes']/1e9:.3f} GB |
| Coarse UK background | {background['sections']:,} | {background['byteCount']/1e6:.1f} MB |

The detailed layer contains {totals['chunks']:,} independently downloadable
chunks. It is {savings:.2f}% smaller than the same source heightfields compressed
with zlib level 6. Its section indices add {totals['indexBytes']/1e6:.1f} MB;
map textures and routing data are separate.

## Coverage

'''
    for source,count in source_counts.items():text+=f'- {source}: {count:,} chunks.\n'
    text+=f'''
The official EA footprint check excluded {plan['rejectedEACandidates']:,}
unsupported candidates from the old prepared inventory. Source ownership rules
also suppress {plan['sourceSelectionPolicy']['suppressedFallbackCandidates']:,} incompatible fallback candidates on the repaired Welsh coast. It requires the whole
chunk plus interpolation support inside the survey footprint and preserves
holes. Welsh and Scottish preparation retain their own explicit NoData policy.
The previous unfiltered UK catalogue was withdrawn.

Detailed LiDAR is **not available throughout the UK**. The separately labelled
coarse background provides context for the full UK grid. The selection polygon
includes territorial water, so polygon coverage is not a UK land percentage.
The adaptive tolerance is measured against prepared samples; it is not a claim
of absolute survey accuracy.

## Validation and delivery

- {totals['withinSectionSeams']+status['crossSectionSeams']:,} detailed shared edges match exactly.
- {background['sharedEdgesChecked']:,} coarse shared edges match exactly, including NoData masks.
- Every compressed container was hashed; actual byte-range downloads were decoded and checked in every detailed section.
- Every coarse section was downloaded, decompressed and hash-checked.
- Private source manifests are inaccessible and server writes are refused.

Each detailed section uses one packed container; offsets allow downloading only
chosen chunks. The UK is a downloadable library, not one scene to load into RAM.
Compressed disk savings do not remove decoded geometry costs. The normal app
still needs the RAT1 range reader to use these new assets; no adaptive experiment
screen has been restored.
'''
    (a.build/'UK-TERRAIN.md').write_text(text);print(json.dumps({k:v for k,v in report.items() if k not in ('sections','officialSurveyCoverage')},indent=2))


if __name__=='__main__':main()
