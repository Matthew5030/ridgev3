import Foundation

@main
struct RouteCoreTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw TestFailure(message: message) }
    }
    static func expectError(_ expected: RouteError? = nil, _ action: () throws -> Void) throws {
        do { try action(); throw TestFailure(message: "Expected an error") }
        catch let error as RouteError { try expect(expected == nil || expected == error, "Unexpected error: \(error)") }
    }
    struct TestFailure: Error { var message: String }

    static func main() async throws {
        try gpxRoundTrip()
        try gpxValidation()
        try pathRouting()
        try directRouting()
        try overviewCoverage()
        try pathContinuity()
        try regionAssociation()
        try routeStatistics()
        try await persistence()
        if CommandLine.arguments.count > 1 { try bundledPeakRoute(directory: URL(fileURLWithPath: CommandLine.arguments[1])) }
        print("RouteCore: \(assertions) assertions passed")
    }

    static func coordinate(_ longitude: Double, _ latitude: Double = 0) -> GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
    static func point(_ longitude: Double, _ elevation: Double? = 0, _ latitude: Double = 0) -> RoutePoint { RoutePoint(coordinate: coordinate(longitude, latitude), elevation: elevation) }
    static func node(_ id: Int, _ longitude: Double, _ latitude: Double = 0) -> WalkingNode { WalkingNode(id: id, coordinate: coordinate(longitude, latitude), elevation: Double(id * 10)) }
    static func edge(_ from: Int, _ to: Int, _ distance: Double = 120, _ bidirectional: Bool = true, _ access: String = "yes", _ kind: String = "path") -> WalkingEdge {
        WalkingEdge(from: from, to: to, distance: distance, bidirectional: bidirectional, access: access, kind: kind)
    }

    static func gpxRoundTrip() throws {
        let route = RidgeRoute(name: "Crib Goch & \"Tryfan\" <walk>", regionID: "snowdonia",
                               waypoints: [RouteWaypoint(point: point(-4, 100, 53), name: "Start & finish")],
                               segments: [RouteSegment(points: [point(-4, 100, 53), point(-4.01, nil, 53.01)], mode: "paths"),
                                          RouteSegment(points: [point(-3.8, 120, 52.8), point(-3.81, 150, 52.81)], mode: "direct")],
                               notes: "Rock & water <3")
        let data = try GPXCodec.encode(route)
        let imported = try GPXCodec.decode(data, regionID: "snowdonia")
        try expect(imported.name == route.name, "GPX name escaping failed")
        try expect(imported.notes == route.notes, "GPX notes escaping failed")
        try expect(imported.regionID == "snowdonia", "GPX region association failed")
        try expect(imported.segments.count == 2, "Disconnected GPX track segments were merged")
        try expect(imported.segments.map(\.points) == route.segments.map(\.points), "GPX coordinates or optional elevations changed")
        try expect(imported.waypoints.first?.name == "Start & finish", "GPX waypoint name lost")
        let rte = Data("<gpx><rte><name>Trail</name><rtept lat=\"53\" lon=\"-4\"/><rtept lat=\"53.01\" lon=\"-4.01\"/></rte><rte><rtept lat=\"52\" lon=\"-3\"/></rte></gpx>".utf8)
        try expect(tryDecode(rte).segments.count == 2, "GPX route segments merged")
        let waypointOnly = try GPXCodec.decode(Data("<gpx><wpt lat=\"53\" lon=\"-4\"/><wpt lat=\"52\" lon=\"-3\"/></gpx>".utf8))
        try expect(waypointOnly.segments.count == 2 && waypointOnly.segments.allSatisfy { $0.points.count == 1 }, "Independent waypoints were falsely connected")
        let namespaced = Data("<g:gpx xmlns:g=\"http://www.topografix.com/GPX/1/1\"><g:trk><g:trkseg><g:trkpt lat=\"53\" lon=\"-4\"/></g:trkseg></g:trk></g:gpx>".utf8)
        try expect(tryDecode(namespaced).segments.count == 1, "Namespaced GPX failed")
    }

    static func tryDecode(_ data: Data) -> RidgeRoute {
        // Test helper only: fixture decoding failures should abort the executable.
        do { return try GPXCodec.decode(data) } catch { fatalError("Fixture failed: \(error)") }
    }

    static func gpxValidation() throws {
        for invalid in ["NaN", "inf", "91", "-91", "hello"] {
            try expectError(.invalidCoordinate) { _ = try GPXCodec.decode(Data("<gpx><trk><trkseg><trkpt lat=\"\(invalid)\" lon=\"-4\"/></trkseg></trk></gpx>".utf8)) }
        }
        try expectError(.invalidCoordinate) { _ = try GPXCodec.decode(Data("<gpx><wpt lat=\"53\" lon=\"181\"/></gpx>".utf8)) }
        try expectError(.invalidCoordinate) { _ = try GPXCodec.decode(Data("<gpx><wpt lat=\"53\"/></gpx>".utf8)) }
        try expectError { _ = try GPXCodec.decode(Data("<gpx><wpt lat=\"53\" lon=\"-4\"><ele>nan</ele></wpt></gpx>".utf8)) }
        try expectError { _ = try GPXCodec.decode(Data("<gpx><trk><trkseg>".utf8)) }
        try expectError { _ = try GPXCodec.decode(Data("<xml><wpt lat=\"53\" lon=\"-4\"/></xml>".utf8)) }
        try expectError { _ = try GPXCodec.decode(Data("<gpx/>".utf8)) }
        try expectError { _ = try GPXCodec.decode(Data("<!DOCTYPE gpx [<!ENTITY attack \"entity\">]><gpx><wpt lat=\"53\" lon=\"-4\"><name>&attack;</name></wpt></gpx>".utf8)) }
        try expectError { _ = try GPXCodec.decode(Data(repeating: 0, count: GPXCodec.maximumFileBytes + 1)) }
        let overlong = String(repeating: "x", count: 161)
        try expectError { _ = try GPXCodec.decode(Data("<gpx><trk><name>\(overlong)</name><trkseg><trkpt lat=\"53\" lon=\"-4\"/></trkseg></trk></gpx>".utf8)) }
    }

    static func pathRouting() throws {
        let graph = WalkingGraph(nodes: [node(0, 0), node(1, 0.001), node(2, 0.002)], edges: [edge(0, 1), edge(1, 2)])
        let route = try RouteEngine.walkingSegment(from: coordinate(0.0002, 0.0001), to: coordinate(0.0018, 0.0001), graph: graph)
        try expect(abs(route.points.first!.coordinate.longitude - 0.0002) < 0.00000001, "Path did not snap to edge interior")
        try expect(route.points.first!.coordinate.latitude == 0 && route.points.last!.coordinate.latitude == 0, "Path invented a straight connector to tap")
        try expect(route.points.contains { $0.coordinate == coordinate(0.001) }, "Path skipped intermediate network node")
        let oneWay = WalkingGraph(nodes: [node(0, 0), node(1, 0.001), node(2, 0.002)], edges: [edge(0, 1, 120, false), edge(1, 2, 120, false)])
        try expectError(.disconnectedPaths) { _ = try RouteEngine.walkingSegment(from: coordinate(0.0018), to: coordinate(0.0002), graph: oneWay) }
        let forward = try RouteEngine.walkingSegment(from: coordinate(0.0002), to: coordinate(0.0008), graph: oneWay)
        try expect(forward.points.count == 2, "Same-edge forward route detoured")
        try expectError(.disconnectedPaths) { _ = try RouteEngine.walkingSegment(from: coordinate(0.0008), to: coordinate(0.0002), graph: oneWay) }
        let blocked = WalkingGraph(nodes: [node(0, 0), node(1, 0.001), node(2, 0.002), node(3, 0.003)], edges: [edge(0, 1), edge(1, 2, 120, true, "private"), edge(2, 3)])
        try expectError(.disconnectedPaths) { _ = try RouteEngine.walkingSegment(from: coordinate(0.0002), to: coordinate(0.0028), graph: blocked) }
        for access in ["private", "no"] {
            let forbidden = WalkingGraph(nodes: [node(0, 0), node(1, 0.001)], edges: [edge(0, 1, 120, true, access)])
            try expectError(.noNearbyPath) { _ = try RouteEngine.walkingSegment(from: coordinate(0), to: coordinate(0.001), graph: forbidden) }
        }
        let road = WalkingGraph(nodes: [node(0, 0), node(1, 0.001)], edges: [edge(0, 1, 120, true, "", "residential")])
        try expectError(.noNearbyPath) { _ = try RouteEngine.walkingSegment(from: coordinate(0), to: coordinate(0.001), graph: road) }
        for access in ["public", "unknown", "permissive"] {
            let normalizedPath = WalkingGraph(nodes: [node(0, 0), node(1, 0.001)], edges: [edge(0, 1, 120, true, access, "footpath")])
            let path = try RouteEngine.walkingSegment(from: coordinate(0), to: coordinate(0.001), graph: normalizedPath)
            try expect(path.points.count == 2, "Normalized footpath was incorrectly excluded")
        }
        for kind in ["minorRoad", "majorRoad"] {
            let unknownRoad = WalkingGraph(nodes: [node(0, 0), node(1, 0.001)], edges: [edge(0, 1, 120, true, "unknown", kind)])
            try expectError(.noNearbyPath) { _ = try RouteEngine.walkingSegment(from: coordinate(0), to: coordinate(0.001), graph: unknownRoad) }
        }
        let ambiguousMajorRoad = WalkingGraph(nodes: [node(0, 0), node(1, 0.001)], edges: [edge(0, 1, 120, true, "public", "majorRoad")])
        try expectError(.noNearbyPath) { _ = try RouteEngine.walkingSegment(from: coordinate(0), to: coordinate(0.001), graph: ambiguousMajorRoad) }
        try expectError(.noNearbyPath) { _ = try RouteEngine.walkingSegment(from: coordinate(1), to: coordinate(0.001), graph: graph) }
        let malformed = WalkingGraph(nodes: graph.nodes, edges: [edge(0, 9)])
        try expectError(.invalidGraph) { _ = try RouteEngine.walkingSegment(from: coordinate(0), to: coordinate(0.001), graph: malformed) }
        // An expensive direct edge must not beat the shorter connected path.
        let detour = WalkingGraph(nodes: [node(0, 0), node(1, 0.001), node(2, 0.002)], edges: [edge(0, 1), edge(1, 2), edge(0, 2, 2_000)])
        let shortest = try RouteEngine.walkingSegment(from: coordinate(0), to: coordinate(0.002), graph: detour)
        try expect(shortest.points.contains { $0.coordinate == coordinate(0.001) }, "Dijkstra did not find the shortest network path")
    }

    static func terrain() -> LoadedTerrain {
        let bounds = GeoBounds(minLatitude: 0, minLongitude: 0, maxLatitude: 0.01, maxLongitude: 0.01)
        let level = TerrainLOD(spacing: 16, width: 10, height: 10, file: "terrain.bin", byteCount: 200, sha256: "")
        let manifest = RegionManifest(schemaVersion: 1, id: "test", name: "Test", subtitle: "", bounds: bounds, sourceResolution: 1, heightScale: 1,
                                      noDataValue: -32768, levels: [level], textures: [], graphFile: nil, graphSHA256: nil, graphByteCount: nil, places: [], sources: [],
                                      defaultSpacing: 16, version: "1", summary: "", verticalDatum: nil)
        return LoadedTerrain(manifest: manifest, level: level, heights: (0..<100).map { Float($0 % 10) * 10 }, textureURLs: [], graph: nil, directory: URL(fileURLWithPath: "/tmp"))
    }

    static func overviewCoverage() throws {
        let terrain = terrain(), b = terrain.manifest.bounds
        let a = b.point(u: 0.5, v: 0.5), outside = b.point(u: 1.5, v: 0.5)
        let leg = try RouteEngine.planningSegment(from: a, to: outside, mode: .paths, terrain: terrain)
        try expect(leg.mode == "overview", "Outside path-mode tap must be an overview sketch, not a fabricated path")
        try expect(leg.points.last?.elevation == nil, "Overview height must not masquerade as detailed elevation")
        let crossing = RouteEngine.coverageSections(from: b.point(u: -0.5, v: 0.5), to: outside, bounds: b)
        try expect(crossing.count == 3 && crossing.map(\.detailed) == [false, true, false], "Outside-to-outside route splits around detailed coverage")
        try expect(crossing[0].to == crossing[1].from && crossing[1].to == crossing[2].from, "Coverage transitions have no gaps")
        try expect(crossing[1].from.longitude == b.minLongitude && crossing[1].to.longitude == b.maxLongitude, "Dashes switch on exact geographic edges")
        let inside = try RouteEngine.planningSegment(from: a, to: b.point(u: 0.7, v: 0.5), mode: .direct, terrain: terrain)
        try expect(inside.mode == "direct", "Detailed routes preserve established routing mode")
        var draft = RidgeRoute(name: "Sketch", regionID: terrain.manifest.id, waypoints: [RouteWaypoint(point: leg.points[0]), RouteWaypoint(point: leg.points[1])], segments: [leg])
        let decoded = try JSONDecoder().decode(RidgeRoute.self, from: JSONEncoder().encode(draft))
        try expect(decoded == draft, "Overview sketches survive persistence")
        let imported = try GPXCodec.decode(GPXCodec.encode(draft))
        try expect(imported.points.map(\.coordinate) == draft.points.map(\.coordinate), "Overview coordinates export to GPX without inventing detail")
        try expect(!RouteEngine.overviewPoints(in: draft, bounds: b).isEmpty, "Coverage need is based on coordinates")
        draft.waypoints[1].point.coordinate = b.point(u: 0.8, v: 0.5)
        draft.segments[0].points[1].coordinate = draft.waypoints[1].point.coordinate
        let resolved = try RouteEngine.resolveOverview(draft, terrain: terrain)
        try expect(resolved.segments[0].mode == "direct" && resolved.waypoints[1].point.elevation != nil, "Available detail resolves manual sketches without claiming path routing")
        try expect(resolved.waypoints.count == draft.waypoints.count, "Resolution never adds a duplicate waypoint")
    }

    static func directRouting() throws {
        var terrain = terrain()
        let route = try RouteEngine.directSegment(from: coordinate(0.001, 0.005), to: coordinate(0.009, 0.005), terrain: terrain)
        try expect(route.points.count > 40, "Direct route was not terrain-sampled")
        try expect(route.points.last!.elevation! > route.points.first!.elevation!, "Direct route does not follow terrain")
        for pair in zip(route.points, route.points.dropFirst()) { try expect(pair.0.coordinate.distance(to: pair.1.coordinate) <= 20.001, "Direct samples exceed 20 metres") }
        try expectError(.outsideArea) { _ = try RouteEngine.directSegment(from: coordinate(0.005, 0.005), to: coordinate(0.02, 0.005), terrain: terrain) }
        terrain.heights[55] = .nan
        try expectError(.missingElevation) { _ = try RouteEngine.directSegment(from: coordinate(0.001, 0.00445), to: coordinate(0.009, 0.00445), terrain: terrain) }
        terrain.heights = []
        try expectError(.missingElevation) { _ = try RouteEngine.directSegment(from: coordinate(0.001, 0.005), to: coordinate(0.009, 0.005), terrain: terrain) }
    }

    static func pathContinuity() throws {
        var terrain = terrain()
        terrain.graph = WalkingGraph(nodes: [node(0, 0.001, 0.005), node(1, 0.009, 0.005)], edges: [edge(0, 1, 900)])
        try expectError(.pathStartMismatch) {
            _ = try RouteEngine.segment(from: coordinate(0.002, 0.0052), to: coordinate(0.008, 0.0051), mode: .paths, terrain: terrain)
        }
        let snappedStart = try RouteEngine.snap(coordinate(0.002, 0.0052), terrain: terrain)
        let continuous = try RouteEngine.segment(from: snappedStart.coordinate, to: coordinate(0.008, 0.0051), mode: .paths, terrain: terrain)
        try expect(continuous.points.first?.coordinate == snappedStart.coordinate, "A path leg moved the already-snapped start")
        try expect(continuous.points.last?.coordinate.latitude == 0.005, "Path destination was not snapped")
    }

    static func regionAssociation() throws {
        var small = terrain().manifest; small.id = "small"
        var large = small; large.id = "large"; large.bounds.maxLatitude = 0.02; large.bounds.maxLongitude = 0.02
        let route = RidgeRoute(name: "Imported before terrain", regionID: "", segments: [RouteSegment(points: [point(0.002, 0, 0.003), point(0.008, 0, 0.009)], mode: "imported")])
        try expect(RouteEngine.containingRegion(for: route, in: [], installedIDs: []) == nil, "Missing coverage should remain unassociated")
        try expect(RouteEngine.containingRegion(for: route, in: [small, large], installedIDs: [large.id])?.id == large.id, "Installed containing terrain should beat smaller unsaved terrain")
        try expect(RouteEngine.containingRegion(for: route, in: [small, large], installedIDs: [])?.id == small.id, "Unsaved route should choose the smallest containing terrain")
        var stale = route; stale.regionID = "removed-pack"
        try expect(RouteEngine.containingRegion(for: stale, in: [large], installedIDs: [large.id])?.id == large.id, "Stale associations were not repaired")
        stale.regionID = small.id
        try expect(RouteEngine.containingRegion(for: stale, in: [small, large], installedIDs: [large.id])?.id == large.id, "Uninstalled old association incorrectly beat installed coverage")
        var outside = route; outside.segments[0].points.append(point(0.03, 0, 0.01))
        try expect(RouteEngine.containingRegion(for: outside, in: [small, large], installedIDs: [large.id]) == nil, "Resolver accepted terrain covering only part of a route")
    }

    static func routeStatistics() throws {
        let route = RidgeRoute(name: "Breaks", regionID: "test", segments: [RouteSegment(points: [point(0, 0), point(0.001, 10)], mode: "paths"), RouteSegment(points: [point(1, 1_000), point(1.001, 990)], mode: "imported")])
        let stats = RouteEngine.statistics(for: route)
        try expect(abs(stats.distanceMeters - 222.39) < 1, "Statistics bridged disconnected track segments")
        try expect(stats.ascentMeters == 10 && stats.descentMeters == 10, "Statistics bridged elevation discontinuity")
        try expect(stats.hasCompleteElevation && stats.segmentCount == 2 && stats.estimatedMinutes > 0, "Statistics flags failed")
        let noise = RidgeRoute(name: "Noise", regionID: "test", segments: [RouteSegment(points: [point(0, 100), point(0.001, 101), point(0.002, 100), point(0.003, 101)], mode: "paths")])
        try expect(RouteEngine.statistics(for: noise).ascentMeters == 0, "Elevation ripple inflated ascent")
        let unknown = RidgeRoute(name: "Unknown", regionID: "test", segments: [RouteSegment(points: [point(0, nil), point(0.001, nil)], mode: "imported")])
        try expect(!RouteEngine.statistics(for: unknown).hasElevation, "Missing elevations were presented as measured")
    }

    static func persistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-routes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RouteStore(directory: directory)
        let initial = try await store.load()
        try expect(initial.isEmpty, "New library should be empty")
        let route = RidgeRoute(name: "Original", regionID: "test", segments: [RouteSegment(points: [point(0), point(0.001)], mode: "paths")])
        try await store.save(route)
        let renamed = try await store.rename(id: route.id, name: "Renamed")
        try expect(renamed.name == "Renamed", "Rename failed")
        let copy = try await store.duplicate(id: route.id)
        try expect(copy.id != route.id && copy.name == "Renamed (copy)", "Duplicate identity failed")
        let loaded = try await RouteStore(directory: directory).load()
        try expect(loaded.count == 2, "Persistence failed across store instances")
        try await store.delete(id: copy.id)
        let remaining = try await store.load()
        try expect(remaining.count == 1 && remaining[0].id == route.id, "Delete removed wrong route")
        // The editor removes an emptied draft from persistence, then re-saves the
        // same identity if the user redoes their first control point.
        try await store.delete(id: route.id)
        let emptyLibrary = try await store.load()
        try expect(emptyLibrary.isEmpty, "Removing an emptied route left a saved card")
        try await store.save(route)
        let restored = try await store.load()
        try expect(restored.count == 1 && restored[0].id == route.id && restored[0].segments == route.segments, "Redo could not restore the removed route identity and geometry")
        let file = directory.appendingPathComponent("library.json")
        let corrupted = Data("corrupted library".utf8)
        try corrupted.write(to: file)
        do { try await store.save(route); throw TestFailure(message: "Saving silently replaced a damaged library") }
        catch is RouteError { assertions += 1 }
        let preserved = try Data(contentsOf: file)
        try expect(preserved == corrupted, "Failed save changed the existing library")
    }

    static func bundledPeakRoute(directory: URL) throws {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(RegionManifest.self, from: Data(contentsOf: directory.appendingPathComponent("pack.json")))
        guard let level = manifest.levels.first(where: { $0.spacing == 8 }), let graphFile = manifest.graphFile else { throw TestFailure(message: "Missing Snowdon integration fixture") }
        let data = try Data(contentsOf: directory.appendingPathComponent(level.file))
        try expect(data.count == level.sampleCount * 2, "Actual terrain heightfield byte count mismatch")
        let heights: [Float] = data.withUnsafeBytes { raw in
            (0..<level.sampleCount).map { index in
                let height = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                return Int(height) == manifest.noDataValue ? .nan : Float(Double(height) * manifest.heightScale)
            }
        }
        let graph = try decoder.decode(WalkingGraph.self, from: Data(contentsOf: directory.appendingPathComponent(graphFile)))
        let terrain = LoadedTerrain(manifest: manifest, level: level, heights: heights, textureURLs: [], graph: graph, directory: directory)
        let wyddfa = coordinate(-4.0762324, 53.0684857), cribGoch = coordinate(-4.0545889, 53.0763169)
        let start = try RouteEngine.snap(wyddfa, terrain: terrain)
        let end = try RouteEngine.snap(cribGoch, terrain: terrain)
        try expect(start.coordinate.distance(to: wyddfa) < 30, "Yr Wyddfa peak should snap to its nearby summit path")
        try expect(end.coordinate.distance(to: cribGoch) < 30, "Crib Goch peak should snap to its nearby ridge path")
        let leg = try RouteEngine.segment(from: start.coordinate, to: cribGoch, mode: .paths, terrain: terrain)
        let route = RidgeRoute(name: "Yr Wyddfa to Crib Goch", regionID: manifest.id, segments: [leg])
        let stats = RouteEngine.statistics(for: route)
        try expect(leg.points.count > 30, "Actual mountain route should follow a detailed network path")
        try expect(leg.points.first!.coordinate.distance(to: start.coordinate) < 1, "Actual route start moved during calculation")
        try expect(leg.points.last!.coordinate.distance(to: end.coordinate) < 1, "Actual route did not reach Crib Goch")
        try expect(leg.points.allSatisfy { $0.elevation?.isFinite == true && manifest.bounds.contains($0.coordinate) }, "Actual route crosses missing or out-of-bounds terrain")
        try expect(stats.distanceMeters > 1_500 && stats.distanceMeters < 8_000, "Actual route length is implausible")
        let reverse = try RouteEngine.segment(from: end.coordinate, to: start.coordinate, mode: .paths, terrain: terrain)
        try expect(reverse.points.count > 30, "Actual mountain route is not available in reverse")
        print(String(format: "Snowdon 8 m integration: %.1f m start snap; %.1f m end snap; %.0f m route; %d terrain points; %.0f m ascent / %.0f m descent", start.coordinate.distance(to: wyddfa), end.coordinate.distance(to: cribGoch), stats.distanceMeters, leg.points.count, stats.ascentMeters, stats.descentMeters))
    }
}
