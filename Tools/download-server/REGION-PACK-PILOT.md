# Single-region download pilot — 18 October 2026

Only **Snowdon & Conwy Valley** (`sheet-explorer-ol17`) is published in this
format. Its 19 existing sections contain 4,368 available terrain tiles.
The 295,143,487 bytes of section packs are preserved byte-for-byte inside a
297,425,064-byte region archive. The extra 2,281,577 bytes hold the index and
compressed manifests. No adaptive terrain, vectors or routing data is rebuilt.
The 128 MB target is a guideline, not a reason to split this named region.

## App behaviour

A fresh save uses one archive request, including all section metadata. The app
keeps the archive intact and reads individual section/asset ranges on demand;
there is no extraction stage or whole-region memory allocation. Existing
geographic tile progress is retained. HTTP Range resumes partial downloads.
Checksums and required entries must pass before offline coverage is admitted.
An interrupted metadata installation can recover from the completed file.

If most of the region is already saved, the existing section/individual-asset
path handles only missing data. Existing section packs, loose downloads and
older clients remain supported. The pilot is additive to the catalogue.
Selecting an overlapping park still reuses the installed section references.

The app opens its cached catalogue immediately and refreshes it in the
background, so a newly published format/coverage does not require clearing maps.

## Format and publication

`RIDGERG1` (eight ASCII bytes), UInt32 little-endian index length, then JSON:
`schemaVersion`, `regionID`, `members`. Each member has `sourceID`, a
payload-relative `offset`, its unchanged section `asset`, a base64/zlib
`manifest`, and decoded `manifestBytes`. The payload concatenates the original
`RIDGEPK1` section files. File name: `region-<whole-file-sha256>.ridgepack`.
Limits: 1 GiB archive, 128 sections, 4 MB index, 32 MB decoded manifests total,
16 MB per manifest. Section and individual-asset limits still apply.

Build one region, verifying every input section hash:

```sh
python3 Tools/world_source/pack_region.py ROOT \
  'ridge v3/Resources/uk-download-zones.json' \
  --region sheet-explorer-ol17 --publish
```

The descriptor is published under optional `catalog.regionArchives` and the
local server exposes only content-addressed archive filenames under
`/world/region-packs/`. Original section files remain available. Cloud hosting
is still disabled; this pilot does not enable it or change billing.

## Red regions: coverage audit

The iPad's cached catalogue and active local server agree on all 2,531 sources
and their terrain masks. This is not a stale-catalogue explanation for the
current red areas. Of the 420 selectable land regions, 262 intersect published
terrain and 158 have none. Partial regions can also contain red gaps.

The frozen input selection has 674 source areas, of which 332 have no chunks.
Its 589,443 selected chunks equal the completed world build's tile count. That
build reports 2,531 completed sources, no deferred sources and no failures.
Spot checks: Leominster (`z10-x504-y337`) and Ludlow (`z10-x504-y336`) contain
zero selected chunks. Cairngorm (`z10-x501-y313`) has only 10 chunks, around
1.97 km² of its 454.36 km² source square. These are gaps in the prepared source
selection, not failures introduced by archive conversion. This does **not**
prove that no usable raw elevation data exists elsewhere.

Next coverage work should audit the original source manifests/acquisition for
those gaps, then either build available terrain or provide an explicitly
coarser fallback. Do not mark them downloadable until actual published data
exists. The app now explains red as unavailable detailed terrain, rather than
merely an area that has not yet been downloaded.

## Validation

```sh
python3 -m unittest discover -s Tools/world_source -p 'test_pack_*.py'
sh Tools/test_world_region_archive.sh
sh Tools/test_world_section_packs.sh
sh Tools/test_world_region_packs.sh
sh Tools/test_world_catalog.sh
```

The archive checks cover normal region selection/download, one physical file,
bounded geographic progress, offline terrain/vector reads in all 19 sections,
overlap/repeated-save reuse, invalid section ranges, metadata recovery and HTTP
resume. The existing section suite also covers corrupted data, cancellation and
servers ignoring Range. A signed iOS Debug build is included in validation.

The DEBUG-only `RIDGE_BENCHMARK_REGION=sheet-explorer-ol17` launch compares the
19-section download against the archive in isolated temporary caches. It writes
`Documents/region-benchmark.json`, checks offline terrain/vector reads with
network access disabled in the reader, then removes its temporary data.
It does not delete the user's saved maps or claim manual airplane-mode testing.

## Physical iPad result

On the connected M1 iPad Pro over the local network:

| Transfer and installation | Bytes | Seconds |
| --- | ---: | ---: |
| Existing 19 section files | 295,143,487 | 39.13 |
| Single region archive | 297,425,064 | 13.19 |

This run was about **2.97× faster** despite the 0.77% metadata overhead. Timings
include the download method's verification and installation; they exclude the
subsequent deliberate offline rendering sweep. Both cases passed offline reads
and terrain/vector preparation for the first and last tile of every section
(38 sampled tiles), and had all 4,368 available tiles recorded offline. This is
one sequential local-network run, not a guarantee for every region or network.
The server/drive cache may also favour the second run.

The final native archive suite passed 31 checks, including recovery after a
simulated interruption between storing the archive and installing references.
Backward compatibility suites passed 24 section-pack checks, 344,699 region
assertions and 59 catalogue/offline checks; three Python builder tests passed.
The final signed iOS Debug build succeeded. User downloads were not cleared.
