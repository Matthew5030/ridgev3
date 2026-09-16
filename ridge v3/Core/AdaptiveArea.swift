import Foundation

/// Selection is a crop of immutable mesh cells. It never resamples or simplifies them.
enum AdaptiveArea {
    static func preview(_ manifest: RegionManifest, selection: AreaSelection) -> RegionManifest {
        var result = manifest
        guard var adaptive = manifest.adaptive, adaptive.index == nil, let grid = manifest.grid,
              let aligned = grid.cellsSelection(selection), let crop = grid.cropped(to: aligned) else {
            result.adaptive?.chunks = []; return result
        }
        let nw = grid.point(u: aligned.minU, v: aligned.minV, in: manifest.bounds), se = grid.point(u: aligned.maxU, v: aligned.maxV, in: manifest.bounds)
        result.bounds = GeoBounds(minLatitude: se.latitude, minLongitude: nw.longitude, maxLatitude: nw.latitude, maxLongitude: se.longitude)
        result.grid = crop
        result.id = manifest.id + "-" + String(crop.originColumn) + "-" + String(crop.originRow) + "-" + String(crop.columns) + "x" + String(crop.rows)
        adaptive.chunks = adaptive.chunks.filter { result.bounds.contains($0.bounds.center) }
        adaptive.coverage = (0..<crop.rows).flatMap { y in (0..<crop.columns).map { x in
            adaptive.coverage[(y + crop.originRow - grid.originRow) * grid.columns + x + crop.originColumn - grid.originColumn]
        } }
        adaptive.isSource = false; adaptive.overview = nil
        if adaptive.graphs.isEmpty, let file = manifest.graphFile, let bytes = manifest.graphByteCount, let hash = manifest.graphSHA256 {
            adaptive.graphs = [TerrainSourceGraph(file: file, byteCount: bytes, sha256: hash, bounds: manifest.bounds)]
        }
        result.graphFile = nil; result.graphSHA256 = nil
        adaptive.graphs = adaptive.graphs.filter { $0.bounds.intersects(result.bounds) }
        result.adaptive = adaptive
        result.places = manifest.places.filter { result.bounds.contains($0.coordinate) }
        result.graphByteCount = adaptive.graphs.reduce(0) { $0 + $1.byteCount }
        if let context = adaptive.context { result.horizon = contextWindow(context, atlas: manifest.cartography, around: result.bounds) }
        result.cartography = manifest.cartography?.cropped(to: result.horizon?.layers.last?.bounds ?? result.bounds)
        result.cartographySourceID = nil
        result.summary = "Adaptive terrain with independent offline maps."
        return result
    }

    static func contextWindow(_ context: TerrainHorizon, atlas: CartographyAtlas?, around bounds: GeoBounds) -> TerrainHorizon? {
        guard let atlas else { return nil }
        let centre = atlas.bounds.uv(bounds.center)
        let columns = min(60, atlas.columns), rows = min(60, atlas.rows)
        let left = max(0, min(atlas.columns - columns, Int(centre.u * Double(atlas.columns)) - columns / 2))
        let top = max(0, min(atlas.rows - rows, Int(centre.v * Double(atlas.rows)) - rows / 2))
        let far = GeoBounds(minLatitude: atlas.latitudeEdges[top + rows], minLongitude: atlas.longitudeEdges[left],
                            maxLatitude: atlas.latitudeEdges[top], maxLongitude: atlas.longitudeEdges[left + columns])
        guard far.minLatitude <= bounds.minLatitude, far.maxLatitude >= bounds.maxLatitude,
              far.minLongitude <= bounds.minLongitude, far.maxLongitude >= bounds.maxLongitude else { return nil }
        let lat = 3000 / 111195.0, lon = lat / max(0.1, cos(bounds.center.latitude * .pi / 180))
        let near = GeoBounds(minLatitude: max(far.minLatitude, bounds.minLatitude - lat), minLongitude: max(far.minLongitude, bounds.minLongitude - lon),
                             maxLatitude: min(far.maxLatitude, bounds.maxLatitude + lat), maxLongitude: min(far.maxLongitude, bounds.maxLongitude + lon))
        return TerrainHorizon(near: context.near.flatMap { cropContext($0, to: near, file: "context-near.bin") },
                              far: context.far.flatMap { cropContext($0, to: far, file: "context-far.bin") })
    }

    static func cropContext(_ source: TerrainBackdrop, to bounds: GeoBounds, file: String) -> TerrainBackdrop? {
        guard let level = source.levels.first else { return nil }
        let a = source.bounds.uv(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
        let b = source.bounds.uv(GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude))
        let x0 = max(0, Int(floor(a.u * Double(level.width - 1) + 1e-7))), y0 = max(0, Int(floor(a.v * Double(level.height - 1) + 1e-7)))
        let x1 = min(level.width - 1, Int(ceil(b.u * Double(level.width - 1) - 1e-7))), y1 = min(level.height - 1, Int(ceil(b.v * Double(level.height - 1) - 1e-7)))
        guard x1 > x0, y1 > y0 else { return nil }
        let nw = source.bounds.point(u: Double(x0) / Double(level.width - 1), v: Double(y0) / Double(level.height - 1))
        let se = source.bounds.point(u: Double(x1) / Double(level.width - 1), v: Double(y1) / Double(level.height - 1))
        let bounds = GeoBounds(minLatitude: max(source.bounds.minLatitude, se.latitude), minLongitude: max(source.bounds.minLongitude, nw.longitude),
                               maxLatitude: min(source.bounds.maxLatitude, nw.latitude), maxLongitude: min(source.bounds.maxLongitude, se.longitude))
        let cropped = TerrainLOD(spacing: level.spacing, width: x1 - x0 + 1, height: y1 - y0 + 1, file: file,
                                 byteCount: Int64(x1 - x0 + 1) * Int64(y1 - y0 + 1) * 2, sha256: level.sha256)
        return TerrainBackdrop(bounds: bounds, levels: [cropped], textures: [])
    }

    static func allowance(_ manifest: RegionManifest, context: TerrainBudget.Context, residentBytes: Int64 = 0) -> TerrainAllowance {
        func rejected(_ message: String, memory: Int64 = 0) -> TerrainAllowance {
            TerrainAllowance(allowed: false, bytesOnDisk: manifest.totalBytes, estimatedMemory: memory, reason: message)
        }
        guard let adaptive = manifest.adaptive, !adaptive.isSource, adaptive.index == nil, !adaptive.chunks.isEmpty,
              (try? adaptive.validate(bounds: manifest.bounds, grid: manifest.grid)) != nil else { return rejected("Select complete highlighted tiles. Some of this area has no prepared terrain.") }
        // Charge compact CPU data, spatial bins, actual expanded GPU geometry,
        // all map residency, graph decode, and one worst-case sequential decode.
        var memory: Int64 = 96 * 1_048_576 + adaptive.chunks.reduce(0) { $0 + $1.residentBytes }
        if let atlas = manifest.cartography, let footprint = atlas.footprint(covering: manifest.horizon?.layers.last?.bounds ?? manifest.bounds) {
            memory += context.useDeviceTextureAllocation ? footprint.estimatedMemoryBytes : footprint.conservativeMemoryBytes
        } else { return rejected("The offline map for this area is unavailable.") }
        memory += max(0, manifest.graphByteCount ?? 0) * 5
        for layer in manifest.horizon?.layers ?? [] {
            guard let level = layer.levels.first, level.width <= 4097, level.height <= 4097 else { return rejected("The surrounding terrain is too large.") }
            memory += Int64(level.sampleCount) * 84 + 8 * 1_048_576
        }
        let vertices = adaptive.chunks.reduce(0) { $0 + $1.vertices }
        guard vertices <= min(TerrainBudget.absoluteMaximumMeshVertices, context.maximumSamples) else { return rejected("Select a smaller area to fit the terrain on this device.", memory: memory) }
        if let limit = context.maximumBufferLength, adaptive.chunks.contains(where: { Int64($0.vertices) * 48 > limit || Int64($0.triangles) * 12 > limit }) { return rejected("This mesh exceeds the device’s graphics buffer limit.", memory: memory) }
        guard memory <= context.sceneMemoryLimit(residentBytes: residentBytes) else { return rejected("Select a smaller area. This terrain and its maps need more memory than is currently available.", memory: memory) }
        return TerrainAllowance(allowed: true, bytesOnDisk: manifest.adaptive?.context == nil ? manifest.totalBytes : assets(manifest).reduce(0) { $0 + $1.byteCount }, estimatedMemory: memory, reason: nil)
    }

    static func assets(_ manifest: RegionManifest) -> [SourceAsset] {
        var assets = (manifest.cartography?.allTextures ?? []).map { SourceAsset(file: $0.file, byteCount: $0.byteCount, sha256: $0.sha256) }
        assets += (manifest.adaptive?.graphs ?? []).map { SourceAsset(file: $0.file, byteCount: $0.byteCount, sha256: $0.sha256) }
        let context = manifest.adaptive?.context ?? manifest.horizon
        if let blocks = manifest.adaptive?.contextBlocks, let source = manifest.adaptive?.context {
            for (original, cropped) in [(source.near, manifest.horizon?.near), (source.far, manifest.horizon?.far)] {
                guard let original, let cropped, let level = original.levels.first else { continue }
                let a = original.bounds.uv(GeoPoint(latitude: cropped.bounds.maxLatitude, longitude: cropped.bounds.minLongitude))
                let b = original.bounds.uv(GeoPoint(latitude: cropped.bounds.minLatitude, longitude: cropped.bounds.maxLongitude))
                let first = Int64((a.v * Double(level.height - 1)).rounded()) * Int64(level.width * 2)
                let end = (Int64((b.v * Double(level.height - 1)).rounded()) + 1) * Int64(level.width * 2)
                assets += blocks.filter { $0.remoteFile == level.file && ($0.byteOffset ?? .max) < end && ($0.byteOffset ?? 0) + $0.byteCount > first }
            }
        } else {
            assets += (context?.layers ?? []).flatMap(\.levels).map { SourceAsset(file: $0.file, byteCount: $0.byteCount, sha256: $0.sha256) }
        }
        assets += (manifest.adaptive?.chunks ?? []).map { SourceAsset(file: $0.fileName, byteCount: Int64($0.byteCount), sha256: $0.sha256, remoteFile: $0.path, byteOffset: $0.byteOffset) }
        return Array(Dictionary(assets.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a }).values).sorted { $0.file < $1.file }
    }
}
