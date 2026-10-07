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
            let deadline = Date().addingTimeInterval(90)
            while model.loadingRegionID != nil && Date() < deadline { try await Task.sleep(nanoseconds:20_000_000) }
            try check(model.loadingRegionID == nil && model.message == nil, model.message ?? "Load timed out")
        }
        model.browse(a.bounds.center); try await waitForLoad()
        try check(model.source?.id == a.id, "First location loaded")
        model.in3D = true
        model.cameraPose = TerrainCameraPose(target:b.bounds.center,targetElevationMeters:300,yaw:1,pitch:0.8,distanceMeters:2000)
        model.update(center:b.bounds.center,distance:2000)
        try check(model.source?.id == a.id && model.loadingRegionID == b.id, "Keep current terrain while next loads")
        try await waitForLoad()
        try check(model.source?.id == b.id && model.center == b.bounds.center, "Pan changes region automatically")
        try check(model.cameraPose?.yaw == 1 && model.cameraPose?.pitch == 0.8, "Preserve camera orientation")
        model.browse(a.bounds.center)
        model.browse(b.bounds.center) // Reverse direction while download is pending.
        try await Task.sleep(nanoseconds:100_000_000)
        try check(model.source?.id == b.id && model.loadingRegionID == nil, "Cancelled stale region cannot replace visible map")
        model.browse(a.bounds.center)
        await model.configure(mode:"cloud",local:"")
        try await Task.sleep(nanoseconds:100_000_000)
        try check(model.source == nil && model.catalog?.sources.count == 4, "Changing source cancels old region")
        print("PASS \(checks) catalogue, handover and cancellation checks")
    }
}
