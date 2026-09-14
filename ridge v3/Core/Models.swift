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
    var totalBytes: Int64 {
        let layers = horizon?.layers ?? []
        let maps = cartography.map { [$0.totalBytes] }
            ?? (textures + (detailTextures ?? []) + layers.flatMap(\.textures)).map(\.byteCount)
        let sizes = (levels + layers.flatMap(\.levels)).map(\.byteCount) + maps + [graphByteCount ?? 0]
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
    func elevation(at point: GeoPoint) -> Double? {
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
