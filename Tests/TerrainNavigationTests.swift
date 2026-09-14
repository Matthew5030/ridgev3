import Foundation

@main
struct TerrainNavigationTests {
    static func main() {
        let primary = GeoBounds(minLatitude: 53.06, minLongitude: -4.08, maxLatitude: 53.08, maxLongitude: -4.05)
        let extended = GeoBounds(minLatitude: 53.02, minLongitude: -4.15, maxLatitude: 53.11, maxLongitude: -4.0)
        let coverage = GeoBounds(minLatitude: 52.97, minLongitude: -4.22, maxLatitude: 53.17, maxLongitude: -3.94)
        let frames = [TerrainNavigationFrame(bounds: primary, minimumElevationMeters: 212),
                      TerrainNavigationFrame(bounds: extended, minimumElevationMeters: -4)]
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }

        // A replacement mesh changes its origin, scale and minimum elevation.
        // The geographic camera must remain stable through either local frame,
        // including when its target lies in the surrounding terrain.
        for point in [primary.center, extended.center, GeoPoint(latitude: 53.13, longitude: -4.17)] {
            for elevation in [-3.0, 512, 1_086] {
                let source = TerrainCameraPose(target: point, targetElevationMeters: elevation,
                                               yaw: -0.382, pitch: 20 * .pi / 180, distanceMeters: 3_725)
                for frame in frames {
                    let target = frame.target(for: source)!
                    let restored = frame.pose(target: target, yaw: source.yaw, pitch: source.pitch,
                                              distance: Float(source.distanceMeters / frame.metersPerUnit))
                    check(restored.target.distance(to: source.target) < 0.005, "Geographic target changed during frame conversion")
                    check(abs(restored.targetElevationMeters - source.targetElevationMeters) < 0.001, "Elevation datum changed during frame conversion")
                    check(abs(restored.distanceMeters - source.distanceMeters) < 0.001, "Camera distance changed during frame conversion")
                    check(restored.yaw == source.yaw && restored.pitch == source.pitch, "Orientation changed during frame conversion")
                }
            }
        }

        // Panning reaches context on every side while retaining finite coverage.
        for frame in frames {
            for x: Float in [-1_000, 0, 1_000] {
                for z: Float in [-1_000, 0, 1_000] {
                    let clamped = frame.clampedTarget(SIMD3(x, 0.1, z), coverage: coverage)
                    let pose = frame.pose(target: clamped, yaw: 0, pitch: 0.4, distance: 1)
                    check(coverage.contains(pose.target), "Pan escaped finite loaded coverage")
                    check(clamped.y == 0.1, "Horizontal pan altered target elevation")
                }
            }
            let outsidePrimary = TerrainCameraPose(target: GeoPoint(latitude: 53.13, longitude: -4.17),
                                                    targetElevationMeters: 600, yaw: 0, pitch: 0.4, distanceMeters: 1_000)
            let local = frame.target(for: outsidePrimary)!
            let clamped = frame.clampedTarget(local, coverage: coverage)
            check(clamped == local, "Pan remains restricted to primary bounds")
        }

        var invalid = TerrainCameraPose(target: primary.center, targetElevationMeters: 600,
                                        yaw: 0, pitch: 0.4, distanceMeters: 1_000)
        invalid.distanceMeters = .nan
        check(frames[0].target(for: invalid) == nil, "NaN distance accepted")
        invalid.distanceMeters = 1_000
        invalid.targetElevationMeters = .greatestFiniteMagnitude
        check(frames[0].target(for: invalid) == nil, "Overflowing local target accepted")
        invalid.targetElevationMeters = 600
        invalid.target.latitude = .infinity
        check(frames[0].target(for: invalid) == nil, "Invalid geographic target accepted")

        // Exact primary-edge rays can accumulate a few Float ulps when their
        // world hit is reconstructed. They must not offer a spurious extension.
        let frame = frames[0]
        for uv in [SIMD2<Float>(-0.0000005, 0.5), SIMD2(1.0000005, 0.5),
                   SIMD2(0.5, -0.0000005), SIMD2(0.5, 1.0000005),
                   SIMD2(-0.0000005, -0.0000005), SIMD2(1.0000005, 1.0000005)] {
            check(primary.contains(frame.pickedPoint(u: uv.x, v: uv.y)), "Float edge roundoff triggered an extension")
        }
        for uv in [SIMD2<Float>(-0.000002, 0.5), SIMD2(1.000002, 0.5),
                   SIMD2(0.5, -0.000002), SIMD2(0.5, 1.000002)] {
            check(!primary.contains(frame.pickedPoint(u: uv.x, v: uv.y)), "A context pick beyond edge tolerance was clamped into planning terrain")
        }
        let distant = SIMD2<Float>(-2, 3)
        check(frame.pickedPoint(u: distant.x, v: distant.y) == primary.point(u: -2, v: 3), "Distant context pick changed during edge canonicalization")
        check(frame.pickedPoint(u: 0.25, v: 0.75) == primary.point(u: 0.25, v: 0.75), "Interior planning pick changed during edge canonicalization")

        print("PASS \(assertions) geographic pose, datum, distance, orientation and finite pan checks")
    }
}
