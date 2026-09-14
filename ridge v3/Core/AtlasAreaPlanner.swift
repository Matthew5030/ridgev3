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
