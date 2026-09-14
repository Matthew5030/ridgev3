import Foundation
import CryptoKit
import ImageIO

enum RidgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct PackEntry: Identifiable, Sendable {
    var manifest: RegionManifest
    var directory: URL
    var installed: Bool
    var id: String { manifest.id }
}

actor PackStore {
    let root: URL
    private let fm = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var catalogueIssues: [String] = []
    private let bundledDirectory: URL?
    private var bundledCartography: [RegionManifest]?

    init(root: URL? = nil, bundledDirectory: URL? = PackStore.bundledRoot) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ridge/Areas", isDirectory: true)
        self.bundledDirectory = bundledDirectory
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    static var bundledRoot: URL? {
        Bundle.main.url(forResource: "RidgeData", withExtension: "bundle")
        ?? Bundle.main.url(forResource: "RidgeData", withExtension: "bundle", subdirectory: "Resources")
    }

    func catalogue() throws -> [PackEntry] {
        catalogueIssues = []
        var entries: [String: PackEntry] = [:]
        if let bundleRoot = bundledDirectory {
            do {
                let url = bundleRoot.appendingPathComponent("catalog.json")
                let manifests = try decoder.decode([RegionManifest].self, from: Data(contentsOf: url))
                for manifest in manifests {
                    try Self.validate(manifest)
                    entries[manifest.id] = PackEntry(manifest: manifest, directory: bundleRoot.appendingPathComponent("regions/\(manifest.id)"), installed: false)
                }
            } catch { catalogueIssues.append("The bundled area catalog could not be read: \(error.localizedDescription)") }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            let url = directory.appendingPathComponent("pack.json")
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                let manifest = try inspect(directory: directory)
                guard directory.lastPathComponent == manifest.id else { throw RidgeError.message("Its folder and area identifier do not match.") }
                if let existing = entries[manifest.id] {
                    // Keep the full catalogue's choice of levels. Opening uses the saved manifest.
                    entries[manifest.id] = PackEntry(manifest: existing.manifest, directory: existing.directory, installed: true)
                } else {
                    entries[manifest.id] = PackEntry(manifest: manifest, directory: directory, installed: true)
                }
            } catch { catalogueIssues.append("Saved area \(directory.lastPathComponent) needs to be imported again: \(error.localizedDescription)") }
        }
        return entries.values.sorted { $0.manifest.name < $1.manifest.name }
    }

    func issues() -> [String] { catalogueIssues }

    func installedManifest(id: String) throws -> RegionManifest? {
        guard Self.safeName(id) else { throw RidgeError.message("Invalid area identifier.") }
        let url = root.appendingPathComponent(id).appendingPathComponent("pack.json")
        guard fm.fileExists(atPath: url.path) else { return nil }
        let manifest = try inspect(directory: url.deletingLastPathComponent())
        guard manifest.id == id else { throw RidgeError.message("The saved area identifier does not match its folder.") }
        return manifest
    }

    func atlas() throws -> AtlasData {
        guard let root = bundledDirectory else { throw RidgeError.message("The offline atlas is missing from this build.") }
        return try decoder.decode(AtlasData.self, from: Data(contentsOf: root.appendingPathComponent("atlas.json")))
    }

    func inspect(directory: URL) throws -> RegionManifest {
        let manifestURL = try Self.asset("pack.json", in: directory)
        let size = (try fm.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber)?.int64Value ?? .max
        guard size < 16_000_000 else { throw RidgeError.message("The area manifest is too large.") }
        let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        guard data.count < 16_000_000 else { throw RidgeError.message("The area manifest is too large.") }
        let manifest = try decoder.decode(RegionManifest.self, from: data)
        try Self.validate(manifest)
        return manifest
    }

    func install(from directory: URL, manifest: RegionManifest, spacing: Int, progress: @Sendable (Double) async -> Void) async throws {
        try Self.validate(manifest)
        var manifest = manifest
        manifest.horizon = TerrainBudget.selectedHorizon(for: manifest, spacing: spacing)
        try Self.useIndependentCartography(&manifest)
        let allowance = TerrainBudget.allowance(for: manifest, spacing: spacing)
        guard allowance.allowed, let level = manifest.levels.first(where: { $0.spacing == spacing }) else {
            throw RidgeError.message(allowance.reason ?? "This resolution is not available.")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
        if directory.standardizedFileURL == destination.standardizedFileURL,
           let installed = try installedManifest(id: manifest.id), installed.levels.contains(where: { $0.spacing == spacing }) {
            _ = try decode(manifest: installed, directory: destination, spacing: spacing)
            return
        }
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard capacity > allowance.bytesOnDisk + 32 * 1_048_576 else { throw RidgeError.message("There isn’t enough free storage to save this area.") }
        let staging = root.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var files: [(String, Int64, String)] = [(level.file, level.byteCount, level.sha256)]
        files += manifest.textures.map { ($0.file, $0.byteCount, $0.sha256) }
        files += Self.horizonFiles(manifest)
        files += Self.cartographyFiles(manifest)
        if let name = manifest.graphFile, let bytes = manifest.graphByteCount, let hash = manifest.graphSHA256 { files.append((name, bytes, hash)) }
        let atlasImages = Dictionary(uniqueKeysWithValues: (manifest.cartography?.allTextures ?? []).map { ($0.file, $0) })
        // Saved areas own immutable assets. Hard links let overlapping areas
        // share identical map bytes; deleting either area leaves the other intact.
        let reusable = reusableMaps(hashes: Set(atlasImages.values.map(\.sha256)))
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let source = try Self.asset(file.0, in: directory)
            try Self.verify(source, size: file.1, hash: file.2)
            if let texture = atlasImages[file.0] {
                try Self.validateAtlasImage(source, texture: texture, decodePixels: true)
            }
            let target = staging.appendingPathComponent(file.0)
            var linked = false
            if atlasImages[file.0] != nil, let existing = reusable[file.2],
               (try? Self.verify(existing, size: file.1, hash: file.2)) != nil {
                do { try fm.linkItem(at: existing, to: target); linked = true } catch { }
            }
            if !linked { try fm.copyItem(at: source, to: target) }
            await progress(Double(index + 1) / Double(files.count + 1))
        }
        var saved = manifest
        saved.levels = [level]
        saved.defaultSpacing = spacing
        // Optional legacy fine maps are source-only. Independent atlas cells
        // keep their native pixels regardless of selected terrain spacing.
        saved.detailTextures = nil
        try encoder.encode(saved).write(to: staging.appendingPathComponent("pack.json"), options: .atomic)
        // Activation is the commit point: invalid but correctly hashed payloads
        // must fail here while the previous installation remains available.
        _ = try decode(manifest: saved, directory: staging, spacing: spacing)
        try Task.checkCancellation()
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else { try fm.moveItem(at: staging, to: destination) }
        await progress(1)
    }

    private func reusableMaps(hashes: Set<String>) -> [String: URL] {
        guard !hashes.isEmpty, let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [:] }
        var result: [String: URL] = [:]
        for directory in directories {
            guard let manifest = try? inspect(directory: directory), directory.lastPathComponent == manifest.id else { continue }
            for image in manifest.cartography?.allTextures ?? [] where hashes.contains(image.sha256) && result[image.sha256] == nil {
                if let url = try? Self.asset(image.file, in: directory) { result[image.sha256] = url }
            }
        }
        return result
    }

    func load(id: String, spacing: Int? = nil) throws -> LoadedTerrain {
        guard let manifest = try installedManifest(id: id) else { throw RidgeError.message("Save this area offline before opening it.") }
        return try decode(manifest: manifest, directory: root.appendingPathComponent(id), spacing: spacing,
                          supplementalCartography: compatibleBundledCartography(for: manifest))
    }

    private func decode(manifest: RegionManifest, directory: URL, spacing: Int?,
                        supplementalCartography: (CartographyAtlas, URL)? = nil) throws -> LoadedTerrain {
        try Self.validate(manifest)
        let selected = spacing ?? manifest.defaultSpacing
        let budgetContext = TerrainBudget.currentContext()
        var manifest = manifest
        let cartographyDirectory = supplementalCartography?.1 ?? directory
        if let atlas = supplementalCartography?.0 { manifest.cartography = atlas }
        manifest.horizon = TerrainBudget.selectedHorizon(for: manifest, spacing: selected, context: budgetContext)
        try Self.useIndependentCartography(&manifest)
        let allowance = TerrainBudget.allowance(for: manifest, spacing: selected, context: budgetContext)
        guard allowance.allowed, let level = manifest.levels.first(where: { $0.spacing == selected }) else { throw RidgeError.message(allowance.reason ?? "Save this resolution first.") }
        let heightURL = try Self.asset(level.file, in: directory)
        try Self.verify(heightURL, size: level.byteCount, hash: level.sha256)
        let data = try Data(contentsOf: heightURL, options: .mappedIfSafe)
        var heights = [Float]()
        heights.reserveCapacity(level.sampleCount)
        data.withUnsafeBytes { raw in
            for index in 0..<level.sampleCount {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                heights.append(Int(value) == manifest.noDataValue ? .nan : Float(Double(value) * manifest.heightScale))
            }
        }
        guard heights.contains(where: \.isFinite) else { throw RidgeError.message("This area contains no usable terrain samples.") }
        let textures = try manifest.textures.map { texture -> URL in
            let url = try Self.asset(texture.file, in: directory)
            try Self.verify(url, size: texture.byteCount, hash: texture.sha256)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  (properties[kCGImagePropertyPixelWidth] as? Int) == texture.width,
                  (properties[kCGImagePropertyPixelHeight] as? Int) == texture.height else { throw RidgeError.message("A map texture has invalid dimensions.") }
            return url
        }
        var graph: WalkingGraph?
        if let file = manifest.graphFile, let bytes = manifest.graphByteCount, let hash = manifest.graphSHA256 {
            let url = try Self.asset(file, in: directory)
            try Self.verify(url, size: bytes, hash: hash)
            graph = try decoder.decode(WalkingGraph.self, from: Data(contentsOf: url, options: .mappedIfSafe))
            guard let graph, graph.nodes.count <= 200_000, graph.edges.count <= 500_000,
                  Set(graph.nodes.map(\.id)).count == graph.nodes.count,
                  graph.nodes.allSatisfy({ $0.coordinate.isValid && $0.elevation.isFinite && manifest.bounds.contains($0.coordinate) }) else { throw RidgeError.message("The offline path network is invalid or too large.") }
            let nodeIDs = Set(graph.nodes.map(\.id))
            guard graph.edges.allSatisfy({ nodeIDs.contains($0.from) && nodeIDs.contains($0.to) && $0.distance.isFinite && $0.distance > 0 && $0.access.count <= 100 && $0.kind.count <= 100 }) else {
                throw RidgeError.message("The offline path network contains invalid connections.")
            }
        }
        let horizon: LoadedHorizon?
        if let metadata = manifest.horizon {
            horizon = LoadedHorizon(near: try metadata.near.map { try decodeBackdrop($0, manifest: manifest, directory: directory) },
                                    far: try metadata.far.map { try decodeBackdrop($0, manifest: manifest, directory: directory) })
        } else { horizon = nil }
        let cartography = try manifest.cartography.map { try decodeCartography($0, directory: cartographyDirectory) }
        return LoadedTerrain(manifest: manifest, level: level, heights: heights, textureURLs: textures, graph: graph, directory: directory, budgetContext: budgetContext, horizon: horizon, cartography: cartography)
    }

    private func decodeBackdrop(_ backdrop: TerrainBackdrop, manifest: RegionManifest, directory: URL) throws -> LoadedBackdrop {
        guard backdrop.levels.count == 1, let level = backdrop.levels.first else { throw RidgeError.message("The surrounding terrain detail is incomplete.") }
        let heightURL = try Self.asset(level.file, in: directory)
        try Self.verify(heightURL, size: level.byteCount, hash: level.sha256)
        let data = try Data(contentsOf: heightURL, options: .mappedIfSafe)
        var heights: [Float] = []; heights.reserveCapacity(level.sampleCount)
        data.withUnsafeBytes { raw in
            for index in 0..<level.sampleCount {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                heights.append(Int(value) == manifest.noDataValue ? .nan : Float(Double(value) * manifest.heightScale))
            }
        }
        guard heights.contains(where: \.isFinite) else { throw RidgeError.message("The surrounding terrain contains no usable elevation samples.") }
        let urls = try backdrop.textures.map { texture -> URL in
            let url = try Self.asset(texture.file, in: directory)
            try Self.verify(url, size: texture.byteCount, hash: texture.sha256)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == texture.width,
                  properties[kCGImagePropertyPixelHeight] as? Int == texture.height else { throw RidgeError.message("A surrounding map texture has invalid dimensions.") }
            return url
        }
        return LoadedBackdrop(metadata: backdrop, level: level, heights: heights, textureURLs: urls)
    }

    /// Existing saved terrain can use the current bundled map without rewriting
    /// its heights, route association or saved files. Only a matching grid with
    /// complete local coverage qualifies; this never fetches a remote asset.
    private func compatibleBundledCartography(for manifest: RegionManifest) throws -> (CartographyAtlas, URL)? {
        guard manifest.cartography == nil, let bundledDirectory, let grid = manifest.grid else { return nil }
        if bundledCartography == nil {
            let data = try Data(contentsOf: bundledDirectory.appendingPathComponent("catalog.json"))
            bundledCartography = try decoder.decode([RegionManifest].self, from: data).filter { $0.cartography != nil }
        }
        let coverage = manifest.horizon?.layers.last?.bounds ?? manifest.bounds
        for source in bundledCartography ?? [] {
            guard source.grid?.gridID == grid.gridID, source.grid?.worldTileID == grid.worldTileID,
                  let atlas = source.cartography?.cropped(to: coverage) else { continue }
            try Self.validate(source)
            return (atlas, bundledDirectory.appendingPathComponent("regions/\(source.id)"))
        }
        return nil
    }

    private func decodeCartography(_ atlas: CartographyAtlas, directory: URL) throws -> LoadedCartography {
        try atlas.validate()
        var images: [URL] = [], previews: [URL] = []
        for tile in atlas.tiles {
            try Task.checkCancellation()
            let image = try Self.asset(tile.image.file, in: directory)
            let preview = try Self.asset(tile.preview.file, in: directory)
            // Native PNGs are hashed during installation and again by the
            // bounded texture worker when used. Do not reread a gigabyte on
            // every area open. Preview images are small and all used immediately.
            let size = (try fm.attributesOfItem(atPath: image.path)[.size] as? NSNumber)?.int64Value
            guard size == tile.image.byteCount else { throw RidgeError.message("A detailed map tile is incomplete. Import the pack again.") }
            try Self.verify(preview, size: tile.preview.byteCount, hash: tile.preview.sha256)
            for (url, texture) in [(image, tile.image), (preview, tile.preview)] {
                try Self.validateAtlasImage(url, texture: texture, decodePixels: false)
            }
            images.append(image); previews.append(preview)
        }
        return LoadedCartography(metadata: atlas, imageURLs: images, previewURLs: previews)
    }

    private static func validateAtlasImage(_ url: URL, texture: MapTexture, decodePixels: Bool) throws {
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == texture.width,
                  properties[kCGImagePropertyPixelHeight] as? Int == texture.height else {
                throw RidgeError.message("An independent map tile has invalid dimensions.")
            }
            if decodePixels {
                guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
                    throw RidgeError.message("An independent map tile cannot be decoded. The previous saved area is unchanged.")
                }
            }
        }
    }

    private static func useIndependentCartography(_ manifest: inout RegionManifest) throws {
        guard let atlas = manifest.cartography else { return }
        let coverage = manifest.horizon?.layers.last?.bounds ?? manifest.bounds
        guard let cropped = atlas.cropped(to: coverage) else { throw RidgeError.message("The independent map does not cover this terrain.") }
        manifest.cartography = cropped
        manifest.textures = []; manifest.detailTextures = nil
        manifest.horizon?.near?.textures = []
        manifest.horizon?.far?.textures = []
    }

    func remove(id: String) throws {
        guard Self.safeName(id) else { throw RidgeError.message("Invalid area identifier.") }
        let url = root.appendingPathComponent(id)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    // Static manifests and asset files only. There is no rendering or route service.
    func fetchManifest(_ url: URL) async throws -> RegionManifest {
        guard url.scheme == "https" else { throw RidgeError.message("Use an HTTPS link to a prepared pack.json file.") }
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url?.scheme == "https",
              (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? .max < 16_000_000 else { throw RidgeError.message("The area manifest could not be downloaded.") }
        let manifest = try decoder.decode(RegionManifest.self, from: Data(contentsOf: file))
        try Self.validate(manifest)
        return manifest
    }

    func download(manifest: RegionManifest, from manifestURL: URL, spacing: Int, progress: @Sendable (Double) async -> Void) async throws {
        try Self.validate(manifest)
        var manifest = manifest
        manifest.horizon = TerrainBudget.selectedHorizon(for: manifest, spacing: spacing)
        try Self.useIndependentCartography(&manifest)
        guard manifestURL.scheme == "https", let level = manifest.levels.first(where: { $0.spacing == spacing }), TerrainBudget.allowance(for: manifest, spacing: spacing).allowed else { throw RidgeError.message("This download is not supported at the selected resolution.") }
        let stage = fm.temporaryDirectory.appendingPathComponent("ridge-download-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var files: [(String, Int64, String)] = [(level.file, level.byteCount, level.sha256)]
        files += manifest.textures.map { ($0.file, $0.byteCount, $0.sha256) }
        files += Self.horizonFiles(manifest)
        files += Self.cartographyFiles(manifest)
        if let name = manifest.graphFile, let bytes = manifest.graphByteCount, let hash = manifest.graphSHA256 { files.append((name, bytes, hash)) }
        let total = files.reduce(Int64(0)) { $0 + $1.1 }
        var finished: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let remote = manifestURL.deletingLastPathComponent().appendingPathComponent(file.0)
            let (temporary, response) = try await URLSession.shared.download(from: remote)
            defer { try? fm.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else { throw RidgeError.message("A file in this area could not be downloaded. Please retry.") }
            try Self.verify(temporary, size: file.1, hash: file.2)
            try fm.moveItem(at: temporary, to: stage.appendingPathComponent(file.0))
            finished += file.1
            await progress(Double(finished) / Double(max(1, total)) * 0.9)
        }
        try await install(from: stage, manifest: manifest, spacing: spacing) { value in await progress(0.9 + value * 0.1) }
    }

    static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 150 && value != "." && value != ".." && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }
    }

    static func validate(_ m: RegionManifest) throws {
        guard m.schemaVersion == 1, safeName(m.id), !m.name.isEmpty, m.name.count <= 200, m.bounds.isValid,
              m.bounds.widthMeters < 100_000, m.bounds.depthMeters < 100_000,
              m.heightScale.isFinite, m.heightScale > 0, m.heightScale <= 100,
              m.sourceResolution.isFinite, m.sourceResolution > 0,
              m.noDataValue >= -32768, m.noDataValue <= 32767,
              !m.levels.isEmpty, m.levels.count <= 6, Set(m.levels.map(\.spacing)).count == m.levels.count,
              m.levels.contains(where: { $0.spacing == m.defaultSpacing }),
              (!m.textures.isEmpty || m.cartography != nil), m.textures.count <= 8, m.places.count <= 5000 else { throw RidgeError.message("This area pack has unsupported or invalid metadata.") }
        for level in m.levels {
            guard [1, 2, 4, 8, 16, 32].contains(level.spacing), level.width >= 2, level.height >= 2,
                  level.width <= 16385, level.height <= 16385,
                  level.byteCount == Int64(level.width) * Int64(level.height) * 2,
                  safeName(level.file), validHash(level.sha256) else { throw RidgeError.message("The terrain resolution metadata is invalid.") }
        }
        if let grid = m.grid {
            guard grid.isValid else { throw RidgeError.message("The original terrain tile grid has invalid identifiers or extents.") }
            for level in m.levels {
                let intervals = TerrainGrid.nativeIntervals / level.spacing
                guard level.width == grid.columns * intervals + 1, level.height == grid.rows * intervals + 1 else {
                    throw RidgeError.message("The terrain dimensions do not match the original precision tile grid.")
                }
            }
        }
        if !m.textures.isEmpty { try validateTextureLayer(m.textures, bounds: m.bounds, maximumCount: 8) }
        if let atlas = m.cartography { try atlas.validate(covering: m.horizon?.layers.last?.bounds ?? m.bounds) }
        if let details = m.detailTextures { try validateTextureLayer(details, bounds: m.bounds, maximumCount: 32) }
        if let horizon = m.horizon {
            guard !horizon.layers.isEmpty else { throw RidgeError.message("The surrounding terrain metadata is empty.") }
            var innerBounds = m.bounds
            for (index, layer) in horizon.layers.enumerated() {
                guard layer.bounds.isValid, layer.bounds.widthMeters < 100_000, layer.bounds.depthMeters < 100_000,
                      contains(layer.bounds, innerBounds), !layer.levels.isEmpty, layer.levels.count <= 3,
                      Set(layer.levels.map(\.spacing)).count == layer.levels.count else { throw RidgeError.message("The surrounding terrain bounds or detail levels are invalid.") }
                let isFar = horizon.far != nil && (horizon.near == nil || index == 1)
                for level in layer.levels {
                    guard (isFar ? [32] : [8, 16, 32]).contains(level.spacing), (2...16385).contains(level.width), (2...16385).contains(level.height),
                          level.byteCount == Int64(level.width) * Int64(level.height) * 2,
                          safeName(level.file), validHash(level.sha256) else { throw RidgeError.message("The surrounding terrain file metadata is invalid.") }
                }
                if !layer.textures.isEmpty { try validateTextureLayer(layer.textures, bounds: layer.bounds, maximumCount: 256) }
                innerBounds = layer.bounds
            }
        }
        if let graph = m.graphFile {
            guard safeName(graph), validHash(m.graphSHA256 ?? ""), let size = m.graphByteCount, size > 0, size < 40_000_000 else { throw RidgeError.message("The walking network metadata is invalid.") }
        }
        let files = m.levels.map(\.file) + m.textures.map(\.file) + (m.detailTextures ?? []).map(\.file) + [m.graphFile].compactMap { $0 } + Self.horizonFiles(m).map { $0.0 } + Self.cartographyFiles(m).map { $0.0 }
        guard Set(files.map { $0.lowercased() }).count == files.count, !files.contains(where: { $0.lowercased() == "pack.json" }), m.places.allSatisfy({ m.bounds.contains($0.coordinate) && ($0.elevation?.isFinite ?? true) && $0.name.count <= 1000 }) else { throw RidgeError.message("This area contains duplicate or invalid assets.") }
    }

    private static func contains(_ outer: GeoBounds, _ inner: GeoBounds) -> Bool {
        let epsilon = 0.000000001
        return outer.minLatitude <= inner.minLatitude + epsilon && outer.maxLatitude >= inner.maxLatitude - epsilon
            && outer.minLongitude <= inner.minLongitude + epsilon && outer.maxLongitude >= inner.maxLongitude - epsilon
    }

    private static func horizonFiles(_ manifest: RegionManifest) -> [(String, Int64, String)] {
        (manifest.horizon?.layers ?? []).flatMap { layer in
            layer.levels.map { ($0.file, $0.byteCount, $0.sha256) } + layer.textures.map { ($0.file, $0.byteCount, $0.sha256) }
        }
    }

    private static func cartographyFiles(_ manifest: RegionManifest) -> [(String, Int64, String)] {
        (manifest.cartography?.allTextures ?? []).map { ($0.file, $0.byteCount, $0.sha256) }
    }

    private static func validateTextureLayer(_ textures: [MapTexture], bounds: GeoBounds, maximumCount: Int) throws {
        guard !textures.isEmpty, textures.count <= maximumCount else { throw RidgeError.message("The map layer contains an invalid number of textures.") }
        for texture in textures {
            guard safeName(texture.file), validHash(texture.sha256), texture.bounds.isValid,
                  texture.width > 0, texture.height > 0, texture.width <= 4096, texture.height <= 4096,
                  texture.byteCount > 0, texture.byteCount <= 100_000_000 else { throw RidgeError.message("The map texture metadata is invalid.") }
            let b = texture.bounds, epsilon = 0.000000001
            guard b.minLatitude >= bounds.minLatitude - epsilon, b.maxLatitude <= bounds.maxLatitude + epsilon,
                  b.minLongitude >= bounds.minLongitude - epsilon, b.maxLongitude <= bounds.maxLongitude + epsilon else {
                throw RidgeError.message("A map texture extends beyond this area.")
            }
        }
        // All map images form one complete, nonoverlapping rectangular surface.
        let area = (bounds.maxLatitude - bounds.minLatitude) * (bounds.maxLongitude - bounds.minLongitude)
        let textureArea = textures.reduce(0.0) { $0 + ($1.bounds.maxLatitude - $1.bounds.minLatitude) * ($1.bounds.maxLongitude - $1.bounds.minLongitude) }
        guard abs(area - textureArea) < area * 0.000001 else { throw RidgeError.message("The map textures do not cover this area completely.") }
        for (index, texture) in textures.enumerated() {
            for other in textures.dropFirst(index + 1) {
                let overlapWidth = min(texture.bounds.maxLongitude, other.bounds.maxLongitude) - max(texture.bounds.minLongitude, other.bounds.minLongitude)
                let overlapHeight = min(texture.bounds.maxLatitude, other.bounds.maxLatitude) - max(texture.bounds.minLatitude, other.bounds.minLatitude)
                guard overlapWidth <= 0.000000001 || overlapHeight <= 0.000000001 else { throw RidgeError.message("The map textures overlap inside this area.") }
            }
        }
    }

    private static func validHash(_ text: String) -> Bool { text.count == 64 && text.allSatisfy(\.isHexDigit) }
    private static func asset(_ name: String, in root: URL) throws -> URL {
        guard safeName(name) else { throw RidgeError.message("Invalid asset filename.") }
        let url = root.appendingPathComponent(name).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent() == root.resolvingSymlinksInPath() else { throw RidgeError.message("An area asset points outside its folder.") }
        return url
    }
    private static func verify(_ url: URL, size: Int64, hash: String) throws {
        let actual = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard actual == size else { throw RidgeError.message("An area file is incomplete. Import or download the pack again.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash.lowercased() else { throw RidgeError.message("An area file failed its integrity check. Import or download the pack again.") }
    }
}
