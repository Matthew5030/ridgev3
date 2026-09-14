# National-park adaptive terrain validation — 14 September 2026

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
| North York Moors National Park | 79.12% | 45.41 MB | 97.72% |
| Northumberland National Park | 98.00% | 43.80 MB | 97.86% |
| Peak District National Park | 100.00% | 72.79 MB | 97.34% |
| Pembrokeshire Coast National Park | 58.11% | 63.08 MB | 86.20% |
| South Downs National Park | 99.70% | 52.92 MB | 97.86% |
| The Broads | 99.86% | 8.55 MB | 97.89% |
| Yorkshire Dales National Park | 100.00% | 105.73 MB | 97.51% |

Total preferred terrain payload: **1,395,881,651 bytes
(1.396 GB)**, excluding index/boundary metadata, map textures,
walking graphs and horizon meshes. Original native heightfields total
38,660,578,776 bytes, or 7,825,178,496 bytes compressed
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
  per park. All meshes are checksum checked and all **142,022
  shared edges** match exactly. Retained original-source samples for the 13
  England/Wales publications were separately rechecked against their hashes.
- Fifteen publication/codec regression tests and seven Scottish source tests
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
The catalogue offers one preferred encoding per landscape; existing legacy URLs
remain valid. The normal catalogue is separate and unchanged.

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
