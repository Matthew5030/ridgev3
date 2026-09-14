import Foundation

/// Stored independently of terrain packs and route documents.
enum TerrainGestureStyle: String, CaseIterable, Identifiable {
    case moveWithOneFinger, rotateWithOneFinger
    static let defaultsKey = "terrainGestureStyle"
    var id: String { rawValue }
    var moveTouches: Int { self == .moveWithOneFinger ? 1 : 2 }
    var rotateTouches: Int { self == .moveWithOneFinger ? 2 : 1 }
    var title: String { self == .moveWithOneFinger ? "One finger moves" : "One finger rotates" }
    var subtitle: String { self == .moveWithOneFinger ? "Two fingers rotate and tilt the terrain" : "Two fingers move across the map" }
    var shortGuide: String { self == .moveWithOneFinger ? "Drag to move · Two fingers to rotate · Pinch to zoom" : "Drag to rotate · Two fingers to move · Pinch to zoom" }
    var guide: String { self == .moveWithOneFinger ? "One finger moves across the map. Two fingers rotate and tilt the terrain. Pinch to zoom. Double-tap to fit the whole area." : "One finger rotates and tilts the terrain. Two fingers move across the map. Pinch to zoom. Double-tap to fit the whole area." }
}

/// Geographic camera state survives a new mesh's origin, scale and elevation datum.
struct TerrainCameraPose: Equatable, Sendable {
    var target: GeoPoint
    var targetElevationMeters: Double
    var yaw: Float
    var pitch: Float
    var distanceMeters: Double

    var isValid: Bool {
        target.isValid && targetElevationMeters.isFinite && yaw.isFinite && pitch.isFinite
            && distanceMeters.isFinite && distanceMeters > 0
    }
}

struct TerrainNavigationState: Equatable, Sendable {
    var pose: TerrainCameraPose
    var spacing: Int?
    var insidePlanningArea: Bool
    var viewedPoint: GeoPoint? = nil
}

/// The renderer's normalized coordinates are local to a saved area. Conversion
/// through geographic metres keeps a camera fixed when that area is extended.
struct TerrainNavigationFrame: Sendable {
    var bounds: GeoBounds
    var minimumElevationMeters: Double
    var metersPerUnit: Double { max(bounds.widthMeters, bounds.depthMeters) }

    /// A ray reconstructed in Float may land a few ulps beyond a shared edge.
    /// Canonicalize only that tiny boundary interval, preserving context picks.
    func pickedPoint(u: Float, v: Float) -> GeoPoint {
        func canonical(_ value: Float) -> Double {
            if abs(value) <= 0.000001 { return 0 }
            if abs(value - 1) <= 0.000001 { return 1 }
            return Double(value)
        }
        return bounds.point(u: canonical(u), v: canonical(v))
    }

    func pose(target: SIMD3<Float>, yaw: Float, pitch: Float, distance: Float) -> TerrainCameraPose {
        let width = bounds.widthMeters / metersPerUnit, depth = bounds.depthMeters / metersPerUnit
        return TerrainCameraPose(target: bounds.point(u: Double(target.x) / width + 0.5, v: Double(target.z) / depth + 0.5),
                                 targetElevationMeters: minimumElevationMeters + Double(target.y) * metersPerUnit,
                                 yaw: yaw, pitch: pitch, distanceMeters: Double(distance) * metersPerUnit)
    }

    func target(for pose: TerrainCameraPose) -> SIMD3<Float>? {
        guard bounds.isValid, pose.isValid, minimumElevationMeters.isFinite else { return nil }
        let uv = bounds.uv(pose.target)
        let result = SIMD3(Float((uv.u - 0.5) * bounds.widthMeters / metersPerUnit),
                          Float((pose.targetElevationMeters - minimumElevationMeters) / metersPerUnit),
                          Float((uv.v - 0.5) * bounds.depthMeters / metersPerUnit))
        return result.x.isFinite && result.y.isFinite && result.z.isFinite ? result : nil
    }

    func clampedTarget(_ target: SIMD3<Float>, coverage: GeoBounds) -> SIMD3<Float> {
        let width = Float(bounds.widthMeters / metersPerUnit), depth = Float(bounds.depthMeters / metersPerUnit)
        let a = bounds.uv(GeoPoint(latitude: coverage.maxLatitude, longitude: coverage.minLongitude))
        let b = bounds.uv(GeoPoint(latitude: coverage.minLatitude, longitude: coverage.maxLongitude))
        let marginX = min(width * 0.02, Float(b.u - a.u) * width * 0.01)
        let marginZ = min(depth * 0.02, Float(b.v - a.v) * depth * 0.01)
        return SIMD3(min(Float(b.u - 0.5) * width - marginX, max(Float(a.u - 0.5) * width + marginX, target.x)),
                     target.y,
                     min(Float(b.v - 0.5) * depth - marginZ, max(Float(a.v - 0.5) * depth + marginZ, target.z)))
    }
}

/// A new identifier deliberately triggers the same camera action again.
struct TerrainCameraCommand: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case home, north, overhead, zoomIn, zoomOut
        case focus(GeoPoint)
        case restore(TerrainCameraPose)
    }
    var action: Action
    var id: UUID
    init(action: Action = .home, id: UUID = UUID()) { self.action = action; self.id = id }
}
