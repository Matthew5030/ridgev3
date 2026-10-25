# Texture compression study

An isolated, reproducible counterpart to the LiDAR study. Never modifies packs or the app.
Requires Python, NumPy and Pillow with WebP. Use a new output directory per run.

```sh
python3 Tools/texture_compression_study/study.py \
  --pack '/path/to/retained/regions/eryri-grid' \
  --output '/path/to/texture-study-results' --samples 16 --decode-repeats 9
python3 -m http.server 8774 --bind 127.0.0.1 --directory '/path/to/texture-study-results'
```

Native Mac compatibility check (separate from the Python timing):

```sh
swiftc Tools/texture_compression_study/native_decode.swift -o /tmp/ridge-texture-native-decode
/tmp/ridge-texture-native-decode '/path/to/texture-study-results'
```

Open localhost:8774 for matching 3D views, flat.html for pixel comparison, REPORT.md
for measured results and limitations, and results.json for source hashes, every
encoded file's size/hash, per-tile errors and timing evidence. Output contains
actual candidate encodings as well as reconstructed display PNGs. The latter
are not counted in download sizes.

The initial fixture is the retained Eryri atlas around Crib Goch, not the newer
illustrated art experiment or the current whole-park source. Sampling is two
fixed Crib Goch tiles plus file-size quantiles of locally available native maps.
It is intentionally challenging, not a statistically representative UK survey.
Source metadata and files are checksum validated. Dataless iCloud files are
skipped to avoid silently fetching unrelated large files.

Compares original PNG, optimised lossless PNG, lossless WebP, 256/128/64-colour
PNG without dithering, quality-90 WebP, and a low-resolution predictor plus exact
residual. Four variants must match every original RGB pixel. The split test is
a codec experiment, not a semantic land-cover/ink implementation. Reconstructing
its original high-frequency detail can cost more than keeping one PNG.

Lossy candidates retain spatial resolution, but may damage anti-aliased lines.
Global error, worst channel error and a dilated reference-edge error metric are
reported separately. No automated visual acceptance threshold is asserted.

Decode timing uses warmed, in-memory Pillow to RGB, one warm-up and nine measured
rounds in deterministic shuffled order; excludes network, disk, GPU upload and
mips. Also run native_decode.swift for a separate Mac ImageIO compatibility/timing
check. Neither measures physical iPad performance. GPU atlas allocation is not
reduced by smaller PNG/WebP download files.

Next gate: repeat on the accepted illustrated style with contours, source-derived
colour/ink layers and boundary-heavy tiles when the source drive is available.
Then profile the shortlisted format on the M1 iPad, including loading, mipmaps,
seams, memory, and actual app decoding. Do not extrapolate a final UK size from
this small legacy fixture. No nationwide reprocessing is authorised by the study.
