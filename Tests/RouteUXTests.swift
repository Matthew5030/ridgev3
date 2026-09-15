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
        for area in [GeoBounds(minLatitude: 53, minLongitude: -4.1, maxLatitude: 53.08, maxLongitude: -4.09),
                     GeoBounds(minLatitude: 53, minLongitude: -4.1, maxLatitude: 53.001, maxLongitude: -3.9)] {
            let fitted = area.libraryPreviewBounds(aspect: 1.5)
            try check(fitted.contains(area.point(u: 0, v: 0)) && fitted.contains(area.point(u: 1, v: 1)), "Thumbnail includes the full route, even for narrow or wide bounds")
            try check(abs(fitted.widthMeters / fitted.depthMeters - 1.5) < 0.001, "Map preview preserves physical proportions at UK latitudes")
            let center = fitted.uv(area.center)
            try check(abs(center.u - 0.5) < 0.001 && abs(center.v - 0.5) < 0.001, "Route stays centred in its map preview")
        }
        let singlePoint = GeoBounds(minLatitude: 53, minLongitude: -4, maxLatitude: 53, maxLongitude: -4).libraryPreviewBounds(aspect: 1.5)
        try check(singlePoint.isValid && singlePoint.depthMeters >= 399, "A one-point draft has a useful nonzero preview extent")
        let square = GeoBounds(minLatitude: 53, minLongitude: -4.1, maxLatitude: 53.06, maxLongitude: -4)
        let cover = square.libraryPreviewBounds(aspect: 1.5, padding: 1, cropToFill: true)
        try check(square.contains(cover.point(u: 0, v: 0)) && square.contains(cover.point(u: 1, v: 1)), "Area cover crops within available map coverage instead of adding blank sidebars")
        try check(abs(cover.widthMeters / cover.depthMeters - 1.5) < 0.001, "Area cover crops without distorting the map")
        print("PASS route inspection: \(checks) assertions")
    }
}
