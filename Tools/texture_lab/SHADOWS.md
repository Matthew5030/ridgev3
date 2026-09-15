# Illustrated Crib Goch lighting experiment

Three native Metal renders reuse the exact approved illustrated planning texture, geometry, camera and sun direction:

1. Current illustrated lighting.
2. Stronger direct sunlight / lower ambient contribution, without cast shadows.
3. The same stronger lighting plus terrain-cast shadows.

No textures, LiDAR, geometry or map packs are regenerated. This is a standalone preview; the production app/defaults are unchanged.

## Run

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swiftc Tools/texture_lab/shadow.swift -o /tmp/ridge-shadow-study
/tmp/ridge-shadow-study \
  '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-illustrated-planning-v1' \
  '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-shadow-study-v1'
python Tools/texture_lab/verify_shadows.py \
  '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-illustrated-planning-v1' \
  '/Volumes/MLB_EXT_4TB/Ridge Experiments/Crib-Goch-shadow-study-v1'
```

Requires Metal/Xcode and the prepared texture experiment. The screenshot verifier uses NumPy/Pillow and macOS Helvetica for its labels. Outputs include matched `close-*` / `wide-*` PNGs, `lighting-comparison.jpg`, `shadow-study.json`, raw float light-space depth, and `verification.json`.

## Shadow method

Rasterize the unchanged terrain mesh into a 1024² depth32Float map, viewed from the same directional sunlight as the shading. The orthographic light frustum fits the existing vertices with 20 m padding. Compare receiver depths using 5×5 percentage-closer filtering and linear depth comparison sampling. Correct sample depths using the receiver triangle's depth gradient and a small normalized bias to reduce false self-shadow stripes. Bias can detach small shadows; this remains a prototype for further bias/coverage validation, not a production shadow system.

The soft filter is an artistic edge treatment, not a physical sun-penumbra model. Only the roughly 1 km test mesh casts shadows; unrepresented surrounding terrain cannot block sunlight. A production implementation needs appropriate surrounding casters and wider-area validation. For fixed terrain and sun the depth map is built once, then sampled while the camera moves; terrain or sun changes require a rebuild. A single small fixed-area shadow map is not a demonstrated whole-park solution.

## Results — Apple M4 Pro

- Same ASTC map allocation: 22,380,544 bytes (21.34 MiB).
- Same geometry allocation: 4,751,360 bytes (4.53 MiB).
- Extra shadow depth allocation: 4,227,072 bytes (4.03 MiB).
- One shadow-depth build: ~0.531 ms GPU.
- Median isolated close render pass: current ~0.276 ms, stronger contrast ~0.475 ms, cast-shadow version ~1.791 ms. 20 warmed-up samples per case, interleaved order, 1440×1000 with 4× MSAA. These are this prototype's Mac measurements, not full-app/iPad performance or a promise of production shader efficiency.

Both baseline camera views reproduce the previous approved ASTC screenshots **pixel-for-pixel**. Geometry checksums match. The shadow-depth texture contains valid finite terrain/background depths. Adding cast shadows never brightens a pixel. Relative to stronger contrast alone, the cast-shadow pass darkens 19,560 close-view pixels by more than five channel values, with maximum darkening 29/255. This is a subtle effect at the fixed high sun angle (~55°), not a dramatic long-shadow scene.

Visual assessment: stronger contrast supplies most of the visible increase in depth here. Cast shadows add local occlusion but also extra GPU work and require further artefact testing. Keep all three as user-review candidates rather than changing the default automatically. Contours and paths are unchanged in every case.
