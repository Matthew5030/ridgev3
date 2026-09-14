import Foundation
import CryptoKit

private struct CartographyRealFailure: Error, CustomStringConvertible { var description: String }

@MainActor @main struct CartographyRealTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw CartographyRealFailure(description: message) }
    }
    static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw CartographyRealFailure(description: message) }
        return value
    }
    static func verifyHeightWindow(saved: TerrainLOD, bounds: GeoBounds, directory: URL,
                                   original: TerrainLOD, originalBounds: GeoBounds, sourceDirectory: URL) throws {
        let result = try Data(contentsOf: directory.appendingPathComponent(saved.file), options: .mappedIfSafe)
        let source = try Data(contentsOf: sourceDirectory.appendingPathComponent(original.file), options: .mappedIfSafe)
        let corner = originalBounds.uv(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
        let left = Int((corner.u * Double(original.width - 1)).rounded())
        let top = Int((corner.v * Double(original.height - 1)).rounded())
        try check(result.count == saved.width * saved.height * 2, "Exact saved height dimensions")
        try check(SHA256.hash(data: result).map { String(format: "%02x", $0) }.joined() == saved.sha256, "Exact saved height checksum")
        for row in 0..<saved.height {
            let destinationOffset = row * saved.width * 2
            let sourceOffset = ((top + row) * original.width + left) * 2
            try check(result[destinationOffset..<(destinationOffset + saved.width * 2)] == source[sourceOffset..<(sourceOffset + saved.width * 2)], "Every saved height row preserves the existing source samples and NoData")
        }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CartographyRealFailure(description: "Pass RidgeData.bundle") }
        let fm = FileManager.default
        let sourceDirectory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("regions/eryri-grid")
        let source = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: sourceDirectory.appendingPathComponent("pack.json")))
        try PackStore.validate(source)
        let grid = try require(source.grid, "Source grid missing")
        let canonical = try require(source.cartography, "Independent canonical atlas missing")
        let sourceTiles = Dictionary(uniqueKeysWithValues: canonical.tiles.map { ($0.image.file, $0) })
        let single = try require(grid.selection(column: 7, row: 8), "Original one-cell selection missing")
        let four = try require(grid.rectangle(from: TerrainCell(column: 4, row: 6), to: TerrainCell(column: 7, row: 9)), "4x4 selection missing")
        let eight = try require(grid.rectangle(from: TerrainCell(column: 2, row: 6), to: TerrainCell(column: 9, row: 10)), "8x5 selection missing")
        let spacings = [1, 2, 4, 8, 16, 32]
        let oneBounds = AreaCropper.preview(manifest: source, selection: single, context: BudgetFixtures.capable).bounds
        var previewResults: [[String: Any]] = []
        for (name, selection) in [("4x4", four), ("8x5", eight)] {
            let raw = AreaCropper.preview(manifest: source, selection: selection, context: BudgetFixtures.capable)
            let rawAtlas = try require(raw.cartography, "Raw preview lost its atlas")
            let rawOverlap = try require(rawAtlas.cropped(to: oneBounds), "Raw preview lost the shared original cell")
            try check(raw.levels.map(\.spacing) == spacings, "Raw preview keeps all requested terrain levels")
            try check(raw.textures.isEmpty && raw.horizon?.layers.allSatisfy({ $0.textures.isEmpty }) == true, "Raw preview carries one independent map, without band-map replacements")
            for spacing in spacings {
                let resolved = AreaCropper.preview(manifest: source, selection: selection, spacing: spacing, context: BudgetFixtures.capable)
                let atlas = try require(resolved.cartography, "A terrain resolution removed the independent map")
                let overlap = try require(atlas.cropped(to: oneBounds), "A terrain resolution removed shared map coverage")
                try check(overlap == rawOverlap, "Shared native and preview bytes/bounds remain identical across all terrain levels and selection widths")
                try check(atlas.tiles.allSatisfy { $0.image.width == 1032 && $0.image.height == 1032 && $0.preview.width == 72 && $0.preview.height == 72 }, "Every retained map cell keeps 1024 native and 64 preview inner pixels at every LiDAR level")
                try check(atlas.tiles.allSatisfy { sourceTiles[$0.image.file] == $0 }, "No preview resamples, rerenders or swaps canonical image files")
                try check(resolved.textures.isEmpty && (resolved.horizon?.layers ?? []).allSatisfy({ $0.textures.isEmpty }), "LiDAR changes do not restore any legacy map layer")
            }
            previewResults.append(["selection": name, "testedSpacings": spacings, "rawAtlasTiles": rawAtlas.tiles.count,
                                   "sharedNativePixelsPerCell": 1024, "sharedPreviewPixelsPerCell": 64])
        }
        print("PASS 4x4 and 8x5 canonical map invariance across 1/2/4/8/16/32 m")

        let preparationStart = Date()
        let crop = try AreaCropper.prepare(directory: sourceDirectory, manifest: source, selection: single, spacing: 1)
        let preparationSeconds = Date().timeIntervalSince(preparationStart)
        defer { try? fm.removeItem(at: crop.directory) }
        try PackStore.validate(crop.manifest)
        let atlas = try require(crop.manifest.cartography, "Prepared selection omitted the independent atlas")
        try check(crop.manifest.horizon?.near?.levels.first?.spacing == 8 && crop.manifest.horizon?.far?.levels.first?.spacing == 32, "One 1 m cell admits both complete nearby 8 m and far 32 m terrain bands")
        try check(crop.manifest.levels.count == 1 && crop.manifest.levels[0].width == 513 && crop.manifest.levels[0].height == 513, "Primary selection retains its original 513x513 1 m heightfield")
        try check(crop.manifest.bounds == oneBounds, "Surroundings and atlas do not expand planning bounds")
        try check(crop.manifest.textures.isEmpty && crop.manifest.detailTextures == nil && (crop.manifest.horizon?.layers ?? []).allSatisfy({ $0.textures.isEmpty }), "Prepared scene uses no primary or horizon legacy texture assets")
        try check(atlas.tiles.allSatisfy { sourceTiles[$0.image.file] == $0 }, "Prepared atlas retains canonical whole-cell files")
        let level = crop.manifest.levels[0]
        let original = try require(source.levels.first { $0.spacing == 1 }, "Native 1 m source missing")
        try verifyHeightWindow(saved: level, bounds: crop.manifest.bounds, directory: crop.directory, original: original, originalBounds: source.bounds, sourceDirectory: sourceDirectory)
        for layer in crop.manifest.horizon?.layers ?? [] {
            let saved = try require(layer.levels.first, "Saved context level missing")
            let originalLayer = try require(source.horizon?.layers.first { $0.levels.contains { $0.spacing == saved.spacing } }, "Original context level missing")
            let originalLevel = try require(originalLayer.levels.first { $0.spacing == saved.spacing }, "Original context spacing missing")
            try verifyHeightWindow(saved: saved, bounds: layer.bounds, directory: crop.directory, original: originalLevel, originalBounds: originalLayer.bounds, sourceDirectory: sourceDirectory)
        }
        let allowance = TerrainBudget.allowance(for: crop.manifest, spacing: 1)
        try check(allowance.allowed, "Complete prepared scene fits the current native host budget")
        print("PASS exact primary and horizon height windows; prepared canonical atlas")

        let installRoot = fm.temporaryDirectory.appendingPathComponent("ridge-atlas-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: installRoot) }
        let packs = PackStore(root: installRoot, bundledDirectory: nil)
        let installationStart = Date()
        try await packs.install(from: crop.directory, manifest: crop.manifest, spacing: 1) { _ in }
        let installationSeconds = Date().timeIntervalSince(installationStart)
        let loadStart = Date()
        let loaded = try await packs.load(id: crop.manifest.id)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        let loadedAtlas = try require(loaded.cartography, "Offline install/load lost the independent map")
        try check(loadedAtlas.metadata == atlas, "Offline install/load retains complete canonical atlas metadata")
        try check(loaded.horizon?.layers.count == 2, "Offline install/load keeps both admitted horizon bands")
        try check(loaded.textureURLs.isEmpty && (loaded.horizon?.layers ?? []).allSatisfy({ $0.textureURLs.isEmpty }), "Loading creates no legacy band-map URLs")
        try check(loadedAtlas.imageURLs.count == atlas.tiles.count && loadedAtlas.previewURLs.count == atlas.tiles.count, "All local image and preview URLs survive the install")
        for (index, tile) in loadedAtlas.metadata.tiles.enumerated() {
            try check(sourceTiles[tile.image.file] == tile, "Installed canonical tile identity is unchanged")
            for (url, texture) in [(loadedAtlas.imageURLs[index], tile.image), (loadedAtlas.previewURLs[index], tile.preview)] {
                try autoreleasepool {
                    let saved = try Data(contentsOf: url, options: .mappedIfSafe)
                    let canonical = try Data(contentsOf: sourceDirectory.appendingPathComponent(texture.file), options: .mappedIfSafe)
                    try check(saved == canonical, "Every installed native and preview payload is byte-identical to the canonical atlas")
                    try check(Int64(saved.count) == texture.byteCount, "Every installed image keeps its exact recorded size")
                }
            }
        }
        let files = try fm.contentsOfDirectory(at: loaded.directory, includingPropertiesForKeys: [.fileSizeKey])
        try check(files.filter { $0.pathExtension == "png" }.allSatisfy { $0.lastPathComponent.hasPrefix("cartography-") }, "No legacy texture PNG was installed")
        let savedBytes = try files.reduce(Int64(0)) { sum, file in sum + Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        let report: [String: Any] = ["assertions": assertions, "selection": ["column": 7, "row": 8, "terrainSpacing": 1],
                                   "atlasTiles": atlas.tiles.count, "horizonLevels": loaded.horizon?.layers.map { $0.level.spacing } ?? [],
                                   "savedBytesIncludingManifest": savedBytes, "estimatedPayloadBytes": allowance.bytesOnDisk,
                                   "estimatedSceneMemoryBytes": allowance.estimatedMemory, "estimatedAtlasMemoryBytes": atlas.estimatedMemoryBytes,
                                   "prepareSeconds": preparationSeconds, "installSeconds": installationSeconds, "loadSeconds": loadSeconds,
                                   "nativeVerificationHost": "macOS command-line Swift using the current core implementations",
                                   "previewChecks": previewResults]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        print("PASS real canonical atlas: \(assertions) assertions; owned temporary crops and install data are removed on return")
    }
}
