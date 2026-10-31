import Foundation

@main struct RouteExitTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            checks += 1
            if !value { throw RidgeError.message(message) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-route-exit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ridge-route-exit-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let bounds = GeoBounds(minLatitude: 53, minLongitude: -4, maxLatitude: 53.01, maxLongitude: -3.99)
        let level = TerrainLOD(spacing: 4, width: 2, height: 2, file: "unused", byteCount: 16, sha256: String(repeating: "0", count: 64))
        let manifest = RegionManifest(schemaVersion: 1, id: "test-window", name: "Eryri", subtitle: "", bounds: bounds, sourceResolution: 4, heightScale: 1, noDataValue: -9999, levels: [level], textures: [], graphFile: nil, graphSHA256: nil, graphByteCount: nil, places: [], sources: [], defaultSpacing: 4, version: "1", summary: "", verticalDatum: nil)
        let terrain = LoadedTerrain(manifest: manifest, level: level, heights: [100, 100, 100, 100], textureURLs: [], graph: nil, directory: root)
        func point(_ x: Double) -> RoutePoint { .init(coordinate: .init(latitude: 53.005, longitude: -4 + x * 0.01), elevation: 100) }
        let original = RidgeRoute(name: "Saved ridge walk", regionID: manifest.id, waypoints: [.init(point: point(0.2)), .init(point: point(0.4))], segments: [.init(points: [point(0.2), point(0.4)], mode: "direct")])
        func store(directory: URL? = nil) -> AppStore {
            let store = AppStore(packs: PackStore(root: root.appendingPathComponent(UUID().uuidString)), routeStore: RouteStore(directory: directory ?? root.appendingPathComponent(UUID().uuidString)), preferences: preferences)
            store.worldTerrain = terrain; store.activeTerrain = terrain; store.planningMode = .direct
            return store
        }
        func savedStore() async throws -> AppStore {
            let store = store()
            try await store.routeStore.save(original)
            store.routes = try await store.routeStore.load()
            store.openRoute(store.routes[0], savedWorldBounds: [bounds])
            store.planningMode = .direct
            return store
        }
        func wait(_ store: AppStore) async throws {
            for _ in 0..<1_000 {
                if !store.isRouting { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw RidgeError.message("Route write did not finish")
        }
        func appendPoint(_ store: AppStore) async throws {
            store.editing = true
            store.tapTerrain(point(0.65).coordinate)
            try await wait(store)
            try check(store.activeRoute?.waypoints.count == 3, "The real editor appends the test waypoint")
        }

        let saved = try await savedStore()
        let before = try await saved.routeStore.load()
        saved.editing = true // Opening the editor alone does not make a saved walk dirty.
        saved.tab = .routes
        saved.requestExplore()
        try check(saved.tab == .explore && saved.activeRoute == nil && !saved.showRouteExitConfirmation, "An unchanged saved route exits without a prompt")
        try check(saved.activeTerrain?.manifest.id == terrain.manifest.id && saved.worldTerrain != nil, "Exit keeps the loaded terrain available")
        try check(try await saved.routeStore.load() == before, "A clean exit does not rewrite the saved library")

        let draft = store()
        draft.startRoute(); draft.planningMode = .direct
        draft.tapTerrain(point(0.2).coordinate)
        try await wait(draft)
        let draftRoute = draft.activeRoute!
        try check(try await draft.routeStore.load().contains(where: { $0.id == draftRoute.id }), "A recovery copy exists before the new draft is explicitly finished")
        draft.requestExplore()
        try check(draft.showRouteExitConfirmation && draft.activeRoute == draftRoute && draft.editing, "Explore prompts for an unfinished new route without leaving the editor")
        draft.showRouteExitConfirmation = false // Keep editing, as the dialog binding does.
        try check(draft.activeRoute == draftRoute && draft.editing && draft.undoStack.count == 1, "Keep editing preserves the route and undo history")
        try check(await draft.saveRouteAndExplore(), "Save and exit succeeds")
        try check(draft.activeRoute == nil && !draft.editing && draft.tab == .explore && draft.undoStack.isEmpty, "Saving closes the route editor")
        try check(try await draft.routeStore.load().contains(where: { $0.id == draftRoute.id && $0.points == draftRoute.points }), "Save and exit leaves the actual route in the persistent library")

        let edited = try await savedStore()
        try await appendPoint(edited)
        edited.requestExplore()
        try check(edited.showRouteExitConfirmation, "Editing a saved route requires confirmation even after its background recovery write")
        edited.showRouteExitConfirmation = false
        edited.undo(); try await wait(edited)
        try check(!edited.routeNeedsExitConfirmation, "Undoing back to the saved geometry removes the dirty state despite a newer timestamp")
        edited.redo(); try await wait(edited)
        try check(edited.routeNeedsExitConfirmation, "Redo restores the unsaved edit")
        edited.renameRoute(edited.activeRoute!, to: "Renamed while editing"); try await wait(edited)
        edited.updateNotes("Saved while editing"); try await wait(edited)
        try check(edited.routeNeedsExitConfirmation, "Saving a name or notes does not silently finish pending geometry edits")
        edited.finishRoute()
        edited.requestExplore()
        try check(edited.activeRoute == nil && !edited.showRouteExitConfirmation, "Finishing the edited route makes the next Explore tap exit directly")

        let discard = try await savedStore()
        try await appendPoint(discard)
        try check(await discard.discardRouteEditsAndExplore(), "Discarding an existing route edit succeeds")
        let restored = try await discard.routeStore.load()
        try check(restored.count == 1 && restored[0].points == original.points && restored[0].waypoints == original.waypoints, "Discard restores the prior saved route rather than deleting it or retaining the recovery edit")
        try check(discard.activeRoute == nil && discard.tab == .explore, "Discard returns to Explore")

        let emptied = try await savedStore()
        emptied.activeRoute!.waypoints = []; emptied.activeRoute!.segments = []
        emptied.requestExplore()
        try check(emptied.showRouteExitConfirmation, "Removing every point from a saved route is still a pending edit")
        try check(await emptied.discardRouteEditsAndExplore(), "An emptied route can be restored instead of discarded silently")
        try check(try await emptied.routeStore.load().first?.points == original.points, "Discard restores all points of the prior saved route")

        let discardNew = try await savedStore()
        discardNew.startRoute(); discardNew.planningMode = .direct
        discardNew.tapTerrain(point(0.7).coordinate); try await wait(discardNew)
        let newID = discardNew.activeRoute!.id
        try check(await discardNew.discardRouteEditsAndExplore(), "A new draft can be discarded")
        let remaining = try await discardNew.routeStore.load()
        try check(remaining.count == 1 && remaining[0].id == original.id && !remaining.contains(where: { $0.id == newID }), "Discarding a new draft removes only that draft and preserves existing walks")

        let empty = store()
        empty.startRoute(); empty.requestExplore()
        try check(empty.activeRoute == nil && !empty.showRouteExitConfirmation, "An untouched empty draft exits directly")

        let automatic = try await savedStore()
        automatic.activeRoute!.modifiedAt = .distantFuture
        automatic.activeRoute!.regionID = "another-terrain-window"
        try check(!automatic.routeNeedsExitConfirmation, "Automatic timestamp and terrain-window changes are not unsaved route edits")
        automatic.renameRoute(automatic.activeRoute!, to: "My saved name"); try await wait(automatic)
        try check(!automatic.routeNeedsExitConfirmation, "An explicitly saved rename does not cause a redundant exit prompt")
        automatic.updateNotes("Saved notes"); try await wait(automatic)
        try check(!automatic.routeNeedsExitConfirmation, "Explicitly saved notes do not cause a redundant exit prompt")

        let busy = try await savedStore()
        busy.isRouting = true; busy.requestExplore()
        try check(busy.activeRoute != nil && !busy.showRouteExitConfirmation, "Explore cannot interrupt an in-progress route update")
        let busySave = await busy.saveRouteAndExplore(), busyDiscard = await busy.discardRouteEditsAndExplore()
        try check(!busySave && !busyDiscard, "Confirmation actions also reject a concurrent route update")
        busy.isRouting = false

        let blockedDirectory = root.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedDirectory)
        let failure = store(directory: blockedDirectory)
        failure.activeRoute = original; failure.editing = true
        try check(!(await failure.saveRouteAndExplore()), "A failed file write must not report a successful save")
        try check(failure.activeRoute == original && failure.editing && failure.errorMessage != nil && !failure.isRouting, "A failed save keeps the route open for retry with an error")
        let failedDiscard = store(directory: blockedDirectory)
        failedDiscard.routes = [original]; failedDiscard.activeRoute = original
        failedDiscard.activeRoute!.name = "Unsaved name"; failedDiscard.editing = true
        try check(!(await failedDiscard.discardRouteEditsAndExplore()), "A failed restoration must not report a successful discard")
        try check(failedDiscard.activeRoute?.name == "Unsaved name" && failedDiscard.editing && failedDiscard.errorMessage != nil, "A failed discard retains the edit and stays in the editor")

        print("PASS \(checks) route exit, save, discard, persistence and failure checks")
    }
}
