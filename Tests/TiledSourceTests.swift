import Foundation
import CryptoKit

private actor TransferLog {
    var partial = false
    func record(_ bytes: Int64, _ total: Int64) { if bytes > 0 && bytes < total { partial = true } }
}
private struct Failure: Error { var message: String }
@MainActor @main struct TiledSourceTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1; if !condition() { throw Failure(message: message) }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ridge-source-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let originalDirectory = root.appendingPathComponent("template")
        let original = try TerrainFixture.make(template: URL(fileURLWithPath: CommandLine.arguments[1]), directory: originalDirectory)
        let served = root.appendingPathComponent("server"), sourceDirectory = served.appendingPathComponent("fixture")
        try fm.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        var manifest = original
        manifest.id = "fixture"; manifest.name = "Fixture source"; manifest.places = []
        manifest.bounds = GeoBounds(minLatitude: 53, minLongitude: -4.1, maxLatitude: 53.02, maxLongitude: -4.06)
        manifest.grid = TerrainGrid(gridID: "ridge-eryri-uniform-v1", worldTileID: "fixture-grid", originColumn: 0, originRow: 0, columns: 4, rows: 2)
        manifest.graphFile = nil; manifest.graphByteCount = nil; manifest.graphSHA256 = nil
        manifest.textures = []; manifest.detailTextures = nil; manifest.cartographySourceID = nil
        let zeroHash = String(repeating: "0", count: 64)
        func virtual(_ spacing: Int, prefix: String) -> TerrainLOD {
            let width = 4 * 512 / spacing + 1, height = 2 * 512 / spacing + 1
            return TerrainLOD(spacing: spacing, width: width, height: height, file: "\(prefix)-\(spacing)m", byteCount: Int64(width * height * 2), sha256: zeroHash)
        }
        manifest.levels = [1,2,4,8,16,32].map { virtual($0, prefix: "tiled") }; manifest.defaultSpacing = 4
        manifest.horizon = TerrainHorizon(near: TerrainBackdrop(bounds: manifest.bounds, levels: [virtual(8, prefix: "near"), virtual(16, prefix: "near")], textures: []),
                                          far: TerrainBackdrop(bounds: manifest.bounds, levels: [virtual(32, prefix: "far")], textures: []))
        var cells: [TerrainSourceCell] = [], maps: [CartographyTile] = []
        let longitude = (0...4).map { manifest.bounds.minLongitude + Double($0) * (manifest.bounds.maxLongitude - manifest.bounds.minLongitude) / 4 }
        let latitude = (0...2).map { manifest.bounds.maxLatitude - Double($0) * (manifest.bounds.maxLatitude - manifest.bounds.minLatitude) / 2 }
        let baseMap = original.cartography!.tiles[0]
        for row in 0..<2 { for column in 0..<4 {
            var levels: [TerrainLOD] = []
            if !(row == 1 && column == 3) {
                for spacing in [1,4,8,16,32] {
                    let side = 512 / spacing + 1
                    var raw = Data()
                    for y in 0..<side { for x in 0..<side {
                        var value = Int16((column * 512 + x * spacing) * 2 + (row * 512 + y * spacing) * 3).littleEndian
                        withUnsafeBytes(of: &value) { raw.append(contentsOf: $0) }
                    } }
                    let file = "cell-\(column)-\(row)-\(spacing)m.bin"; try raw.write(to: sourceDirectory.appendingPathComponent(file))
                    levels.append(TerrainLOD(spacing: spacing, width: side, height: side, file: file, byteCount: Int64(raw.count), sha256: hash(raw)))
                }
            }
            cells.append(TerrainSourceCell(column: column, row: row, complete: !levels.isEmpty, levels: levels))
            let bounds = GeoBounds(minLatitude: latitude[row + 1], minLongitude: longitude[column], maxLatitude: latitude[row], maxLongitude: longitude[column + 1])
            var image = baseMap.image, preview = baseMap.preview
            for (key, base) in [("image", baseMap.image), ("preview", baseMap.preview)] {
                let file = "map-\(column)-\(row)-\(key).png"
                try fm.copyItem(at: originalDirectory.appendingPathComponent(base.file), to: sourceDirectory.appendingPathComponent(file))
                if key == "image" { image.file = file; image.bounds = bounds } else { preview.file = file; preview.bounds = bounds }
            }
            maps.append(CartographyTile(image: image, preview: preview))
        } }
        var overview = baseMap.image; overview.bounds = manifest.bounds; overview.file = "overview.png"
        try fm.copyItem(at: originalDirectory.appendingPathComponent(baseMap.image.file), to: sourceDirectory.appendingPathComponent(overview.file))
        manifest.cartography = CartographyAtlas(columns: 4, rows: 2, longitudeEdges: longitude, latitudeEdges: latitude, tiles: maps, sourceOnly: true)
        manifest.tiledTerrain = TiledTerrainSource(cells: cells, graphs: [], overview: overview)
        try PackStore.validate(manifest)
        let encoded = try JSONEncoder().encode(manifest); try encoded.write(to: sourceDirectory.appendingPathComponent("pack.json"))
        let catalogue: [String: Any] = ["schemaVersion": 1, "sources": [["id": manifest.id, "name": manifest.name, "byteCount": encoded.count, "sha256": hash(encoded)]]]
        try JSONSerialization.data(withJSONObject: catalogue).write(to: served.appendingPathComponent("catalog.json"))
        let server = Process(), pipe = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", "import http.server,os,time\nclass Handler(http.server.SimpleHTTPRequestHandler):\n def copyfile(self, source, output):\n  while True:\n   data=source.read(16384)\n   if not data: break\n   output.write(data); output.flush()\n   if self.path.endswith('-1m.bin'): time.sleep(0.05)\nos.chdir(\(String(reflecting: served.path)))\ns=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)\nprint(s.server_port,flush=True)\ns.serve_forever()"]
        server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let port = Int(String(data: pipe.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))!
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let cache = root.appendingPathComponent("cache"), saves = root.appendingPathComponent("saved")
        let store = PackStore(root: saves, bundledDirectory: nil, sourceDirectory: cache)
        let connected = try await store.connectSourceServer(url)
        try check(connected == 1, "Connect reads source catalogue")
        let entries = try await store.catalogue(), entry = entries[0]
        try check(entry.remoteSource != nil && entry.manifest.tiledTerrain != nil, "Normal catalogue contains the remote tiled source")
        try check(!fm.fileExists(atPath: entry.directory.appendingPathComponent(cells[0].levels[0].file).path), "Connecting downloads metadata and overview only")
        let broken = cache.appendingPathComponent("broken-source")
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{invalid".utf8).write(to: broken.appendingPathComponent("pack.json"))
        for _ in 0..<2 {
            let healthy = try await store.catalogue()
            let issues = await store.issues()
            try check(healthy.contains { $0.id == manifest.id }, "A malformed neighbour never hides valid sources, including cached reads")
            try check(issues.count == 1 && issues[0].contains("broken-source"), "Catalogue identifies the broken source on every read")
        }
        var badOrigin = manifest; badOrigin.id = "broken-source"
        try JSONEncoder().encode(badOrigin).write(to: broken.appendingPathComponent("pack.json"))
        try Data("not a URL".utf8).write(to: broken.appendingPathComponent("origin.json"))
        let originEntries = try await store.catalogue()
        try check(originEntries.contains { $0.id == manifest.id }, "An invalid origin is isolated just like an invalid manifest")
        let selection = AreaSelection(minU: 0, minV: 0, maxU: 0.5, maxV: 0.5)
        let preview = AreaCropper.preview(manifest: manifest, selection: selection, spacing: 4, context: BudgetFixtures.capable)
        try check(preview.tiledTerrain == nil && preview.cartography?.sourceOnly != true, "Selected scene is a normal bounded pack")
        try check(preview.levels.first(where: { $0.spacing == 4 })?.width == 257, "Two tiles produce exactly 256 intervals at 4m")
        let gap = manifest.bounds.point(u: 0.875, v: 0.75)
        try check(AtlasAreaPlanner.tile(at: gap, entries: entries) == nil, "A coverage gap cannot be tapped as downloadable terrain")
        let invalid = AreaCropper.preview(manifest: manifest, selection: AreaSelection(), spacing: 4)
        try check(invalid.levels.isEmpty, "A rectangle containing missing primary tiles is rejected before downloading")
        let plan = AreaCropper.sourceAssets(manifest: manifest, preview: preview, spacing: 4)
        try check(!plan.contains(where: { $0.file.hasSuffix("-1m.bin") }), "A 4m area never downloads native 1m files")
        let native = cells[0].levels[0], nativeURL = sourceDirectory.appendingPathComponent(cells[0].levels[0].file)
        let originalNative = try Data(contentsOf: nativeURL)
        var damaged = originalNative; damaged[damaged.count - 1] ^= 1
        try damaged.write(to: nativeURL)
        do {
            try await SourceDownloads.ensure([SourceAsset(file: native.file, byteCount: native.byteCount, sha256: native.sha256)], at: entry.directory, remote: entry.remoteSource!) { _ in }
            throw Failure(message: "Corrupt download was accepted")
        } catch is Failure { throw Failure(message: "Corrupt download was accepted") }
          catch { checks += 1 }
        try check(!fm.fileExists(atPath: entry.directory.appendingPathComponent(native.file).path), "Failed checksum does not publish a partial cached file")
        try originalNative.write(to: nativeURL)
        let meterDirectory = root.appendingPathComponent("meter-test")
        try fm.createDirectory(at: meterDirectory, withIntermediateDirectories: true)
        let transferLog = TransferLog()
        try await SourceDownloads.ensure([SourceAsset(file: native.file, byteCount: native.byteCount, sha256: native.sha256)],
                                         at: meterDirectory, remote: url.appendingPathComponent("fixture"),
                                         transfer: { bytes, total in await transferLog.record(bytes, total) }) { _ in }
        let sawPartialFile = await transferLog.partial
        try check(sawPartialFile, "Live byte progress arrives before a single large file completes")
        let cancelDirectory = root.appendingPathComponent("cancel-transfer-test")
        try fm.createDirectory(at: cancelDirectory, withIntermediateDirectories: true)
        let cancelLog = TransferLog()
        let transferTask = Task {
            try await SourceDownloads.ensure([SourceAsset(file: native.file, byteCount: native.byteCount, sha256: native.sha256)],
                                             at: cancelDirectory, remote: url.appendingPathComponent("fixture"),
                                             transfer: { bytes, total in await cancelLog.record(bytes, total) }) { _ in }
        }
        for _ in 0..<100 {
            if await cancelLog.partial { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let transferStarted = await cancelLog.partial
        transferTask.cancel()
        do {
            try await transferTask.value
            throw Failure(message: "Cancelled transfer completed successfully")
        } catch is CancellationError { checks += 1 }
          catch let error as URLError where error.code == .cancelled { checks += 1 }
        try check(transferStarted, "Cancellation exercises an active transfer after bytes arrive")
        try check(!fm.fileExists(atPath: cancelDirectory.appendingPathComponent(native.file).path), "Cancelled transfer never publishes a partial asset")
        let downloaded = try await store.downloadSelection(from: entry, selection: selection, spacing: 4) { _ in }
        let crop = try AreaCropper.prepare(directory: entry.directory, manifest: manifest, selection: selection, spacing: 4,
                                           cartographySourceID: manifest.id, downloadedPreview: downloaded)
        defer { try? fm.removeItem(at: crop.directory) }
        let installed = try await store.install(from: crop.directory, manifest: crop.manifest, spacing: 4) { _ in }
        let terrain = try await store.load(id: crop.manifest.id)
        try check(installed.heights == terrain.heights && installed.directory == terrain.directory, "Installation returns the activated terrain without another load")
        try check(installed.cartography?.imageURLs == terrain.cartography?.imageURLs, "Borrowed source map URLs survive activation unchanged")
        for y in stride(from: 0, to: terrain.level.height, by: 7) { for x in stride(from: 0, to: terrain.level.width, by: 13) {
            let expected = Float(x * 4 * 2 + y * 4 * 3) * 0.1
            try check(abs(terrain.heights[y * terrain.level.width + x] - expected) < 0.001, "Tile assembly retains exact samples across cell boundaries")
        } }
        let expandedSelection = AreaSelection(minU: 0, minV: 0, maxU: 0.75, maxV: 0.5)
        let expandedPreview = try await store.downloadSelection(from: entry, selection: expandedSelection, spacing: 4) { _ in }
        let expanded = try AreaCropper.prepare(directory: entry.directory, manifest: manifest, selection: expandedSelection, spacing: 4, cartographySourceID: manifest.id, downloadedPreview: expandedPreview)
        defer { try? fm.removeItem(at: expanded.directory) }
        try check(expanded.manifest.bounds != crop.manifest.bounds && expanded.manifest.levels[0].width == 385, "Expansion opens the newly selected tiles rather than repeating the original area")
        server.terminate(); server.waitUntilExit()
        _ = try await store.downloadSelection(from: entry, selection: selection, spacing: 4) { _ in }
        let reopened = try await store.load(id: crop.manifest.id)
        try check(reopened.heights == terrain.heights, "Saved area and cached selection work with the server stopped")
        let offlineStore = PackStore(root: saves, bundledDirectory: nil, sourceDirectory: cache)
        let cold = try await offlineStore.load(id: crop.manifest.id)
        try check(cold.heights == terrain.heights, "A fresh app instance opens the saved area offline")
        try fm.removeItem(at: broken)
        _ = try await store.catalogue()
        let repairedIssues = await store.issues()
        try check(repairedIssues.isEmpty, "Removing the broken neighbour clears cached warnings")
        do {
            _ = try await store.downloadSelection(from: entry, selection: selection, spacing: 1) { _ in }
            throw Failure(message: "Missing 1m files should require the server")
        } catch is Failure { throw Failure(message: "Missing 1m files were incorrectly treated as cached") }
          catch { checks += 1 }
        for bad in ["http://example.com", "http://user:password@localhost:8787", "file:///tmp/data"] {
            do { _ = try SourceDownloads.validBase(URL(string: bad)!); throw Failure(message: "Accepted invalid server address") }
            catch is Failure { throw Failure(message: "Accepted invalid server address") }
            catch { checks += 1 }
        }
        print("PASS tiled sources, selected downloads, expansion and offline reopening: \(checks) assertions")
    }
}
