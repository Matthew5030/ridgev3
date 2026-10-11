import Foundation

actor TileProgressAudit {
    var ready=Set<GeoBounds>()
    var valid=true
    var updates=0
    var existingNeverActive=true
    var initialReady: Set<GeoBounds>?
    func record(_ done:Set<GeoBounds>,_ active:Set<GeoBounds>,plan:WorldDownloadPlan,cache:URL) {
        if initialReady == nil { initialReady=done }
        existingNeverActive = existingNeverActive && plan.readyBounds.isDisjoint(with:active)
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
    func reused(_ expected:Set<GeoBounds>) -> Bool { initialReady==expected && existingNeverActive }
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
        let local=try WorldLibrary.root(mode:"local",local:ProcessInfo.processInfo.environment["RIDGE_TEST_SERVER"] ?? "http://127.0.0.1:8787")
        try check(local.path=="/world","Local server root")
        let liveCount=try await WorldLibrary.checkConnection(root:local)
        try check(liveCount==2531,"Connection test reads the live catalogue")
        do {
            _=try await WorldLibrary.checkConnection(root:local.appendingPathComponent("missing-library"))
            throw RidgeError.message("Accepted missing live catalogue")
        } catch {
            try check(error.localizedDescription.contains("HTTP 404"),"Connection test reports wrong server paths without using cached data")
        }
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
        let section=catalog.region(at:origin)!
        let selected=WorldRegionPack(id:"connection-test",name:"Connection test",subtitle:"",landmark:"",
                                     cells:[.init(id:section.id,bounds:section.bounds)])
        let reconnecting=WorldModel(cacheURL:cache)
        reconnecting.offerRegionDownload(selected)
        try check(reconnecting.regionPlan==nil && reconnecting.downloadError != nil,"Selecting before connection cannot offer an invalid download")
        await reconnecting.configure(mode:"local",local:local.absoluteString,preservingSelection:true)
        try check(reconnecting.downloadRegion?.id==selected.id && reconnecting.regionPlan != nil && reconnecting.downloadError==nil,
                  "Successful reconnection restores the selected region's download action")
        try check(!reconnecting.isSavingOffline && !reconnecting.in3D,"Reconnecting never starts a download or terrain load")
        reconnecting.cancelDownload()
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
        let shifted=GeoPoint(latitude:origin.latitude,longitude:origin.longitude+0.012)
        let overlap=try await repair.plan(center:shifted,radius:600,catalog:catalog,root:local)
        let existing=Set(overlap.bounds).intersection(plan.bounds)
        try check(!existing.isEmpty && existing.count<overlap.bounds.count,"Overlap fixture includes both saved and new tiles")
        try check(overlap.readyBounds==existing,"Overlapping tiles are ready in the preview before any transfer")
        let overlapAudit=TileProgressAudit()
        try await repair.download(overlap,tilesProgress: { done,active in
            await overlapAudit.record(done,active,plan:overlap,cache:cache)
        },progress: { _ in })
        try check(await overlapAudit.passed(Set(overlap.bounds)),"Overlapping download completes with verified assets")
        try check(await overlapAudit.reused(existing),"Saved tiles start ready and never enter the loading animation")
        let repeated=try await repair.plan(center:shifted,radius:600,catalog:catalog,root:local)
        try check(repeated.bytes==0 && repeated.readyBounds==Set(repeated.bounds),"Selecting the same area again requires no new data")
        for part in repeated.parts {
            let region=catalog.sources.first { $0.id==part.source.id }!
            let offline=WorldSourceStore(cacheURL:cache,allowsNetwork:false)
            _=try await offline.manifest(address:local.appendingPathComponent(region.path).absoluteString,routing:region.routing,preferCached:true)
            // A fully overlapping selection must finish even with HTTP forbidden.
            try await offline.pin(part.source.tiles,source:part.source,countCachedInProgress:false,assetProgress: { verified,active in
                precondition(active.isEmpty,"Cached files entered the transfer queue")
                precondition(!verified.isEmpty,"Cached files must be ready immediately")
            },progress: { bytes in precondition(bytes==0,"Cached assets counted as new data") })
        }
        try check(true,"Fully overlapping saves need no network or active transfer files")
        // Verify a previously checked file is not blindly trusted after replacement.
        let stampTile=repeated.parts[0].source.tiles[0]
        let stampFile=cache.appendingPathComponent(stampTile.mesh.sha256)
        var damaged=try Data(contentsOf:stampFile);damaged[0] ^= 1
        try damaged.write(to:stampFile,options:.atomic)
        let stampAsset=WorldMapAsset(file:stampTile.mesh.path,byteCount:stampTile.mesh.byteCount,sha256:stampTile.mesh.sha256)
        try check(try await repeated.parts[0].files.cachedAssetHashes(for:[stampAsset]).isEmpty,"Replacing a same-size file invalidates remembered verification")
        let damagedPlan=try await repair.plan(center:shifted,radius:600,catalog:catalog,root:local)
        try check(damagedPlan.bytes==Int64(stampTile.mesh.byteCount) && !damagedPlan.readyBounds.contains(stampTile.mesh.bounds),"Damaged overlapping tiles request only their broken asset")
        let unavailable="http://127.0.0.1:1/world/world.json"
        let offlineIndex=cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(unavailable.utf8))+".index")
        try JSONEncoder().encode(first.source).write(to:offlineIndex)
        let unreachable=WorldSourceStore(cacheURL:cache)
        _=try await unreachable.manifest(address:unavailable,preferCached:true)
        let began=Date()
        do {
            try await unreachable.checkDownloadConnection()
            throw RidgeError.message("Unreachable server accepted")
        } catch { try check(error.localizedDescription.contains("Cannot reach 127.0.0.1"),"Dead server produces an actionable connection error") }
        try check(Date().timeIntervalSince(began)<10,"Connection failure has a bounded wait")
        let failedModel=WorldModel(cacheURL:cache)
        await failedModel.configure(mode:"local",local:local.absoluteString)
        failedModel.downloadCenter=origin
        failedModel.downloadPlan=WorldDownloadPlan(center:origin,radius:600,selection:nil,
            parts:[.init(source:first.source,files:unreachable,missingBytes:1)],bytes:1,
            bounds:plan.bounds,edges:plan.edges,readyBounds:[])
        failedModel.downloadAndOpen()
        try check(failedModel.isConnectingDownload,"Connection checking is distinct from a 0% transfer")
        try await wait { failedModel.isSavingOffline || failedModel.checkingDownload }
        try check(!failedModel.isConnectingDownload && failedModel.downloadError?.contains("Cannot reach") == true,"Failed connection leaves progress and offers retry")
        try check(failedModel.downloadCenter==origin && failedModel.activeDownloadTiles.isEmpty,"Connection failure keeps selection without fake active tiles")
        failedModel.cancelDownload()
        model.offerDownload(at:outside,radius:600);model.cancelDownload()
        try await Task.sleep(nanoseconds:100_000_000)
        try check(model.downloadPlan==nil && !model.checkingDownload && !model.isSavingOffline,"Cancelled selection cannot publish stale work")
        print("PASS \(checks) download-first, offline rendering, boundary and repair checks; \(plan.bounds.count) tiles, \(plan.bytes) bytes")
    }
}
