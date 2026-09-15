# Crib Goch texture comparison

A reproducible, separate experiment: redraw the existing baked map at twice the width and height, then compress it with ASTC 4×4. The application and published packs are unchanged.

## Results — 15 September 2026

Actual private Metal texture allocations, including complete mip chains, on Apple M4 Pro:

| Variant | Map dimensions | Texture GPU allocation | Median render pass |
| --- | --- | --- | --- |
| Current RGBA sRGB | 2048² | 21.34 MiB | 0.156 ms |
| 2× RGBA sRGB | 4096² | 85.34 MiB | 0.160 ms |
| 2× ASTC 4×4 sRGB | 4096² | 21.34 MiB | 0.150 ms |

Geometry is identical: 66,049 vertices, 131,072 triangles, 4.53 MiB of allocated vertex/index buffers. These are the prepared normal-app 4 m samples, not a new adaptive mesh. The texture already outweighs geometry in this particular test; compression avoids quadrupling that texture allocation.

The compressed 2× result visibly reduces pixel stepping on close contours and paths. It does not remove every raster artefact or add new contour/source geometry. Compression is very close to the uncompressed 2× image: CPU mean absolute channel error 0.0101/255, edge error 0.0482/255, PSNR 68.04 dB. On the actual Metal close-up, compressed versus uncompressed mean error is 0.0123/255, maximum 4/255. No pixel has a channel error above 16/255.

Full-resolution Metal flat readbacks match the original HD PNG and Arm's decompressed ASTC reference exactly, respectively. This verifies orientation, colour conversion and native ASTC upload/decode. All four existing source PNGs were independently regenerated pixel-for-pixel before increasing resolution.

Download size is a separate tradeoff: current complete PNG mip files total 2.37 MB, HD PNGs 6.34 MB, raw ASTC mips 22.37 MB. Zlib compresses those ASTC files to 7.23 MB. This is an experimental bundle, not a production container. ASTC saves GPU storage relative to decoded RGBA, not necessarily download bytes relative to PNG.

One-run loading/upload times were 0.097 s current, 0.204 s HD and 0.348 s ASTC. The renderer's loading path includes file parsing, validation and upload; these are not a statistically controlled download/decode benchmark. Render timings use 20 warmed-up samples per variant with interleaved order, 1440×1000, 4× MSAA and 16× anisotropy. Differences are tiny; do not infer that ASTC makes the app faster. This is a small Mac render-pass experiment, not an iPad memory ceiling, full app benchmark, or peak working-memory measurement.

## Reproduce

Requires Python with NumPy/Pillow and the existing pack tooling dependencies, Xcode, and the official Arm astcenc 5.7.0 macOS universal binary. The test is deliberately fixed to four Crib Goch cells (columns 30–31, rows 48–49) in the `eryri-park` source. It also reads the original map source via `prepare_packs.OLD`, so keep that local archive available.

```sh
python Tools/texture_lab/prepare.py \
  --source '/Volumes/MLB_EXT_4TB/Ridge Sources/eryri-park' \
  --output '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-texture-2x' \
  --encoder /tmp/ridge-astcenc-5.7.0/bin/astcenc
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swiftc Tools/texture_lab/render.swift -o /tmp/ridge-texture-lab-render
/tmp/ridge-texture-lab-render '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-texture-2x'
python Tools/texture_lab/verify.py '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-texture-2x'
cp Tools/texture_lab/index.html Tools/texture_lab/README.md '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-texture-2x/'
python -m http.server 8770 --bind 127.0.0.1 \
  --directory '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-texture-2x'
```

Open http://127.0.0.1:8770/. Whole-image switching preserves inspection zoom/pan; keys 1–3 compare variants. The page displays fixed native Metal renders, not a browser terrain renderer. Changing camera preset resets zoom. Large generated artifacts remain on the external drive.

`source.json` records bounds, source checksums, encoder checksum, exact baseline reproduction, geometry hashes, mip metadata and compression error. `gpu.json` records real Metal allocations and timings. `verification.json` records GPU readback checks. All variants share precomputed linear-light box mip filtering; production currently generates mips through Metal. Style widths and dash lengths double in pixels to preserve their map-space size. Same source contours, shading, geometry and camera throughout.

Encoder: [Arm astcenc 5.7.0](https://github.com/ARM-software/astc-encoder/releases/tag/5.7.0), sRGB, 4×4 blocks, `-thorough`. Official macOS universal zip SHA-256: `374b2f0aea1d3ab5f849784666d6ece6e27b4bc1f945e5c90d6eeabf00e955f8`.

Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright). LiDAR is reused from the existing Ridge prepared Welsh terrain source; retain the source pack's full attribution when shipping derived assets.
