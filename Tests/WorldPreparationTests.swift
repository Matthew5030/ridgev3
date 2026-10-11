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
        let model = WorldModel(cacheURL:cache)
        await model.configure(mode:"local",local:local)
        model.distance = 3500
        let began = Date()
        model.browse(point)
        var phases = Set<String>()
        while model.streaming || model.isLoading {
            guard Date().timeIntervalSince(began)<180 else { throw RidgeError.message("Preparation timed out") }
            if let phase=model.downloadPhase { phases.insert(phase) }
            try await Task.sleep(nanoseconds:20_000_000)
        }
        guard let source=model.source,model.message == nil else { throw RidgeError.message(model.message ?? "Missing terrain") }
        print("Ready: \(source.tiles.count) tiles, radius \(model.loadedRadius) m, \(Date().timeIntervalSince(began)) s, \(phases.count) progress updates")
        if env["RIDGE_PREPARATION_BASELINE"] != "1" {
            guard model.loadedRadius == 8000 else { throw RidgeError.message("Entry waited for the extended horizon") }
            guard model.browse(point),!model.streaming else { throw RidgeError.message("Ready atlas viewport restarted preparation") }
            guard phases.count>1 else { throw RidgeError.message("Preparation did not report progress") }
            guard source.tiles.allSatisfy({ model.preparedTile($0.id) != nil }) else { throw RidgeError.message("Entry contains untextured tiles") }
            model.in3D=true
            model.update(center:point,distance:3500)
            guard model.streaming else { throw RidgeError.message("Horizon did not resume after entry") }
            model.suspend()
            print("PASS: entry stops at the initial window; every tile textured; wider horizon starts in 3D")
        } else { model.suspend() }
    }
}
