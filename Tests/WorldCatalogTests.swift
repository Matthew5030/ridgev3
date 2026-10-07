import Foundation

@main struct WorldCatalogTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ pass: Bool, _ message: String) throws {
            guard pass else { throw RidgeError.message(message) }; checks += 1
        }
        let cloud = try WorldLibrary.root(mode: "cloud", local: "")
        try check(cloud.absoluteString == WorldLibrary.cloud, "Cloud root")
        let local = try WorldLibrary.root(mode: "local", local: "http://127.0.0.1:8787")
        try check(local.path == "/world", "LAN root uses stable alias")
        for bad in ["", "file:///etc", "http://u:p@host", "https://host/?q=1", "http://host/#fragment"] {
            do { _ = try WorldLibrary.root(mode:"local", local:bad); throw RidgeError.message("Accepted bad endpoint") }
            catch { try check(!(error.localizedDescription == "Accepted bad endpoint"), "Endpoint rejection") }
        }
        let catalog = try await WorldCatalogStore(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)).open(root: cloud)
        try catalog.validate()
        try check(catalog.sources.count == 4, "Pilot catalogue")
        for region in catalog.sources { try check(catalog.region(at:region.bounds.center)?.id == region.id, "Geographic selection") }
        let a = catalog.sources.first { $0.id.hasSuffix("c16-r00") }!
        let b = catalog.sources.first { $0.id.hasSuffix("c00-r00") }!
        let edge = GeoPoint(latitude:a.bounds.center.latitude, longitude:a.bounds.minLongitude)
        try check(catalog.region(at:edge, retaining:a.id)?.id == a.id, "Stable shared boundary")
        try check(catalog.region(at:edge, retaining:b.id)?.id == b.id, "Stable reverse boundary")
        try check(catalog.region(at:GeoPoint(latitude:54.5,longitude:-3)) == nil, "No invented cloud coverage")
        let invalid = WorldCatalog(schemaVersion:1,revision:"v1",sources:[.init(id:"world-test",path:"../secret",bounds:a.bounds,tileCount:1)])
        do { try invalid.validate(); throw RidgeError.message("Accepted traversal") }
        catch { try check(error.localizedDescription != "Accepted traversal", "Reject traversal") }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let model = WorldModel(cacheURL:cache)
        await model.configure(mode:"local", local:local.absoluteString)
        try check(model.catalog?.sources.count == 2531, "Full drive catalogue")
        func waitForLoad() async throws {
            let started = Date(), deadline = Date().addingTimeInterval(300)
            while model.loadingRegionID != nil && Date() < deadline { try await Task.sleep(nanoseconds:20_000_000) }
            FileHandle.standardError.write(Data("Landscape ready in \(Date().timeIntervalSince(started)) s, \(model.source?.tiles.count ?? 0) tiles\n".utf8))
            try check(model.loadingRegionID == nil && model.message == nil, model.message ?? "Load timed out")
        }
        model.browse(a.bounds.center)
        let proposalDeadline = Date().addingTimeInterval(60)
        while model.isLoading && Date() < proposalDeadline { try await Task.sleep(nanoseconds:20_000_000) }
        try check(model.downloadPhase == "Download this area" && model.source == nil, "No partial landscape before download approval")
        try check((model.downloadSummary?.remainingBytes ?? 0) > 0, "Missing download size is shown")
        let untouched = (try? FileManager.default.contentsOfDirectory(atPath:cache.path)) ?? []
        try check(!untouched.contains(where: { $0.count == 64 }), "Only metadata is fetched before download")
        model.downloadArea()
        try await waitForLoad()
        try check(model.downloadPhase == nil, "Gate clears only after the whole landscape is ready")
        let verified = WorldLandscapeStore(cacheURL:cache)
        let summary = try await verified.inspect(anchor:model.catalog!.sources.first { $0.id == a.id }!,catalog:model.catalog!,root:local)
        try check(summary.remainingBytes == 0, "Every fine mesh, vector page, background and routing file is saved")
        let pins = try JSONDecoder().decode(Set<String>.self,from:Data(contentsOf:cache.appendingPathComponent("pins.json")))
        try check(!pins.isEmpty, "Saved landscape is protected from eviction")
        let fineAsset = model.source!.tiles[0].mesh
        let fineURL = cache.appendingPathComponent(fineAsset.sha256)
        let intact = try Data(contentsOf:fineURL)
        try Data([0,1,2]).write(to:fineURL,options:.atomic)
        let damaged = try await verified.inspect(anchor:model.catalog!.sources.first { $0.id == a.id }!,catalog:model.catalog!,root:local)
        try check(damaged.remainingBytes >= Int64(fineAsset.byteCount), "A damaged saved mesh cannot bypass the download gate")
        try intact.write(to:fineURL,options:.atomic)
        try check(model.tiles.values.contains { $0.request.fine && $0.geometry != nil }, "Nearby fine terrain is prepared before entering 3D")
        try check(model.source?.id == a.id, "First location loaded")
        try check((model.source?.tiles.count ?? 0) > 256, "Neighbouring regions are loaded together")
        let landscape = model.source!
        try check(landscape.graph.file == "paths-connected-v1.json", "Only connected graph is used and pinned")
        try check(Set(landscape.tiles.map(\.id)).count == landscape.tiles.count, "Tile identifiers are globally unique")
        try check(model.backdrop?.geometries.count == landscape.tiles.count, "Every landscape tile has terrain")
        let graph = model.routeTerrain!.graph!
        let indexed = Dictionary(uniqueKeysWithValues:graph.nodes.map { ($0.id,$0) })
        let boundary = a.bounds.minLongitude
        let crossing = graph.edges.first { edge in
            guard let from = indexed[edge.from], let to = indexed[edge.to] else { return false }
            return (from.coordinate.longitude-boundary)*(to.coordinate.longitude-boundary)<0 && from.coordinate.distance(to:to.coordinate)>2
        }
        try check(crossing != nil, "Original path edges cross the old region boundary")
        if let edge = crossing {
            let start = indexed[edge.from]!.coordinate, end = indexed[edge.to]!.coordinate
            let route = try RouteEngine.walkingSegment(from:start,to:end,graph:graph)
            try check(route.points.count >= 2 && route.points.first!.coordinate.distance(to:start)<1 && route.points.last!.coordinate.distance(to:end)<1, "Follow paths across the original region boundary")
        }
        model.in3D = true
        model.cameraPose = TerrainCameraPose(target:b.bounds.center,targetElevationMeters:300,yaw:1,pitch:0.8,distanceMeters:2000)
        model.update(center:b.bounds.center,distance:2000)
        try check(model.source?.id == a.id && model.loadingRegionID == nil, "Crossing an internal boundary retains the landscape")
        try check(model.cameraPose?.yaw == 1 && model.cameraPose?.pitch == 0.8, "Preserve camera orientation")
        try check(landscape.tiles.allSatisfy { model.preparedTile($0.id) != nil }, "Far terrain keeps its map texture outside the detail budget")
        let requests = WorldWorkingSet.requests(source:landscape,center:b.bounds.center,distance:2000)
        let fineIDs = Set(requests.filter(\.fine).map(\.id))
        try check(landscape.tiles.filter { fineIDs.contains($0.id) }.reduce(Int64(0)) { $0+$1.mesh.residentBytes } <= WorldWorkingSet.meshBudget, "One global fine mesh budget")
        let far = GeoPoint(latitude:54.600,longitude:-3.137)
        model.browse(far)
        model.browse(b.bounds.center)
        try await Task.sleep(nanoseconds:100_000_000)
        try check(model.source?.id == a.id && model.loadingRegionID == nil, "Cancelled stale landscape cannot replace visible map")
        model.browse(far)
        model.suspend()
        try check(model.loadingRegionID == nil && !model.isLoading, "Backgrounding clears cancelled loading state")
        model.resume()
        let resumeDeadline = Date().addingTimeInterval(60)
        while model.isLoading && Date() < resumeDeadline { try await Task.sleep(nanoseconds:20_000_000) }
        try check(model.downloadPhase == "Download this area", "New landscape requires its own download")
        model.downloadArea()
        let progressDeadline = Date().addingTimeInterval(30)
        while model.downloadCompleted == 0 && model.isLoading && Date() < progressDeadline { try await Task.sleep(nanoseconds:5_000_000) }
        try check(model.downloadCompleted > 0 && model.source?.id == a.id, "Download progress does not replace the visible landscape")
        model.pauseDownload()
        try check(model.source?.id == a.id && !model.isLoading, "Cancel keeps the current landscape")
        model.retry()
        while model.isLoading && Date() < resumeDeadline { try await Task.sleep(nanoseconds:20_000_000) }
        model.update(center:b.bounds.center,distance:2000)
        try check(model.loadingRegionID != nil && model.requestFocus == nil, "The old camera cannot cancel a requested destination or fly there early")
        model.downloadArea(); try await waitForLoad()
        try check(model.requestFocus == far, "Fly to a searched destination only after download and preparation")
        try check(model.source?.bounds.contains(far) == true, "Returning to the app resumes the requested terrain")
        model.browse(a.bounds.center)
        try await waitForLoad()
        try check(model.source?.id == a.id && model.downloadSummary == nil, "Saved landscape opens without another download prompt")
        await model.configure(mode:"cloud",local:"")
        try await Task.sleep(nanoseconds:100_000_000)
        try check(model.source == nil && model.catalog?.sources.count == 4, "Changing source cancels old region")
        print("PASS \(checks) catalogue, handover and cancellation checks")
    }
}
