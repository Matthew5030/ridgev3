import Foundation

@main struct WorldCatalogTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ pass: Bool,_ message: String) throws {
            guard pass else { throw RidgeError.message(message) }; checks += 1
        }
        let cloud = try WorldLibrary.root(mode:"cloud",local:"")
        try check(cloud.absoluteString == WorldLibrary.cloud,"Cloud root")
        let local = try WorldLibrary.root(mode:"local",local:"http://127.0.0.1:8787")
        try check(local.path == "/world","LAN root uses stable alias")
        for bad in ["", "file:///etc", "http://u:p@host", "https://host/?q=1", "http://host/#fragment"] {
            do { _ = try WorldLibrary.root(mode:"local",local:bad); throw RidgeError.message("Accepted bad endpoint") }
            catch { try check(error.localizedDescription != "Accepted bad endpoint","Endpoint rejection") }
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-model-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let model = WorldModel(cacheURL:cache)
        await model.configure(mode:"local",local:local.absoluteString)
        guard let catalog = model.catalog else { throw RidgeError.message(model.message ?? "Missing catalogue") }
        try check(catalog.sources.count == 2531,"Full drive catalogue")
        try catalog.validate()
        let origin = GeoPoint(latitude:53.0685,longitude:-4.0763)
        let anchor = catalog.region(at:origin)!
        let invalid = WorldCatalog(schemaVersion:1,revision:"v1",sources:[.init(id:"world-test",path:"../secret",bounds:anchor.bounds,tileCount:1)])
        do { try invalid.validate(); throw RidgeError.message("Accepted traversal") }
        catch { try check(error.localizedDescription != "Accepted traversal","Reject traversal") }
        model.distance = 2000
        let began = Date()
        model.browse(origin)
        let deadline = Date().addingTimeInterval(300)
        while model.source == nil && model.streaming && Date()<deadline { try await Task.sleep(nanoseconds:20_000_000) }
        try check(model.source != nil,model.message ?? "Initial map timed out")
        print("First usable terrain: \(Date().timeIntervalSince(began)) s")
        try check(model.downloadPhase == nil,"No download confirmation interrupts entry")
        model.in3D = true
        model.cameraPose = TerrainCameraPose(target:origin,targetElevationMeters:300,yaw:1,pitch:0.8,distanceMeters:2000)
        while model.streaming && Date()<deadline { try await Task.sleep(nanoseconds:20_000_000) }
        try check(model.message == nil && !model.streaming,model.message ?? "Horizon timed out")
        print("Full horizon: \(model.source!.tiles.count) tiles, \(Date().timeIntervalSince(began)) s")
        try check(model.loadedRadius >= 16000,"Horizon grows beyond the initial entry without another gesture")
        let initial = model.source!, revision = initial.revision
        let shifted = GeoPoint(latitude:origin.latitude,longitude:origin.longitude+0.05)
        model.update(center:shifted,distance:2000)
        try check(model.source?.revision == revision && model.streaming,"Visible map stays installed while surroundings load")
        while model.streaming && Date()<deadline { try await Task.sleep(nanoseconds:20_000_000) }
        try check(model.source?.revision != revision && model.source?.frame == initial.frame,"Moving window publishes in the same frame")
        try check(model.cameraPose?.yaw == 1 && model.cameraPose?.pitch == 0.8,"Streaming preserves camera orientation")
        try check(model.source!.tiles.allSatisfy { model.preparedTile($0.id) != nil },"Every far tile retains cartography")
        let stable = model.source!.revision
        let destination = GeoPoint(latitude:54.6,longitude:-3.137)
        model.visit(destination)
        model.update(center:shifted,distance:2000)
        try check(model.loadingRegionID != nil && model.requestFocus == nil,"Old camera cannot cancel a requested destination or fly there early")
        model.suspend()
        try await Task.sleep(nanoseconds:100_000_000)
        try check(!model.streaming && model.source?.revision == stable,"Cancelled candidate cannot replace the visible map")
        model.visit(shifted)
        try check(model.requestFocus == shifted,"An already loaded destination focuses immediately")
        model.suspend()
        await model.configure(mode:"local",local:"http://127.0.0.1:1")
        try check(model.source == nil && model.catalog == nil && !model.streaming,"Source changes invalidate the previous window and requests")
        print("PASS \(checks) catalogue, automatic streaming, cancellation and camera checks")
    }
}
