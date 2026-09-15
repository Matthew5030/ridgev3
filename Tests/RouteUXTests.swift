import Foundation

@main struct RouteUXTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            checks += 1
            if !value { throw RidgeError.message(message) }
        }
        func point(_ index: Int, elevation: Double?) -> RoutePoint {
            RoutePoint(coordinate: GeoPoint(latitude: 53 + Double(index) * 0.0001, longitude: -4), elevation: elevation)
        }
        let uphill = (0..<10).map { point($0, elevation: Double($0) * 10) }
        let samples = RouteEngine.elevationProfile([RouteSegment(points: uphill, mode: "direct")])
        let expected = 30 / uphill[0].coordinate.distance(to: uphill[3].coordinate) * 100
        try check(abs(samples[3].gradientPercent! - expected) < 0.01, "Gradient uses measured distance over a useful interval")
        try check(samples.first?.gradientPercent == nil, "The start never invents a gradient")
        try check(abs(samples.last!.distance - uphill[0].coordinate.distance(to: uphill[9].coordinate)) < 0.01, "Profile retains travelled distance")
        var gap = uphill
        gap[3].elevation = nil
        let partial = RouteEngine.elevationProfile([RouteSegment(points: gap, mode: "direct")])
        try check(partial[3].point.elevation == nil && partial[4].unknownBefore && partial[4].breakBefore, "Unknown heights interrupt the drawn line")
        try check(partial[4].gradientPercent == nil && partial[7].gradientPercent != nil, "Gradient resumes only after enough known terrain")
        let disconnected = RouteEngine.elevationProfile([RouteSegment(points: Array(uphill.prefix(5)), mode: "imported"), RouteSegment(points: Array(uphill.suffix(5)), mode: "imported")])
        try check(disconnected[5].breakBefore && disconnected[5].gradientPercent == nil, "Imported segment breaks remain disconnected")
        let large = (0..<50_000).map { RoutePoint(coordinate: GeoPoint(latitude: 53 + Double($0) * 0.000001, longitude: -4), elevation: Double($0 % 100)) }
        let bounded = RouteEngine.elevationProfile([RouteSegment(points: large, mode: "imported")])
        try check(bounded.count <= 1002 && bounded.first?.point == large.first && bounded.last?.point == large.last, "Large profiles remain bounded and retain endpoints")
        try check(RouteEngine.elevationProfile([]).isEmpty, "Empty drafts have an empty profile")
        print("PASS route inspection: \(checks) assertions")
    }
}
