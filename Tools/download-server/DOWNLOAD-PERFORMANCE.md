# Download measurements — 11 October 2026

Observed the iPad's live requests to the local Docker server while investigating
slow regional downloads. No cloud service was enabled.

- Device log window: 5,963 successful requests, 150.16 MB in 88 seconds
  (approximately 1.7 MB/s). All responses were HTTP 200, with no completed-request
  gap exceeding one second in that window.
- Eryri catalogue: 57 published sections, 13,424 tiles, approximately 1.245 GB
  before shared-asset reuse, and 40,272 individual tile files plus metadata.
- A warm-server Mac test of 240 assets (5.87 MB), from a section being downloaded,
  achieved 42.85 MB/s over one persistent localhost connection and 121.89 MB/s
  over six. This is not an iPad Wi-Fi benchmark or a cold-drive benchmark.
- The downloader copies and verifies files; it does not construct 3D geometry or
  rasterise vector textures during this transfer stage.

The previous transfer loop awaited byte progress on the UI actor after every
file, before replacing the completed network request. Its tile reporter also
rebuilt per-tile sets before deciding whether to throttle the update.

The fix refills the network queue first and coalesces byte/tile updates to roughly
12 per second, preserving initial/final updates. The reporter checks its throttle
before building tile sets. A 35,136,787-byte Mac integration test changed from
1,539 byte callbacks to 16, retaining 14 tile animation updates. Transfer times
were 1.224 s before and 1.163 s after; this is a callback reduction, not evidence
of a substantial iPad throughput improvement.

## Remaining work

The many-small-file transfer format remains inefficient. Trial a bounded bundle
per source or small tile group, with an index of constituent hashes and offsets.
Verify files while installing into the existing hash cache; preserve overlap
reuse, pause/resume, corruption repair and tile completion animation. Keep the
individual-file path for sparse repairs so one missing asset does not force a
whole bundle transfer. Benchmark on the physical iPad, including raw network
throughput, before claiming a speedup or changing the full published library.
