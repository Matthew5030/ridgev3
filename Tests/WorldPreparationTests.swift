import Foundation

/// Warm-cache benchmark: transfer is timed separately from opening the saved map.
@main struct WorldPreparationTests {
    @MainActor static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        let cache = env["RIDGE_PREPARATION_CACHE"].map { URL(fileURLWithPath:$0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ridge-preparation-"+UUID().uuidString)
        defer { if env["RIDGE_PREPARATION_CACHE"] == nil { try? FileManager.default.removeItem(at:cache) } }
        let local = env["RIDGE_TEST_SERVER"] ?? "http://127.0.0.1:8787"
        let root = try WorldLibrary.root(mode:"local",local:local)
        let catalog = try await WorldCatalogStore(cacheURL:cache).open(root:root)
        let point = GeoPoint(latitude:53.0685,longitude:-4.0763)
        let downloads = WorldDownloadStore(cacheURL:cache)
        let plan = try await downloads.plan(center:point,radius:8000,catalog:catalog,root:root)
        let transfer = Date()
        try await downloads.download(plan,progress: { _ in })
        print("Transfer: \(plan.bytes) bytes, \(plan.bounds.count) tiles, \(Date().timeIntervalSince(transfer)) s")
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent()
        let distant=WorldDistantTerrainStore(root:resources.appendingPathComponent("WorldContext.bundle"),atlas:resources.appendingPathComponent("WorldAtlas.bundle"))
        let model = WorldModel(cacheURL:cache,distantStore:distant)
        await model.configure(mode:"local",local:local)
        let receipts=cache.appendingPathComponent("offline-coverage.json")
        let receiptDate=try? receipts.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate
        model.distance = 3500
        let began = Date()
        model.browse(point)
        var firstEntry:Double?
        var previewFrame:GeoBounds?
        var previewID:String?
        var phases = Set<String>()
        while model.streaming || model.isLoading {
            guard Date().timeIntervalSince(began)<180 else { throw RidgeError.message("Preparation timed out") }
            if let phase=model.downloadPhase { phases.insert(phase) }
            if firstEntry == nil,model.canEnterTerrain(at:point) {
                firstEntry=Date().timeIntervalSince(began)
                previewFrame=model.source?.frame;previewID=model.source?.id
                guard model.routeTerrain == nil,model.distantTerrain != nil,model.streaming else { throw RidgeError.message("Preview did not precede detailed terrain and routing") }
                guard !model.canEnterTerrain(at:GeoPoint(latitude:0,longitude:0)) else { throw RidgeError.message("Preview bypassed offline coverage") }
                print("3D overview ready: \(firstEntry!) s, \(model.source?.tiles.count ?? 0) detailed tiles")
            }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        guard let source=model.source,model.message == nil else { throw RidgeError.message(model.message ?? "Missing terrain") }
        print("Ready: \(source.tiles.count) tiles, radius \(model.loadedRadius) m, \(Date().timeIntervalSince(began)) s, \(phases.count) progress updates")
        if env["RIDGE_PREPARATION_BASELINE"] != "1" {
            guard firstEntry != nil,model.routeTerrain != nil else { throw RidgeError.message("Missing staged overview/detail handover") }
            guard previewFrame==source.frame,previewID==source.id else { throw RidgeError.message("Detailed terrain would reset the preview camera") }
            guard model.loadedRadius == WorldWindow.entryRadius, source.tiles.count<plan.bounds.count/2 else { throw RidgeError.message("Entry waited for the extended horizon") }
            guard (try? receipts.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate)==receiptDate else { throw RidgeError.message("Opening saved terrain rewrote download coverage") }
            guard model.browse(point),!model.streaming else { throw RidgeError.message("Ready atlas viewport restarted preparation") }
            guard phases.count>1 else { throw RidgeError.message("Preparation did not report progress") }
            guard source.tiles.allSatisfy({ model.preparedTile($0.id) != nil }) else { throw RidgeError.message("Entry contains untextured tiles") }
            model.in3D=true
            model.update(center:point,distance:3500)
            guard model.streaming else { throw RidgeError.message("Horizon did not resume after entry") }
            model.suspend()
            print("PASS: overview enters before detail; camera frame retained; every detail tile textured; horizon grows in 3D")
        } else { model.suspend() }
    }
}
