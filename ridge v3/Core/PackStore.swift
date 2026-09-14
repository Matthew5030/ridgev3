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
    var remoteSource: URL? = nil
    var id: String { manifest.id }
}

actor PackStore {
    let root: URL
    private let fm = FileManager.default
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var catalogueIssues: [String] = []
    private let bundledDirectory: URL?
    private var bundledCartography: [PackEntry]?
    private let sourceDirectory: URL
    private var sourceCacheKey: String?
    private var sourceCache: [PackEntry] = []

    init(root: URL? = nil, bundledDirectory: URL? = PackStore.bundledRoot, sourceDirectory: URL? = nil) {
        self.sourceDirectory = sourceDirectory ?? Self.sourceRoot
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ridge/Areas", isDirectory: true)
        self.bundledDirectory = bundledDirectory
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    static var sourceRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RidgeSources", isDirectory: true)
    }

    private func sourceEntries() throws -> [PackEntry] {
        guard fm.fileExists(atPath: sourceDirectory.path) else { return [] }
        let directories = try fm.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("pack.json").path) }.sorted { $0.path < $1.path }
        let key = try directories.flatMap { directory in
            try ["pack.json", "origin.json"].map { file in
                let path = directory.appendingPathComponent(file).path
                guard fm.fileExists(atPath: path) else { return path }
                let attributes = try fm.attributesOfItem(atPath: path)
                return path + ":" + String(describing: attributes[.size]) + ":" + String(describing: attributes[.modificationDate])
            }
        }.joined(separator: "|")
        if key == sourceCacheKey { return sourceCache }
        let entries = try directories.map { directory in
            let manifest = try inspect(directory: directory)
            guard manifest.tiledTerrain != nil, manifest.id == directory.lastPathComponent else { throw RidgeError.message("The terrain source folder does not match its index.") }
            let origin = directory.appendingPathComponent("origin.json")
            let remote = fm.fileExists(atPath: origin.path) ? try decoder.decode(URL.self, from: Data(contentsOf: origin)) : nil
            if let remote { _ = try SourceDownloads.validBase(remote) }
            return PackEntry(manifest: manifest, directory: directory, installed: false, remoteSource: remote)
        }
        sourceCacheKey = key; sourceCache = entries
        return entries
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
        do {
            for entry in try sourceEntries() { entries[entry.id] = entry }
        } catch { catalogueIssues.append("A terrain source could not be read: \(error.localizedDescription)") }
        bundledCartography = nil
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
        guard size < 64_000_000 else { throw RidgeError.message("The area manifest is too large.") }
        let data = try Data(contentsOf: manifestURL, options: .mappedIfSafe)
        guard data.count < 64_000_000 else { throw RidgeError.message("The area manifest is too large.") }
        let manifest = try decoder.decode(RegionManifest.self, from: data)
        try Self.validate(manifest)
        return manifest
    }

    func install(from directory: URL, manifest: RegionManifest, spacing: Int, progress: @Sendable (Double) async -> Void) async throws {
        try Self.validate(manifest)
        var manifest = manifest
        manifest.horizon = TerrainBudget.selectedHorizon(for: manifest, spacing: spacing)
        try Self.useIndependentCartography(&manifest)
        if manifest.cartographySourceID != nil {
            guard let borrowed = try compatibleBundledCartography(for: manifest) else {
                throw RidgeError.message("The bundled map referenced by this area is unavailable.")
            }
            manifest.cartography = borrowed.0
        }
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
        if manifest.cartographySourceID == nil { files += Self.cartographyFiles(manifest) }
        if let name = manifest.graphFile, let bytes = manifest.graphByteCount, let hash = manifest.graphSHA256 { files.append((name, bytes, hash)) }
        let atlasImages = Dictionary(uniqueKeysWithValues: (manifest.cartographySourceID == nil ? manifest.cartography?.allTextures ?? [] : []).map { ($0.file, $0) })
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
        return try decode(manifest: manifest, directory: root.appendingPathComponent(id), spacing: spacing)
    }

    private func decode(manifest: RegionManifest, directory: URL, spacing: Int?,
                        supplementalCartography: (CartographyAtlas, URL)? = nil) throws -> LoadedTerrain {
        try Self.validate(manifest)
        let resolvedCartography = try supplementalCartography ?? compatibleBundledCartography(for: manifest)
        let selected = spacing ?? manifest.defaultSpacing
        let budgetContext = TerrainBudget.currentContext()
        var manifest = manifest
        let cartographyDirectory = resolvedCartography?.1 ?? directory
        if let atlas = resolvedCartography?.0 { manifest.cartography = atlas }
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
        let cartography = try manifest.cartography.map {
            try decodeCartography($0, directory: cartographyDirectory, trustedBundled: resolvedCartography != nil && bundledDirectory.map { cartographyDirectory.path.hasPrefix($0.path + "/") } == true)
        }
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
        guard let grid = manifest.grid,
              manifest.cartography == nil || manifest.cartographySourceID != nil else { return nil }
        if bundledCartography == nil {
            var entries = try sourceEntries()
            if let bundledDirectory {
                let data = try Data(contentsOf: bundledDirectory.appendingPathComponent("catalog.json"))
                entries += try decoder.decode([RegionManifest].self, from: data).filter { $0.cartography != nil }.map {
                    try Self.validate($0)
                    return PackEntry(manifest: $0, directory: bundledDirectory.appendingPathComponent("regions/\($0.id)"), installed: false)
                }
            }
            bundledCartography = entries
        }
        let coverage = manifest.horizon?.layers.last?.bounds ?? manifest.bounds
        for entry in bundledCartography ?? [] {
            let source = entry.manifest
            if let sourceID = manifest.cartographySourceID, source.id != sourceID { continue }
            guard source.grid?.gridID == grid.gridID, source.grid?.worldTileID == grid.worldTileID,
                  let atlas = source.cartography?.cropped(to: coverage) else { continue }
            return (atlas, entry.directory)
        }
        return nil
    }

    private func decodeCartography(_ atlas: CartographyAtlas, directory: URL, trustedBundled: Bool = false) throws -> LoadedCartography {
        try atlas.validate()
        var images: [URL] = [], previews: [URL] = []
        if trustedBundled {
            // These immutable resources are inside the signed application
            // bundle and were validated when the build's source pack was made.
            // Avoid thousands of filesystem reads every time a saved area opens.
            images.reserveCapacity(atlas.tiles.count); previews.reserveCapacity(atlas.tiles.count)
            for tile in atlas.tiles {
                images.append(directory.appendingPathComponent(tile.image.file))
                previews.append(directory.appendingPathComponent(tile.preview.file))
            }
            return LoadedCartography(metadata: atlas, imageURLs: images, previewURLs: previews)
        }
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
        !value.isEmpty && value.utf8.count <= 150 && value != "." && value != ".." && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
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
                  level.width <= (m.tiledTerrain == nil ? 16385 : 131073), level.height <= (m.tiledTerrain == nil ? 16385 : 131073),
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
        guard (m.cartography?.sourceOnly == true) == (m.tiledTerrain != nil) else { throw RidgeError.message("A source atlas must be cropped before opening it.") }
        if let source = m.tiledTerrain { try validateTiledSource(source, manifest: m) }
        if !m.textures.isEmpty { try validateTextureLayer(m.textures, bounds: m.bounds, maximumCount: 8) }
        if let atlas = m.cartography { try atlas.validate(covering: m.horizon?.layers.last?.bounds ?? m.bounds) }
        if let sourceID = m.cartographySourceID {
            guard safeName(sourceID), m.cartography != nil else { throw RidgeError.message("The bundled map reference is invalid.") }
        }
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

    private static func validateTiledSource(_ source: TiledTerrainSource, manifest: RegionManifest) throws {
        guard let grid = manifest.grid, grid.gridID == "ridge-eryri-uniform-v1",
              grid.originColumn == 0, grid.originRow == 0,
              source.cells.count == grid.columns * grid.rows, source.graphs.count <= 32,
              manifest.cartographySourceID == nil, manifest.graphFile == nil,
              manifest.horizon?.layers.allSatisfy({ $0.bounds == manifest.bounds }) == true,
              source.overview.bounds == manifest.bounds, source.overview.width <= 4096, source.overview.height <= 4096,
              safeName(source.overview.file), validHash(source.overview.sha256), source.overview.byteCount > 0 else {
            throw RidgeError.message("The tiled terrain source index is invalid.")
        }
        var names = Set<String>()
        for (i, cell) in source.cells.enumerated() {
            guard cell.column == i % grid.columns, cell.row == i / grid.columns,
                  cell.levels.count <= 6, Set(cell.levels.map(\.spacing)).count == cell.levels.count,
                  !cell.complete || cell.levels.contains(where: { $0.spacing == 1 }) else { throw RidgeError.message("The source tile grid is incomplete.") }
            for level in cell.levels {
                guard [1, 2, 4, 8, 16, 32].contains(level.spacing), level.width == 512 / level.spacing + 1,
                      level.height == level.width, level.byteCount == Int64(level.width * level.height * 2),
                      safeName(level.file), validHash(level.sha256), names.insert(level.file.lowercased()).inserted else {
                    throw RidgeError.message("A source tile has invalid samples or integrity metadata.")
                }
            }
        }
        for graph in source.graphs {
            guard safeName(graph.file), validHash(graph.sha256), graph.bounds.isValid,
                  contains(manifest.bounds, graph.bounds), graph.byteCount > 0, graph.byteCount < 40_000_000,
                  names.insert(graph.file.lowercased()).inserted else { throw RidgeError.message("A source walking network is invalid.") }
        }
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
        (manifest.cartographySourceID == nil ? manifest.cartography?.allTextures ?? [] : []).map { ($0.file, $0.byteCount, $0.sha256) }
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

    private static func validHash(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    private static func asset(_ name: String, in root: URL) throws -> URL {
        guard safeName(name) else { throw RidgeError.message("Invalid asset filename.") }
        let url = root.appendingPathComponent(name).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == root.resolvingSymlinksInPath().path else { throw RidgeError.message("An area asset points outside its folder.") }
        return url
    }
    fileprivate static func verify(_ url: URL, size: Int64, hash: String) throws {
        let actual = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard actual == size else { throw RidgeError.message("An area file is incomplete. Import or download the pack again.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { digest.update(data: chunk) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash.lowercased() else { throw RidgeError.message("An area file failed its integrity check. Import or download the pack again.") }
    }
}

struct SourceAsset: Codable, Hashable, Sendable {
    var file: String
    var byteCount: Int64
    var sha256: String
}

/// A file-download transport only. Camera motion and terrain rendering never
/// call this type. Verified completed files survive interrupted downloads.
enum SourceDownloads {
    struct Catalogue: Decodable { var schemaVersion: Int; var sources: [Entry] }
    struct Entry: Decodable { var id: String; var name: String; var byteCount: Int64; var sha256: String }

    static func validBase(_ url: URL) throws -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.port == nil || (1...65535).contains(c.port!), ["http", "https"].contains(c.scheme?.lowercased() ?? "") else {
            throw RidgeError.message("Enter a download server address, such as http://your-mac.local:8787.")
        }
        let numbers = host.split(separator: ".").compactMap { Int($0) }
        let privateIPv4 = host.split(separator: ".").count == 4 && numbers.count == 4 && numbers.allSatisfy { (0...255).contains($0) } &&
            (numbers[0] == 10 || numbers[0] == 127 || (numbers[0] == 192 && numbers[1] == 168) ||
             (numbers[0] == 172 && (16...31).contains(numbers[1])) || (numbers[0] == 169 && numbers[1] == 254))
        let local = host.lowercased().hasSuffix(".local") || host == "localhost" || privateIPv4
        guard c.scheme?.lowercased() == "https" || local else { throw RidgeError.message("Use a local .local hostname or private network address for an HTTP download server.") }
        c.scheme = c.scheme?.lowercased(); c.host = host.lowercased()
        return c.url!
    }

    private static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 300
        c.httpMaximumConnectionsPerHost = 4; c.urlCache = nil
        return URLSession(configuration: c)
    }

    private static func downloaded(_ url: URL, maximumBytes: Int64, session: URLSession) async throws -> URL {
        var request = URLRequest(url: url); request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporary, response) = try await session.download(for: request)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: temporary) } }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host?.lowercased() == url.host?.lowercased(), http.url?.port == url.port,
              http.url?.scheme?.lowercased() == url.scheme?.lowercased(),
              let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value,
              size > 0, size <= maximumBytes else {
            throw RidgeError.message("The download server did not return a complete prepared file. Check the server and try again.")
        }
        try Task.checkCancellation(); keep = true; return temporary
    }

    static func register(base: URL, directory: URL) async throws -> Int {
        let base = try validBase(base), session = session()
        defer { session.invalidateAndCancel() }
        let catalogueURL = try await downloaded(base.appendingPathComponent("catalog.json"), maximumBytes: 1_048_576, session: session)
        defer { try? FileManager.default.removeItem(at: catalogueURL) }
        let catalogue = try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: catalogueURL))
        guard catalogue.schemaVersion == 1, catalogue.sources.count <= 32,
              Set(catalogue.sources.map(\.id)).count == catalogue.sources.count else { throw RidgeError.message("This server has an invalid source catalogue.") }
        guard !catalogue.sources.isEmpty else { throw RidgeError.message("The server is running, but its prepared terrain catalogue has not been published yet.") }
        for item in catalogue.sources {
            guard PackStore.safeName(item.id), item.byteCount > 0, item.byteCount < 64_000_000, item.sha256.count == 64 else { throw RidgeError.message("A server source has invalid metadata.") }
            let remote = base.appendingPathComponent(item.id, isDirectory: true)
            let index = try await downloaded(remote.appendingPathComponent("pack.json"), maximumBytes: item.byteCount, session: session)
            defer { try? FileManager.default.removeItem(at: index) }
            try PackStore.verify(index, size: item.byteCount, hash: item.sha256)
            let bytes = try Data(contentsOf: index)
            let manifest = try JSONDecoder().decode(RegionManifest.self, from: bytes)
            try PackStore.validate(manifest)
            guard manifest.id == item.id, let source = manifest.tiledTerrain else { throw RidgeError.message("This server source is not a tiled offline area.") }
            let target = directory.appendingPathComponent(item.id, isDirectory: true)
            let previous = target.appendingPathComponent("pack.json")
            if FileManager.default.fileExists(atPath: previous.path) {
                let old = try Data(contentsOf: previous)
                guard old == bytes else { throw RidgeError.message("The server has changed an existing source. Publish the new revision with a new source ID so saved areas remain usable offline.") }
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let image = try await downloaded(remote.appendingPathComponent(source.overview.file), maximumBytes: source.overview.byteCount, session: session)
            defer { try? FileManager.default.removeItem(at: image) }
            try PackStore.verify(image, size: source.overview.byteCount, hash: source.overview.sha256)
            try Data(contentsOf: image).write(to: target.appendingPathComponent(source.overview.file), options: .atomic)
            try JSONEncoder().encode(remote).write(to: target.appendingPathComponent("origin.json"), options: .atomic)
            try bytes.write(to: previous, options: .atomic)
        }
        return catalogue.sources.count
    }

    static func ensure(_ assets: [SourceAsset], at directory: URL, remote: URL,
                       progress: @Sendable (Double) async -> Void) async throws {
        _ = try validBase(remote)
        let fm = FileManager.default, receipt = directory.appendingPathComponent("downloaded.json")
        var verified = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipt))) ?? [:]
        // A failed/cancelled run keeps completed verified files for the retry.
        defer { if let data = try? JSONEncoder().encode(verified) { try? data.write(to: receipt, options: .atomic) } }
        var missing: [SourceAsset] = []
        for asset in assets {
            try Task.checkCancellation()
            let url = try PackStore.assetPathForDownload(asset.file, in: directory)
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            if verified[asset.file] == asset.sha256, size == asset.byteCount { continue }
            // Locally installed sources can acquire receipts without networking.
            if size == asset.byteCount, (try? PackStore.verify(url, size: asset.byteCount, hash: asset.sha256)) != nil {
                verified[asset.file] = asset.sha256; continue
            }
            missing.append(asset)
        }
        guard !missing.isEmpty else { await progress(1); return }
        let total = missing.reduce(Int64(0)) { $0 + $1.byteCount }
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? .max
        guard capacity > total + 64 * 1_048_576 else { throw RidgeError.message("There is not enough free storage for this download. Select a smaller area.") }
        let session = session(); defer { session.invalidateAndCancel() }
        var completed: Int64 = 0
        try await withThrowingTaskGroup(of: SourceAsset.self) { group in
            var next = 0
            func enqueue(_ asset: SourceAsset) {
                group.addTask {
                    let temporary = try await downloaded(remote.appendingPathComponent(asset.file), maximumBytes: asset.byteCount, session: session)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try PackStore.verify(temporary, size: asset.byteCount, hash: asset.sha256)
                    try Task.checkCancellation()
                    let target = try PackStore.assetPathForDownload(asset.file, in: directory)
                    let files = FileManager.default
                    if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                    try files.moveItem(at: temporary, to: target)
                    return asset
                }
            }
            while next < min(4, missing.count) { enqueue(missing[next]); next += 1 }
            while let asset = try await group.next() {
                verified[asset.file] = asset.sha256
                completed += asset.byteCount; await progress(Double(completed) / Double(total))
                if next < missing.count { enqueue(missing[next]); next += 1 }
            }
        }
    }
}

extension PackStore {
    static func assetPathForDownload(_ file: String, in directory: URL) throws -> URL {
        guard safeName(file) else { throw RidgeError.message("Invalid download asset name.") }
        let root = directory.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(file).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == root.path else { throw RidgeError.message("A downloaded asset points outside the source cache.") }
        return url
    }

    func connectSourceServer(_ url: URL) async throws -> Int {
        let count = try await SourceDownloads.register(base: url, directory: sourceDirectory)
        bundledCartography = nil; sourceCacheKey = nil
        return count
    }


}
