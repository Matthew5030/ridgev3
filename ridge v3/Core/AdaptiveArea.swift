import Foundation

/// Selection is a crop of immutable mesh cells. It never resamples or simplifies them.
enum AdaptiveArea {
    static func preview(_ manifest: RegionManifest, selection: AreaSelection) -> RegionManifest {
        var result = manifest
        guard var adaptive = manifest.adaptive, adaptive.index == nil, let grid = manifest.grid,
              let aligned = grid.cellsSelection(selection), let crop = grid.cropped(to: aligned) else {
            result.adaptive?.chunks = []; return result
        }
        let nw = manifest.bounds.point(u: aligned.minU, v: aligned.minV), se = manifest.bounds.point(u: aligned.maxU, v: aligned.maxV)
        result.bounds = GeoBounds(minLatitude: se.latitude, minLongitude: nw.longitude, maxLatitude: nw.latitude, maxLongitude: se.longitude)
        result.grid = crop
        result.id = manifest.id + "-" + String(crop.originColumn) + "-" + String(crop.originRow) + "-" + String(crop.columns) + "x" + String(crop.rows)
        adaptive.chunks = adaptive.chunks.filter { result.bounds.contains($0.bounds.center) }
        adaptive.coverage = (0..<crop.rows).flatMap { y in (0..<crop.columns).map { x in
            adaptive.coverage[(y + crop.originRow - grid.originRow) * grid.columns + x + crop.originColumn - grid.originColumn]
        } }
        adaptive.isSource = false; adaptive.overview = nil
        adaptive.graphs = adaptive.graphs.filter { $0.bounds.intersects(result.bounds) }
        result.adaptive = adaptive
        result.places = manifest.places.filter { result.bounds.contains($0.coordinate) }
        result.graphByteCount = adaptive.graphs.reduce(0) { $0 + $1.byteCount }
        result.cartography = manifest.cartography?.cropped(to: result.horizon?.layers.last?.bounds ?? result.bounds)
        result.cartographySourceID = nil
        result.summary = "Adaptive terrain with independent offline maps."
        return result
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
        guard vertices <= TerrainBudget.absoluteMaximumMeshVertices else { return rejected("Select a smaller area to fit the terrain on this device.", memory: memory) }
        if let limit = context.maximumBufferLength, adaptive.chunks.contains(where: { Int64($0.vertices) * 48 > limit || Int64($0.triangles) * 12 > limit }) { return rejected("This mesh exceeds the device’s graphics buffer limit.", memory: memory) }
        guard memory <= context.sceneMemoryLimit(residentBytes: residentBytes) else { return rejected("Select a smaller area. This terrain and its maps need more memory than is currently available.", memory: memory) }
        return TerrainAllowance(allowed: true, bytesOnDisk: manifest.totalBytes, estimatedMemory: memory, reason: nil)
    }

    static func assets(_ manifest: RegionManifest) -> [SourceAsset] {
        var assets = (manifest.cartography?.allTextures ?? []).map { SourceAsset(file: $0.file, byteCount: $0.byteCount, sha256: $0.sha256) }
        assets += (manifest.adaptive?.graphs ?? []).map { SourceAsset(file: $0.file, byteCount: $0.byteCount, sha256: $0.sha256) }
        assets += (manifest.horizon?.layers ?? []).flatMap(\.levels).map { SourceAsset(file: $0.file, byteCount: $0.byteCount, sha256: $0.sha256) }
        assets += (manifest.adaptive?.chunks ?? []).map { SourceAsset(file: $0.fileName, byteCount: Int64($0.byteCount), sha256: $0.sha256, remoteFile: $0.path, byteOffset: $0.byteOffset) }
        return Array(Dictionary(assets.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a }).values).sorted { $0.file < $1.file }
    }
}
