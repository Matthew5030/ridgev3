import Foundation

/// Personal walking plans are separate from route geometry and preview speed.
struct RouteTripPlan: Codable, Equatable, Sendable {
    struct ChecklistItem: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var title: String
        var completed = false
    }
    var version = 1
    var walkingKilometersPerHour = 4.0
    var breakMinutes = 0
    var departure: Date?
    var checklist: [ChecklistItem] = [
        .init(id: "weather", title: "Check the weather"),
        .init(id: "food", title: "Pack food and water"),
        .init(id: "layers", title: "Pack layers and waterproofs"),
        .init(id: "share", title: "Share the plan with someone")
    ]

    static func storageKey(for id: UUID) -> String { "ridge.tripPlan.\(id.uuidString)" }
    static func decode(_ data: Data) -> RouteTripPlan? {
        if data.isEmpty { return RouteTripPlan() }
        guard data.count <= 64_000, let plan = try? JSONDecoder().decode(Self.self, from: data),
              plan.version == 1, plan.walkingKilometersPerHour.isFinite,
              (2...6).contains(plan.walkingKilometersPerHour), (0...180).contains(plan.breakMinutes),
              plan.departure?.timeIntervalSince1970.isFinite != false,
              plan.checklist.count <= 40, Set(plan.checklist.map(\.id)).count == plan.checklist.count,
              plan.checklist.allSatisfy({ !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 120 }) else { return nil }
        return plan
    }
    func walkingMinutes(for statistics: RouteStatistics) -> Double {
        statistics.distanceMeters / (walkingKilometersPerHour * 1000) * 60 + statistics.ascentMeters / 600 * 60
    }
    func totalMinutes(for statistics: RouteStatistics) -> Double { walkingMinutes(for: statistics) + Double(breakMinutes) }
    func finish(for statistics: RouteStatistics) -> Date? { departure?.addingTimeInterval(totalMinutes(for: statistics) * 60) }

    mutating func addItem(_ title: String) {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !title.isEmpty, checklist.count < 40 else { return }
        checklist.append(.init(id: UUID().uuidString, title: title))
    }
    static func duration(_ minutes: Double) -> String {
        guard minutes.isFinite, minutes >= 0 else { return "—" }
        let value = Int(min(10_000_000, minutes.rounded(.up)))
        return value >= 60 ? "\(value / 60)h \(value % 60)m" : "\(value)m"
    }
}

struct RouteTripBrief: Sendable {
    struct Leg: Identifiable, Sendable {
        var id: Int
        var from: String
        var to: String
        var statistics: RouteStatistics
        var startsNewTrack: Bool
    }
    var statistics: RouteStatistics
    var legs: [Leg]
    var returnsToStart: Bool

    init(route: RidgeRoute) {
        statistics = RouteEngine.statistics(for: route)
        let segments = route.segments.isEmpty ? [RouteSegment(points: route.points, mode: "direct")] : route.segments
        let linkedWaypoints = !route.segments.isEmpty && route.waypoints.count == segments.count + 1
            && zip(segments.indices, segments).allSatisfy { i, segment in
                guard let first = segment.points.first, let last = segment.points.last else { return false }
                return first.coordinate.distance(to: route.waypoints[i].point.coordinate) <= 2
                    && last.coordinate.distance(to: route.waypoints[i + 1].point.coordinate) <= 2
            }
        legs = segments.enumerated().compactMap { index, segment in
            guard segment.points.count > 1 else { return nil }
            var legRoute = route
            legRoute.waypoints = []; legRoute.segments = [segment]
            let from = linkedWaypoints ? Self.waypointName(route.waypoints[index], index: index, count: route.waypoints.count) : "Start"
            let to = linkedWaypoints ? Self.waypointName(route.waypoints[index + 1], index: index + 1, count: route.waypoints.count) : segments.count == 1 ? "Finish" : "Track section \(index + 1)"
            let previous = index > 0 ? segments[index - 1].points.last : nil
            let separate = previous.map { $0.coordinate.distance(to: segment.points[0].coordinate) > 2 } ?? false
            return Leg(id: index, from: from, to: to, statistics: RouteEngine.statistics(for: legRoute), startsNewTrack: separate)
        }
        if let first = route.points.first, let last = route.points.last, statistics.distanceMeters > 50 {
            returnsToStart = first.coordinate.distance(to: last.coordinate) <= 25
        } else { returnsToStart = false }
    }
    private static func waypointName(_ waypoint: RouteWaypoint, index: Int, count: Int) -> String {
        if let name = waypoint.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return index == 0 ? "Start" : index == count - 1 ? "Finish" : "Waypoint \(index + 1)"
    }
}

enum RouteLibraryOrder: String, CaseIterable, Identifiable {
    case recent, name, shortest, longest
    var id: Self { self }
    var title: String {
        switch self {
        case .recent: "Recently edited"
        case .name: "Name A–Z"
        case .shortest: "Shortest first"
        case .longest: "Longest first"
        }
    }
    func sorted(_ routes: [RidgeRoute], distances: [UUID: Double]) -> [RidgeRoute] {
        routes.sorted { a, b in
            switch self {
            case .recent: if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
            case .name:
                let order = a.name.localizedStandardCompare(b.name)
                if order != .orderedSame { return order == .orderedAscending }
            case .shortest, .longest:
                if (distances[a.id] == nil) != (distances[b.id] == nil) { return distances[a.id] != nil }
                let x = distances[a.id] ?? .infinity, y = distances[b.id] ?? .infinity
                if x != y { return self == .shortest ? x < y : x > y }
            }
            return a.id.uuidString < b.id.uuidString
        }
    }
}
