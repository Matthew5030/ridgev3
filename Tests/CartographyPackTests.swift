import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private struct AtlasPackFailure: Error, CustomStringConvertible { let description: String }
@MainActor @main struct CartographyPackTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw AtlasPackFailure(description: message) }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func png(size: Int) throws -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.7, green: 0.8, blue: 0.6, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setStrokeColor(CGColor(red: 0.2, green: 0.3, blue: 0.2, alpha: 1)); context.setLineWidth(2)
        context.move(to: .zero); context.addLine(to: CGPoint(x: size, y: size)); context.strokePath()
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw AtlasPackFailure(description: "PNG fixture encoding failed") }
        return data as Data
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw AtlasPackFailure(description: "Pass Eryri source directory") }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("ridge-atlas-pack-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let bundle = temporary.appendingPathComponent("Bundle"), sourceURL = bundle.appendingPathComponent("regions/atlas-test")
        try fm.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        let original = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("pack.json")))
        var source = original
        source.id = "atlas-test"; source.name = "Atlas fixture"; source.horizon = nil; source.detailTextures = nil
        source.graphFile = nil; source.graphByteCount = nil; source.graphSHA256 = nil; source.places = []
        source.grid?.columns = 2; source.grid?.rows = 2
        source.bounds = GeoBounds(minLatitude: 53, minLongitude: -4.1, maxLatitude: 53.01, maxLongitude: -4.08)
        source.levels = try [1, 2, 4, 8, 16, 32].map { spacing in
            let width = 2 * 512 / spacing + 1, data = [Int16](repeating: 1000, count: width * width).withUnsafeBytes { Data($0) }
            let file = "terrain-\(spacing)m.bin"
            try data.write(to: sourceURL.appendingPathComponent(file))
            return TerrainLOD(spacing: spacing, width: width, height: width, file: file, byteCount: Int64(data.count), sha256: digest(data))
        }
        source.defaultSpacing = 8
        let full = try png(size: CartographyAtlas.imageSize), small = try png(size: CartographyAtlas.previewSize)
        let longitudes = (0...2).map { source.bounds.point(u: Double($0) / 2, v: 0).longitude }
        let latitudes = (0...2).map { source.bounds.point(u: 0, v: Double($0) / 2).latitude }
        var tiles: [CartographyTile] = []
        for row in 0..<2 { for column in 0..<2 {
            let bounds = GeoBounds(minLatitude: latitudes[row + 1], minLongitude: longitudes[column], maxLatitude: latitudes[row], maxLongitude: longitudes[column + 1])
            func texture(_ data: Data, size: Int, suffix: String) throws -> MapTexture {
                let file = "atlas-\(column)-\(row)-\(suffix).png"
                try data.write(to: sourceURL.appendingPathComponent(file))
                return MapTexture(file: file, width: size, height: size, byteCount: Int64(data.count), sha256: digest(data), bounds: bounds)
            }
            tiles.append(CartographyTile(image: try texture(full, size: CartographyAtlas.imageSize, suffix: "native"), preview: try texture(small, size: CartographyAtlas.previewSize, suffix: "preview")))
        } }
        source.cartography = CartographyAtlas(columns: 2, rows: 2, longitudeEdges: longitudes, latitudeEdges: latitudes, tiles: tiles)
        // Keep a valid source overview to verify it is never copied into a new atlas installation.
        try small.write(to: sourceURL.appendingPathComponent("overview.png"))
        source.textures = [MapTexture(file: "overview.png", width: 72, height: 72, byteCount: Int64(small.count), sha256: digest(small), bounds: source.bounds)]
        try PackStore.validate(source)
        try JSONEncoder().encode([source]).write(to: bundle.appendingPathComponent("catalog.json"))
        try JSONEncoder().encode(source).write(to: sourceURL.appendingPathComponent("pack.json"))
        let selected = source.grid!.selection(column: 0, row: 0)!
        var firstAtlas: CartographyAtlas?
        for spacing in [1, 2, 4, 8, 16, 32] {
            let preview = AreaCropper.preview(manifest: source, selection: selected, spacing: spacing)
            if firstAtlas == nil { firstAtlas = preview.cartography }
            try check(preview.cartography == firstAtlas && preview.cartography?.tiles.count == 1, "Changing LiDAR never changes selected map files, pixels, bounds or gutters")
        }
        let crop = try AreaCropper.prepare(directory: sourceURL, manifest: source, selection: selected, spacing: 1)
        defer { try? fm.removeItem(at: crop.directory) }
        try check(crop.manifest.cartography == firstAtlas && crop.manifest.textures.isEmpty, "Cropped independent map is identical to preview without a legacy overlay")
        for texture in crop.manifest.cartography!.allTextures {
            let bytes = try Data(contentsOf: crop.directory.appendingPathComponent(texture.file))
            try check(bytes == (texture.width == CartographyAtlas.imageSize ? full : small), "Native and preview map cells are copied byte-for-byte")
        }
        let store = PackStore(root: temporary.appendingPathComponent("Installed"), bundledDirectory: nil)
        try await store.install(from: crop.directory, manifest: crop.manifest, spacing: 1) { _ in }
        let loaded = try await store.load(id: crop.manifest.id)
        try check(loaded.cartography?.metadata == firstAtlas && loaded.textureURLs.isEmpty, "Installed area resolves the independent local map")
        try check(!fm.fileExists(atPath: loaded.directory.appendingPathComponent("overview.png").path), "Unused overview is not copied or charged as installed data")
        var overlapping = crop.manifest; overlapping.id = "overlapping-area"
        try await store.install(from: crop.directory, manifest: overlapping, spacing: 1) { _ in }
        let overlappingLoaded = try await store.load(id: overlapping.id)
        let mapFile = firstAtlas!.tiles[0].image.file
        let originalAttributes = try fm.attributesOfItem(atPath: loaded.directory.appendingPathComponent(mapFile).path)
        let overlapAttributes = try fm.attributesOfItem(atPath: overlappingLoaded.directory.appendingPathComponent(mapFile).path)
        try check((originalAttributes[.systemFileNumber] as? NSNumber) == (overlapAttributes[.systemFileNumber] as? NSNumber), "Overlapping saved areas share identical map storage")
        let sourceAttributes = try fm.attributesOfItem(atPath: crop.directory.appendingPathComponent(mapFile).path)
        try check((sourceAttributes[.systemFileNumber] as? NSNumber) != (originalAttributes[.systemFileNumber] as? NSNumber), "Mutable imported/source files are never linked into saved areas")
        let bad = crop.directory.appendingPathComponent(firstAtlas!.tiles[0].image.file)
        var corrupt = full; corrupt[corrupt.count - 1] ^= 1; try corrupt.write(to: bad)
        do { try await store.install(from: crop.directory, manifest: crop.manifest, spacing: 1) { _ in }; throw AtlasPackFailure(description: "Corrupt replacement was accepted") }
        catch let error as AtlasPackFailure { throw error }
        catch { assertions += 1 }
        let retained = try await store.load(id: crop.manifest.id)
        try check(retained.cartography?.metadata == firstAtlas, "Corrupt atlas replacement preserves the previous installed area")

        try await store.remove(id: crop.manifest.id)
        let afterRemoval = try await store.load(id: overlapping.id)
        let sharedBytes = try Data(contentsOf: afterRemoval.directory.appendingPathComponent(mapFile))
        try check(sharedBytes == full, "Removing one area preserves shared maps used by another")

        var legacy = source; legacy.cartography = nil
        let legacyRoot = temporary.appendingPathComponent("Legacy")
        let legacyStore = PackStore(root: legacyRoot, bundledDirectory: bundle)
        try await legacyStore.install(from: sourceURL, manifest: legacy, spacing: 8) { _ in }
        let savedURL = legacyRoot.appendingPathComponent(source.id).appendingPathComponent("pack.json")
        let savedBefore = try Data(contentsOf: savedURL)
        let upgraded = try await legacyStore.load(id: source.id)
        try check(upgraded.cartography?.metadata == source.cartography && upgraded.textureURLs.isEmpty, "Existing saved terrain uses compatible bundled cartography")
        try check(upgraded.level.spacing == 8 && upgraded.manifest.id == source.id && upgraded.manifest.bounds == source.bounds, "Compatibility map upgrade preserves terrain detail, bounds and area identity")
        let savedAfter = try Data(contentsOf: savedURL)
        try check(savedBefore == savedAfter, "Compatibility map upgrade does not rewrite the saved pack")
        print("PASS cartography crop/install/rollback/legacy upgrade: \(assertions) assertions")
    }
}
