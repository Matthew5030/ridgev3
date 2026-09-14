import Foundation

/// A local, reviewable extension of one fixed planning rectangle. The proposed
/// area never changes route geometry until the user explicitly confirms it.
struct AreaExtensionProposal: Sendable {
    var destination: GeoPoint
    var source: PackEntry? = nil
    var selection: AreaSelection? = nil
    /// Raw, cached crop metadata; keeps every primary LOD and horizon alternative.
    var preview: RegionManifest? = nil
    var additionalTileCount: Int? = nil
    var unavailableReason: String? = nil
    var displayName: String? = nil
}

enum AreaExtensionPlanner {
    static func propose(destination: GeoPoint, terrain: LoadedTerrain, route: RidgeRoute?, entries: [PackEntry],
                        context: TerrainBudget.Context, marginMeters: Double? = nil, bufferWholeRoute: Bool = false) -> AreaExtensionProposal {
        guard destination.isValid else { return unavailable(destination, "Choose a valid point on the terrain.") }
        let current = terrain.manifest
        guard current.bounds.isValid else { return unavailable(destination, "The current planning area has invalid bounds. Reopen a saved area.") }
        guard current.grid?.isValid ?? true else { return unavailable(destination, "The current planning tile grid is invalid. Reopen a saved area.") }
        guard !current.bounds.contains(destination) else { return unavailable(destination, "This point is already inside your planning area.") }

        // Include segment geometry as well as control points. A real walking
        // route can take a substantial detour between two nearby waypoints.
        let routePoints = (route?.points.map(\.coordinate) ?? []) + (route?.waypoints.map { $0.point.coordinate } ?? [])
        guard routePoints.allSatisfy(\.isValid) else { return unavailable(destination, "The current route contains an invalid coordinate. Resolve it before extending the area.") }
        let required = [destination] + corners(current.bounds) + routePoints
        let sources = entries.filter { entry in
            entry.directory.isFileURL && entry.manifest.bounds.isValid && required.allSatisfy(entry.manifest.bounds.contains)
        }.sorted { lhs, rhs in
            let leftMatch = matchingGrid(lhs.manifest.grid, current.grid)
            let rightMatch = matchingGrid(rhs.manifest.grid, current.grid)
            if leftMatch != rightMatch { return leftMatch }
            if (lhs.manifest.cartography != nil) != (rhs.manifest.cartography != nil) { return lhs.manifest.cartography != nil }
            let leftSpacing = lhs.manifest.levels.map(\.spacing).min() ?? .max
            let rightSpacing = rhs.manifest.levels.map(\.spacing).min() ?? .max
            if leftSpacing != rightSpacing { return leftSpacing < rightSpacing }
            // A saved crop is already local, but so is the bundled collection.
            // Prefer the original prepared map source: a crop may retain older
            // quiet surroundings and only one terrain resolution, losing both
            // current cartography and coarser choices when the area expands.
            let leftDetails = lhs.manifest.detailTextures?.isEmpty == false
            let rightDetails = rhs.manifest.detailTextures?.isEmpty == false
            if leftDetails != rightDetails { return leftDetails }
            let leftLevels = Set(lhs.manifest.levels.map(\.spacing)).count
            let rightLevels = Set(rhs.manifest.levels.map(\.spacing)).count
            if leftLevels != rightLevels { return leftLevels > rightLevels }
            if lhs.installed != rhs.installed { return lhs.installed }
            if lhs.manifest.bounds.areaSquareKilometers != rhs.manifest.bounds.areaSquareKilometers {
                return lhs.manifest.bounds.areaSquareKilometers < rhs.manifest.bounds.areaSquareKilometers
            }
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            return lhs.directory.absoluteString < rhs.directory.absoluteString
        }

        for source in sources {
            guard (try? PackStore.validate(source.manifest)) != nil else { continue }
            let selection: AreaSelection?
            if let grid = source.manifest.grid {
                selection = gridSelection(source: source.manifest, grid: grid, required: required, destination: destination, addHalo: marginMeters == nil)
            } else {
                selection = legacySelection(source: source.manifest, required: required, destination: destination, current: current, paddingOverride: marginMeters)
            }
            guard var selection else { continue }
            if let marginMeters, marginMeters.isFinite, (0...5000).contains(marginMeters) {
                let anchors = bufferWholeRoute ? [destination] + routePoints : [destination]
                let du = marginMeters / source.manifest.bounds.widthMeters
                let dv = marginMeters / source.manifest.bounds.depthMeters
                for point in anchors {
                    let uv = source.manifest.bounds.uv(point)
                    selection.minU = max(0, min(selection.minU, uv.u - du))
                    selection.maxU = min(1, max(selection.maxU, uv.u + du))
                    selection.minV = max(0, min(selection.minV, uv.v - dv))
                    selection.maxV = min(1, max(selection.maxV, uv.v + dv))
                }
                if let grid = source.manifest.grid {
                    let left = max(0, Int(floor(selection.minU * Double(grid.columns))))
                    let top = max(0, Int(floor(selection.minV * Double(grid.rows))))
                    let right = min(grid.columns - 1, Int(ceil(selection.maxU * Double(grid.columns))) - 1)
                    let bottom = min(grid.rows - 1, Int(ceil(selection.maxV * Double(grid.rows))) - 1)
                    guard let snapped = grid.rectangle(from: TerrainCell(column: left, row: top), to: TerrainCell(column: right, row: bottom)) else { continue }
                    selection = snapped
                }
            }
            let preview = AreaCropper.preview(manifest: source.manifest, selection: selection, context: context)
            guard !preview.levels.isEmpty, required.allSatisfy(preview.bounds.contains) else { continue }
            return AreaExtensionProposal(destination: destination, source: source, selection: selection, preview: preview,
                                         additionalTileCount: additionalTiles(current: current.grid, proposed: preview.grid))
        }

        return unavailable(destination, "No prepared area on this device covers this point, your current area and the whole route. Your overview sketch is kept. Import a compatible terrain pack to add detail here.")
    }

    private static func gridSelection(source: RegionManifest, grid: TerrainGrid, required: [GeoPoint], destination: GeoPoint, addHalo: Bool = true) -> AreaSelection? {
        guard grid.isValid, let west = required.map(\.longitude).min(), let east = required.map(\.longitude).max(),
              let south = required.map(\.latitude).min(), let north = required.map(\.latitude).max() else { return nil }
        let longitudes = (0...grid.columns).map { source.bounds.point(u: Double($0) / Double(grid.columns), v: 0).longitude }
        let latitudes = (0...grid.rows).map { source.bounds.point(u: 0, v: Double($0) / Double(grid.rows)).latitude }
        // Compare the same actual geographic edge values that AreaCropper uses,
        // rather than rounding normalized values and accidentally losing an edge.
        var left = (0..<grid.columns).last { longitudes[$0] <= west } ?? 0
        var right = ((left + 1)...grid.columns).first { longitudes[$0] >= east } ?? grid.columns
        var top = (0..<grid.rows).last { latitudes[$0] >= north } ?? 0
        var bottom = ((top + 1)...grid.rows).first { latitudes[$0] <= south } ?? grid.rows

        // Buffer the new destination only. Existing area edges and old route
        // points are preserved without growing a ring around the whole scene.
        if addHalo {
        let horizontal = halo(around: destination.longitude, edges: longitudes, ascending: true)
        let vertical = halo(around: destination.latitude, edges: latitudes, ascending: false)
        left = min(left, horizontal.lower); right = max(right, horizontal.upper)
        top = min(top, vertical.lower); bottom = max(bottom, vertical.upper)
        }
        return grid.rectangle(from: TerrainCell(column: left, row: top), to: TerrainCell(column: right - 1, row: bottom - 1))
    }

    /// A point exactly on an edge needs one cell on either side; a point inside a
    /// cell gets that cell and its two neighbours. Source boundaries clip the halo.
    private static func halo(around coordinate: Double, edges: [Double], ascending: Bool) -> (lower: Int, upper: Int) {
        let count = edges.count - 1
        if let edge = edges.firstIndex(of: coordinate) { return (max(0, edge - 1), min(count, edge + 1)) }
        let cell = (0..<count).last { ascending ? edges[$0] <= coordinate : edges[$0] >= coordinate } ?? 0
        return (max(0, cell - 1), min(count, cell + 2))
    }

    private static func legacySelection(source: RegionManifest, required: [GeoPoint], destination: GeoPoint,
                                        current: RegionManifest, paddingOverride: Double? = nil) -> AreaSelection? {
        guard let west = required.map(\.longitude).min(), let east = required.map(\.longitude).max(),
              let south = required.map(\.latitude).min(), let north = required.map(\.latitude).max() else { return nil }
        // A legacy rectangle has no original tile IDs. Use approximately one
        // precision-cell width as a modest margin, then let AreaCropper snap to
        // exact common source anchors. No tile count is invented for this case.
        let padding = paddingOverride ?? (current.grid.map { max(current.bounds.widthMeters / Double($0.columns), current.bounds.depthMeters / Double($0.rows)) } ?? 500)
        let latitudePadding = padding / source.bounds.depthMeters * (source.bounds.maxLatitude - source.bounds.minLatitude)
        let longitudePadding = padding / source.bounds.widthMeters * (source.bounds.maxLongitude - source.bounds.minLongitude)
        let bounds = GeoBounds(minLatitude: max(source.bounds.minLatitude, min(south, destination.latitude - latitudePadding)),
                               minLongitude: max(source.bounds.minLongitude, min(west, destination.longitude - longitudePadding)),
                               maxLatitude: min(source.bounds.maxLatitude, max(north, destination.latitude + latitudePadding)),
                               maxLongitude: min(source.bounds.maxLongitude, max(east, destination.longitude + longitudePadding)))
        let a = source.bounds.uv(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
        let b = source.bounds.uv(GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude))
        guard [a.u, a.v, b.u, b.v].allSatisfy(\.isFinite), a.u < b.u, a.v < b.v else { return nil }
        return AreaSelection(minU: max(0, a.u), minV: max(0, a.v), maxU: min(1, b.u), maxV: min(1, b.v))
    }

    private static func matchingGrid(_ lhs: TerrainGrid?, _ rhs: TerrainGrid?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.isValid && rhs.isValid && lhs.gridID == rhs.gridID && lhs.worldTileID == rhs.worldTileID
    }

    private static func additionalTiles(current: TerrainGrid?, proposed: TerrainGrid?) -> Int? {
        guard let current, let proposed, matchingGrid(current, proposed),
              proposed.originColumn <= current.originColumn, proposed.originRow <= current.originRow,
              proposed.originColumn + proposed.columns >= current.originColumn + current.columns,
              proposed.originRow + proposed.rows >= current.originRow + current.rows else { return nil }
        return proposed.columns * proposed.rows - current.columns * current.rows
    }

    private static func corners(_ bounds: GeoBounds) -> [GeoPoint] {
        [GeoPoint(latitude: bounds.minLatitude, longitude: bounds.minLongitude), GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude),
         GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude), GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.maxLongitude)]
    }

    private static func unavailable(_ destination: GeoPoint, _ reason: String) -> AreaExtensionProposal {
        AreaExtensionProposal(destination: destination, unavailableReason: reason)
    }
}
