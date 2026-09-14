import Foundation

/// One user rectangle; source cells and levels remain storage details.
struct AtlasAreaProposal: Sendable {
    var requested: GeoBounds
    var source: PackEntry?
    var selection: AreaSelection?
    var preview: RegionManifest?
    var saved: PackEntry?
    var allowance: TerrainAllowance?
    var reason: String?
    var canOpen: Bool { reason == nil && allowance?.allowed == true && preview != nil }
}

enum AtlasAreaPlanner {
    /// Resolve complete source cells immediately, before preview/admission.
    /// Moves retain the number of cells; resizes include every touched cell.
    static func snapped(_ requested: GeoBounds, entries: [PackEntry], preservingSize: Bool = false) -> GeoBounds? {
        guard requested.isValid else { return nil }
        let candidates = entries.filter {
            $0.manifest.grid?.isValid == true &&
            $0.manifest.bounds.minLatitude < requested.maxLatitude && $0.manifest.bounds.maxLatitude > requested.minLatitude &&
            $0.manifest.bounds.minLongitude < requested.maxLongitude && $0.manifest.bounds.maxLongitude > requested.minLongitude
        }.sorted {
            if $0.manifest.levels.count != $1.manifest.levels.count { return $0.manifest.levels.count > $1.manifest.levels.count }
            if $0.manifest.bounds.areaSquareKilometers != $1.manifest.bounds.areaSquareKilometers { return $0.manifest.bounds.areaSquareKilometers > $1.manifest.bounds.areaSquareKilometers }
            return $0.id < $1.id
        }
        guard let source = candidates.first?.manifest, let grid = source.grid else { return nil }
        let a = source.bounds.uv(GeoPoint(latitude: requested.maxLatitude, longitude: requested.minLongitude))
        let b = source.bounds.uv(GeoPoint(latitude: requested.minLatitude, longitude: requested.maxLongitude))
        let left: Int, top: Int, right: Int, bottom: Int
        if preservingSize {
            let columns = min(grid.columns, max(1, Int(((b.u - a.u) * Double(grid.columns)).rounded())))
            let rows = min(grid.rows, max(1, Int(((b.v - a.v) * Double(grid.rows)).rounded())))
            left = min(grid.columns - columns, max(0, Int((a.u * Double(grid.columns)).rounded())))
            top = min(grid.rows - rows, max(0, Int((a.v * Double(grid.rows)).rounded())))
            right = left + columns; bottom = top + rows
        } else {
            left = min(grid.columns - 1, max(0, Int(floor(a.u * Double(grid.columns) + 1e-8))))
            top = min(grid.rows - 1, max(0, Int(floor(a.v * Double(grid.rows) + 1e-8))))
            right = min(grid.columns, max(left + 1, Int(ceil(b.u * Double(grid.columns) - 1e-8))))
            bottom = min(grid.rows, max(top + 1, Int(ceil(b.v * Double(grid.rows) - 1e-8))))
        }
        let nw = source.bounds.point(u: Double(left) / Double(grid.columns), v: Double(top) / Double(grid.rows))
        let se = source.bounds.point(u: Double(right) / Double(grid.columns), v: Double(bottom) / Double(grid.rows))
        return GeoBounds(minLatitude: se.latitude, minLongitude: nw.longitude, maxLatitude: nw.latitude, maxLongitude: se.longitude)
    }

    static func tile(at point: GeoPoint, entries: [PackEntry]) -> GeoBounds? {
        guard point.isValid, let source = entries.filter({ $0.manifest.grid?.isValid == true && $0.manifest.bounds.contains(point) })
            .sorted(by: { $0.manifest.levels.count > $1.manifest.levels.count }).first?.manifest, let grid = source.grid else { return nil }
        let uv = source.bounds.uv(point)
        let column = min(grid.columns - 1, max(0, Int(floor(uv.u * Double(grid.columns) + 1e-9))))
        let row = min(grid.rows - 1, max(0, Int(floor(uv.v * Double(grid.rows) + 1e-9))))
        let nw = source.bounds.point(u: Double(column) / Double(grid.columns), v: Double(row) / Double(grid.rows))
        let se = source.bounds.point(u: Double(column + 1) / Double(grid.columns), v: Double(row + 1) / Double(grid.rows))
        return GeoBounds(minLatitude: se.latitude, minLongitude: nw.longitude, maxLatitude: nw.latitude, maxLongitude: se.longitude)
    }

    /// Move the chosen footprint with a place tap, preserving its size. Coverage
    /// admission happens afterwards; never silently keep the previous location.
    static func recentered(_ bounds: GeoBounds, on point: GeoPoint) -> GeoBounds {
        let latitudeSpan = bounds.maxLatitude - bounds.minLatitude
        let longitudeSpan = bounds.maxLongitude - bounds.minLongitude
        let south = min(85 - latitudeSpan, max(-85, point.latitude - latitudeSpan / 2))
        let west = min(180 - longitudeSpan, max(-180, point.longitude - longitudeSpan / 2))
        return GeoBounds(minLatitude: south, minLongitude: west,
                         maxLatitude: south + latitudeSpan, maxLongitude: west + longitudeSpan)
    }

    /// Older saves can have a shorter horizon. Re-selecting the same primary
    /// rectangle should prepare the wider scene instead of reopening that crop.
    static func reusable(_ saved: RegionManifest, for preview: RegionManifest, spacing: Int) -> Bool {
        guard saved.id == preview.id, saved.bounds == preview.bounds, saved.defaultSpacing == spacing else { return false }
        return contains(saved.horizon?.layers.last?.bounds ?? saved.bounds,
                        preview.horizon?.layers.last?.bounds ?? preview.bounds)
    }

    static func contains(_ outer: GeoBounds, _ inner: GeoBounds) -> Bool {
        outer.isValid && inner.isValid && outer.minLatitude <= inner.minLatitude && outer.maxLatitude >= inner.maxLatitude &&
        outer.minLongitude <= inner.minLongitude && outer.maxLongitude >= inner.maxLongitude
    }

    static func propose(bounds: GeoBounds, entries: [PackEntry], spacing: Int = 4,
                        required: GeoBounds? = nil, route: RidgeRoute? = nil,
                        context: TerrainBudget.Context = TerrainBudget.currentContext()) -> AtlasAreaProposal {
        var result = AtlasAreaProposal(requested: bounds)
        guard bounds.isValid else { result.reason = "Draw a rectangle on the map."; return result }
        if let required, !contains(bounds, required) {
            result.reason = "Keep your current detailed area inside the rectangle when expanding it."; return result
        }
        if let route, !(route.points.map(\.coordinate) + route.waypoints.map { $0.point.coordinate }).allSatisfy(bounds.contains) {
            result.reason = "Include the whole route in your area."; return result
        }
        let sources = entries.filter { $0.directory.isFileURL && contains($0.manifest.bounds, bounds) }.sorted {
            if ($0.manifest.cartography != nil) != ($1.manifest.cartography != nil) { return $0.manifest.cartography != nil }
            if $0.manifest.levels.count != $1.manifest.levels.count { return $0.manifest.levels.count > $1.manifest.levels.count }
            if $0.manifest.bounds.areaSquareKilometers != $1.manifest.bounds.areaSquareKilometers { return $0.manifest.bounds.areaSquareKilometers > $1.manifest.bounds.areaSquareKilometers }
            return $0.id < $1.id
        }
        guard let source = sources.first(where: { $0.manifest.levels.contains { $0.spacing == spacing } }) else {
            result.reason = sources.isEmpty ? "Prepared terrain is not available for this whole rectangle. Choose an area inside the marked coverage, or add terrain data in Settings." : "This source does not include \(spacing) m terrain. Choose another area or import compatible data."
            return result
        }
        let a = source.manifest.bounds.uv(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
        let b = source.manifest.bounds.uv(GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude))
        var selection = AreaSelection(minU: max(0, a.u), minV: max(0, a.v), maxU: min(1, b.u), maxV: min(1, b.v))
        if let grid = source.manifest.grid {
            guard let aligned = grid.cellsSelection(selection) else { result.reason = "This area could not be selected."; return result }
            selection = aligned
        }
        var preview = AreaCropper.preview(manifest: source.manifest, selection: selection, spacing: spacing, context: context)
        guard !preview.levels.isEmpty else { result.reason = "This rectangle cannot be prepared from the available terrain."; return result }
        let nearest = source.manifest.places.min { $0.coordinate.distance(to: preview.bounds.center) < $1.coordinate.distance(to: preview.bounds.center) }
        preview.name = nearest.map { "Around " + $0.name } ?? source.manifest.name + " area"
        let allowance = TerrainBudget.allowance(for: preview, spacing: spacing, context: context)
        result.source = source; result.selection = selection; result.preview = preview; result.allowance = allowance
        result.saved = entries.first { $0.installed && $0.manifest.levels.count == 1 && reusable($0.manifest, for: preview, spacing: spacing) }
        if !allowance.allowed { result.reason = "Make the area smaller to open it at this detail. " + (allowance.reason ?? "This selection exceeds the device’s current memory budget.") }
        return result
    }
}
