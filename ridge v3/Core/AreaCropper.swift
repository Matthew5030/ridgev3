import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

struct PreparedCrop: Sendable {
    var manifest: RegionManifest
    /// A disposable directory. The caller removes it after install, including cancellation.
    var directory: URL
}

enum AreaCropper {
    /// This is also the download plan. It mirrors the exact bounded windows
    /// below, so the renderer can remain completely unaware of networking.
    static func sourceAssets(manifest: RegionManifest, preview: RegionManifest, spacing: Int) -> [SourceAsset] {
        guard let source = manifest.tiledTerrain, let grid = manifest.grid,
              let primary = preview.levels.first(where: { $0.spacing == spacing }) else { return [] }
        var assets: [String: SourceAsset] = [:]
        let layers = [(preview.bounds, primary)] + (preview.horizon?.layers ?? []).compactMap { layer in layer.levels.first.map { (layer.bounds, $0) } }
        for (bounds, level) in layers {
            let intervals = 512 / level.spacing
            let uv = manifest.bounds.uv(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
            let x = Int((uv.u * Double(grid.columns * intervals)).rounded()), y = Int((uv.v * Double(grid.rows * intervals)).rounded())
            let left = min(grid.columns - 1, max(0, x / intervals)), right = min(grid.columns - 1, max(0, (x + level.width - 1) / intervals))
            let top = min(grid.rows - 1, max(0, y / intervals)), bottom = min(grid.rows - 1, max(0, (y + level.height - 1) / intervals))
            for row in top...bottom {
                for column in left...right {
                    if let stored = source.cells[row * grid.columns + column].levels.filter({ $0.spacing <= level.spacing }).max(by: { $0.spacing < $1.spacing }) {
                        assets[stored.file] = SourceAsset(file: stored.file, byteCount: stored.byteCount, sha256: stored.sha256)
                    }
                }
            }
        }
        for image in preview.cartography?.allTextures ?? [] { assets[image.file] = SourceAsset(file: image.file, byteCount: image.byteCount, sha256: image.sha256) }
        for graph in source.graphs where intersection(graph.bounds, preview.bounds) != nil {
            assets[graph.file] = SourceAsset(file: graph.file, byteCount: graph.byteCount, sha256: graph.sha256)
        }
        return assets.values.sorted { $0.file < $1.file }
    }
    private struct Window {
        var x: Int, y: Int, width: Int, height: Int
    }
    private struct Plan {
        var bounds: GeoBounds
        var windows: [Int: Window]
        var grid: TerrainGrid?
    }

    /// Bounds and sample dimensions are exact; encoded map/graph sizes are estimates.
    /// Invalid selections have no levels, so TerrainBudget rejects them without throwing in UI.
    static func preview(manifest: RegionManifest, selection: AreaSelection, spacing: Int? = nil,
                        context: TerrainBudget.Context = TerrainBudget.currentContext()) -> RegionManifest {
        guard let plan = try? plan(manifest, selection) else {
            var invalid = manifest; invalid.levels = []; return invalid
        }
        var result = manifest
        result.tiledTerrain = nil
        result.bounds = plan.bounds
        result.grid = plan.grid
        result.detailTextures = nil
        if let grid = plan.grid, !selection.isWhole {
            result.id = grid.stableID
            result.name = grid.name(sourceName: manifest.name)
        } else if !selection.isWhole {
            let boundsKey = [plan.bounds.minLatitude, plan.bounds.minLongitude, plan.bounds.maxLatitude, plan.bounds.maxLongitude].map { String($0.bitPattern) }.joined(separator: ":")
            let identity = manifest.version + ":" + boundsKey + ":" + manifest.levels.map(\.sha256).joined(separator: ":")
            result.id = String(manifest.id.prefix(130)) + "-" + hash(Data(identity.utf8)).prefix(12)
        }
        result.levels = manifest.levels.compactMap { level in
            guard let window = plan.windows[level.spacing] else { return nil }
            var cropped = level
            cropped.width = window.width; cropped.height = window.height
            cropped.byteCount = Int64(window.width) * Int64(window.height) * 2
            return cropped
        }
        result.textures = (manifest.cartography == nil ? textureLayer(manifest: manifest, bounds: plan.bounds) : []).compactMap { texture in
            guard let bounds = intersection(texture.bounds, plan.bounds) else { return nil }
            let dimensions = textureDimensions(texture, bounds)
            var cropped = texture
            cropped.bounds = bounds; cropped.width = dimensions.width; cropped.height = dimensions.height
            let fraction = Double(dimensions.width * dimensions.height) / Double(texture.width * texture.height)
            cropped.byteCount = max(1024, Int64(ceil(Double(texture.byteCount) * fraction)))
            return cropped
        }
        result.places = manifest.places.filter { plan.bounds.contains($0.coordinate) }
        result.horizon = previewHorizon(manifest.horizon, selectedBounds: plan.bounds, atlas: manifest.cartography)
        if let atlas = manifest.cartography {
            result.cartography = atlas.cropped(to: result.horizon?.layers.last?.bounds ?? plan.bounds)
            guard result.cartography != nil else { result.levels = []; return result }
            result.textures = []
            result.horizon?.near?.textures = []
            result.horizon?.far?.textures = []
        }
        if let spacing { result.horizon = TerrainBudget.selectedHorizon(for: result, spacing: spacing, context: context) }
        if let atlas = result.cartography {
            result.cartography = atlas.cropped(to: result.horizon?.layers.last?.bounds ?? plan.bounds)
        }
        return result
    }

    static func prepare(directory: URL, manifest: RegionManifest, selection: AreaSelection, spacing: Int,
                        cartographySourceID: String? = nil, downloadedPreview: RegionManifest? = nil) throws -> PreparedCrop {
        try PackStore.validate(manifest)
        let plan = try plan(manifest, selection)
        let context = TerrainBudget.currentContext()
        var result = preview(manifest: manifest, selection: selection, spacing: spacing, context: context)
        if let downloadedPreview {
            guard downloadedPreview.bounds == result.bounds else { throw RidgeError.message("The download does not match the selected area.") }
            // Memory can fall during a download. Retain at most the downloaded
            // horizon; never expand the file requirements during preparation.
            result.horizon = downloadedPreview.horizon
            result.horizon = TerrainBudget.selectedHorizon(for: result, spacing: spacing, context: context)
            result.cartography = manifest.cartography?.cropped(to: result.horizon?.layers.last?.bounds ?? result.bounds)
        }
        if result.cartography != nil {
            result.cartographySourceID = cartographySourceID ?? manifest.cartographySourceID
        }
        let allowance = TerrainBudget.allowance(for: result, spacing: spacing, context: context)
        guard allowance.allowed, let sourceLevel = manifest.levels.first(where: { $0.spacing == spacing }),
              let window = plan.windows[spacing], let selectedLevel = result.levels.first(where: { $0.spacing == spacing }) else {
            throw RidgeError.message(allowance.reason ?? "This source has no terrain at the selected resolution.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-crop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: output) } }
        try Task.checkCancellation()

        let heights: Data
        if manifest.tiledTerrain != nil {
            heights = try tiledHeights(manifest, directory: directory, spacing: spacing, window: window)
        } else {
        let terrainURL = try verifiedAsset(sourceLevel.file, directory: directory, bytes: sourceLevel.byteCount, sha256: sourceLevel.sha256)
        let input = try FileHandle(forReadingFrom: terrainURL)
        defer { try? input.close() }
        var croppedHeights = Data(); croppedHeights.reserveCapacity(Int(selectedLevel.byteCount))
        for row in 0..<window.height {
            try Task.checkCancellation()
            let offset = (Int64(window.y + row) * Int64(sourceLevel.width) + Int64(window.x)) * 2
            try input.seek(toOffset: UInt64(offset))
            guard let data = try input.read(upToCount: window.width * 2), data.count == window.width * 2 else {
                throw RidgeError.message("The source terrain ended inside the selected area.")
            }
            croppedHeights.append(data)
        }
            heights = croppedHeights
        }
        let usable = heights.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: 2).contains { Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))) != manifest.noDataValue }
        }
        guard usable else { throw RidgeError.message("This selection has no usable LiDAR samples. Choose a different area.") }
        let heightFile = "terrain-\(spacing)m.bin"
        try heights.write(to: output.appendingPathComponent(heightFile))
        var level = selectedLevel; level.file = heightFile; level.sha256 = hash(heights)
        result.levels = [level]; result.defaultSpacing = spacing
        result.textures = []

        for (index, texture) in (manifest.cartography == nil ? textureLayer(manifest: manifest, bounds: plan.bounds) : []).enumerated() {
            try Task.checkCancellation()
            guard let bounds = intersection(texture.bounds, plan.bounds) else { continue }
            let cropped: MapTexture = try autoreleasepool {
                let url = try verifiedAsset(texture.file, directory: directory, bytes: texture.byteCount, sha256: texture.sha256)
                let dimensions = textureDimensions(texture, bounds)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      properties[kCGImagePropertyPixelWidth] as? Int == texture.width,
                      properties[kCGImagePropertyPixelHeight] as? Int == texture.height,
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                    throw RidgeError.message("The source map image has invalid dimensions or cannot be read.")
                }
                let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                guard let context = CGContext(data: nil, width: dimensions.width, height: dimensions.height, bitsPerComponent: 8,
                                              bytesPerRow: dimensions.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else {
                    throw RidgeError.message("There is not enough memory to prepare this map image.")
                }
                let topLeft = texture.bounds.uv(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
                let bottomRight = texture.bounds.uv(GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude))
                let x0 = topLeft.u * Double(texture.width), y0 = topLeft.v * Double(texture.height)
                let x1 = bottomRight.u * Double(texture.width), y1 = bottomRight.v * Double(texture.height)
                let sx = Double(dimensions.width) / (x1 - x0), sy = Double(dimensions.height) / (y1 - y0)
                context.interpolationQuality = .high
                // Quartz origin is bottom-left; selection V runs south from the north edge.
                // Fractional source pixels are resampled to the exact geographic intersection.
                context.draw(image, in: CGRect(x: -x0 * sx, y: -(Double(texture.height) - y1) * sy,
                                               width: Double(texture.width) * sx, height: Double(texture.height) * sy))
                guard let croppedImage = context.makeImage() else { throw RidgeError.message("The selected map image could not be prepared.") }
                let file = "map-\(index).png", target = output.appendingPathComponent("map-\(index).png")
                guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw RidgeError.message("The selected map image could not be saved.")
                }
                CGImageDestinationAddImage(destination, croppedImage, nil)
                guard CGImageDestinationFinalize(destination) else { throw RidgeError.message("The selected map image could not be saved.") }
                let bytes = try Data(contentsOf: target, options: .mappedIfSafe)
                return MapTexture(file: file, width: dimensions.width, height: dimensions.height, byteCount: Int64(bytes.count), sha256: hash(bytes), bounds: bounds)
            }
            result.textures.append(cropped)
        }

        var graphSources = manifest.tiledTerrain?.graphs.filter { intersection($0.bounds, plan.bounds) != nil } ?? []
        if let file = manifest.graphFile, let count = manifest.graphByteCount, let checksum = manifest.graphSHA256 {
            graphSources = [TerrainSourceGraph(file: file, byteCount: count, sha256: checksum, bounds: manifest.bounds)]
        }
        var selectedNodes: [WalkingNode] = [], selectedEdges: [WalkingEdge] = []
        for record in graphSources {
            try Task.checkCancellation()
            let url = try verifiedAsset(record.file, directory: directory, bytes: record.byteCount, sha256: record.sha256)
            let graph = try JSONDecoder().decode(WalkingGraph.self, from: Data(contentsOf: url, options: .mappedIfSafe))
            let originalIDs = Set(graph.nodes.map(\.id))
            guard graph.nodes.count <= 200_000, graph.edges.count <= 500_000, originalIDs.count == graph.nodes.count,
                  graph.nodes.allSatisfy({ $0.coordinate.isValid && $0.elevation.isFinite && record.bounds.contains($0.coordinate) }),
                  graph.edges.allSatisfy({ originalIDs.contains($0.from) && originalIDs.contains($0.to) && $0.distance.isFinite && $0.distance > 0 }) else {
                throw RidgeError.message("The source walking graph is invalid.")
            }
            let nodes = graph.nodes.filter { plan.bounds.contains($0.coordinate) }, nodeIDs = Set(nodes.map(\.id))
            selectedNodes += nodes
            selectedEdges += graph.edges.filter { nodeIDs.contains($0.from) && nodeIDs.contains($0.to) }
        }
        guard selectedNodes.count <= 200_000, selectedEdges.count <= 500_000,
              Set(selectedNodes.map(\.id)).count == selectedNodes.count else { throw RidgeError.message("The selected walking network exceeds its supported size or has duplicate identifiers.") }
        // Only exact coincident source nodes are joined. Never invent a path
        // between nearby but disconnected trails on opposite sides of a ridge.
        var byCoordinate: [GeoPoint: Int] = [:], aliases: [Int: Int] = [:]
        for node in selectedNodes {
            if let id = byCoordinate[node.coordinate] { aliases[node.id] = id }
            else { byCoordinate[node.coordinate] = node.id }
        }
        selectedEdges = selectedEdges.compactMap { edge in
            var edge = edge; edge.from = aliases[edge.from] ?? edge.from; edge.to = aliases[edge.to] ?? edge.to
            return edge.from == edge.to ? nil : edge
        }
        if selectedEdges.contains(where: hasWalkingAccess) {
            let used = Set(selectedEdges.flatMap { [$0.from, $0.to] })
            let clipped = WalkingGraph(nodes: selectedNodes.filter { aliases[$0.id] == nil && used.contains($0.id) }, edges: selectedEdges)
            let bytes = try JSONEncoder().encode(clipped)
            try bytes.write(to: output.appendingPathComponent("graph.json"))
            result.graphFile = "graph.json"; result.graphByteCount = Int64(bytes.count); result.graphSHA256 = hash(bytes)
        } else { result.graphFile = nil; result.graphByteCount = nil; result.graphSHA256 = nil }

        if let horizon = result.horizon, let source = manifest.horizon {
            result.horizon = TerrainHorizon(
                near: try horizon.near.map { try prepareBackdrop($0, source: source.near, directory: directory, output: output, prefix: "horizon-near", noDataValue: manifest.noDataValue, tiledSource: manifest.tiledTerrain == nil ? nil : manifest) },
                far: try horizon.far.map { try prepareBackdrop($0, source: source.far, directory: directory, output: output, prefix: "horizon-far", noDataValue: manifest.noDataValue, tiledSource: manifest.tiledTerrain == nil ? nil : manifest) })
        }

        // The atlas is a separate, fixed geographic grid. Retain complete cells
        // and their neighbour gutters byte-for-byte at every terrain spacing.
        if let atlas = result.cartography, result.cartographySourceID == nil {
            for texture in atlas.allTextures {
                try Task.checkCancellation()
                let url = try verifiedAsset(texture.file, directory: directory, bytes: texture.byteCount, sha256: texture.sha256)
                try FileManager.default.copyItem(at: url, to: output.appendingPathComponent(texture.file))
            }
        }

        if selection.isWhole {
            result.id = manifest.id; result.name = manifest.name
        } else if let grid = result.grid {
            result.id = grid.stableID
            result.name = String(grid.name(sourceName: manifest.name).prefix(200))
            result.summary = "\(grid.columns * grid.rows) original precision \(grid.columns * grid.rows == 1 ? "tile" : "tiles") from \(manifest.name). Saved at \(spacing) m terrain spacing with the original map detail."
        } else {
            result.name = String(manifest.name.prefix(175)) + " · selected area"
            result.summary = "Selected from \(manifest.name). Saved at \(spacing) m terrain spacing with the original map detail."
        }
        try PackStore.validate(result)
        guard TerrainBudget.allowance(for: result, spacing: spacing).allowed else { throw RidgeError.message("The prepared selection exceeds this device’s memory budget. Select a smaller area.") }
        try Task.checkCancellation()
        try JSONEncoder().encode(result).write(to: output.appendingPathComponent("pack.json"), options: .atomic)
        complete = true
        return PreparedCrop(manifest: result, directory: output)
    }

    private static func previewHorizon(_ source: TerrainHorizon?, selectedBounds: GeoBounds, atlas: CartographyAtlas?) -> TerrainHorizon? {
        guard let source else { return nil }
        let near = source.near.flatMap { backdropPreview($0, selectedBounds: selectedBounds, marginMeters: 2_000, atlas: atlas) }
        let far = source.far.flatMap { backdropPreview($0, selectedBounds: selectedBounds, marginMeters: 15_000, atlas: atlas) }
        return near == nil && far == nil ? nil : TerrainHorizon(near: near, far: far)
    }

    private static func backdropPreview(_ source: TerrainBackdrop, selectedBounds: GeoBounds, marginMeters: Double, atlas: CartographyAtlas?) -> TerrainBackdrop? {
        guard source.bounds.isValid, !source.levels.isEmpty else { return nil }
        let gridX = source.levels.map { $0.width - 1 }.reduce(0, gcd)
        let gridY = source.levels.map { $0.height - 1 }.reduce(0, gcd)
        guard gridX >= 1, gridY >= 1 else { return nil }
        var latMargin = marginMeters / source.bounds.depthMeters * (source.bounds.maxLatitude - source.bounds.minLatitude)
        var lonMargin = marginMeters / source.bounds.widthMeters * (source.bounds.maxLongitude - source.bounds.minLongitude)
        if let atlas, atlas.sourceOnly == true {
            let latSpan = atlas.latitudeEdges[0] - atlas.latitudeEdges[min(62, atlas.rows)]
            let lonSpan = atlas.longitudeEdges[min(62, atlas.columns)] - atlas.longitudeEdges[0]
            latMargin = min(latMargin, max(0, (latSpan - selectedBounds.maxLatitude + selectedBounds.minLatitude) / 2))
            lonMargin = min(lonMargin, max(0, (lonSpan - selectedBounds.maxLongitude + selectedBounds.minLongitude) / 2))
        }
        let padded = GeoBounds(minLatitude: max(source.bounds.minLatitude, selectedBounds.minLatitude - latMargin),
                               minLongitude: max(source.bounds.minLongitude, selectedBounds.minLongitude - lonMargin),
                               maxLatitude: min(source.bounds.maxLatitude, selectedBounds.maxLatitude + latMargin),
                               maxLongitude: min(source.bounds.maxLongitude, selectedBounds.maxLongitude + lonMargin))
        guard padded.isValid else { return nil }
        let a = source.bounds.uv(GeoPoint(latitude: padded.maxLatitude, longitude: padded.minLongitude))
        let b = source.bounds.uv(GeoPoint(latitude: padded.minLatitude, longitude: padded.maxLongitude))
        let left = max(0, Int(floor(a.u * Double(gridX) + 1e-8)))
        let top = max(0, Int(floor(a.v * Double(gridY) + 1e-8)))
        let right = min(gridX, Int(ceil(b.u * Double(gridX) - 1e-8)))
        let bottom = min(gridY, Int(ceil(b.v * Double(gridY) - 1e-8)))
        guard right > left, bottom > top else { return nil }
        let northwest = source.bounds.point(u: Double(left) / Double(gridX), v: Double(top) / Double(gridY))
        let southeast = source.bounds.point(u: Double(right) / Double(gridX), v: Double(bottom) / Double(gridY))
        let bounds = GeoBounds(minLatitude: southeast.latitude, minLongitude: northwest.longitude, maxLatitude: northwest.latitude, maxLongitude: southeast.longitude)
        let expands = bounds.minLatitude < selectedBounds.minLatitude - 1e-9 || bounds.maxLatitude > selectedBounds.maxLatitude + 1e-9
            || bounds.minLongitude < selectedBounds.minLongitude - 1e-9 || bounds.maxLongitude > selectedBounds.maxLongitude + 1e-9
        guard expands else { return nil }
        var result = source; result.bounds = bounds
        result.levels = source.levels.map { level in
            var level = level
            level.width = (right - left) * ((level.width - 1) / gridX) + 1
            level.height = (bottom - top) * ((level.height - 1) / gridY) + 1
            level.byteCount = Int64(level.width) * Int64(level.height) * 2
            return level
        }
        result.textures = source.textures.compactMap { texture in
            guard let intersection = intersection(texture.bounds, bounds) else { return nil }
            // Map density comes from the prepared cartography, independently of
            // the height grid. Preserve those pixels in both surrounding bands.
            let dimensions = textureDimensions(texture, intersection)
            var result = texture; result.bounds = intersection
            result.width = dimensions.width; result.height = dimensions.height
            let ratio = Double(result.width * result.height) / Double(texture.width * texture.height)
            result.byteCount = max(1024, Int64(ceil(Double(texture.byteCount) * ratio)))
            return result
        }
        return result
    }

    private static func prepareBackdrop(_ preview: TerrainBackdrop, source: TerrainBackdrop?, directory: URL, output: URL,
                                        prefix: String, noDataValue: Int, tiledSource: RegionManifest? = nil) throws -> TerrainBackdrop {
        guard let source, preview.levels.count == 1, let selected = preview.levels.first,
              let level = source.levels.first(where: { $0.spacing == selected.spacing }) else { throw RidgeError.message("The selected surrounding terrain is unavailable.") }
        let topLeft = source.bounds.uv(GeoPoint(latitude: preview.bounds.maxLatitude, longitude: preview.bounds.minLongitude))
        let x = Int((topLeft.u * Double(level.width - 1)).rounded())
        let y = Int((topLeft.v * Double(level.height - 1)).rounded())
        guard x >= 0, y >= 0, x + selected.width <= level.width, y + selected.height <= level.height else { throw RidgeError.message("The surrounding terrain crop lies outside its source.") }
        if let tiledSource {
            let bytes = try tiledHeights(tiledSource, directory: directory, spacing: selected.spacing,
                                         window: Window(x: x, y: y, width: selected.width, height: selected.height))
            let file = "\(prefix)-\(selected.spacing)m.bin"
            try bytes.write(to: output.appendingPathComponent(file))
            var result = preview, level = selected
            level.file = file; level.sha256 = hash(bytes)
            result.levels = [level]; result.textures = []
            return result
        }
        let url = try verifiedAsset(level.file, directory: directory, bytes: level.byteCount, sha256: level.sha256)
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let file = "\(prefix)-\(selected.spacing)m.bin", target = output.appendingPathComponent(file)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target); defer { try? handle.close() }
        var digest = SHA256(), usable = false
        for row in 0..<selected.height {
            try Task.checkCancellation()
            try input.seek(toOffset: UInt64((Int64(y + row) * Int64(level.width) + Int64(x)) * 2))
            guard let bytes = try input.read(upToCount: selected.width * 2), bytes.count == selected.width * 2 else { throw RidgeError.message("The surrounding terrain source is incomplete.") }
            if !usable { usable = bytes.withUnsafeBytes { raw in stride(from: 0, to: raw.count, by: 2).contains { Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))) != noDataValue } } }
            try handle.write(contentsOf: bytes); digest.update(data: bytes)
        }
        guard usable else { throw RidgeError.message("The surrounding terrain contains no usable elevation samples.") }
        var result = preview, savedLevel = selected
        savedLevel.file = file; savedLevel.sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
        result.levels = [savedLevel]; result.textures = []
        for (index, texture) in preview.textures.enumerated() {
            guard let original = source.textures.first(where: { $0.file == texture.file }) else { throw RidgeError.message("A surrounding map source is missing.") }
            result.textures.append(try cropBackdropTexture(original, preview: texture, directory: directory, output: output, file: "\(prefix)-map-\(index).png"))
        }
        return result
    }

    private static func cropBackdropTexture(_ sourceTexture: MapTexture, preview: MapTexture, directory: URL, output: URL, file: String) throws -> MapTexture {
        try autoreleasepool {
            let url = try verifiedAsset(sourceTexture.file, directory: directory, bytes: sourceTexture.byteCount, sha256: sourceTexture.sha256)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == sourceTexture.width,
                  properties[kCGImagePropertyPixelHeight] as? Int == sourceTexture.height,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw RidgeError.message("A surrounding map source has invalid dimensions.") }
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: nil, width: preview.width, height: preview.height, bitsPerComponent: 8,
                                          bytesPerRow: preview.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { throw RidgeError.message("There is not enough memory to prepare the surrounding map.") }
            let a = sourceTexture.bounds.uv(GeoPoint(latitude: preview.bounds.maxLatitude, longitude: preview.bounds.minLongitude))
            let b = sourceTexture.bounds.uv(GeoPoint(latitude: preview.bounds.minLatitude, longitude: preview.bounds.maxLongitude))
            let sx = Double(preview.width) / (b.u - a.u), sy = Double(preview.height) / (b.v - a.v)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: -a.u * sx, y: -(1 - b.v) * sy, width: sx, height: sy))
            guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(file) as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw RidgeError.message("The surrounding map could not be saved.") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw RidgeError.message("The surrounding map could not be saved.") }
            let bytes = try Data(contentsOf: output.appendingPathComponent(file), options: .mappedIfSafe)
            var result = preview; result.file = file; result.byteCount = Int64(bytes.count); result.sha256 = hash(bytes)
            return result
        }
    }

    private static func plan(_ manifest: RegionManifest, _ selection: AreaSelection) throws -> Plan {
        // The source is fully validated on catalogue/import and before prepare.
        // A per-tap atlas preview does not use any legacy map layers, so avoid
        // their quadratic overlap scans while still validating every field
        // needed by the terrain and independent map selection.
        var planningManifest = manifest
        if planningManifest.cartography != nil {
            planningManifest.textures = []; planningManifest.detailTextures = nil
            planningManifest.horizon?.near?.textures = []
            planningManifest.horizon?.far?.textures = []
        }
        try PackStore.validate(planningManifest)
        if let grid = manifest.grid {
            guard let aligned = grid.cellsSelection(selection), let cropped = grid.cropped(to: aligned) else { throw RidgeError.message("Select one or more original terrain tiles.") }
            if let tiled = manifest.tiledTerrain, !tiled.covers(cropped, in: grid) {
                throw RidgeError.message("Some selected tiles have no complete prepared LiDAR. Choose highlighted tiles.")
            }
            let left = cropped.originColumn - grid.originColumn, top = cropped.originRow - grid.originRow
            var windows: [Int: Window] = [:]
            for level in manifest.levels {
                let intervals = TerrainGrid.nativeIntervals / level.spacing
                windows[level.spacing] = Window(x: left * intervals, y: top * intervals,
                                                width: cropped.columns * intervals + 1, height: cropped.rows * intervals + 1)
            }
            let a = manifest.bounds.point(u: aligned.minU, v: aligned.minV), b = manifest.bounds.point(u: aligned.maxU, v: aligned.maxV)
            return Plan(bounds: GeoBounds(minLatitude: b.latitude, minLongitude: a.longitude, maxLatitude: a.latitude, maxLongitude: b.longitude), windows: windows, grid: cropped)
        }
        let numbers = [selection.minU, selection.minV, selection.maxU, selection.maxV]
        guard numbers.allSatisfy({ $0.isFinite && (0...1).contains($0) }), selection.minU < selection.maxU, selection.minV < selection.maxV,
              let finest = manifest.levels.min(by: { $0.spacing < $1.spacing }) else { throw RidgeError.message("Select a rectangle inside this prepared area.") }
        let factor = 32 / finest.spacing
        var gridX: Int, gridY: Int
        if (finest.width - 1).isMultiple(of: factor), (finest.height - 1).isMultiple(of: factor) {
            gridX = (finest.width - 1) / factor; gridY = (finest.height - 1) / factor
        } else {
            // Third-party packs may have a non-32m extent. Use the common exact
            // native anchors rather than shift or interpolate terrain samples.
            gridX = manifest.levels.map { $0.width - 1 }.reduce(0, gcd)
            gridY = manifest.levels.map { $0.height - 1 }.reduce(0, gcd)
        }
        guard gridX >= 2, gridY >= 2 else { throw RidgeError.message("This prepared area is too small to subdivide.") }
        // Outward snapping includes the user's entire rectangle. Reject a drag
        // smaller than one coarse cell even if snapping would enlarge it.
        guard (selection.maxU - selection.minU) * Double(gridX) >= 1,
              (selection.maxV - selection.minV) * Double(gridY) >= 1 else { throw RidgeError.message("Select a larger rectangle, at least two terrain grid points across.") }
        let left = max(0, Int(floor(selection.minU * Double(gridX) + 1e-9)))
        let right = min(gridX, Int(ceil(selection.maxU * Double(gridX) - 1e-9)))
        let top = max(0, Int(floor(selection.minV * Double(gridY) + 1e-9)))
        let bottom = min(gridY, Int(ceil(selection.maxV * Double(gridY) - 1e-9)))
        guard right - left >= 2, bottom - top >= 2 else { throw RidgeError.message("Select a larger rectangle, at least two coarse terrain cells across.") }
        var windows: [Int: Window] = [:]
        for level in manifest.levels {
            guard (level.width - 1).isMultiple(of: gridX), (level.height - 1).isMultiple(of: gridY) else { throw RidgeError.message("This pack’s terrain levels do not share exact grid anchors.") }
            let dx = (level.width - 1) / gridX, dy = (level.height - 1) / gridY
            windows[level.spacing] = Window(x: left * dx, y: top * dy, width: (right - left) * dx + 1, height: (bottom - top) * dy + 1)
        }
        let a = manifest.bounds.point(u: Double(left) / Double(gridX), v: Double(top) / Double(gridY))
        let b = manifest.bounds.point(u: Double(right) / Double(gridX), v: Double(bottom) / Double(gridY))
        return Plan(bounds: GeoBounds(minLatitude: b.latitude, minLongitude: a.longitude, maxLatitude: a.latitude, maxLongitude: b.longitude), windows: windows, grid: nil)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { var x = a, y = b; while y != 0 { (x, y) = (y, x % y) }; return x }
    private static func textureLayer(manifest: RegionManifest, bounds: GeoBounds) -> [MapTexture] {
        guard manifest.grid != nil, let details = manifest.detailTextures, !details.isEmpty else { return manifest.textures }
        let intersecting = details.filter { intersection($0.bounds, bounds) != nil }
        guard !intersecting.isEmpty, intersecting.count <= 8 else { return manifest.textures }
        // At the densest source scale, the selected rectangular map must fit in
        // a 4096-square pixel footprint. This decision never depends on terrain LOD.
        let horizontalDensity = intersecting.map { Double($0.width) / ($0.bounds.maxLongitude - $0.bounds.minLongitude) }.max()!
        let verticalDensity = intersecting.map { Double($0.height) / ($0.bounds.maxLatitude - $0.bounds.minLatitude) }.max()!
        let width = (bounds.maxLongitude - bounds.minLongitude) * horizontalDensity
        let height = (bounds.maxLatitude - bounds.minLatitude) * verticalDensity
        return width <= 4096 + 1e-6 && height <= 4096 + 1e-6 ? details : manifest.textures
    }
    private static func hasWalkingAccess(_ edge: WalkingEdge) -> Bool {
        // Match RouteEngine's conservative source-graph eligibility. Keep all
        // classified edges if any are usable; omit the capability only if none are.
        let access = edge.access.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let kind = edge.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["no", "private", "customers", "delivery", "agricultural", "forestry", "destination"].contains(access) { return false }
        if ["motorway", "motorway_link", "trunk", "trunk_link", "majorroad", "construction", "proposed", "raceway"].contains(kind) { return false }
        if ["path", "footway", "footpath", "bridleway", "steps", "pedestrian", "track"].contains(kind) {
            return ["", "unknown", "yes", "designated", "permissive", "public", "official"].contains(access)
        }
        return ["minorroad", "living_street", "residential", "service", "unclassified", "tertiary", "tertiary_link", "secondary", "secondary_link", "primary", "primary_link", "cycleway"].contains(kind)
            && ["yes", "designated", "permissive", "public", "official"].contains(access)
    }
    private static func intersection(_ a: GeoBounds, _ b: GeoBounds) -> GeoBounds? {
        let bounds = GeoBounds(minLatitude: max(a.minLatitude, b.minLatitude), minLongitude: max(a.minLongitude, b.minLongitude),
                               maxLatitude: min(a.maxLatitude, b.maxLatitude), maxLongitude: min(a.maxLongitude, b.maxLongitude))
        return bounds.maxLatitude - bounds.minLatitude > 1e-12 && bounds.maxLongitude - bounds.minLongitude > 1e-12 ? bounds : nil
    }
    private static func textureDimensions(_ texture: MapTexture, _ bounds: GeoBounds) -> (width: Int, height: Int) {
        let width = Double(texture.width) * (bounds.maxLongitude - bounds.minLongitude) / (texture.bounds.maxLongitude - texture.bounds.minLongitude)
        let height = Double(texture.height) * (bounds.maxLatitude - bounds.minLatitude) / (texture.bounds.maxLatitude - texture.bounds.minLatitude)
        return (max(1, Int(ceil(width - 1e-8))), max(1, Int(ceil(height - 1e-8))))
    }
    /// Read just the intersecting cells at the nearest stored finer spacing.
    /// Peak CPU storage is the admitted crop plus one small source tile.
    private static func tiledHeights(_ manifest: RegionManifest, directory: URL, spacing: Int, window: Window) throws -> Data {
        guard let source = manifest.tiledTerrain, let grid = manifest.grid,
              [1, 2, 4, 8, 16, 32].contains(spacing), window.width > 0, window.height > 0,
              window.width <= 16385, window.height <= 16385 else { throw RidgeError.message("Invalid source tile window.") }
        let intervals = 512 / spacing
        guard window.x >= 0, window.y >= 0, window.x + window.width <= grid.columns * intervals + 1,
              window.y + window.height <= grid.rows * intervals + 1 else { throw RidgeError.message("The selected tiles lie outside this source.") }
        var output = Data(count: window.width * window.height * 2)
        output.withUnsafeMutableBytes { raw in
            for i in 0..<(raw.count / 2) { raw.storeBytes(of: Int16(manifest.noDataValue).littleEndian, toByteOffset: i * 2, as: Int16.self) }
        }
        let left = min(grid.columns - 1, window.x / intervals), top = min(grid.rows - 1, window.y / intervals)
        let right = min(grid.columns - 1, (window.x + window.width - 1) / intervals)
        let bottom = min(grid.rows - 1, (window.y + window.height - 1) / intervals)
        for row in top...bottom {
            for column in left...right {
                try Task.checkCancellation()
                let cell = source.cells[row * grid.columns + column]
                guard let level = cell.levels.filter({ $0.spacing <= spacing }).max(by: { $0.spacing < $1.spacing }) else { continue }
                let url = try verifiedAsset(level.file, directory: directory, bytes: level.byteCount, sha256: level.sha256)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let factor = spacing / level.spacing
                let x0 = max(window.x, column * intervals), x1 = min(window.x + window.width - 1, (column + 1) * intervals)
                let y0 = max(window.y, row * intervals), y1 = min(window.y + window.height - 1, (row + 1) * intervals)
                output.withUnsafeMutableBytes { destination in
                    data.withUnsafeBytes { input in
                        for y in y0...y1 {
                            for x in x0...x1 {
                                let index = ((y - row * intervals) * factor * level.width + (x - column * intervals) * factor) * 2
                                let value = input.loadUnaligned(fromByteOffset: index, as: Int16.self)
                                if Int(Int16(littleEndian: value)) != manifest.noDataValue {
                                    destination.storeBytes(of: value, toByteOffset: ((y - window.y) * window.width + x - window.x) * 2, as: Int16.self)
                                }
                            }
                        }
                    }
                }
            }
        }
        return output
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func verifiedAsset(_ file: String, directory: URL, bytes: Int64, sha256: String) throws -> URL {
        guard PackStore.safeName(file) else { throw RidgeError.message("Invalid source asset name.") }
        let root = directory.resolvingSymlinksInPath(), url = directory.appendingPathComponent(file).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == root.path else { throw RidgeError.message("A source file points outside this area.") }
        let actual = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        guard actual == bytes else { throw RidgeError.message("A source file is incomplete. Import the original area again.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var checksum = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); checksum.update(data: data) }
        guard checksum.finalize().map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else { throw RidgeError.message("A source file failed its integrity check.") }
        return url
    }
}


extension PackStore {
    func downloadSelection(from entry: PackEntry, selection: AreaSelection, spacing: Int,
                           progress: @Sendable (Double) async -> Void) async throws -> RegionManifest? {
        guard entry.manifest.tiledTerrain != nil, let remote = entry.remoteSource else { return nil }
        let preview = AreaCropper.preview(manifest: entry.manifest, selection: selection, spacing: spacing)
        let allowance = TerrainBudget.allowance(for: preview, spacing: spacing)
        guard allowance.allowed else { throw RidgeError.message(allowance.reason ?? "Select a smaller area.") }
        try await SourceDownloads.ensure(AreaCropper.sourceAssets(manifest: entry.manifest, preview: preview, spacing: spacing),
                                         at: entry.directory, remote: remote, progress: progress)
        return preview
    }
}
