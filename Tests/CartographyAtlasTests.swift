import Foundation

private struct AtlasFailure: Error, CustomStringConvertible { let description: String }

@MainActor @main struct CartographyAtlasTests {
    private static var assertions = 0
    private static let hash = String(repeating: "a", count: 64)
    private static let context = TerrainBudget.Context(physicalMemory: 8 * 1_024 * 1_048_576, gpuTier: .modern)

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw AtlasFailure(description: message) }
    }

    private static func fixture(columns: Int = 4, rows: Int = 4) -> CartographyAtlas {
        // Deliberately nonuniform north/south spacing exercises original grid
        // edges across world-tile boundaries without reconstructing them.
        let longitude = (0...columns).map { -4.0 + Double($0) * 0.001 }
        let latitude: [Double] = (0...rows).map { index in
            let linear = Double(index) * 0.001
            let curved = Double(index * index) * 0.000001
            return 54.0 - linear - curved
        }
        var tiles: [CartographyTile] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let bounds = GeoBounds(minLatitude: latitude[row + 1], minLongitude: longitude[column],
                                       maxLatitude: latitude[row], maxLongitude: longitude[column + 1])
                let image = MapTexture(file: "cartography-c\(column)-r\(row).png", width: 1032, height: 1032,
                                       byteCount: 140_000 + Int64(row * columns + column), sha256: hash, bounds: bounds)
                let preview = MapTexture(file: "cartography-c\(column)-r\(row)-preview.png", width: 72, height: 72,
                                         byteCount: 6_000 + Int64(row * columns + column), sha256: hash, bounds: bounds)
                tiles.append(CartographyTile(image: image, preview: preview))
            }
        }
        return CartographyAtlas(columns: columns, rows: rows, longitudeEdges: longitude, latitudeEdges: latitude, tiles: tiles)
    }

    private static func level(_ spacing: Int, width: Int = 65) -> TerrainLOD {
        TerrainLOD(spacing: spacing, width: width, height: width, file: "height-\(spacing).bin",
                   byteCount: Int64(width * width * 2), sha256: hash)
    }

    private static func manifest(_ atlas: CartographyAtlas) -> RegionManifest {
        RegionManifest(schemaVersion: 1, id: "atlas-test", name: "Shared cartography", subtitle: "Offline",
                       bounds: atlas.bounds, sourceResolution: 1, heightScale: 0.1, noDataValue: -32768,
                       levels: [1, 2, 4, 8, 16, 32].map { level($0, width: 512 / $0 + 1) }, textures: [],
                       graphFile: nil, graphSHA256: nil, graphByteCount: nil, places: [], sources: [], defaultSpacing: 8,
                       version: "1", summary: "Test", verticalDatum: nil, cartography: atlas)
    }

    private static func reject(_ atlas: CartographyAtlas, _ message: String) throws {
        var rejected = false
        do { try atlas.validate() } catch { rejected = true }
        try check(rejected, message)
        try check(atlas.cropped(to: fixture().bounds) == nil, "Malformed atlas cannot be cropped: " + message)
    }

    private static func rejectAllocation(_ atlas: CartographyAtlas, _ message: String) throws {
        try reject(atlas, message)
        try check(atlas.footprint(covering: fixture().bounds) == nil, "Allocation footprint rejects " + message)
        var area = manifest(fixture()); area.cartography = atlas
        try check(!TerrainBudget.allowance(for: area, spacing: 32, context: context).allowed,
                  "Budget fails safely before allocation: " + message)
    }

    static func main() throws {
        let source = fixture()
        try source.validate(covering: source.bounds)
        try check(source.allTextures.count == 32, "Both native and preview files are enumerated once")
        try check(source.totalBytes == source.tiles.reduce(0) { $0 + $1.image.byteCount + $1.preview.byteCount }, "Atlas disk bytes include both representations exactly once")
        try check(source.cropped(to: source.bounds) == source, "Whole atlas cropping preserves all metadata exactly")
        let centerBounds = GeoBounds(minLatitude: source.latitudeEdges[3], minLongitude: source.longitudeEdges[1],
                                     maxLatitude: source.latitudeEdges[1], maxLongitude: source.longitudeEdges[3])
        guard let center = source.cropped(to: centerBounds) else { throw AtlasFailure(description: "Missing centre crop") }
        try check(center.columns == 2 && center.rows == 2 && center.bounds == centerBounds, "Exact edges produce the minimal rectangle without adjacent extras")
        try check(center.tiles == [source.tiles[5], source.tiles[6], source.tiles[9], source.tiles[10]], "Cropped cells retain original row-major image and preview metadata")
        try center.validate(covering: centerBounds)
        let inset = GeoBounds(minLatitude: centerBounds.minLatitude + 0.0001, minLongitude: centerBounds.minLongitude + 0.0001,
                              maxLatitude: centerBounds.maxLatitude - 0.0001, maxLongitude: centerBounds.maxLongitude - 0.0001)
        try check(source.cropped(to: inset) == center, "Interior bounds select unchanged whole cells")
        for tile in source.tiles {
            let crop = source.cropped(to: tile.image.bounds)
            try check(crop?.columns == 1 && crop?.rows == 1 && crop?.tiles == [tile], "Every exact single-cell crop keeps its original native pixels")
        }
        var outside = source.bounds; outside.minLongitude -= 0.000001
        try check(source.cropped(to: outside) == nil, "Partial source coverage does not invent missing tiles")
        var invalidBounds = source.bounds; invalidBounds.maxLatitude = .nan
        try check(source.cropped(to: invalidBounds) == nil, "Invalid crop coordinates fail closed")
        try check(source.footprint(covering: outside) == nil && source.footprint(covering: invalidBounds) == nil,
                  "Allocation-only coverage checks never invent missing cells")

        for top in 0..<source.rows {
            for bottom in (top + 1)...source.rows {
                for left in 0..<source.columns {
                    for right in (left + 1)...source.columns {
                        let requested = GeoBounds(minLatitude: source.latitudeEdges[bottom], minLongitude: source.longitudeEdges[left],
                                                  maxLatitude: source.latitudeEdges[top], maxLongitude: source.longitudeEdges[right])
                        let crop = source.cropped(to: requested)!, footprint = source.footprint(covering: requested)!
                        try check(footprint.tileCount == crop.tiles.count && footprint.bytesOnDisk == crop.totalBytes,
                                  "Allocation-only rectangle matches the validated whole-image crop")
                        try check(footprint.estimatedMemoryBytes == crop.estimatedMemoryBytes,
                                  "Allocation-only estimate retains exact native/medium/preview residency counts")
                    }
                }
            }
        }

        let small = source.cropped(to: source.tiles[5].image.bounds)!
        let extended = source.cropped(to: centerBounds)!
        try check(extended.tiles.contains(small.tiles[0]), "Extending an area reuses the existing native and preview images")
        try check(extended.tiles.allSatisfy { $0.image.width == 1032 && $0.preview.width == 72 }, "Area extension preserves the common image density")
        print("PASS exact geographic cells, nonuniform edges, whole-image cropping and extension density")

        var area = manifest(source)
        var withoutMaps = area; withoutMaps.cartography = nil
        let mapMemory = source.conservativeMemoryBytes
        for spacing in [1, 2, 4, 8, 16, 32] {
            let shared = TerrainBudget.allowance(for: area, spacing: spacing, context: context)
            let bare = TerrainBudget.allowance(for: withoutMaps, spacing: spacing, context: context)
            try check(shared.allowed && bare.allowed, "Supported terrain spacings fit the controlled context")
            try check(shared.estimatedMemory - bare.estimatedMemory == mapMemory, "Map memory is independent of LiDAR spacing \(spacing)")
            try check(shared.bytesOnDisk - bare.bytesOnDisk == source.totalBytes, "Map disk bytes are independent of LiDAR spacing \(spacing)")
            try check(area.cartography == source, "Budgeting never changes native cartography")
        }
        let legacy = MapTexture(file: "old-map.png", width: 4096, height: 4096, byteCount: 9_000_000, sha256: hash, bounds: source.bounds)
        let originalAllowance = TerrainBudget.allowance(for: area, spacing: 8, context: context)
        area.textures = [legacy]; area.detailTextures = [legacy]
        let withLegacy = TerrainBudget.allowance(for: area, spacing: 8, context: context)
        try check(withLegacy.estimatedMemory == originalAllowance.estimatedMemory && withLegacy.bytesOnDisk == originalAllowance.bytesOnDisk,
                  "Legacy overview/detail files are not counted beside a shared atlas")
        try check(area.totalBytes == withoutMaps.levels.reduce(0) { $0 + $1.byteCount } + source.totalBytes, "Manifest file totals ignore unused legacy maps")

        area.bounds = small.bounds
        let nearBounds = GeoBounds(minLatitude: source.latitudeEdges[3], minLongitude: source.longitudeEdges[0],
                                   maxLatitude: source.latitudeEdges[0], maxLongitude: source.longitudeEdges[3])
        area.horizon = TerrainHorizon(near: TerrainBackdrop(bounds: nearBounds, levels: [level(8)], textures: [legacy]),
                                     far: TerrainBackdrop(bounds: source.bounds, levels: [level(32)], textures: [legacy]))
        var unmapped = area; unmapped.cartography = nil; unmapped.textures = []; unmapped.detailTextures = nil
        unmapped.horizon?.near?.textures = []; unmapped.horizon?.far?.textures = []
        let horizonShared = TerrainBudget.allowance(for: area, spacing: 8, context: context)
        let horizonBare = TerrainBudget.allowance(for: unmapped, spacing: 8, context: context)
        try check(horizonShared.allowed && horizonBare.allowed, "Primary and both context layers fit the test scene")
        try check(horizonShared.estimatedMemory - horizonBare.estimatedMemory == mapMemory,
                  "Near and far terrain share one map cache without multiplying resident map costs")
        try check(horizonShared.bytesOnDisk - horizonBare.bytesOnDisk == source.totalBytes,
                  "Shared map files are installed once across all terrain bands")
        var primaryOnly = area; primaryOnly.horizon = nil
        let primaryCost = TerrainBudget.allowance(for: primaryOnly, spacing: 8, context: context)
        var primaryBare = primaryOnly; primaryBare.cartography = nil; primaryBare.textures = []
        try check(primaryCost.bytesOnDisk - TerrainBudget.allowance(for: primaryBare, spacing: 8, context: context).bytesOnDisk == small.totalBytes,
                  "Primary-only budget crops cartography to the actual saved coverage")
        print("PASS map memory/disk invariance across all six LiDAR spacings and shared terrain bands")

        let largest = fixture(columns: 64, rows: 64)
        try largest.validate()
        try check(largest.tiles.count == CartographyAtlas.maximumTiles, "The full 4096-tile atlas is supported")
        try check(largest.conservativeMemoryBytes < CartographyAtlas.maximumMemoryBytes, "Continuous previews, 16 native slots, 192 medium slots and staging fit the conservative fallback")
        try check(small.conservativeMemoryBytes < source.conservativeMemoryBytes && source.conservativeMemoryBytes < largest.conservativeMemoryBytes,
                  "Small areas reserve only their actual preview and native slot counts")
        let expectedPreview = [72, 36, 18, 9, 4, 2, 1].reduce(Int64(0)) { $0 + Int64($1 * $1 * 4) }
        try check(CartographyAtlas.mipmappedRGBABytes(size: 72) == expectedPreview, "Non-power-of-two mip allocation is counted exactly")
        try check(CartographyAtlas.mipmappedRGBABytes(size: Int.max) == .max, "Unsupported dimensions cannot overflow mip accounting")
        try check(CartographyAtlas.mediumSize == 264 && CartographyAtlas.mediumGutter == 4,
                  "Medium pages retain four pixels of neighboring map coverage for minification")
        try check(CartographyAtlas.maximumResidentMediumImages == 192 && CartographyAtlas.maximumAxisTiles == 64,
                  "The supported layout bounds both the preview mosaic axes and medium residency")
        try check(largest.conservativeMemoryBytes == 393_674_752,
                  "The deterministic fallback reserves driver-padded array slots and a complete preview mosaic")
        var lowMemory = context; lowMemory.availableMemory = 64 * 1_048_576
        try check(!TerrainBudget.allowance(for: manifest(small), spacing: 32, context: lowMemory).allowed, "The bounded map cache still obeys live process memory")
        try check(TerrainBudget.recommendedSpacing(for: manifest(small), context: lowMemory) == nil, "No coarser terrain is promised when fixed map resources cannot fit")
        print(String(format: "PASS fallback atlas budget: one tile %.2f MiB; 4096 tiles %.2f MiB", Double(small.conservativeMemoryBytes) / 1_048_576, Double(largest.conservativeMemoryBytes) / 1_048_576))

        for value in [Int.min, -1, 0, 65, Int.max, 4097] {
            var bad = source; bad.columns = value; try rejectAllocation(bad, "Unsafe column count \(value)")
            bad = source; bad.rows = value; try rejectAllocation(bad, "Unsafe row count \(value)")
        }
        var bad = source; bad.tiles.removeLast(); try rejectAllocation(bad, "Missing tile")
        bad = source; bad.tiles.swapAt(0, 1); try rejectAllocation(bad, "Wrong row-major tile order")
        bad = source; bad.longitudeEdges.removeLast(); try rejectAllocation(bad, "Missing longitude edge")
        bad = source; bad.latitudeEdges.append(0); try rejectAllocation(bad, "Extra latitude edge")
        for value in [Double.nan, .infinity, -181, 181] {
            bad = source; bad.longitudeEdges[1] = value; try rejectAllocation(bad, "Invalid longitude edge")
        }
        for value in [Double.nan, -Double.infinity, -91, 91] {
            bad = source; bad.latitudeEdges[1] = value; try rejectAllocation(bad, "Invalid latitude edge")
        }
        bad = source; bad.longitudeEdges[1] = bad.longitudeEdges[0]; try rejectAllocation(bad, "Zero-width cell")
        bad = source; bad.latitudeEdges.swapAt(1, 2); try rejectAllocation(bad, "Reversed latitude edge")
        bad = source; bad.tiles[0].image.bounds.maxLongitude += 0.000000000001; try rejectAllocation(bad, "Image bounds must exactly match their inner cell")
        bad = source; bad.tiles[0].preview.bounds = bad.tiles[1].preview.bounds; try rejectAllocation(bad, "Preview must describe the same cell")
        for size in [0, 1024, 1031, 1033, Int.max] {
            bad = source; bad.tiles[0].image.width = size; try rejectAllocation(bad, "Native dimensions include exactly four gutter pixels")
        }
        bad = source; bad.tiles[0].preview.height = 64; try rejectAllocation(bad, "Preview dimensions include their gutters")
        for name in ["", ".", "..", "../outside.png", "/tmp/map.png", "maps/tile.png", "a\\b.png", "map%2Fbad.png", "map😀.png", "pack.json", "PACK.JSON", String(repeating: "a", count: 151)] {
            bad = source; bad.tiles[0].image.file = name; try reject(bad, "Unsafe asset filename")
        }
        bad = source; bad.tiles[0].preview.file = bad.tiles[0].image.file; try reject(bad, "Image and preview filenames must differ")
        bad = source; bad.tiles[1].image.file = bad.tiles[0].image.file; try reject(bad, "All atlas filenames are unique")
        bad = source; bad.tiles[1].image.file = bad.tiles[0].image.file.uppercased(); try reject(bad, "Asset names are unique on case-insensitive filesystems")
        for invalid in ["", String(repeating: "a", count: 63), String(repeating: "z", count: 64), String(repeating: "Ｆ", count: 64)] {
            bad = source; bad.tiles[0].image.sha256 = invalid; try reject(bad, "Hash must be 64 ASCII hexadecimal digits")
        }
        for size: Int64 in [Int64.min, -1, 0, CartographyAtlas.maximumImageFileBytes + 1, Int64.max] {
            bad = source; bad.tiles[0].image.byteCount = size; try rejectAllocation(bad, "Encoded native bytes fit the single-job staging reserve")
        }
        bad = source; bad.tiles[0].preview.byteCount = CartographyAtlas.maximumPreviewFileBytes + 1; try rejectAllocation(bad, "Encoded preview bytes are bounded")
        bad = source; bad.tiles[0].image.file = "../unreadable.png"; bad.tiles[0].image.sha256 = "bad"
        try check(bad.footprint(covering: source.bounds)?.bytesOnDisk == source.totalBytes,
                  "Allocation estimates never authorize or read file paths")
        try reject(bad, "Full validation still rejects unsafe filenames and hashes before crop or asset access")
        bad = source; bad.tiles[0].image.byteCount = .max; bad.tiles[0].preview.byteCount = .max
        try check(bad.totalBytes == .max, "Invalid huge byte counts saturate instead of overflowing display totals")
        var overflowingManifest = manifest(bad); overflowingManifest.graphByteCount = .max
        try check(overflowingManifest.totalBytes == .max, "Manifest totals also saturate malformed combined sizes")
        try check(!TerrainBudget.allowance(for: overflowingManifest, spacing: 8, context: context).allowed, "Budget rejects malformed atlas metadata before allocation")
        print("PASS malformed grid, file, hash, coverage, gutter and overflow rejection")

        let encoded = try JSONEncoder().encode(manifest(source))
        let decoded = try JSONDecoder().decode(RegionManifest.self, from: encoded)
        try check(decoded.cartography == source, "Shared atlas metadata round-trips through pack JSON")
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyObject.removeValue(forKey: "cartography")
        let legacyManifest = try JSONDecoder().decode(RegionManifest.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        try check(legacyManifest.cartography == nil, "Legacy manifests remain compatible without cartography")
        print("PASS cartography atlas: \(assertions) assertions")
    }
}
