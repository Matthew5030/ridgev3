import Foundation

@MainActor @main struct OfflinePackTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the published Eryri source") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let manifest = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: source.appendingPathComponent("index.json")))
        let all = try PackStore.offlinePackAssets(manifest)
        let expected = (manifest.cartography?.allTextures.reduce(Int64(0)) { $0 + $1.byteCount } ?? 0)
            + manifest.adaptive!.chunks.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
            + manifest.adaptive!.graphs.reduce(Int64(0)) { $0 + $1.byteCount }
            + manifest.adaptive!.contextBlocks!.reduce(Int64(0)) { $0 + $1.byteCount }
        precondition(all.reduce(Int64(0)) { $0 + $1.byteCount } == expected, "Whole pack omitted assets")
        precondition(Set(all.map(\.file)).count == all.count)
        precondition(!AdaptiveArea.allowance(manifest, context: TerrainBudget.Context(physicalMemory: 8 * 1_073_741_824, gpuTier: .modern)).allowed)
        print("Whole Eryri pack: \(all.count) assets; \(expected) bytes; enumerates despite exceeding scene memory allowance")

        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("ridge-offline-pack-tests-" + UUID().uuidString)
        defer { try? files.removeItem(at: work) }
        let cache = work.appendingPathComponent("sources/fixture")
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        let grid = manifest.grid!, uv = manifest.tileUV(GeoPoint(latitude: 53.0793, longitude: -4.0539))
        let selection = grid.selection(column: Int(uv.u * Double(grid.columns)), row: Int(uv.v * Double(grid.rows)))!
        var fixture = AdaptiveArea.preview(manifest, selection: selection)
        fixture.id = "fixture"; fixture.name = "Offline test"; fixture.places = []
        fixture.cartography = manifest.cartography!.cropped(to: fixture.bounds)
        fixture.horizon = nil
        fixture.adaptive!.isSource = true; fixture.adaptive!.context = nil; fixture.adaptive!.contextBlocks = nil
        try PackStore.validate(fixture)
        let assets = try PackStore.offlinePackAssets(fixture)
        precondition(assets.reduce(Int64(0)) { $0 + $1.byteCount } < 40_000_000, "Refuse an unexpectedly large test download")
        try JSONEncoder().encode(fixture).write(to: cache.appendingPathComponent("pack.json"))
        let remote = URL(string: "http://127.0.0.1:8787/" + manifest.id)!
        try JSONEncoder().encode(remote).write(to: cache.appendingPathComponent("origin.json"))
        let entry = PackEntry(manifest: fixture, directory: cache, installed: false, remoteSource: remote)
        let packs = PackStore(root: work.appendingPathComponent("areas"), bundledDirectory: nil, sourceDirectory: work.appendingPathComponent("sources"))
        let before = try await packs.offlinePackSummary(entry)
        precondition(!before.complete && before.download.cachedBytes == 0)
        let suite = "ridge.offline.pack.test." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let app = AppStore(packs: packs, routeStore: RouteStore(directory: work.appendingPathComponent("routes")), preferences: preferences)
        app.entries = [entry]
        app.downloadOfflinePack(entry)
        try await Task.sleep(for: .milliseconds(30))
        app.cancelPreparation()
        app.downloadOfflinePack(entry)
        let deadline = Date().addingTimeInterval(90)
        while app.isPreparing {
            precondition(Date() < deadline, "Pack download timed out")
            try await Task.sleep(for: .milliseconds(30))
        }
        precondition(app.errorMessage == nil, app.errorMessage ?? "")
        precondition(app.activeTerrain == nil && app.activeRoute == nil, "Download opened a scene")
        precondition(app.entries.allSatisfy { !$0.installed }, "Download created a saved 3D area")
        let after = try await packs.offlinePackSummary(entry)
        precondition(after.complete && after.download.totalBytes == before.download.totalBytes)
        var offline = entry; offline.remoteSource = URL(string: "http://127.0.0.1:1")!
        try await packs.downloadOfflinePack(offline, transfer: { _, _ in fatalError("Cached pack transferred bytes") }, progress: { _ in })
        let scene = try await packs.prepareAdaptive(offline, selection: AreaSelection(minU: 0, minV: 0, maxU: 1, maxV: 1), displayName: nil) { _ in }
        precondition(scene.adaptiveMeshes.count == 1 && scene.cartography != nil)
        let stored=try await packs.downloadedSourceStorage()
        precondition(stored.count==1 && stored[0].bytes>0,"Previously downloaded source files appear in storage management")
        try await packs.removeDownloadedSource(entry)
        let removed = try await packs.offlinePackSummary(offline)
        precondition(!removed.complete && removed.download.cachedBytes == 0)
        let reopened = try await packs.load(id: scene.manifest.id)
        precondition(reopened.adaptiveMeshes.count == 1 && reopened.graph?.nodes.isEmpty == false, "Removing download damaged saved area")
        precondition(files.fileExists(atPath: cache.appendingPathComponent("pack.json").path))
        let sourcesAfterRemoval=try await packs.downloadedSourceStorage()
        precondition(sourcesAfterRemoval.isEmpty,"Removed source no longer appears as downloaded")
        let savedRoutes=work.appendingPathComponent("routes/preserved.gpx")
        try files.createDirectory(at:savedRoutes.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("saved route".utf8).write(to:savedRoutes)
        await app.refresh()
        let abandoned=work.appendingPathComponent("areas/.adaptive-interrupted")
        try files.createDirectory(at:abandoned,withIntermediateDirectories:true)
        try Data([1,2,3]).write(to:abandoned.appendingPathComponent("partial-terrain"))
        try await app.removeAllDownloadedAreas()
        let catalogueAfterRemoval=try await packs.catalogue(),routesAfterRemoval=try Data(contentsOf:savedRoutes)
        precondition(catalogueAfterRemoval.allSatisfy { !$0.installed },"Remove all clears previous saved 3D areas")
        precondition(routesAfterRemoval==Data("saved route".utf8),"Remove all keeps routes")
        precondition(!files.fileExists(atPath:abandoned.path),"Remove all clears abandoned preparation files too")
        print("PASS: complete asset accounting, RAM-independent download, real HTTP assets, no scene allocation, cached offline retry, offline area selection, removal preserves saved terrain/maps/paths")
    }
}
