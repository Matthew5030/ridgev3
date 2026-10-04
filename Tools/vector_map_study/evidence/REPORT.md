# Crib Goch vector map experiment

One compressed vector source is rasterized locally at the requested resolution, then draped over the existing terrain. No app or source packs were modified.

| Source for the same area | Bytes |
|---|---:|
| SVG + gzip, including shared style | 39,920 |
| Matched-style lossless WebP, 1024 × 2051 | 109,678 |
| Matched-style PNG | 465,381 |

Vectors save **63.6%** against the matched WebP in this sample. They are not pixel-lossless against the older production map. At equal output size the matched WebP and vector draw are verified pixel-identical.

The earlier legacy WebP pair was 450,202 bytes, but it includes baked relief and differently generated contours. Comparing against that figure would mix a format change with a content/style change.

84 contour lines: 12,658 → 6,304 points. Measured planar simplification error before coordinate rounding: 0.2499 m. Coordinates rounded to 0.01 m. This is contour geometry simplification, not a terrain elevation accuracy claim.

## Browser measurements

Warm browser on Mac. Draw completion includes a 1-pixel readback. Upload includes mip generation and blocking gl.finish for measurement only. Network and native iPad excluded.

Renderer: ANGLE (Apple, ANGLE Metal Renderer: Apple M4 Pro, Unspecified Version)

| Texture width | Draw submission median | Draw + readback median | Upload + mips + GPU finish median | RGBA + mip estimate |
|---|---:|---:|---:|---:|
| 512 px | 1.90 ms | 4.40 ms | 0.30 ms | 2.7 MiB |
| 1024 px | 2.40 ms | 5.40 ms | 0.30 ms | 10.7 MiB |
| 2048 px | 2.60 ms | 9.10 ms | 0.40 ms | 42.7 MiB |

Seven warm samples after one discarded run per size. Tiny sample on this Mac, not an iPad performance guarantee. A blocking GPU finish is used only by the benchmark. The interactive viewer does not wait for GPU completion.

Memory estimates describe one resident RGBA texture and its mipmaps, not total app memory. Canvas, decoding, meshes, comparison textures and temporary old/new textures during replacement add more. This prototype redraws on the main thread after zoom settles; it does not prove background rendering or smooth streaming.

## Limits and next decision

- Two adjacent Crib Goch cells only; not representative of the UK.
- Legacy source/style; not the latest illustrated map style.
- 10 m contours derived from retained 4 m terrain; no new 1 m processing.
- SVG is an experiment transport, not a proposed production format.
- Labels retained as metadata, not part of texture rendering.
- Matched control has identical features/style; legacy imagery also has baked relief.
- Runtime texture memory remains; this does not make a bigger texture free.
- This is one combined study extent, not a proof of seamless independently clipped vector tiles. Dash phase, polygon edges, contour continuity, labels and seams need separate multi-tile validation.
- Point labels are retained in report metadata but deliberately absent from BOTH matched textures. A production screen-space label renderer and its costs remain to be tested.
- The source buffer is 8 m. Simplification and clipping are offline. Routing graphs are separate and unchanged.
- The automatic detail policy is a small camera-distance experiment capped at 2048 px wide, not a production screen-space-error scheduler.
- No device disk cache, network stress test, sustained memory measurement, wider-UK extrapolation or latest illustrated material test was performed.
- Next: test native background rasterization on M1 iPad and larger mixed rural/urban/water areas; reuse the same vector source while keeping GPU texture pages bounded.

Attribution: © OpenStreetMap contributors (ODbL); Welsh Government terrain (OGL v3).
