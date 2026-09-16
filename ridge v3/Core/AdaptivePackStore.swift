import Foundation

extension PackStore {
    /// Metadata only. Called after an explicit selection, never by the renderer.
    func hydrateAdaptiveSources(covering bounds: GeoBounds, candidates: [PackEntry]? = nil,
                                transfer: (@Sendable (Int64, Int64) async -> Void)? = nil) async throws -> Bool {
        var changed = false
        let entries = try candidates ?? catalogue()
        for entry in entries where entry.manifest.adaptive?.index != nil && entry.manifest.bounds.intersects(bounds) {
            guard let asset = entry.manifest.adaptive?.index else { continue }
            let path = entry.directory.appendingPathComponent(asset.file)
            if let remote = entry.remoteSource {
                try await SourceDownloads.ensure([asset], at: entry.directory, remote: remote,
                                                 requestTimeout: 15, resourceTimeout: 90, transfer: transfer) { _ in }
            }
            try Self.verify(path, size: asset.byteCount, hash: asset.sha256)
            let data = try Data(contentsOf: path)
            let manifest = try JSONDecoder().decode(RegionManifest.self, from: data)
            try Self.validate(manifest)
            guard manifest.id == entry.id, manifest.bounds == entry.manifest.bounds,
                  manifest.grid == entry.manifest.grid, manifest.adaptive?.coverage == entry.manifest.adaptive?.coverage,
                  manifest.adaptive?.index == nil, manifest.adaptive?.isSource == true else { throw RidgeError.message("The adaptive index does not match its catalogue.") }
            try Task.checkCancellation()
            try data.write(to: entry.directory.appendingPathComponent("pack.json"), options: .atomic)
            changed = true
        }
        return changed
    }

    func estimateAdaptiveDownload(_ manifest: RegionManifest, from source: PackEntry) throws -> AreaDownloadEstimate {
        try SourceDownloads.estimate(AdaptiveArea.assets(manifest), at: source.directory)
    }

    func prepareAdaptive(_ entry: PackEntry, selection: AreaSelection, displayName: String?,
                         transfer: (@Sendable (Int64, Int64) async -> Void)? = nil,
                         progress: @Sendable (Double) async -> Void) async throws -> LoadedTerrain {
        var manifest = AdaptiveArea.preview(entry.manifest, selection: selection)
        let allowance = AdaptiveArea.allowance(manifest, context: TerrainBudget.currentContext())
        guard allowance.allowed else { throw RidgeError.message(allowance.reason ?? "Select a smaller area.") }
        let assets = AdaptiveArea.assets(manifest)
        if let remote = entry.remoteSource {
            try await SourceDownloads.ensure(assets, at: entry.directory, remote: remote, transfer: transfer) { value in await progress(value * 0.85) }
        }
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".adaptive-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: stage) }
        for asset in assets {
            try Task.checkCancellation()
            let from = try Self.assetPathForDownload(asset.file, in: entry.directory)
            // ensure() has already checked downloaded files against verified receipts.
            // Rehashing the entire map pack here made every new local selection slow.
            if entry.remoteSource == nil {
                try Self.verify(from, size: asset.byteCount, hash: asset.sha256)
            } else {
                guard let size = (try from.resourceValues(forKeys: [.fileSizeKey])).fileSize, Int64(size) == asset.byteCount else {
                    throw RidgeError.message("A downloaded pack file is incomplete. Resume its download.")
                }
            }
            let to = try Self.assetPathForDownload(asset.file, in: stage)
            // Immutable assets can share disk blocks with the source cache.
            do { try files.linkItem(at: from, to: to) } catch { try files.copyItem(at: from, to: to) }
        }
        if let context = manifest.adaptive?.context {
            func prepare(_ source: TerrainBackdrop?, _ cropped: TerrainBackdrop?) throws -> TerrainBackdrop? {
                guard let source, var cropped, let original = source.levels.first, var level = cropped.levels.first else { return nil }
                let uv = source.bounds.uv(GeoPoint(latitude: cropped.bounds.maxLatitude, longitude: cropped.bounds.minLongitude))
                let x = Int((uv.u * Double(original.width - 1)).rounded()), y = Int((uv.v * Double(original.height - 1)).rounded())
                guard x >= 0, y >= 0, x + level.width <= original.width, y + level.height <= original.height else { throw RidgeError.message("Invalid surrounding terrain crop.") }
                let blocks = manifest.adaptive?.contextBlocks?.filter { $0.remoteFile == original.file }
                let handle = try blocks == nil ? FileHandle(forReadingFrom: stage.appendingPathComponent(original.file)) : nil
                defer { try? handle?.close() }
                var data = Data(); data.reserveCapacity(Int(level.byteCount))
                var current: SourceAsset?, blockData = Data()
                for row in 0..<level.height {
                    try Task.checkCancellation()
                    let offset = Int64(((y + row) * original.width + x) * 2), count = level.width * 2
                    if let blocks {
                        if current == nil || offset < current!.byteOffset! || offset + Int64(count) > current!.byteOffset! + current!.byteCount {
                            guard let block = blocks.first(where: { offset >= $0.byteOffset! && offset + Int64(count) <= $0.byteOffset! + $0.byteCount }) else { throw RidgeError.message("A surrounding terrain strip is missing.") }
                            current = block; blockData = try Data(contentsOf: stage.appendingPathComponent(block.file))
                        }
                        let start = Int(offset - current!.byteOffset!)
                        data.append(blockData[start..<(start + count)])
                    } else {
                        try handle!.seek(toOffset: UInt64(offset))
                        guard let bytes = try handle!.read(upToCount: count), bytes.count == count else { throw RidgeError.message("The surrounding terrain is incomplete.") }
                        data.append(bytes)
                    }
                }
                level.sha256 = AdaptiveTerrainCodec.hash(data)
                try data.write(to: stage.appendingPathComponent(level.file), options: .atomic)
                cropped.levels = [level]; return cropped
            }
            manifest.horizon = TerrainHorizon(near: try prepare(context.near, manifest.horizon?.near), far: try prepare(context.far, manifest.horizon?.far))
            let scratch = manifest.adaptive?.contextBlocks?.map(\.file) ?? context.layers.flatMap(\.levels).map(\.file)
            for file in scratch where files.fileExists(atPath: stage.appendingPathComponent(file).path) { try files.removeItem(at: stage.appendingPathComponent(file)) }
            manifest.adaptive?.context = nil; manifest.adaptive?.contextBlocks = nil
        }
        var nodes: [WalkingNode] = [], edges: [WalkingEdge] = []
        for graphAsset in manifest.adaptive?.graphs ?? [] {
            try Task.checkCancellation()
            let graph = try JSONDecoder().decode(WalkingGraph.self, from: Data(contentsOf: stage.appendingPathComponent(graphAsset.file)))
            guard graph.nodes.count <= 200_000, graph.edges.count <= 500_000 else { throw RidgeError.message("The source walking network is too large.") }
            let selected = graph.nodes.filter { manifest.bounds.contains($0.coordinate) }
            guard selected.allSatisfy({ $0.elevation.isFinite }), Set(graph.nodes.map(\.id)).count == graph.nodes.count else { throw RidgeError.message("Invalid source walking nodes.") }
            let ids = Set(selected.map(\.id))
            nodes += selected; edges += graph.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        }
        if !nodes.isEmpty {
            guard Set(nodes.map(\.id)).count == nodes.count, nodes.count <= 200_000, edges.count <= 500_000 else { throw RidgeError.message("The selected walking network is invalid or too large.") }
            let bytes = try JSONEncoder().encode(WalkingGraph(nodes: nodes, edges: edges))
            manifest.graphFile = "walking.json"; manifest.graphByteCount = Int64(bytes.count); manifest.graphSHA256 = AdaptiveTerrainCodec.hash(bytes)
            try bytes.write(to: stage.appendingPathComponent("walking.json"), options: .atomic)
        } else { manifest.graphFile = nil; manifest.graphByteCount = nil; manifest.graphSHA256 = nil }
        manifest.adaptive?.graphs = []
        if let displayName { manifest.name = displayName }
        try Self.validate(manifest)
        try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("pack.json"), options: .atomic)
        await progress(0.9)
        var loaded = try decodeAdaptive(manifest, directory: stage)
        try Task.checkCancellation()
        let destination = root.appendingPathComponent(manifest.id, isDirectory: true)
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: stage)
        } else { try files.moveItem(at: stage, to: destination) }
        loaded.directory = destination
        if var maps = loaded.cartography {
            maps.imageURLs = maps.imageURLs.map { destination.appendingPathComponent($0.lastPathComponent) }
            maps.previewURLs = maps.previewURLs.map { destination.appendingPathComponent($0.lastPathComponent) }
            loaded.cartography = maps
        }
        await progress(1)
        return loaded
    }

    func decodeAdaptive(_ manifest: RegionManifest, directory: URL) throws -> LoadedTerrain {
        try Self.validate(manifest)
        let context = TerrainBudget.currentContext()
        let allowance = AdaptiveArea.allowance(manifest, context: context)
        guard allowance.allowed, let adaptive = manifest.adaptive else { throw RidgeError.message(allowance.reason ?? "Select an area first.") }
        var meshes: [AdaptiveMesh] = []
        meshes.reserveCapacity(adaptive.chunks.count)
        // Sequential decoding keeps scratch memory bounded to one native chunk.
        for chunk in adaptive.chunks {
            try Task.checkCancellation()
            let file = try Self.assetPathForDownload(chunk.fileName, in: directory)
            guard (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize == chunk.byteCount else { throw RidgeError.message("A saved terrain chunk is incomplete.") }
            meshes.append(try AdaptiveTerrainCodec.decode(Data(contentsOf: file, options: .mappedIfSafe), chunk: chunk))
        }
        var graph: WalkingGraph?
        if let name = manifest.graphFile, let size = manifest.graphByteCount, let hash = manifest.graphSHA256 {
            let url = try Self.assetPathForDownload(name, in: directory)
            try Self.verify(url, size: size, hash: hash)
            graph = try JSONDecoder().decode(WalkingGraph.self, from: Data(contentsOf: url))
            guard let graph, graph.nodes.count <= 200_000, graph.edges.count <= 500_000,
                  graph.nodes.allSatisfy({ $0.elevation.isFinite && manifest.bounds.contains($0.coordinate) }),
                  Set(graph.nodes.map(\.id)).count == graph.nodes.count else { throw RidgeError.message("The saved path network is invalid.") }
            let ids = Set(graph.nodes.map(\.id))
            guard graph.edges.allSatisfy({ ids.contains($0.from) && ids.contains($0.to) && $0.distance.isFinite && $0.distance > 0 }) else { throw RidgeError.message("The saved path network contains invalid connections.") }
        }
        let horizon = try manifest.horizon.map { h in
            LoadedHorizon(near: try h.near.map { try decodeBackdrop($0, manifest: manifest, directory: directory) },
                          far: try h.far.map { try decodeBackdrop($0, manifest: manifest, directory: directory) })
        }
        let cartography = try manifest.cartography.map { try decodeCartography($0, directory: directory) }
        // A four-value compatibility surface supplies extents to old framing code.
        // It is never rendered or used for terrain queries or picking.
        let level = TerrainLOD(spacing: 0, width: 2, height: 2, file: "", byteCount: 0, sha256: "")
        let corners = [(0.0,0.0),(1.0,0.0),(0.0,1.0),(1.0,1.0)].map { u,v -> Float in
            let p = manifest.bounds.point(u: u,v: v)
            return Float(meshes.first(where: { $0.contains(p) })?.elevation(at: p) ?? 0)
        }
        return LoadedTerrain(manifest: manifest, level: level, heights: corners, textureURLs: [], graph: graph,
                             directory: directory, budgetContext: context, horizon: horizon, cartography: cartography, adaptiveMeshes: meshes)
    }
}

extension SourceDownloads {
    struct AdaptiveCatalogue: Decodable { var schemaVersion: Int; var sources: [RegionManifest] }
    static func registerAdaptive(_ data: Data, base: URL, directory: URL) async throws -> Int {
        let catalogue = try JSONDecoder().decode(AdaptiveCatalogue.self, from: data)
        guard catalogue.schemaVersion == 2, !catalogue.sources.isEmpty, catalogue.sources.count <= 1024,
              Set(catalogue.sources.map(\.id)).count == catalogue.sources.count else { throw RidgeError.message("Invalid adaptive catalogue.") }
        // Validate every entry before changing the local catalogue.
        for manifest in catalogue.sources {
            try PackStore.validate(manifest)
            guard manifest.adaptive?.index != nil else { throw RidgeError.message("Expected an adaptive source reference.") }
        }
        for manifest in catalogue.sources {
            try Task.checkCancellation()
            let target = directory.appendingPathComponent(manifest.id, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let source = target.appendingPathComponent("source.json"), encoded = try JSONEncoder().encode(manifest)
            if FileManager.default.fileExists(atPath: source.path) {
                let existing = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: source))
                guard existing == manifest else { throw RidgeError.message("Publish changed adaptive data under a new source ID.") }
            }
            let remote = base.appendingPathComponent(manifest.id, isDirectory: true)
            if let overview = manifest.adaptive?.overview {
                try await ensure([SourceAsset(file: overview.file, byteCount: overview.byteCount, sha256: overview.sha256)], at: target, remote: remote) { _ in }
            }
            try Task.checkCancellation()
            try JSONEncoder().encode(remote).write(to: target.appendingPathComponent("origin.json"), options: .atomic)
            if !FileManager.default.fileExists(atPath: source.path) { try encoded.write(to: source, options: .atomic) }
            let pack = target.appendingPathComponent("pack.json")
            if !FileManager.default.fileExists(atPath: pack.path) { try encoded.write(to: pack, options: .atomic) }
        }
        return catalogue.sources.count
    }
}
