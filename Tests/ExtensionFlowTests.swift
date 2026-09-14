import Foundation

private struct FlowFailure: Error, CustomStringConvertible { let description: String }

@MainActor @main struct ExtensionFlowTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw FlowFailure(description: message) }
    }
    static func settle(_ store: AppStore) async throws {
        let deadline = Date().addingTimeInterval(45)
        while store.extensionInProgress || store.isRouting {
            guard Date() < deadline else { throw FlowFailure(description: "Extension did not finish: \(store.preparationLabel)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw FlowFailure(description: "Pass the Eryri source directory") }
        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
        var source = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: sourceURL.appendingPathComponent("pack.json")))
        source.horizon = nil // Transaction tests do not need to recopy distant maps.
        guard let grid = source.grid, let selected = grid.selection(column: 0, row: 0) else { throw FlowFailure(description: "Missing original grid") }
        let crop = try AreaCropper.prepare(directory: sourceURL, manifest: source, selection: selected, spacing: 8)
        defer { try? FileManager.default.removeItem(at: crop.directory) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-extension-flow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let packs = PackStore(root: temporary.appendingPathComponent("Areas"))
        let routes = RouteStore(directory: temporary.appendingPathComponent("Routes"))
        try await packs.install(from: crop.directory, manifest: crop.manifest, spacing: 8) { _ in }
        let original = try await packs.load(id: crop.manifest.id)
        let sourceEntry = PackEntry(manifest: source, directory: sourceURL, installed: false)
        let store = AppStore(packs: packs, routeStore: routes)
        store.entries = [sourceEntry]
        store.activeTerrain = original
        store.planningMode = .direct
        store.startRoute()
        let first = original.manifest.bounds.point(u: 0.25, v: 0.25)
        let second = original.manifest.bounds.point(u: 0.55, v: 0.55)
        store.tapTerrain(first); try await settle(store)
        store.tapTerrain(second); try await settle(store)
        guard let originalRoute = store.activeRoute else { throw FlowFailure(description: "Route missing") }
        let originalUndo = store.undoStack
        let pose = TerrainCameraPose(target: second, targetElevationMeters: 500, yaw: 0.7, pitch: 0.5, distanceMeters: 1600)
        store.updateNavigation(TerrainNavigationState(pose: pose, spacing: 8, insidePlanningArea: true))
        let destination = source.bounds.point(u: 1.5 / Double(grid.columns), v: 0.5 / Double(grid.rows))
        store.updateNavigation(TerrainNavigationState(pose: pose, spacing: 32, insidePlanningArea: false, viewedPoint: destination))
        try check(store.viewingSurroundings, "Coverage follows the viewed ground even when the orbit pivot is inside detail")
        try check(store.areaExpansionFocus == destination, "Visible Expand area follows the viewed ground rather than the camera pivot")
        try check(store.viewingSceneEdge, "Looking beyond saved coverage exposes the scene-edge explanation")
        store.requestExtensionAtViewpoint()
        try check(store.pendingExtension?.destination == destination, "Add detail here targets viewed ground rather than the orbit pivot")
        store.dismissExtension()
        try check(store.activeRoute?.points == originalRoute.points && store.pendingExtension == nil, "Dismissing a view-centred preview leaves the route unchanged")
        store.updateNavigation(TerrainNavigationState(pose: pose, spacing: 8, insidePlanningArea: true))
        try check(!store.viewingSceneEdge, "Returning to detailed terrain clears the scene-edge explanation")
        store.tapTerrain(destination); try await settle(store)
        guard let sketch = store.activeRoute else { throw FlowFailure(description: "Sketch missing") }
        try check(store.pendingExtension == nil && !store.extensionInProgress, "Outside waypoint never opens or starts a download")
        try check(sketch.waypoints.count == originalRoute.waypoints.count + 1 && sketch.segments.last?.mode == "overview", "Outside waypoint persists as an explicit overview sketch")
        try check(store.routeNeedsDetail && sketch.waypoints.last?.point.elevation == nil, "Missing detailed coverage and elevation are honest")
        let before = try await routes.load()
        try check(before.first?.points == sketch.points, "Overview sketch is durably saved before downloading")
        store.undo(); try await settle(store)
        try check(store.activeRoute?.points == originalRoute.points && !store.routeNeedsDetail, "Undo removes the overview waypoint without touching coverage")
        store.redo(); try await settle(store)
        try check(store.activeRoute?.points == sketch.points, "Redo restores the overview sketch")
        store.requestDetailAlongRoute()
        try check(store.pendingExtension?.preview != nil && store.extensionForRoute, "Add detail along route produces an explicit preview")
        let smallerArea = store.extensionManifest!.bounds.areaSquareKilometers
        store.setExtensionMargin(1000)
        try check(store.extensionManifest!.bounds.areaSquareKilometers >= smallerArea, "Larger margin never shrinks the proposed coverage")
        store.setExtensionMargin(500)
        try check(store.selectedPoint == destination && store.extensionSpacing == 8, "Preview retains the requested point and chosen detail")
        store.confirmExtension()
        try await Task.sleep(for: .milliseconds(40))
        try check(store.activeTerrain == nil && store.extensionInProgress, "Old scene retires before preparing the replacement")
        try check(store.progress == 0, "Preparation waits for the old renderer release acknowledgement")
        // Observe the first actor-visible interactive state, before a library
        // refresh could yield and let another edit replace the captured route.
        let interactivePublication = Task { @MainActor in
            while store.extensionInProgress { await Task.yield() }
            return store.activeRoute?.segments.last?.mode == "direct" && store.activeRoute?.waypoints.count == originalRoute.waypoints.count + 1
        }
        store.terrainViewReleased()
        try await settle(store)
        let continuationWasReserved = await interactivePublication.value
        try check(continuationWasReserved, "The first published editor state already contains the resolved sketch with no duplicate waypoint")
        guard let expanded = store.activeTerrain, let extendedRoute = store.activeRoute else { throw FlowFailure(description: "Extension did not restore the editor: \(store.extensionError ?? "unknown")") }
        try check(expanded.manifest.id != original.manifest.id && expanded.manifest.bounds.contains(destination), "Extended area contains the pending destination")
        try check(extendedRoute.id == originalRoute.id && extendedRoute.name == originalRoute.name, "Existing route identity and name survive")
        try check(extendedRoute.waypoints.count == originalRoute.waypoints.count + 1, "Adding detail does not duplicate the already saved waypoint")
        try check(Array(extendedRoute.segments.prefix(originalRoute.segments.count)) == originalRoute.segments, "Existing route geometry is preserved exactly")
        try check(extendedRoute.segments.last?.mode == "direct", "Added detail retains the manual line instead of inventing a followed path")
        try check(extendedRoute.regionID == expanded.manifest.id, "Saved route associates with the extended area")
        try check(store.editing && store.planningMode == .direct, "Editing mode resumes")
        try check(store.undoStack.count == originalUndo.count + 1 && store.undoStack.allSatisfy { $0.regionID == expanded.manifest.id }, "Undo history remains valid in the expanded area")
        try check(store.camera.action == .restore(pose), "Viewpoint is restored in geographic metres")
        try check(store.pendingExtension == nil && store.extensionError == nil, "Completed proposal is cleared")
        let saved = try await routes.load()
        try check(saved.first?.points == extendedRoute.points && saved.first?.regionID == expanded.manifest.id, "Completed route persists with its new association")
        let previousPack = try await packs.installedManifest(id: original.manifest.id)
        try check(previousPack != nil, "Original saved area remains available for recovery")
        store.undo(); try await settle(store)
        try check(store.activeRoute?.points == originalRoute.points && store.activeRoute?.regionID == expanded.manifest.id, "Undo removes only the new leg while keeping extended coverage")
        store.redo(); try await settle(store)
        try check(store.activeRoute?.points == extendedRoute.points && store.activeRoute?.regionID == expanded.manifest.id, "Redo restores the added leg in the extended area")
        print("PASS saved overview sketch, explicit extension, route/history/camera preservation and no duplicate waypoint")

        // A cancelled operation must recover on an uncancelled task and must
        // still wait for the old renderer before decoding that saved scene.
        store.activeTerrain = original; store.activeRoute = originalRoute
        store.undoStack = originalUndo; store.redoStack = []; store.entries = [sourceEntry]
        try await routes.save(originalRoute)
        store.updateNavigation(TerrainNavigationState(pose: pose, spacing: 8, insidePlanningArea: true))
        store.requestExtension(at: destination); store.confirmExtension(); store.cancelPreparation()
        try await Task.sleep(for: .milliseconds(30))
        try check(store.extensionInProgress && store.activeTerrain == nil, "Cancelled extension waits for renderer release before recovery")
        store.terrainViewReleased(); try await settle(store)
        try check(store.activeTerrain?.manifest.id == original.manifest.id, "Cancellation reopens the previous saved area")
        try check(store.activeRoute == originalRoute && store.undoStack == originalUndo, "Cancellation preserves the draft and undo history")
        try check(store.pendingExtension?.destination == destination && store.extensionError != nil, "Cancellation leaves the proposal available to retry")
        try check(store.camera.action == .restore(pose), "Cancellation restores the same viewpoint")
        print("PASS cancellation recovery without overlapping active scenes")

        // A valid manifest with unavailable source bytes can be proposed, but
        // failed preparation must not replace any saved route or active area.
        var missingEntry = sourceEntry
        missingEntry.directory = temporary.appendingPathComponent("MissingSource")
        store.entries = [missingEntry]
        store.requestExtension(at: destination)
        store.confirmExtension(); store.terrainViewReleased(); try await settle(store)
        try check(store.activeTerrain?.manifest.id == original.manifest.id && store.activeRoute == originalRoute, "Missing source bytes restore the unchanged route and area")
        try check(store.extensionError != nil && store.pendingExtension?.destination == destination, "Failure explains the issue and retains the requested point")
        let retained = try await routes.load()
        try check(retained.first?.points == originalRoute.points && retained.first?.regionID == originalRoute.regionID, "Failed preparation cannot change the saved route association")
        store.entries = [sourceEntry]
        let unavailable = GeoPoint(latitude: source.bounds.maxLatitude + 0.02, longitude: source.bounds.center.longitude)
        store.requestExtension(at: unavailable)
        try check(store.pendingExtension?.source == nil && store.pendingExtension?.unavailableReason != nil, "Missing planning coverage is shown honestly")
        store.confirmExtension()
        try check(!store.extensionInProgress && store.activeRoute == originalRoute, "Unavailable coverage never starts a download or route calculation")
        store.dismissExtension()
        try check(store.pendingExtension == nil && store.selectedPoint == nil, "Keep looking dismisses only the proposed pin")
        print("PASS failure recovery and honest unavailable coverage")
        print("PASS extension flow: \(checks) assertions")
    }
}
