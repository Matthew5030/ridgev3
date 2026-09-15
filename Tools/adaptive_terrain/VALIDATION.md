# National-park and UK terrain validation — 15 September 2026

Built terrain assets for all **15 parks in the supplied boundary collection**.
Coverage is partial wherever complete prepared native chunks are unavailable;
this is not a claim of complete survey coverage in every park.

| Park | Polygon coverage | Compact terrain | Fewer triangles vs native grid |
| --- | ---: | ---: | ---: |
| Bannau Brycheiniog National Park | 99.34% | 261.62 MB | 84.52% |
| Cairngorms National Park | 7.52% | 15.94 MB | 97.61% |
| Dartmoor National Park | 100.00% | 37.37 MB | 97.61% |
| Eryri National Park | 97.82% | 490.94 MB | 83.74% |
| Exmoor National Park | 98.51% | 30.48 MB | 97.45% |
| Lake District National Park | 99.96% | 150.84 MB | 96.89% |
| Loch Lomond and The Trossachs National Park | 3.00% | 2.87 MB | 97.46% |
| New Forest National Park | 99.19% | 13.57 MB | 98.02% |
| North York Moors National Park | 70.30% | 45.17 MB | 97.63% |
| Northumberland National Park | 98.00% | 43.80 MB | 97.86% |
| Peak District National Park | 100.00% | 72.79 MB | 97.34% |
| Pembrokeshire Coast National Park | 58.11% | 63.08 MB | 86.20% |
| South Downs National Park | 99.70% | 52.92 MB | 97.86% |
| The Broads | 99.86% | 8.55 MB | 97.89% |
| Yorkshire Dales National Park | 100.00% | 105.73 MB | 97.51% |

Total preferred terrain payload: **1,395,648,961 bytes
(1.396 GB)**, excluding index/boundary metadata, map textures,
walking graphs and horizon meshes. Original native heightfields total
38,365,303,158 bytes, or 7,824,558,266 bytes compressed
with the same zlib level. RAT1 reduces downloads by
82.16% against that compressed baseline.

## Geometry and source checks

- The adaptive compiler is unchanged: SHA-256
  `d05946e01796cfeb37995cee3396d42dadd47f23599de9de5c6be6c397035ab7`.
  Every emitted triangle is checked at native vertices and native diagonal
  crossing points against the prepared surface's 0.5 m additional vertical
  error limit. This does not assert absolute LiDAR survey accuracy.
- Every RAT1 encoding reconstructs its original RME1 file byte-for-byte before
  acceptance. Heights, triangle counts, triangle/vertex order and native shared
  edges remain identical; only the storage representation changes.
- Independent interpolation/topology checks use up to 26 distributed/extreme chunks
  per park. All meshes are checksum checked and all **140,945
  shared edges** match exactly. Retained original-source samples for the 13
  England/Wales publications were separately rechecked against their hashes.
- Seventeen publication/codec regression tests and seven Scottish source tests
  pass. They cover native 32-bit and simplified 16-bit meshes, malformed data,
  immutable revisions, concatenated-package reuse, direct verification without
  raw scratch files, missing sources, source corruption, NoData and resampling.

## Scottish inputs

The supplied prepared products have no Scottish native source coverage. This
batch acquired 58 official DTM TIFFs (3.74 GB) from the Scottish public-sector
LiDAR bucket, recording object ETags, lengths, SHA-256 hashes and original URLs.
Only the selected nominal 1 m and 50 cm inputs were used. Filename grid squares
were only a shortlist: actual valid raster coverage is substantially smaller.

Preparation uses the official OSTN15 coordinate grid, a virtual 1 m British
National Grid mosaic, geographic sampling and 0.1 m height quantisation. Missing
samples exclude a whole native chunk. Published Scottish terrain uses prepared
source version `2026.09.14-2`.

The first preparation was rejected by the seam audit: window-dependent VRT
resampling differences could round to different 10 cm source heights. The fix
uses globally aligned 512-pixel reads with a bounded cache. A regression test
fails with the original sampler and passes with the corrected one; the final
Scottish meshes also pass the full shared-edge check. Rejected assets were never
published. Source licences, attribution, preparation and transformation details
are retained in each public index.

## Static download checks and application limits

Actual Docker HTTP checks passed for all 15 preferred sources: index/asset
checksums, representative and extreme chunks, zlib/RAT1 decoding, reconstructed
mesh hashes, byte ranges, private-file exclusion and rejected write requests.
The catalogue offers one preferred encoding per landscape. The unsupported
North York Moors revision returns HTTP 410, as described below. The normal
catalogue and its existing URLs are separate and unchanged.

These are **prepared terrain files**, not complete routable map packs. The normal
iOS app still uses its regular-grid reader and does not consume RAT1 yet. No
removed experiment entry point was restored. This change includes no app UI or
renderer modifications. Smaller downloads do not reduce the decoded mesh's GPU
memory, and no physical-iPad performance result is claimed.

Private manifests, source receipts, coverage plots, per-park reports and detailed
HTTP results are on the external drive under `Ridge Experiments`. Published
chunks are under `Ridge Sources` and served at `/adaptive-catalog.json` on the
existing local Docker server, port 8787. `NATIONAL-PARKS.md` and
`NATIONAL-PARKS.json` hold the complete measured collection summary.

## UK extension and official-footprint correction

The whole-UK inventory now applies the official EA 2022 DTM survey footprints
before accepting EA-derived source chunks. The earlier prepared availability
flags incorrectly admitted terrain outside those footprints. The corrected
plan retains 589,443 native chunks in 342 grid sections and excludes 212,986
unsupported candidates. All known constant −0.3 m chunks are excluded.

The footprint snapshot contains 21,380 checksum-locked features. GEOS linework
repairs invalid nested rings without outward buffering; acceptance requires the
full projected chunk envelope plus 2 m interpolation support within the survey
union. Six footprint tests and four planner tests cover holes, adjoining
surveys, checksums, incomplete snapshots and valid fallback selection.

Comparing all 15 existing park publications against the corrected selection
found only North York Moors affected. Its new immutable revision is
`north-york-moors-adaptive-0p5-coverage-v2`: 4,746 chunks, with 561 unsupported
chunks excluded, including 80 wholly flat −0.3 m chunks. The old revision is
superseded in the catalogue and returns HTTP 410. Its updated coverage and
payload are reflected in the table above. All 75 representative park chunk
HTTP checks passed again after this correction.

The separately labelled UK coarse background is complete: **674 sections,
193,728,577 bytes**. Every section was downloaded, decompressed and checked;
all **1,197 shared edges** agree exactly, including NoData masks. Four background
regression tests pass. This is coarse global elevation, not 1 m LiDAR and not
covered by the detailed layer's 0.5 m error guarantee.

The detailed UK conversion is complete. Its catalogue advertises
`rat1-zlib-range-v1`, contains all **342 planned detailed sections**, and has
`buildComplete: true`. The final HTTP verification passed in every section,
including actual byte-range delivery, lossless decoded hashes, full local
container hashes, background descriptor checks, private-file exclusion and
write refusal. The final plan's SHA-256 matches the frozen build identity.

| Final UK measurement | Result |
| --- | ---: |
| Independently downloadable detailed chunks | 589,443 |
| Compressed adaptive terrain | 7,034,679,311 bytes |
| Detailed section indices | 468,690,319 bytes |
| Original native heightfields | 310,246,249,734 bytes |
| Same heightfields compressed with zlib level 6 | 44,393,701,339 bytes |
| Adaptive payload saving against compressed heightfields | 84.15% |
| Maximum measured additional surface error | 0.499219 m |
| Matching within-section shared edges | 1,149,759 |
| Matching cross-section shared edges | 23,702 |

All served UK terrain assets, including detailed and background metadata and
boundaries, total **7,698,107,317 bytes (7.70 GB)**. Cartography and routing data
are separate. The new compact files still require a RAT1 reader in the normal
app; this asset build does not change the app's reader or renderer.

The detailed layer contains 506,790 EA chunks, 80,574 Welsh chunks and 2,079
Scottish chunks. It is **not nationwide 1 m LiDAR coverage**. Most of Scotland
and Northern Ireland have only coarse context in this collection. The UK
administrative polygon includes territorial water; its coverage ratio must
not be presented as a UK land percentage.

Completed revision: `uk-adaptive-0p5-v3`, served by the local Docker server at
`/uk-adaptive-0p5-v3/catalog.json`. Private final reports are
`Ridge Experiments/UK-adaptive-0p5-v3/UK-TERRAIN.json` and `UK-TERRAIN.md` on the
external drive. The measured totals are storage/download sizes: the complete
UK geometry is not intended to be loaded into one scene.


### South Wales join correction

A cross-source audit found nine mismatching native edges between the older EA
fallback and the Welsh source, including one 44 m difference at a coastal edge.
The same immutable Welsh COG reproduced the existing reference exactly and
supplied 78 complete coastal chunks that the earlier whole-parent rule had
lost. The corrected section uses 78 Welsh chunks and 240 EA chunks on the
separate Somerset shore. Its 613 shared native edges, including the northern
neighbour, agree exactly. The source ownership policy suppresses incompatible
fallbacks where the Welsh source has gaps.

The corrected UK revision is `uk-adaptive-0p5-v3`. Survey checks now require the
local official OSTN15 coordinate grid. All 83 already completed sections had
unchanged source selections and were imported after full container checksum
verification. Three import regression tests pass, including changed selections
and damaged containers. The following pilot reached 84 sections and passed
actual HTTP range, decoded-hash, background-descriptor and access-control
checks at the new URLs. The repaired section subsequently passed the full UK
build and final HTTP verification; completed totals are recorded above.
