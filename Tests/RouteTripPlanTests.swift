import Foundation

@main struct RouteTripPlanTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "RouteTripPlanTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let statistics = RouteStatistics(distanceMeters: 4000, ascentMeters: 600, descentMeters: 100,
                                         estimatedMinutes: 120, hasElevation: true, hasCompleteElevation: true, segmentCount: 1)
        var plan = RouteTripPlan()
        try check(plan.totalMinutes(for: statistics) == 120, "Default pace retains the existing distance-plus-ascent estimate")
        plan.walkingKilometersPerHour = 2
        try check(plan.walkingMinutes(for: statistics) == 180, "Slower walking changes distance time, without changing the climbing allowance")
        plan.walkingKilometersPerHour = 6; plan.breakMinutes = 20
        try check(plan.totalMinutes(for: statistics) == 120, "Breaks are added once to the whole walk")
        try check(plan.walkingMinutes(for: .empty) == 0, "Empty drafts never invent walking time")
        let start = Date(timeIntervalSince1970: 1_792_967_400)
        plan.departure = start
        try check(plan.finish(for: statistics) == start.addingTimeInterval(7200), "Finish time includes walking, ascent and breaks across date boundaries")
        plan.departure = nil
        try check(plan.finish(for: statistics) == nil, "No start time means no invented finish time")
        try check(RouteTripPlan.duration(59.1) == "1h 0m" && RouteTripPlan.duration(0) == "0m", "Display rounds up once, including hour boundaries")
        try check(RouteTripPlan.duration(.infinity) == "—", "Non-finite durations cannot trap during formatting")
        plan.checklist[0].completed = true
        plan.addItem("  Charge headtorch  ")
        try check(plan.checklist.last?.title == "Charge headtorch", "Custom checklist titles are trimmed")
        let count = plan.checklist.count
        plan.addItem("\n \t")
        try check(plan.checklist.count == count, "Empty checklist entries are ignored")
        let encoded = try JSONEncoder().encode(plan)
        try check(RouteTripPlan.decode(encoded) == plan, "Timing, custom items and ticked items survive a save and reload")
        try check(RouteTripPlan.decode(Data()) == RouteTripPlan(), "New routes receive unticked defaults")
        try check(RouteTripPlan.storageKey(for: UUID()) != RouteTripPlan.storageKey(for: UUID()), "Plans for separate routes use separate storage keys")
        try check(RouteTripPlan.decode(Data("broken".utf8)) == nil, "Damaged preferences are detectable without overwriting them")
        var unsupported = plan; unsupported.version = 2
        try check(RouteTripPlan.decode(try JSONEncoder().encode(unsupported)) == nil, "Unknown plan versions remain unread instead of silently resetting")
        var invalid = plan; invalid.walkingKilometersPerHour = 0
        try check(RouteTripPlan.decode(try JSONEncoder().encode(invalid)) == nil, "Zero walking speed is rejected")
        invalid = plan; invalid.breakMinutes = -1
        try check(RouteTripPlan.decode(try JSONEncoder().encode(invalid)) == nil, "Negative break times are rejected")
        invalid = plan; invalid.checklist.append(invalid.checklist[0])
        try check(RouteTripPlan.decode(try JSONEncoder().encode(invalid)) == nil, "Duplicate checklist IDs are rejected")
        while plan.checklist.count < 40 { plan.addItem("Item") }
        plan.addItem("Too many")
        try check(plan.checklist.count == 40, "Checklist storage stays bounded")

        func point(_ i: Int, _ height: Double?) -> RoutePoint {
            .init(coordinate: .init(latitude: 53 + Double(i) * 0.001, longitude: -4), elevation: height)
        }
        let a = point(0, 0), b = point(1, 10), c = point(2, 5)
        let route = RidgeRoute(name: "Ridge walk", regionID: "test", waypoints: [
            .init(point: a, name: "Car park"), .init(point: b, name: "Summit"), .init(point: c)
        ], segments: [.init(points: [a,b], mode: "paths"), .init(points: [b,c], mode: "paths")], notes: "Meet at nine")
        let brief = RouteTripBrief(route: route)
        try check(brief.legs.count == 2 && brief.legs[0].from == "Car park" && brief.legs[0].to == "Summit" && brief.legs[1].to == "Finish", "Planning legs retain their named waypoint endpoints")
        try check(abs(brief.legs.reduce(0) { $0 + $1.statistics.distanceMeters } - brief.statistics.distanceMeters) < 0.001, "Leg distances sum to the route without duplicating junctions")
        try check(brief.legs[0].statistics.ascentMeters == 10 && brief.legs[1].statistics.descentMeters == 5, "Leg ascent and descent follow the walking direction")
        try check(!brief.returnsToStart, "A one-way route is not labelled a loop")
        var loop = route; loop.segments.append(.init(points: [c,a], mode: "direct"))
        try check(RouteTripBrief(route: loop).returnsToStart, "A route returning to its start is recognized")
        var imported = route
        imported.waypoints = []
        imported.segments = [.init(points: [a,b], mode: "imported"), .init(points: [point(100, nil),point(101, nil)], mode: "imported")]
        let tracks = RouteTripBrief(route: imported)
        try check(tracks.legs[1].startsNewTrack && tracks.legs[1].to == "Track section 2", "Disconnected imported tracks are identified as separate sections")
        try check(abs(tracks.statistics.distanceMeters - a.coordinate.distance(to: b.coordinate) - point(100,nil).coordinate.distance(to: point(101,nil).coordinate)) < 0.001, "An imported gap adds no fictitious walking distance")
        try check(!tracks.statistics.hasCompleteElevation && tracks.legs[1].statistics.ascentMeters == 0, "Missing elevations are reported instead of inventing climbing")
        imported.waypoints = route.waypoints
        try check(RouteTripBrief(route: imported).legs[0].from == "Start", "Unrelated GPX waypoints are not assigned to track legs by count alone")
        let empty = RidgeRoute(name: "Draft", regionID: "test")
        try check(RouteTripBrief(route: empty).legs.isEmpty && RouteTripBrief(route: empty).statistics.distanceMeters == 0, "An empty draft produces an empty itinerary")
        let direct = RidgeRoute(name: "Direct", regionID: "test", waypoints: route.waypoints)
        try check(RouteTripBrief(route: direct).legs.count == 1, "Waypoint-only legacy routes keep their complete direct geometry")
        try check(route.notes == "Meet at nine" && route.segments.count == 2, "Brief calculations never mutate the saved route")

        var one = route, two = route, three = route
        one.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!; one.name = "Walk 10"; one.modifiedAt = .init(timeIntervalSince1970: 1)
        two.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!; two.name = "Walk 2"; two.modifiedAt = .init(timeIntervalSince1970: 3)
        three.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!; three.name = "Alpha"; three.modifiedAt = .init(timeIntervalSince1970: 2)
        let routes = [one,two,three], distances = [one.id:300.0,two.id:100.0,three.id:200.0]
        try check(RouteLibraryOrder.shortest.sorted(routes, distances: distances).map(\.id) == [two.id,three.id,one.id], "Shortest-first sorting uses measured distance")
        try check(RouteLibraryOrder.longest.sorted(routes, distances: distances).map(\.id) == [one.id,three.id,two.id], "Longest-first sorting reverses distance order")
        try check(RouteLibraryOrder.recent.sorted(routes, distances: distances).map(\.id) == [two.id,three.id,one.id], "Recent sorting uses modification dates")
        try check(RouteLibraryOrder.name.sorted(routes, distances: distances).map(\.id) == [three.id,two.id,one.id], "Name sorting handles numbered walks naturally")
        try check(RouteLibraryOrder.longest.sorted(routes, distances: [two.id:100]).first?.id == two.id, "Routes still calculating their distance stay after known results")
        print("PASS walk planning: \(checks) assertions")
    }
}
