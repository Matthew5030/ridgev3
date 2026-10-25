# Vector map study

Separate experiment, with no production app/data changes. Uses original semantic map geometry, source-derived contours and the exact fixed mesh from the previous compression study. SVG + gzip is a convenient prototype transport; this does not select the final production format.

Dependencies: Python with numpy, Pillow, shapely and contourpy; Node with Playwright; installed Chrome. No external web services are used by the viewer.

1. Extract `map-data.ridgemap` from the retained source tile archive (z10/500/333) as JSON. Do not trace the raster images. Keep the source revision and checksum. This run used source revision `2026-08-23T20:21:36Z/d6f43249a332623a`.
2. Run `prepare.py --source PATH/map-data.json --reference PATH/texture-study-results --output NEW_OUTPUT`. Output must be fresh. The prior study provides source metadata and the exact terrain mesh. Inputs are read-only and hashes are verified.
3. Serve the new output: `python3 -m http.server 8775 --bind 127.0.0.1 --directory NEW_OUTPUT`.
4. Run `node measure.cjs NEW_OUTPUT control`, then `python finish.py NEW_OUTPUT` to encode the matched WebP. `PLAYWRIGHT_MODULE` can specify an absolute module directory; `CHROME_PATH` overrides Chrome's executable path.
5. Run `node measure.cjs NEW_OUTPUT`, then `python finish.py NEW_OUTPUT` again for the measurements, verification, screenshots and report.
6. Open `http://127.0.0.1:8775/`. Left is a fixed lossless raster, right draws the same vector source locally. Automatic quality refreshes after zoom settles. Both share geometry, lighting and camera. The selector also exposes the earlier map as a separate visual reference.

The browser only fetches `map.svg.gz` for vectors; `map.svg` and high-resolution PNG outputs are diagnostic artifacts, not extra published imagery levels. SVG embeds the shared style. Labels are retained in report metadata and excluded equally from both matched textures. Routing data is unaffected.

See `evidence/REPORT.md` for measured results and explicit limitations. In particular, this is not a native iPad or sustained-memory benchmark and does not validate independent tile seams. The browser prototype uses main-thread rasterization after a debounce; production needs bounded background work and GPU texture pages.
