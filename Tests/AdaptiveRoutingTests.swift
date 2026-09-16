import Foundation

/// Uses an existing disposable nine-cell adaptive integration fixture; no downloads.
@MainActor @main struct AdaptiveRoutingTests {
  static func waitFor(_ busy: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(60)
    while busy() {
      guard Date() < deadline else { fatalError("App operation timed out") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }
  static func main() async throws {
    guard CommandLine.arguments.count == 3 else {
      fatalError("Pass disposable saved areas and source-header directories")
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "ridge.routing.test." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer {
      try? FileManager.default.removeItem(at: scratch)
      preferences.removePersistentDomain(forName: suite)
    }
    let packs = PackStore(
      root: root, bundledDirectory: nil,
      sourceDirectory: URL(fileURLWithPath: CommandLine.arguments[2]))
    let entries = try await packs.catalogue()
    let entry = entries.first { $0.manifest.adaptive?.chunks.count == 9 }!
    let terrain = try await packs.load(id: entry.id)
    let graph = terrain.graph!
    var chosen: (GeoPoint, GeoPoint, RouteSegment, Double)?
    let samples = stride(from: 0, to: graph.nodes.count, by: max(1, graph.nodes.count / 24)).map {
      graph.nodes[$0].coordinate
    }
    outer: for a in samples {
      for b in samples where a.distance(to: b) > 200 {
        guard let start = try? RouteEngine.snap(a, terrain: terrain),
          let route = try? RouteEngine.segment(
            from: start.coordinate, to: b, mode: .paths, terrain: terrain), route.points.count > 10
        else { continue }
        let first = route.points.first!.coordinate
        let last = route.points.last!.coordinate
        let length = zip(route.points, route.points.dropFirst()).reduce(0.0) {
          $0 + $1.0.coordinate.distance(to: $1.1.coordinate)
        }
        if length > first.distance(to: last) * 1.2 {
          chosen = (start.coordinate, b, route, length)
          break outer
        }
      }
    }
    guard let (start, finish, expected, length) = chosen else { fatalError("No curved fixture") }
    let app = AppStore(
      packs: packs, routeStore: RouteStore(directory: scratch), preferences: preferences)
    app.entries = entries
    app.open(entry)
    try await waitFor { app.isPreparing }
    precondition(app.activeTerrain != nil && app.planningMode == .paths)
    print(
      "Default mode:", app.planningMode.rawValue, "graph nodes", graph.nodes.count, "edges",
      graph.edges.count)
    app.startRoute()
    app.tapTerrain(start)
    try await waitFor { app.isRouting }
    app.tapTerrain(finish)
    try await waitFor { app.isRouting }
    guard let leg = app.activeRoute?.segments.first else {
      fatalError("App failed to route: \(app.notice ?? "")")
    }
    print(
      "App route:", leg.mode, leg.points.count, "points; walking metres", length, "direct metres",
      start.distance(to: finish))
    guard leg.mode == "paths", leg.points.count == expected.points.count else {
      fatalError("App changed route geometry")
    }
    let original = app.activeRoute!
    let outside = terrain.manifest.bounds.point(u: 1.2, v: 0.5)
    app.tapTerrain(outside)
    try await waitFor { app.isRouting }
    precondition(app.activeRoute == original, "Outside tap must not mutate the route")
    precondition(app.pendingExtension?.destination == outside, "Outside tap must offer expansion")
    app.movingWaypoint = 1
    app.tapTerrain(outside)
    try await waitFor { app.isRouting }
    precondition(
      app.activeRoute == original, "Moving a path endpoint outside must not create a straight line")
    app.movingWaypoint = nil
    app.planningMode = .direct
    app.tapTerrain(outside)
    try await waitFor { app.isRouting }
    precondition(
      app.activeRoute?.segments.last?.mode == "overview", "Explicit manual sketch must still work")
    app.planningMode = .paths
    app.startRoute()
    app.tapTerrain(outside)
    try await waitFor { app.isRouting }
    precondition(
      app.activeRoute?.waypoints.isEmpty == true && app.pendingExtension?.destination == outside)
    var graphless = terrain
    graphless.graph = nil
    app.activeTerrain = graphless
    app.startRoute()
    app.tapTerrain(start)
    try await waitFor { app.isRouting }
    precondition(
      app.planningMode == .paths && app.activeRoute?.waypoints.isEmpty == true,
      "Missing network must not implicitly draw direct lines")
    print(
      "PASS: real curved path, boundary expansion without route changes, path edit rejection, explicit manual sketch, outside start and missing network"
    )
  }
}
