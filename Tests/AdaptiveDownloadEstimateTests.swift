import Foundation

private actor TransferTotals {
    var totals: Set<Int64> = []
    func record(_ total: Int64) { totals.insert(total) }
}

/// Live local-server check with a caller-supplied disposable cache.
@main struct AdaptiveDownloadEstimateTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Pass the published adaptive source and a disposable cache directory") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let cache = URL(fileURLWithPath: CommandLine.arguments[2])
        let manifest = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: source.appendingPathComponent("index.json")))
        let grid = manifest.grid!, uv = manifest.tileUV(GeoPoint(latitude: 53.0793, longitude: -4.0539))
        let x = Int(uv.u * Double(grid.columns)), y = Int(uv.v * Double(grid.rows))
        let selection = grid.rectangle(from: TerrainCell(column: x - 1, row: y - 1), to: TerrainCell(column: x, row: y))!
        let preview = AdaptiveArea.preview(manifest, selection: selection)
        let assets = AdaptiveArea.assets(preview)
        let before = try SourceDownloads.estimate(assets, at: cache)
        // Avoid accidentally running a gigabyte-scale cold-cache integration test.
        guard before.cachedBytes > 1_000_000_000, before.downloadBytes > 0, before.downloadBytes < 50_000_000 else {
            fatalError("Seed a nearby verified test download first; expected a partially shared map cache")
        }
        let log = TransferTotals()
        try await SourceDownloads.ensure(assets, at: cache,
            remote: URL(string: "http://127.0.0.1:8787/" + manifest.id)!,
            transfer: { _, total in await log.record(total) }) { _ in }
        let totals = await log.totals
        guard totals == [before.downloadBytes] else { fatalError("Displayed estimate and actual transfer disagree") }
        let after = try SourceDownloads.estimate(assets, at: cache)
        guard after.downloadBytes == 0, after.totalBytes == before.totalBytes else { fatalError("Completed download was not reused") }
        print("PASS: estimated and actual transfer both \(before.downloadBytes) bytes; reused \(before.cachedBytes) bytes; repeat selection needs zero bytes")
    }
}
