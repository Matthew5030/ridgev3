import Foundation

enum RoutePlanningMode: String, CaseIterable, Identifiable, Sendable {
    case paths, direct
    var id: String { rawValue }
    var title: String { self == .paths ? "Follow paths" : "Direct line" }
}

struct RouteStatistics: Sendable {
    var distanceMeters: Double
    var ascentMeters: Double
    var descentMeters: Double
    var estimatedMinutes: Double
    var hasElevation: Bool
    var hasCompleteElevation: Bool
    var segmentCount: Int
    static let empty = RouteStatistics(distanceMeters: 0, ascentMeters: 0, descentMeters: 0, estimatedMinutes: 0, hasElevation: false, hasCompleteElevation: false, segmentCount: 0)
}

enum RouteError: LocalizedError, Equatable {
    case invalidCoordinate
    case outsideArea
    case missingElevation
    case noWalkingGraph
    case invalidGraph
    case noNearbyPath
    case disconnectedPaths
    case pathStartMismatch
    case tooManyPoints
    case invalidFile(String)
    case missingRoute
    case invalidName
    var errorDescription: String? {
        switch self {
        case .invalidCoordinate: return "This route contains an invalid map coordinate."
        case .outsideArea: return "This point is outside the open terrain. Select a larger area to continue."
        case .missingElevation: return "There is a gap in the terrain along this line. Choose a different point."
        case .noWalkingGraph: return "This area has no offline walking network. Use Direct line to draw a manual route."
        case .invalidGraph: return "This area's walking network is damaged or too large to open safely."
        case .noNearbyPath: return "There is no eligible walking path within 150 metres. Tap closer to a path or choose Direct line."
        case .disconnectedPaths: return "These paths do not connect in the downloaded walking network. Choose another point or use Direct line."
        case .pathStartMismatch: return "Your last point is off the walking network. Use Direct line to add a connector to a mapped path before switching to Follow paths."
        case .tooManyPoints: return "This route has too many points. Divide it into smaller routes."
        case .invalidFile(let message): return message
        case .missingRoute: return "This saved route could not be found."
        case .invalidName: return "Give the route a name of up to 160 characters."
        }
    }
}

/// Pure, bounded route calculations. Run these on a background task for large networks.
enum RouteEngine {
    static let maximumRoutePoints = 100_000
    static let maximumGraphNodes = 250_000
    static let maximumGraphEdges = 750_000

    /// Resolve a GPX against today's local catalogue, including packs added after import.
    /// Installed coverage takes priority; an existing valid association breaks ties.
    static func containingRegion(for route: RidgeRoute, in manifests: [RegionManifest], installedIDs: Set<String>) -> RegionManifest? {
        let points = route.points
        guard !points.isEmpty, points.allSatisfy({ $0.coordinate.isValid }) else { return nil }
        let minLatitude = points.map(\.coordinate.latitude).min()!, maxLatitude = points.map(\.coordinate.latitude).max()!
        let minLongitude = points.map(\.coordinate.longitude).min()!, maxLongitude = points.map(\.coordinate.longitude).max()!
        return manifests.filter { manifest in
            let bounds = manifest.bounds
            return bounds.isValid && bounds.minLatitude <= minLatitude && bounds.maxLatitude >= maxLatitude
                && bounds.minLongitude <= minLongitude && bounds.maxLongitude >= maxLongitude
        }.sorted { lhs, rhs in
            let a = installedIDs.contains(lhs.id), b = installedIDs.contains(rhs.id)
            if a != b { return a }
            if (lhs.id == route.regionID) != (rhs.id == route.regionID) { return lhs.id == route.regionID }
            if lhs.bounds.areaSquareKilometers != rhs.bounds.areaSquareKilometers { return lhs.bounds.areaSquareKilometers < rhs.bounds.areaSquareKilometers }
            return lhs.id < rhs.id
        }.first
    }

    /// Split at exact coverage crossings, including a leg that exits and re-enters.
    static func coverageSections(from: GeoPoint, to: GeoPoint, bounds: GeoBounds) -> [(from: GeoPoint, to: GeoPoint, detailed: Bool)] {
        guard from.isValid, to.isValid, bounds.isValid else { return [] }
        let a = bounds.uv(from), b = bounds.uv(to)
        var cuts = [0.0, 1.0]
        for (start, end) in [(a.u, b.u), (a.v, b.v)] where abs(end - start) > 1e-12 {
            for edge in [0.0, 1.0] {
                let t = (edge - start) / (end - start)
                if t > 0 && t < 1 { cuts.append(t) }
            }
        }
        cuts = Array(Set(cuts)).sorted()
        func point(_ t: Double) -> GeoPoint {
            var u = a.u + (b.u - a.u) * t, v = a.v + (b.v - a.v) * t
            for edge in [0.0, 1.0] {
                if abs(u - edge) < 1e-10 { u = edge }
                if abs(v - edge) < 1e-10 { v = edge }
            }
            return bounds.point(u: u, v: v)
        }
        return zip(cuts, cuts.dropFirst()).map { (point($0), point($1), bounds.contains(point(($0 + $1) / 2))) }
    }

    /// Overview legs are persisted manual sketches, never inferred walking paths.
    static func planningSegment(from: GeoPoint, to: GeoPoint, mode: RoutePlanningMode,
                                terrain: LoadedTerrain) throws -> RouteSegment {
        guard from.isValid, to.isValid else { throw RouteError.invalidCoordinate }
        if terrain.manifest.bounds.contains(from), terrain.manifest.bounds.contains(to) {
            return try segment(from: from, to: to, mode: mode, terrain: terrain)
        }
        return RouteSegment(points: [RoutePoint(coordinate: from, elevation: terrain.elevation(at: from)),
                                     RoutePoint(coordinate: to, elevation: terrain.elevation(at: to))], mode: "overview")
    }

    static func overviewPoints(in route: RidgeRoute?, bounds: GeoBounds) -> [GeoPoint] {
        guard let route else { return [] }
        return (route.points + route.waypoints.map(\.point)).map(\.coordinate).filter { !bounds.contains($0) }
    }

    /// Downloading detail does not change a sketched line into a claimed path.
    static func resolveOverview(_ route: RidgeRoute, terrain: LoadedTerrain) throws -> RidgeRoute {
        var updated = route
        for i in updated.segments.indices where updated.segments[i].mode == "overview" {
            let points = updated.segments[i].points
            guard let first = points.first, let last = points.last,
                  points.allSatisfy({ terrain.manifest.bounds.contains($0.coordinate) }) else { continue }
            updated.segments[i] = try directSegment(from: first.coordinate, to: last.coordinate, terrain: terrain)
        }
        for i in updated.waypoints.indices where updated.waypoints[i].point.elevation == nil {
            if let elevation = terrain.elevation(at: updated.waypoints[i].point.coordinate) {
                updated.waypoints[i].point.elevation = elevation
            }
        }
        return updated
    }

    static func segment(from: GeoPoint, to: GeoPoint, mode: RoutePlanningMode,
                        terrain: LoadedTerrain, snapDistance: Double = 150) throws -> RouteSegment {
        try validateTerrain(terrain)
        guard from.isValid, to.isValid else { throw RouteError.invalidCoordinate }
        guard terrain.manifest.bounds.contains(from), terrain.manifest.bounds.contains(to) else { throw RouteError.outsideArea }
        switch mode {
        case .direct:
            return try directSegment(from: from, to: to, terrain: terrain)
        case .paths:
            guard let graph = terrain.graph else { throw RouteError.noWalkingGraph }
            let raw = try walkingSegment(from: from, to: to, graph: graph, snapDistance: snapDistance)
            guard let first = raw.points.first, from.distance(to: first.coordinate) <= 1 else { throw RouteError.pathStartMismatch }
            return RouteSegment(points: try terrainPoints(along: raw.points.map(\.coordinate), terrain: terrain), mode: mode.rawValue)
        }
    }

    static func snap(_ coordinate: GeoPoint, terrain: LoadedTerrain, maxDistance: Double = 150) throws -> RoutePoint {
        try validateTerrain(terrain)
        guard coordinate.isValid else { throw RouteError.invalidCoordinate }
        guard terrain.manifest.bounds.contains(coordinate) else { throw RouteError.outsideArea }
        guard let graph = terrain.graph else { throw RouteError.noWalkingGraph }
        let prepared = try PreparedGraph(graph)
        let snapped = try nearestEdge(to: coordinate, graph: prepared, maxDistance: maxDistance)
        guard let elevation = terrain.elevation(at: snapped.point.coordinate) else { throw RouteError.missingElevation }
        return RoutePoint(coordinate: snapped.point.coordinate, elevation: elevation)
    }

    static func directSegment(from: GeoPoint, to: GeoPoint, terrain: LoadedTerrain) throws -> RouteSegment {
        try validateTerrain(terrain)
        return RouteSegment(points: try terrainPoints(along: [from, to], terrain: terrain), mode: RoutePlanningMode.direct.rawValue)
    }

    /// Edge snapping uses virtual endpoints, preserving one-way restrictions even halfway along an edge.
    static func walkingSegment(from: GeoPoint, to: GeoPoint, graph: WalkingGraph, snapDistance: Double = 150) throws -> RouteSegment {
        guard from.isValid, to.isValid else { throw RouteError.invalidCoordinate }
        let prepared = try PreparedGraph(graph)
        let start = try nearestEdge(to: from, graph: prepared, maxDistance: snapDistance)
        let finish = try nearestEdge(to: to, graph: prepared, maxDistance: snapDistance)
        let a = prepared.edges[start.edgeIndex], b = prepared.edges[finish.edgeIndex]
        var bestCost = Double.infinity
        var bestNode: Int?
        var sameEdge = false
        if start.edgeIndex == finish.edgeIndex, a.bidirectional || finish.fraction >= start.fraction {
            bestCost = abs(finish.fraction - start.fraction) * a.distance
            sameEdge = true
        }
        var sources: [(Int, Double)] = [(a.to, (1 - start.fraction) * a.distance)]
        if a.bidirectional || start.fraction < 0.0000001 { sources.append((a.from, start.fraction * a.distance)) }
        var targets: [Int: Double] = [b.from: finish.fraction * b.distance]
        if b.bidirectional || finish.fraction > 0.9999999 { targets[b.to] = (1 - finish.fraction) * b.distance }
        var distances: [Int: Double] = [:]
        var predecessors: [Int: Int] = [:]
        var queue = MinimumQueue()
        for (node, distance) in sources where distance < (distances[node] ?? .infinity) {
            distances[node] = distance
            queue.push(node: node, cost: distance)
        }
        var visited = 0
        while let current = queue.pop() {
            if current.cost > (distances[current.node] ?? .infinity) { continue }
            if current.cost > bestCost { break }
            visited += 1
            if visited % 1024 == 0 { try Task.checkCancellation() }
            if let remaining = targets[current.node], current.cost + remaining < bestCost {
                bestCost = current.cost + remaining
                bestNode = current.node
                sameEdge = false
            }
            for next in prepared.adjacency[current.node] ?? [] {
                let cost = current.cost + next.cost
                if cost < (distances[next.node] ?? .infinity) {
                    distances[next.node] = cost
                    predecessors[next.node] = current.node
                    queue.push(node: next.node, cost: cost)
                }
            }
        }
        guard bestCost.isFinite else { throw RouteError.disconnectedPaths }
        if sameEdge { return RouteSegment(points: deduplicated([start.point, finish.point]), mode: RoutePlanningMode.paths.rawValue) }
        guard var node = bestNode else { throw RouteError.disconnectedPaths }
        var chain = [node]
        while let previous = predecessors[node] {
            chain.append(previous)
            node = previous
            guard chain.count <= maximumRoutePoints else { throw RouteError.tooManyPoints }
        }
        let points = [start.point] + chain.reversed().compactMap { prepared.nodes[$0].map { RoutePoint(coordinate: $0.coordinate, elevation: $0.elevation) } } + [finish.point]
        return RouteSegment(points: deduplicated(points), mode: RoutePlanningMode.paths.rawValue)
    }

    static func statistics(for route: RidgeRoute) -> RouteStatistics {
        let segments = route.segments.isEmpty ? [RouteSegment(points: route.waypoints.map(\.point), mode: "direct")] : route.segments
        var stats = RouteStatistics.empty
        var elevationCount = 0, pointCount = 0
        for segment in segments where !segment.points.isEmpty {
            stats.segmentCount += 1
            let points = segment.points
            pointCount += points.count
            elevationCount += points.filter { $0.elevation?.isFinite == true }.count
            // A three-metre hysteresis avoids turning small LiDAR ripples into fictitious ascent.
            // Missing elevations and segment breaks always reset the elevation accumulator.
            var anchor: Double?
            for index in points.indices {
                if index > 0, points[index - 1].coordinate.isValid, points[index].coordinate.isValid {
                    stats.distanceMeters += points[index - 1].coordinate.distance(to: points[index].coordinate)
                }
                guard let height = points[index].elevation, height.isFinite else { anchor = nil; continue }
                if let old = anchor {
                    let difference = height - old
                    if abs(difference) >= 3 {
                        if difference > 0 { stats.ascentMeters += difference } else { stats.descentMeters -= difference }
                        anchor = height
                    }
                } else { anchor = height }
            }
        }
        stats.hasElevation = elevationCount > 0
        stats.hasCompleteElevation = pointCount > 0 && elevationCount == pointCount
        // Planning estimate: 4 km/h plus one hour per 600 m ascent. No live conditions are assumed.
        stats.estimatedMinutes = stats.distanceMeters / 4_000 * 60 + stats.ascentMeters / 600 * 60
        return stats
    }

    static func validate(_ route: RidgeRoute) throws {
        guard !route.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, route.name.count <= 160 else { throw RouteError.invalidName }
        guard route.notes.count <= 100_000, route.segments.count <= 10_000,
              route.waypoints.count <= maximumRoutePoints else { throw RouteError.tooManyPoints }
        var count = route.waypoints.count
        for point in route.waypoints.map(\.point) { try validate(point) }
        for segment in route.segments {
            count += segment.points.count
            guard count <= maximumRoutePoints else { throw RouteError.tooManyPoints }
            for point in segment.points { try validate(point) }
        }
    }

    private static func validate(_ point: RoutePoint) throws {
        guard point.coordinate.isValid, point.elevation == nil || point.elevation!.isFinite else { throw RouteError.invalidCoordinate }
    }

    private static func validateTerrain(_ terrain: LoadedTerrain) throws {
        let w = terrain.level.width, h = terrain.level.height
        guard terrain.manifest.bounds.isValid, w >= 2, h >= 2, w <= 32_768, h <= 32_768,
              terrain.heights.count == w * h else { throw RouteError.missingElevation }
    }

    private static func terrainPoints(along coordinates: [GeoPoint], terrain: LoadedTerrain) throws -> [RoutePoint] {
        guard let first = coordinates.first else { return [] }
        var result = [RoutePoint]()
        func append(_ coordinate: GeoPoint) throws {
            guard coordinate.isValid else { throw RouteError.invalidCoordinate }
            guard terrain.manifest.bounds.contains(coordinate) else { throw RouteError.outsideArea }
            guard let height = terrain.elevation(at: coordinate) else { throw RouteError.missingElevation }
            guard result.count < maximumRoutePoints else { throw RouteError.tooManyPoints }
            if result.last?.coordinate != coordinate { result.append(RoutePoint(coordinate: coordinate, elevation: height)) }
        }
        try append(first)
        for index in coordinates.indices.dropFirst() {
            let previous = coordinates[index - 1], current = coordinates[index]
            guard current.isValid else { throw RouteError.invalidCoordinate }
            let count = max(1, Int(ceil(previous.distance(to: current) / 20)))
            guard count <= maximumRoutePoints - result.count else { throw RouteError.tooManyPoints }
            for step in 1...count {
                if step % 1024 == 0 { try Task.checkCancellation() }
                try append(interpolate(previous, current, fraction: Double(step) / Double(count)))
            }
        }
        return result
    }

    private static func deduplicated(_ points: [RoutePoint]) -> [RoutePoint] {
        var result: [RoutePoint] = []
        for point in points where result.last?.coordinate.distance(to: point.coordinate) ?? 1 > 0.01 { result.append(point) }
        return result
    }

    private static func interpolate(_ a: GeoPoint, _ b: GeoPoint, fraction: Double) -> GeoPoint {
        if fraction == 0 { return a }; if fraction == 1 { return b }
        return GeoPoint(latitude: a.latitude + (b.latitude - a.latitude) * fraction, longitude: a.longitude + (b.longitude - a.longitude) * fraction)
    }

    private struct EdgeSnap {
        var edgeIndex: Int
        var fraction: Double
        var point: RoutePoint
    }

    private static func nearestEdge(to point: GeoPoint, graph: PreparedGraph, maxDistance: Double) throws -> EdgeSnap {
        guard maxDistance.isFinite, maxDistance > 0, maxDistance <= 10_000 else { throw RouteError.noNearbyPath }
        let longitudeScale = cos(point.latitude * .pi / 180)
        var nearest: EdgeSnap?
        var distance = maxDistance
        for (index, edge) in graph.edges.enumerated() {
            if index % 2048 == 0 { try Task.checkCancellation() }
            guard let a = graph.nodes[edge.from], let b = graph.nodes[edge.to] else { continue }
            let dx = (b.coordinate.longitude - a.coordinate.longitude) * longitudeScale
            let dy = b.coordinate.latitude - a.coordinate.latitude
            let denominator = dx * dx + dy * dy
            guard denominator > 0 else { continue }
            let px = (point.longitude - a.coordinate.longitude) * longitudeScale
            let py = point.latitude - a.coordinate.latitude
            let fraction = max(0, min(1, (px * dx + py * dy) / denominator))
            let projected = interpolate(a.coordinate, b.coordinate, fraction: fraction)
            let separation = point.distance(to: projected)
            if separation <= distance {
                distance = separation
                nearest = EdgeSnap(edgeIndex: index, fraction: fraction,
                                   point: RoutePoint(coordinate: projected, elevation: a.elevation + (b.elevation - a.elevation) * fraction))
            }
        }
        guard let nearest else { throw RouteError.noNearbyPath }
        return nearest
    }

    private struct Connection { var node: Int; var cost: Double }
    private struct PreparedGraph {
        var nodes: [Int: WalkingNode] = [:]
        var edges: [WalkingEdge] = []
        var adjacency: [Int: [Connection]] = [:]
        init(_ graph: WalkingGraph) throws {
            guard graph.nodes.count <= maximumGraphNodes, graph.edges.count <= maximumGraphEdges else { throw RouteError.invalidGraph }
            for node in graph.nodes {
                guard node.coordinate.isValid, node.elevation.isFinite, nodes[node.id] == nil else { throw RouteError.invalidGraph }
                nodes[node.id] = node
            }
            for (index, input) in graph.edges.enumerated() {
                if index % 2048 == 0 { try Task.checkCancellation() }
                guard let from = nodes[input.from], let to = nodes[input.to], input.distance.isFinite, input.distance > 0 else { throw RouteError.invalidGraph }
                guard Self.isWalkable(input), input.from != input.to else { continue }
                var edge = input
                edge.distance = max(input.distance, from.coordinate.distance(to: to.coordinate))
                edges.append(edge)
                adjacency[edge.from, default: []].append(Connection(node: edge.to, cost: edge.distance))
                if edge.bidirectional { adjacency[edge.to, default: []].append(Connection(node: edge.from, cost: edge.distance)) }
            }
        }
        private static func isWalkable(_ edge: WalkingEdge) -> Bool {
            let access = edge.access.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let kind = edge.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["no", "private", "customers", "delivery", "agricultural", "forestry", "destination"].contains(access) { return false }
            // The older pack normalizes motorways and A-roads to majorRoad, losing
            // the distinction. Do not infer pedestrian eligibility for that class.
            if ["motorway", "motorway_link", "trunk", "trunk_link", "majorroad", "construction", "proposed", "raceway"].contains(kind) { return false }
            let pathKinds = ["path", "footway", "footpath", "bridleway", "steps", "pedestrian", "track"]
            // Both raw OSM and Ridge's normalized path names are supported. On a
            // walking-path feature, unknown means no explicit access tag was saved.
            if pathKinds.contains(kind) { return ["", "unknown", "yes", "designated", "permissive", "public", "official"].contains(access) }
            // Roads are usable only when the prepared pack explicitly marks pedestrian access.
            let roadKinds = ["minorroad", "living_street", "residential", "service", "unclassified", "tertiary", "tertiary_link", "secondary", "secondary_link", "primary", "primary_link", "cycleway"]
            return roadKinds.contains(kind) && ["yes", "designated", "permissive", "public", "official"].contains(access)
        }
    }

    private struct MinimumQueue {
        struct Entry { var node: Int; var cost: Double }
        var entries: [Entry] = []
        mutating func push(node: Int, cost: Double) {
            entries.append(Entry(node: node, cost: cost))
            var child = entries.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard entries[child].cost < entries[parent].cost else { break }
                entries.swapAt(child, parent); child = parent
            }
        }
        mutating func pop() -> Entry? {
            guard !entries.isEmpty else { return nil }
            if entries.count == 1 { return entries.removeLast() }
            let first = entries[0]
            entries[0] = entries.removeLast()
            var parent = 0
            while true {
                let left = parent * 2 + 1, right = left + 1
                guard left < entries.count else { break }
                let child = right < entries.count && entries[right].cost < entries[left].cost ? right : left
                guard entries[child].cost < entries[parent].cost else { break }
                entries.swapAt(child, parent); parent = child
            }
            return first
        }
    }
}
