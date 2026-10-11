# Indexed section downloads

Each existing source section can advertise an optional `pack` asset in the world
catalogue. It contains the section overview, effective connected routing graph,
and its original background, vector and adaptive terrain assets. No geometry or
cartography is regenerated or reduced in quality.

The app streams the pack into a `.partial` file and resumes with HTTP Range.
It verifies complete entries as they arrive, driving the existing geographic tile
progress. Only after validating required entries and the whole-file SHA-256 does
it rename the file, pin it and record offline coverage. It never extracts the
pack: the source actor opens an index and reads/decompresses only requested assets.

Old loose-file downloads remain valid. When most of a section is already saved,
the downloader fetches only missing assets instead of replacing it with a pack.
Completed packed sections are reused across overlapping area/park selections.
The published loose assets remain available for old app versions and sparse repair.

## Format version 1

- Eight ASCII bytes `RIDGEPK1`, followed by a little-endian UInt32 index length.
- UTF-8 JSON: `schemaVersion`, `sourceID`, `entries`.
- Entries contain original `sha256`, decoded `byteCount`, payload-relative
  `offset`, `storedByteCount`, and `compressed` (zlib when true).
- Entries are contiguous and deduplicated by original content hash. JSON assets
  are compressed when beneficial; existing compressed map/mesh bytes are retained.
- Maximum pack 256 MiB, index 2 MB, 1,024 entries, decoded entry 64 MB.
- Filename `section-<whole-pack-sha256>.ridgepack`; catalogue `pack` has the same
  `file`, `byteCount`, `sha256` fields as other map assets.

The app stores packs under `WorldCache/section-packs/`, with a small reference
per source. Offline receipts reference the pack hash once per tile, avoiding
hundreds of filesystem checks. Rendering still loads individual nearby tiles;
downloading a region does not load that region into memory.

## Build and publish

```
python3 Tools/world_source/pack_sections.py ROOT --source SOURCE_ID --publish
python3 Tools/world_source/pack_sections.py ROOT --workers 4 --publish
```

The builder verifies original hashes, writes immutable packs, saves resumable
per-source receipts, and atomically publishes completed packs in batches of 25. Unconverted
sections continue using existing assets until their packs are ready. A resumed run validates existing packs before skipping them.
`section-pack-status.json` reports progress. Original assets and the previous
catalogue are retained. Allow disk space for both representations during rollout.

The local Docker server allows pack filenames and supports byte ranges. Its
runtime nginx configuration may be an Application Support copy rather than the
repository file: inspect `docker inspect` mounts before applying configuration.
Cloud hosting is not enabled by this change.

## Verification

```
python3 -m unittest discover -s Tools/world_source -p test_pack_sections.py
sh Tools/test_world_section_packs.sh
sh Tools/test_world_region_packs.sh
```

Native tests use the local pilot section, exercise indexed offline reads, verify
overlap reuse, inject corruption, cancel an actual HTTP transfer, resume it and
exercise a server that ignores Range. Region tests explicitly retain the legacy
loose-file path to cover compatibility and single-asset repair.

## Pilot result — 11 October 2026

On the connected M1 iPad Pro over its local-network connection, source
`world-z10-x500-y333-c00-r16` took 18.59 seconds as loose files (26,090,256
bytes) and 2.87 seconds as an indexed pack (20,192,690 bytes). This is one
section, about 6.5× faster and 22.6% fewer transferred bytes; it is not a promise
for every region or network. The library packaging job was also using the drive.
Both paths reopened offline and prepared adaptive terrain with vector cartography.
The opt-in debug `RIDGE_BENCHMARK_PACK` launch writes `Documents/pack-benchmark.json`
and removes its isolated temporary downloads afterwards.

Validation: 24 native pack checks (including normal region download/planning and
an already-open landscape discovering a new pack); 344,699 existing region,
coverage, overlap, rendering, animation and repair assertions; Python pack
round-trip/deduplication/rebuild/corruption tests; signed iOS Debug build.
