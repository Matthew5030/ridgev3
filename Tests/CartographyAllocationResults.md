# Cartography allocation regression

Measured on **Apple M4 Pro** using `MTLTexture.allocatedSize`. Reproduce with:

```sh
sh Tools/test_cartography_allocation.sh
```

The current renderer uses one continuous preview texture, 16 native array slices and 192 medium array slices. All textures are private `rgba8Unorm_srgb` with complete mip chains. The preview is `columns × 64` by `rows × 64` and uses `shaderRead`; native 1032² and medium 264² arrays use `shaderRead | pixelFormatView`.

The table adds the policy's **32 MiB sequential decode/upload reserve and 2 MiB metadata reserve** to measured GPU allocations. These totals are not measured process memory or iPhone performance results.

| Atlas cells | Preview GPU MiB | Native GPU MiB | Medium GPU MiB | GPU + 34 MiB reserve | Device admission estimate MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 × 1 | 0.03125 | 6.54688 | 0.65625 | 41.23438 | 41.50000 |
| 1 × 64 | 1.35938 | 104.75000 | 42.00000 | 182.10938 | 182.31250 |
| 43 × 43 | 40.46875 | 104.75000 | 126.00000 | 305.21875 | 305.43750 |
| 50 × 47 | 50.70312 | 104.75000 | 126.00000 | 315.45312 | 315.68750 |
| 56 × 56 | 66.17188 | 104.75000 | 126.00000 | 330.92188 | 331.12500 |
| 64 × 64 | 86.01562 | 104.75000 | 126.00000 | 350.76562 | 351.00000 |

The maximum measured layout stays within the **384 MiB cartography cap**. Live admission uses `heapTextureSizeAndAlign` with matching descriptors, rounds each result up to at least 64 KiB alignment, and adds 64 KiB per texture resource. The renderer separately checks actual allocated sizes before decoding maps. Explicitly injected test contexts use a deterministic fallback, whose maximum is 375.43750 MiB.

The harness preserves the failed earlier layout for comparison. Two 72² × 2048 preview arrays consumed **384 MiB** alone; adding 16 native slices and 256 medium slices produced **656.75 MiB of textures**, or **690.75 MiB including reserves**. Counting nominal mip texels plus ten percent had incorrectly predicted **347.83153 MiB**. Small array-slice alignment was the main cause.

An additional regression caught mismatched preview usage flags: the 56² preview consumed 66.17188 MiB with `shaderRead`, versus 65.50000 MiB when `pixelFormatView` was also enabled. The final estimator matches the renderer's flags exactly.

Validation: **13 actual-allocation assertions**, **473 atlas assertions**, and **338 legacy terrain-budget assertions** passed. Full filename/hash/crop validation is retained; the fast budget footprint validates allocation dimensions, geographic cells, coverage and byte limits without repeating file-integrity scans.
