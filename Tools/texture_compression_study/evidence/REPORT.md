# Texture compression study

Measured 16 real tiles from 1863 locally available native atlas images.

Locally retained legacy Eryri atlas, not the current illustrated experiment or full published park.
Two Crib Goch cells plus deterministic file-size quantiles among locally available native tiles; not a UK-representative sample.

Encoded native images only; existing previews, network, disk I/O, mip generation, GPU upload and render timings excluded. Warm in-memory Pillow decode to RGB on Mac.

| Format | Sample MB | Saving | Exact pixels | Median decode / tile (ms) | Worst edge p99 /255 | Max error /255 |
|---|---:|---:|---|---:|---:|---:|
| Original PNG | 3.966 | 0.0% | True | 5.55 | 0.0 | 0 |
| Optimised PNG · lossless | 3.661 | 7.7% | True | 5.29 | 0.0 | 0 |
| WebP · lossless | 2.263 | 43.0% | True | 3.34 | 0.0 | 0 |
| PNG · 256 colours | 2.775 | 30.0% | False | 2.03 | 1.0 | 3 |
| PNG · 128 colours | 2.652 | 33.1% | False | 1.96 | 27.0 | 27 |
| PNG · 64 colours | 2.320 | 41.5% | False | 1.82 | 67.0 | 79 |
| WebP · quality 90 | 1.025 | 74.2% | False | 4.32 | 28.0 | 51 |
| Small base + exact residual | 8.517 | -114.7% | True | 6.00 | 0.0 | 0 |

## Interpretation and limits

- Palette tests preserve dimensions and positions but change colours, including anti-aliased line pixels. They are not lossless.
- WebP requires verified iOS decoding and app loader integration before adoption; browser/Pillow support is not proof of app support.
- Split is an exact low-resolution predictor plus RGB residual, not a semantic land-cover/ink implementation. Both files, reconstruction metadata and decode cost are counted.
- All displayed images are reconstructed PNGs for controlled visual comparison. Their sizes are excluded; encoded candidate assets are measured instead.
- Every browser profile uses the same measured heightfield, mesh, lighting, camera and resolution. Browser previews are not iPad GPU benchmarks.
- 3D stats show two Crib Goch tile bytes; percentage saving is across the full sample. Error views show max channel difference ×8.
- No geometry, texture resolution, map styles, source features, or production assets were changed.
- Sample source hashes are checked before and after. Four lossless variants must round-trip exactly.
- GPU memory is unchanged if candidates are expanded into the current RGBA atlas. Download compression is a separate metric.
- Current illustrated sources and full park are unavailable on the disconnected external drive. True source-separated colour/ink, seam validation of such layers, and full-park size projection remain pending.

Environment: {"platform": "macOS-26.6.2-arm64-arm-64bit", "machine": "arm64", "python": "3.12.14", "pillow": "12.3.0", "numpy": "2.3.5"}

Edge metric: 3x3 dilation of reference adjacent RGB channel differences >=20; proxy for fine detail, not a semantic path/contour mask.

Open index.html through a local HTTP server for matched 3D views, or flat.html for pixel inspection. Machine-readable evidence: results.json.

## Native Apple decoder check

Mac ImageIO decode and draw to sRGB RGBA; warm memory; excludes I/O, network, GPU and mip generation. Not physical iPad.

| Format | Supported tiles | Median decode (ms) | Worst RGBA difference |
|---|---:|---:|---:|
| original | 16/16 | 9.82 | 0 |
| png9 | 16/16 | 9.61 | 0 |
| webp-lossless | 16/16 | 10.74 | 0 |
| palette256 | 16/16 | 10.64 | 3 |
| palette128 | 16/16 | 10.69 | 27 |
| palette64 | 16/16 | 10.55 | 79 |
| webp90 | 16/16 | 12.51 | 51 |

Native harness compiled with swiftc defaults (no optimisation flag). Concurrent machine activity was not controlled. Treat timing as indicative, not a device performance guarantee.

## Decision from this fixture

Shortlist lossless WebP: 42.95% smaller with zero RGB differences in all 16 images, also zero RGBA differences through Mac ImageIO. Median native decode is 10.74 ms versus 9.82 ms for original PNG. It saves downloads; this does not demonstrate faster rendering or reduced GPU memory.

Optimised PNG saves 7.71% without changing pixels or requiring a new decoder. Palette 256 saves 30.05% but changes some pixels (worst channel difference 3/255). Lossless WebP is both smaller and exact on this sample, so there is no reason here to sacrifice colours.

128 and 64 colours introduce much larger local errors; quality-90 WebP saves 74.17% but changes fine map detail. Do not approve these using average error alone.

The exact predictor/residual split is 114.72% larger than the original. Reject this naive implementation. This says nothing definitive about a future source-derived land-cover/ink representation, which was not tested.

If the 42.95% texture saving repeated across Eryri, texture storage would fall from 5.55 GB to about 3.16 GB and the complete pack from 6.66 GB to about 4.28 GB. This is illustrative arithmetic, NOT a measured full-park result or an estimate for the accepted illustrated style.

Validation: 128 stored candidate bundles independently reread, checksum/size checked, decoded and compared; 112 native ImageIO sample/format combinations checked. Browser variant switching, shared camera, and the zero-error view inspected. Input hashes unchanged.

Pending: current illustrated source/semantic layers on external drive; M1 iPad; actual app loader, full park and shared tile-edge checks. No production changes or nationwide rebuild.
