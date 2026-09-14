import Foundation
import CryptoKit

private struct HorizonFailure: Error, CustomStringConvertible { var description: String }
@MainActor @main struct HorizonTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw HorizonFailure(description: message) }
    }
    static func rejects(_ message: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { assertions += 1; return }
        throw HorizonFailure(description: "Expected rejection: " + message)
    }
    static func contains(_ outer: GeoBounds, _ inner: GeoBounds) -> Bool {
        outer.contains(GeoPoint(latitude: inner.minLatitude, longitude: inner.minLongitude)) &&
        outer.contains(GeoPoint(latitude: inner.maxLatitude, longitude: inner.maxLongitude))
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw HorizonFailure(description: "Pass the data bundle") }
        let fm = FileManager.default
        let sourceDirectory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("regions/eryri-grid")
        var source = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: sourceDirectory.appendingPathComponent("pack.json")))
        source.cartography = nil // Exercise compatibility with existing band-map packs.
        try PackStore.validate(source)
        guard let sourceHorizon = source.horizon, let grid = source.grid else { throw HorizonFailure(description: "Real horizon source has not been packaged") }
        try check(sourceHorizon.near?.levels.map(\.spacing) == [8, 16], "Nearby source contains real 8m and 16m levels")
        try check(sourceHorizon.far?.levels.map(\.spacing) == [32], "Distant source contains 32m terrain")
        try check(sourceHorizon.near?.textures.count == 196 && sourceHorizon.far?.textures.count == 196, "Both bands carry the complete original-parent cartographic tile set")
        try check(sourceHorizon.near?.textures.allSatisfy { $0.width == 1024 && $0.height == 1024 } == true, "Nearby source cartography retains its prepared pixel density")
        try check(sourceHorizon.far?.textures.allSatisfy { $0.width == 512 && $0.height == 512 } == true, "Distant maps use bounded tiles of the same cartography")
        try check(sourceHorizon.near?.textures.map(\.bounds) == sourceHorizon.far?.textures.map(\.bounds), "Near and distant map tiles share identical geographic alignment")
        for layer in sourceHorizon.layers {
            try check(contains(layer.bounds, source.bounds), "Horizon source surrounds the complete primary collection")
            try check(layer.bounds.widthMeters > 25_000 && layer.bounds.depthMeters > 25_000, "Broad source covers a real landscape horizon")
        }
        let selection = grid.selection(column: 7, row: 8)!
        let alternatives = AreaCropper.preview(manifest: source, selection: selection, context: BudgetFixtures.capable)
        let preview = AreaCropper.preview(manifest: source, selection: selection, spacing: 1, context: BudgetFixtures.capable)
        guard let expected = preview.horizon, let near = expected.near, let far = expected.far else { throw HorizonFailure(description: "A capable device must keep both horizon bands for one precision cell") }
        try check(near.levels.count == 1 && near.levels[0].spacing == 8, "Near band selects 8m on a capable device")
        try check(far.levels.count == 1 && far.levels[0].spacing == 32, "Far band selects 32m")
        try check(contains(near.bounds, preview.bounds) && contains(far.bounds, near.bounds), "Bands surround the primary and each other")
        try check(near.bounds.widthMeters < 5_500 && near.bounds.widthMeters > 4_000, "Nearby crop has about 2km on each side")
        try check(far.bounds == sourceHorizon.far?.bounds, "15km margin uses the full available Eryri horizon for a central cell")
        try check(near.textures.allSatisfy { $0.width <= 2048 && $0.height <= 2048 }, "Nearby cartography stays bounded")
        try check(far.textures.allSatisfy { $0.width <= 1024 && $0.height <= 1024 }, "Distant cartography stays bounded")
        try check(near.textures.count > 1 && far.textures.count > near.textures.count, "Preparation selects multiple native map tiles instead of one enlarged overview")
        let coarserPrimary = AreaCropper.preview(manifest: source, selection: selection, spacing: 8, context: BudgetFixtures.capable)
        try check(coarserPrimary.textures == preview.textures, "Changing primary LiDAR detail does not change its cartography")
        try check(coarserPrimary.horizon?.near?.textures == near.textures && coarserPrimary.horizon?.far?.textures == far.textures, "Changing primary LiDAR detail does not change surrounding cartography")
        var withoutHorizon = preview; withoutHorizon.horizon = nil
        let combined = TerrainBudget.allowance(for: preview, spacing: 1, context: BudgetFixtures.capable)
        let primary = TerrainBudget.allowance(for: withoutHorizon, spacing: 1, context: BudgetFixtures.capable)
        try check(combined.allowed && combined.estimatedMemory > primary.estimatedMemory, "One combined budget includes surrounding terrain and maps")
        try check(combined.bytesOnDisk > primary.bytesOnDisk, "Save estimate includes horizon assets")
        try check(TerrainBudget.recommendedSpacing(for: alternatives, context: BudgetFixtures.capable) == 1, "Auto retains genuine 1m when the complete scene fits")
        let whole = AreaCropper.preview(manifest: source, selection: AreaSelection(), spacing: 8, context: BudgetFixtures.capable)
        try check(whole.id == source.id && whole.name == source.name && whole.bounds == source.bounds, "Whole-source preparation keeps its catalogue identity")
        try check(whole.horizon != nil, "Whole-source preview also contains surrounding terrain")
        let edge = AreaCropper.preview(manifest: source, selection: grid.selection(column: 0, row: 0)!, spacing: 8, context: BudgetFixtures.capable)
        for layer in edge.horizon?.layers ?? [] {
            try check(sourceHorizon.layers.contains { contains($0.bounds, layer.bounds) }, "Edge selections clip to available source coverage")
        }
        print("PASS broad coverage, two-band previews, identity and combined budget")

        let crop = try AreaCropper.prepare(directory: sourceDirectory, manifest: source, selection: selection, spacing: 1)
        defer { try? fm.removeItem(at: crop.directory) }
        try PackStore.validate(crop.manifest)
        try check(crop.manifest.bounds == preview.bounds && crop.manifest.grid == preview.grid, "Horizon does not expand the planning area")
        try check(crop.manifest.levels[0].width == 513 && crop.manifest.levels[0].height == 513, "Selected native primary grid remains untouched")
        guard let prepared = crop.manifest.horizon else { throw HorizonFailure(description: "Prepared crop omitted its horizon") }
        for layer in prepared.layers {
            for texture in layer.textures {
                let data = try Data(contentsOf: crop.directory.appendingPathComponent(texture.file))
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try check(digest == texture.sha256 && Int64(data.count) == texture.byteCount, "Every saved cartographic tile has an exact complete payload hash and size")
            }
            for level in layer.levels {
                let data = try Data(contentsOf: crop.directory.appendingPathComponent(level.file))
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try check(data.count == level.width * level.height * 2 && Int64(data.count) == level.byteCount, "Horizon height file dimensions and byte count are exact")
                try check(digest == level.sha256, "Horizon height checksum matches its complete file")
                guard let original = sourceHorizon.layers.first(where: { $0.levels.contains { $0.spacing == level.spacing } }),
                      let originalLevel = original.levels.first(where: { $0.spacing == level.spacing }) else { throw HorizonFailure(description: "Prepared context invented an unsupported level") }
                let originalData = try Data(contentsOf: sourceDirectory.appendingPathComponent(originalLevel.file))
                let uv = original.bounds.uv(GeoPoint(latitude: layer.bounds.maxLatitude, longitude: layer.bounds.minLongitude))
                let left = Int((uv.u * Double(originalLevel.width - 1)).rounded())
                let top = Int((uv.v * Double(originalLevel.height - 1)).rounded())
                for y in stride(from: 0, to: level.height, by: max(1, level.height / 19)) {
                    let a = y * level.width * 2
                    let b = ((top + y) * originalLevel.width + left) * 2
                    try check(data[a..<(a + level.width * 2)] == originalData[b..<(b + level.width * 2)], "Saved context preserves exact prepared height rows, including NoData")
                }
            }
        }
        let installRoot = fm.temporaryDirectory.appendingPathComponent("ridge-horizon-tests-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: installRoot) }
        let packs = PackStore(root: installRoot)
        try await packs.install(from: crop.directory, manifest: crop.manifest, spacing: 1) { _ in }
        let loaded = try await packs.load(id: crop.manifest.id)
        try check(loaded.horizon?.layers.count == prepared.layers.count, "Install and load retain both saved bands")
        for layer in loaded.horizon?.layers ?? [] {
            try check(layer.heights.count == layer.level.width * layer.level.height && layer.heights.contains(where: \.isFinite), "Loaded context has valid heights and bounded dimensions")
            try check(layer.textureURLs.count == layer.metadata.textures.count, "Offline loading retains every selected surrounding map tile")
        }
        let outside = far.bounds.point(u: 0.1, v: 0.1)
        try check(!loaded.manifest.bounds.contains(outside) && loaded.elevation(at: outside) == nil, "Horizon remains visual context, not implicit planning coverage")
        print("PASS exact context samples, complete file hashes, offline install and planning bounds")

        var unsafe = crop.manifest
        if unsafe.horizon?.near != nil { unsafe.horizon?.near?.levels[0].file = "../escape.bin" }
        try await rejects("unsafe context path") { try PackStore.validate(unsafe) }
        var huge = crop.manifest
        if huge.horizon?.far != nil { huge.horizon?.far?.levels[0].width = Int.max }
        try await rejects("malformed context dimensions") { try PackStore.validate(huge) }
        var missingMap = crop.manifest
        missingMap.horizon?.far?.textures.removeLast()
        try await rejects("a missing tile cannot leave a hole in surrounding cartography") { try PackStore.validate(missingMap) }
        var overlappingMap = crop.manifest
        if let firstMap = overlappingMap.horizon?.near?.textures.first { overlappingMap.horizon?.near?.textures.append(firstMap) }
        try await rejects("overlapping context map tiles") { try PackStore.validate(overlappingMap) }
        let originalManifest = try Data(contentsOf: installRoot.appendingPathComponent(crop.manifest.id).appendingPathComponent("pack.json"))
        let first = prepared.layers[0].levels[0]
        let corruptURL = crop.directory.appendingPathComponent(first.file)
        var bytes = try Data(contentsOf: corruptURL); bytes[0] ^= 0xff; try bytes.write(to: corruptURL)
        try await rejects("corrupt context payload") { try await packs.install(from: crop.directory, manifest: crop.manifest, spacing: 1) { _ in } }
        let retainedManifest = try Data(contentsOf: installRoot.appendingPathComponent(crop.manifest.id).appendingPathComponent("pack.json"))
        try check(retainedManifest == originalManifest, "Failed horizon replacement preserves the previous working area")
        _ = try await packs.load(id: crop.manifest.id)
        print("PASS unsafe and corrupt context cannot replace a working saved scene")
        print("PASS horizon: \(assertions) assertions")
    }
}
