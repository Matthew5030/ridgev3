import Foundation

actor TileProgressAudit {
    var ready=Set<GeoBounds>()
    var valid=true
    var updates=0
    func record(_ done:Set<GeoBounds>,_ active:Set<GeoBounds>,plan:WorldDownloadPlan,cache:URL) {
        valid = valid && ready.isSubset(of:done) && done.isDisjoint(with:active)
        for part in plan.parts {
            for tile in part.source.tiles where done.contains(tile.mesh.bounds) {
                let assets=[part.source.overview,part.source.graph,tile.map,
                    WorldMapAsset(file:tile.mesh.path,byteCount:tile.mesh.byteCount,sha256:tile.mesh.sha256)]
                    + [tile.background].compactMap { $0 }.map { WorldMapAsset(file:$0.path,byteCount:$0.byteCount,sha256:$0.sha256) }
                for asset in assets {
                    let data=try? Data(contentsOf:cache.appendingPathComponent(asset.sha256))
                    valid = valid && data.map { $0.count == asset.byteCount && AdaptiveTerrainCodec.hash($0) == asset.sha256 } == true
                }
            }
        }
        ready=done;updates+=1
    }
    func passed(_ expected:Set<GeoBounds>) -> Bool { valid && ready==expected && updates>1 }
}

@main struct WorldCatalogTests {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ pass: Bool,_ message: String) throws { guard pass else { throw RidgeError.message(message) };checks+=1 }
        func wait(_ active: () -> Bool) async throws {
            let deadline=Date().addingTimeInterval(180)
            while active() && Date()<deadline { try await Task.sleep(nanoseconds:20_000_000) }
            try check(!active(),"Operation timed out")
        }
        let local=try WorldLibrary.root(mode:"local",local:"http://127.0.0.1:8787")
        try check(local.path=="/world","Local server root")
        for bad in ["", "file:///etc", "http://u:p@host", "https://host/?q=1", "http://host/#fragment"] {
            do { _=try WorldLibrary.root(mode:"local",local:bad);throw RidgeError.message("Accepted bad endpoint") }
            catch { try check(error.localizedDescription != "Accepted bad endpoint","Endpoint rejection") }
        }
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("ridge-download-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let model=WorldModel(cacheURL:cache)
        await model.configure(mode:"local",local:local.absoluteString)
        guard let catalog=model.catalog else { throw RidgeError.message(model.message ?? "Missing catalogue") }
        let origin=GeoPoint(latitude:53.0685,longitude:-4.0763)
        try check(catalog.sources.count==2531,"Full catalogue available for choosing an area")
        model.distance=2000
        model.offerDownload(at:origin,radius:600)
        try await wait { model.checkingDownload }
        guard let plan=model.downloadPlan else { throw RidgeError.message(model.downloadError ?? "No plan") }
        try check(plan.bytes>0 && !plan.edges.isEmpty,"Exact transfer estimate and geographic preview")
        try check(model.source==nil && !model.isSavingOffline && !model.in3D,"Reviewing an area cannot open or download terrain")
        let files=try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)
        try check(files.allSatisfy { $0.lastPathComponent.count != 64 },"Only metadata fetched before confirmation")
        model.downloadAndOpen()
        try await wait { model.isSavingOffline || model.streaming || model.isLoading }
        try check(model.downloadError==nil && model.message==nil,model.downloadError ?? model.message ?? "Download failure")
        guard let source=model.source else { throw RidgeError.message("Completed download did not prepare terrain") }
        try check(model.downloadCenter==nil && model.downloadPhase==nil,"Transfer and preparation finish separately")
        try check(Set(model.offlineBounds)==Set(plan.bounds),"Only complete selected tiles become offline coverage")
        try check(source.tiles.allSatisfy { plan.bounds.contains($0.mesh.bounds) },"Rendering never expands into unsaved tiles")
        try check(model.downloadedBytes==plan.bytes,"Transfer progress reaches the declared total")
        try check(model.completedDownloadTiles==Set(plan.bounds) && model.activeDownloadTiles.isEmpty,"Tile progress completes exactly the selected area")
        try check(source.tiles.allSatisfy { model.preparedTile($0.id) != nil },"Every admitted tile has local cartography")
        try check(model.routeTerrain?.graph?.nodes.allSatisfy { node in plan.bounds.contains { $0.contains(node.coordinate) } } == true,"Walking graph cannot route through undownloaded tiles")
        model.in3D=true
        let revision=source.revision
        let outside=GeoPoint(latitude:53.2,longitude:-4.0)
        model.update(center:outside,distance:2000)
        try await Task.sleep(nanoseconds:100_000_000)
        try check(!model.streaming && model.source?.revision==revision,"Crossing the edge never starts live terrain loading")
        try check(model.downloadCenter==nil && model.coverageMessage != nil,"Movement explains the boundary without starting a download")
        model.suspend()
        let reopened=WorldModel(cacheURL:cache)
        await reopened.configure(mode:"local",local:local.absoluteString)
        try check(reopened.hasCoverage(origin),"Saved coverage survives relaunch")
        reopened.browse(origin)
        try await wait { reopened.streaming || reopened.isLoading }
        try check(reopened.source != nil && reopened.downloadCenter==nil,"Downloaded area reopens directly from disk")
        reopened.suspend()
        let first=plan.parts[0]
        let region=catalog.sources.first { $0.id==first.source.id }!
        let cacheOnly=WorldSourceStore(cacheURL:cache,allowsNetwork:false)
        let manifest=try await cacheOnly.manifest(address:local.appendingPathComponent(region.path).absoluteString,routing:region.routing)
        let tile=first.source.tiles[0]
        _=try await cacheOnly.prepare(tile,request:.init(id:tile.id,pixels:128,fine:true),sourceBounds:manifest.bounds)
        try check(true,"Cache-only renderer reads saved vectors and fine LiDAR")
        // The server remains available. A missing file must fail locally rather
        // than silently fetching it and stalling the gesture/render path.
        let missing=cache.appendingPathComponent(tile.mesh.sha256)
        try FileManager.default.removeItem(at:missing)
        do {
            _=try await cacheOnly.prepare(tile,request:.init(id:tile.id,pixels:128,fine:true),sourceBounds:manifest.bounds)
            throw RidgeError.message("Cache-only renderer fetched a missing file")
        } catch { try check(error.localizedDescription.contains("downloaded map file is missing"),"Missing detail never falls back to the live server") }
        try check(!FileManager.default.fileExists(atPath:missing.path),"Missing asset remains absent until explicit repair")
        let repair=WorldDownloadStore(cacheURL:cache)
        let repairPlan=try await repair.plan(center:origin,radius:600,catalog:catalog,root:local)
        try check(repairPlan.bytes==Int64(tile.mesh.byteCount),"Resume/repair downloads only missing bytes")
        let rectangle=tile.mesh.bounds
        let drawn=try await repair.plan(center:rectangle.center,radius:8000,catalog:catalog,root:local,selection:rectangle)
        try check(drawn.selection==rectangle && Set(drawn.bounds)==[rectangle],"Drawing one exact tile excludes touching neighbours")
        try check(drawn.bytes==Int64(tile.mesh.byteCount),"Drawn estimate uses exact missing files")
        let audit=TileProgressAudit()
        try await repair.download(drawn,tilesProgress: { done,active in
            await audit.record(done,active,plan:drawn,cache:cache)
        },progress: { _ in })
        try check(await audit.passed(Set(drawn.bounds)),"Ready animation only follows verified terrain, vectors and shared files")
        let tooLarge=GeoBounds(minLatitude:52,minLongitude:-5,maxLatitude:54,maxLongitude:-3)
        do {
            _=try await repair.plan(center:origin,radius:8000,catalog:catalog,root:local,selection:tooLarge)
            throw RidgeError.message("Oversized rectangle accepted")
        } catch { try check(error.localizedDescription.contains("24 km"),"Oversized drawing has a useful correction") }
        model.setDrawingDownload(true)
        try check(model.drawingDownload && model.downloadPlan==nil && !model.checkingDownload,"Drawing waits for the user's rectangle")
        model.offerDownload(at:rectangle.center,selection:rectangle)
        try await wait { model.checkingDownload }
        try check(model.downloadPlan?.selection==rectangle,"Model preserves custom rectangle")
        model.cancelDownload()
        try check(!model.drawingDownload && model.downloadSelection==nil && model.completedDownloadTiles.isEmpty,"Cancel clears drawing and progress")
        model.offerDownload(at:outside,radius:600);model.cancelDownload()
        try await Task.sleep(nanoseconds:100_000_000)
        try check(model.downloadPlan==nil && !model.checkingDownload && !model.isSavingOffline,"Cancelled selection cannot publish stale work")
        print("PASS \(checks) download-first, offline rendering, boundary and repair checks; \(plan.bounds.count) tiles, \(plan.bytes) bytes")
    }
}
