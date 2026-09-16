import Foundation

struct GeoPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
    func distance(to other: GeoPoint) -> Double {
        let p1 = latitude * .pi / 180, p2 = other.latitude * .pi / 180
        let dp = p2 - p1, dl = (other.longitude - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 6_371_008.8 * 2 * atan2(sqrt(max(0, a)), sqrt(max(0, 1 - a)))
    }
}

struct GeoBounds: Codable, Hashable, Sendable {
    var minLatitude: Double
    var minLongitude: Double
    var maxLatitude: Double
    var maxLongitude: Double
    var center: GeoPoint { GeoPoint(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2) }
    var isValid: Bool { GeoPoint(latitude: minLatitude, longitude: minLongitude).isValid && GeoPoint(latitude: maxLatitude, longitude: maxLongitude).isValid && minLatitude < maxLatitude && minLongitude < maxLongitude }
    var widthMeters: Double { GeoPoint(latitude: center.latitude, longitude: minLongitude).distance(to: GeoPoint(latitude: center.latitude, longitude: maxLongitude)) }
    var depthMeters: Double { GeoPoint(latitude: minLatitude, longitude: center.longitude).distance(to: GeoPoint(latitude: maxLatitude, longitude: center.longitude)) }
    var areaSquareKilometers: Double { widthMeters * depthMeters / 1_000_000 }
    func contains(_ point: GeoPoint) -> Bool { point.isValid && (minLatitude...maxLatitude).contains(point.latitude) && (minLongitude...maxLongitude).contains(point.longitude) }
    func intersects(_ other: GeoBounds) -> Bool { minLatitude <= other.maxLatitude && maxLatitude >= other.minLatitude && minLongitude <= other.maxLongitude && maxLongitude >= other.minLongitude }
    func point(u: Double, v: Double) -> GeoPoint { GeoPoint(latitude: maxLatitude - v * (maxLatitude - minLatitude), longitude: minLongitude + u * (maxLongitude - minLongitude)) }
    func uv(_ point: GeoPoint) -> (u: Double, v: Double) { ((point.longitude - minLongitude) / (maxLongitude - minLongitude), (maxLatitude - point.latitude) / (maxLatitude - minLatitude)) }

    /// North-up preview with undistorted geography: fit routes, or crop area covers to fill.
    func libraryPreviewBounds(aspect: Double, padding: Double = 1.25, cropToFill: Bool = false) -> GeoBounds {
        let longitudeScale = max(0.01, cos(center.latitude * .pi / 180))
        let metresPerDegree = 111_195.0
        var height = max(400, (maxLatitude - minLatitude) * metresPerDegree) * padding
        let width = max(400, (maxLongitude - minLongitude) * metresPerDegree * longitudeScale) * padding
        height = cropToFill ? min(height, width / max(0.1, aspect)) : max(height, width / max(0.1, aspect))
        let latitudeSpan = min(180, height / metresPerDegree)
        let longitudeSpan = min(360, height * max(0.1, aspect) / (metresPerDegree * longitudeScale))
        let latitude = min(90 - latitudeSpan / 2, max(-90 + latitudeSpan / 2, center.latitude))
        let longitude = min(180 - longitudeSpan / 2, max(-180 + longitudeSpan / 2, center.longitude))
        return GeoBounds(minLatitude: latitude - latitudeSpan / 2, minLongitude: longitude - longitudeSpan / 2,
                         maxLatitude: latitude + latitudeSpan / 2, maxLongitude: longitude + longitudeSpan / 2)
    }
}

struct TerrainLOD: Codable, Hashable, Identifiable, Sendable {
    var spacing: Int
    var width: Int
    var height: Int
    var file: String
    var byteCount: Int64
    var sha256: String
    var id: Int { spacing }
    var sampleCount: Int { width * height }
}

struct MapTexture: Codable, Hashable, Sendable {
    var file: String
    var width: Int
    var height: Int
    var byteCount: Int64
    var sha256: String
    var bounds: GeoBounds
}

struct MapPlace: Codable, Hashable, Identifiable, Sendable {
    var searchIdentity: String { name.lowercased() + String(format: "|%.6f|%.6f", coordinate.latitude, coordinate.longitude) }
    var id: String
    var name: String
    var coordinate: GeoPoint
    var kind: String
    var elevation: Double?
}

struct SourceCredit: Codable, Hashable, Sendable {
    var name: String
    var attribution: String
    var license: String
    var url: String
}

/// Prepared context terrain only; route planning remains inside the main area.
struct TerrainBackdrop: Codable, Hashable, Sendable {
    var bounds: GeoBounds
    var levels: [TerrainLOD]
    var textures: [MapTexture]
}

struct TerrainHorizon: Codable, Hashable, Sendable {
    var near: TerrainBackdrop? = nil
    var far: TerrainBackdrop? = nil
    var layers: [TerrainBackdrop] { [near, far].compactMap { $0 } }
}

struct LoadedBackdrop: Sendable {
    var metadata: TerrainBackdrop
    var level: TerrainLOD
    var heights: [Float]
    var textureURLs: [URL]
}

struct LoadedHorizon: Sendable {
    var near: LoadedBackdrop? = nil
    var far: LoadedBackdrop? = nil
    var layers: [LoadedBackdrop] { [near, far].compactMap { $0 } }
}

/// Offline source storage. These records never become a resident terrain mesh.
struct TerrainSourceCell: Codable, Hashable, Sendable {
    var column: Int
    var row: Int
    var complete: Bool
    var levels: [TerrainLOD]
}

struct TerrainSourceGraph: Codable, Hashable, Sendable {
    var file: String
    var byteCount: Int64
    var sha256: String
    var bounds: GeoBounds
}

struct TiledTerrainSource: Codable, Hashable, Sendable {
    /// Dense metadata, northwest first. Empty levels mean absent source data.
    var cells: [TerrainSourceCell]
    var graphs: [TerrainSourceGraph]
    var overview: MapTexture

    func covers(_ selected: TerrainGrid, in source: TerrainGrid) -> Bool {
        let left = selected.originColumn - source.originColumn, top = selected.originRow - source.originRow
        guard left >= 0, top >= 0, left + selected.columns <= source.columns,
              top + selected.rows <= source.rows, cells.count == source.columns * source.rows else { return false }
        for row in top..<(top + selected.rows) {
            for column in left..<(left + selected.columns) where !cells[row * source.columns + column].complete { return false }
        }
        return true
    }
}

struct RegionManifest: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion: Int
    var id: String
    var name: String
    var subtitle: String
    var bounds: GeoBounds
    var sourceResolution: Double
    var heightScale: Double
    var noDataValue: Int
    var levels: [TerrainLOD]
    var textures: [MapTexture]
    var graphFile: String?
    var graphSHA256: String?
    var graphByteCount: Int64?
    var places: [MapPlace]
    var sources: [SourceCredit]
    var defaultSpacing: Int
    var version: String
    var summary: String
    var verticalDatum: String?
    var grid: TerrainGrid? = nil
    var detailTextures: [MapTexture]? = nil
    var horizon: TerrainHorizon? = nil
    var cartography: CartographyAtlas? = nil
    /// A trusted bundled source can provide immutable map cells to saved crops.
    /// Terrain, horizon and routes remain owned by the saved area.
    var cartographySourceID: String? = nil
    var tiledTerrain: TiledTerrainSource? = nil
    var adaptive: AdaptiveTerrainSource? = nil
    var totalBytes: Int64 {
        let layers = horizon?.layers ?? []
        let maps = cartographySourceID == nil ? cartography.map { [$0.totalBytes] }
            ?? (textures + (detailTextures ?? []) + layers.flatMap(\.textures)).map(\.byteCount)
            : []
        let sizes = (levels + layers.flatMap(\.levels)).map(\.byteCount) + maps + [graphByteCount ?? 0, adaptive?.downloadBytes ?? 0]
        return sizes.reduce(0) { sum, size in
            let result = sum.addingReportingOverflow(max(0, size))
            return result.overflow ? .max : result.partialValue
        }
    }
}

struct AtlasData: Codable, Sendable {
    var land: [[[Double]]]
    var places: [MapPlace]
    var coverage: [AtlasCoverage]
}

struct AtlasCoverage: Codable, Identifiable, Sendable {
    var id: String
    var bounds: GeoBounds
    var status: String
}

struct LoadedTerrain: Sendable {
    var manifest: RegionManifest
    var level: TerrainLOD
    var heights: [Float]
    var textureURLs: [URL]
    var graph: WalkingGraph?
    var directory: URL
    /// The admission snapshot taken before heights or graph allocations.
    var budgetContext: TerrainBudget.Context? = nil
    var horizon: LoadedHorizon? = nil
    var cartography: LoadedCartography? = nil
    var adaptiveMeshes: [AdaptiveMesh] = []
    func elevation(at point: GeoPoint) -> Double? {
        if !adaptiveMeshes.isEmpty { return adaptiveMeshes.first(where: { $0.contains(point) })?.elevation(at: point) }
        guard manifest.bounds.contains(point), level.width >= 2, level.height >= 2 else { return nil }
        let uv = manifest.bounds.uv(point)
        let x = min(Double(level.width - 1), max(0, uv.u * Double(level.width - 1)))
        let y = min(Double(level.height - 1), max(0, uv.v * Double(level.height - 1)))
        let x0 = Int(x), y0 = Int(y), x1 = min(x0 + 1, level.width - 1), y1 = min(y0 + 1, level.height - 1)
        let a = heights[y0 * level.width + x0], b = heights[y0 * level.width + x1]
        let c = heights[y1 * level.width + x0], d = heights[y1 * level.width + x1]
        guard a.isFinite && b.isFinite && c.isFinite && d.isFinite else { return nil }
        let tx = Float(x - Double(x0)), ty = Float(y - Double(y0))
        return Double((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty)
    }
}

struct WalkingGraph: Codable, Sendable {
    var nodes: [WalkingNode]
    var edges: [WalkingEdge]
}

struct WalkingNode: Codable, Sendable {
    var id: Int
    var coordinate: GeoPoint
    var elevation: Double
}

struct WalkingEdge: Codable, Sendable {
    var from: Int
    var to: Int
    var distance: Double
    var bidirectional: Bool
    var access: String
    var kind: String
}

struct RoutePoint: Codable, Hashable, Sendable {
    var coordinate: GeoPoint
    var elevation: Double?
}

struct RouteWaypoint: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var point: RoutePoint
    var name: String?
}

struct RouteSegment: Codable, Hashable, Sendable {
    var points: [RoutePoint]
    var mode: String
}

struct RidgeRoute: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var regionID: String
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var waypoints: [RouteWaypoint] = []
    var segments: [RouteSegment] = []
    var notes: String = ""
    var points: [RoutePoint] {
        if segments.isEmpty { return waypoints.map(\.point) }
        return segments.enumerated().flatMap { index, segment in index == 0 ? segment.points : Array(segment.points.dropFirst(segment.points.first == segments[index - 1].points.last ? 1 : 0)) }
    }
}

/// A tap on existing route geometry must not append an accidental endpoint.
enum RouteEditTarget: Equatable, Sendable {
    case waypoint(UUID)
    case segment(Int)
}

struct RouteProfileSample: Equatable, Sendable {
    var distance: Double
    var point: RoutePoint
    var breakBefore: Bool
    var unknownBefore: Bool
    var gradientPercent: Double? = nil
}

/// Transfer bytes for immutable assets, distinct from saved size and render memory.
struct AreaDownloadEstimate: Equatable, Sendable {
    var totalBytes: Int64
    var downloadBytes: Int64
    var cachedBytes: Int64 { max(0, totalBytes - downloadBytes) }
}

struct SourceAsset: Codable, Hashable, Sendable {
    var file: String
    var byteCount: Int64
    var sha256: String
    var remoteFile: String? = nil
    var byteOffset: Int64? = nil
}

extension RegionManifest {
    func tilePoint(u: Double, v: Double) -> GeoPoint { grid?.point(u: u, v: v, in: bounds) ?? bounds.point(u: u, v: v) }
    func tileUV(_ point: GeoPoint) -> (u: Double, v: Double) { grid?.uv(point, in: bounds) ?? bounds.uv(point) }
}
