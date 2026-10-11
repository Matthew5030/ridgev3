import Foundation

actor RegionTransferAudit {
    var streamedBeforeFinalIndex=false
    var bytes:Int64=0
    var tileEvents=0,maximumTiles=0
    var sawActive=false,validTiles=true
    var completedTiles=Set<GeoBounds>()
    var previousSavedCount=0
    var sawPreviousSection=false
    func recordTiles(_ state:WorldRegionTileProgress) {
        tileEvents+=1;maximumTiles=max(maximumTiles,state.tiles.count)
        sawActive = sawActive || !state.active.isEmpty
        let tiles=Set(state.tiles)
        validTiles = validTiles && state.completed.isSubset(of:tiles) && state.active.isSubset(of:tiles)
            && state.completed.isDisjoint(with:state.active) && state.savedTileCount>=previousSavedCount
        completedTiles.formUnion(state.completed)
        previousSavedCount=state.savedTileCount
        sawPreviousSection = sawPreviousSection || (state.savedTileCount>0 && !state.savedFills.isEmpty)
    }
    func record(_ value:Int64,saved:Int,finalIndex:URL) {
        bytes=value
        if saved==0,value>0,!FileManager.default.fileExists(atPath:finalIndex.path) { streamedBeforeFinalIndex=true }
    }
}

@main struct WorldRegionPackTests {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ value:Bool,_ reason:String) throws { guard value else { throw RidgeError.message(reason) };checks+=1 }
        func wait(_ active:()->Bool) async throws {
            let deadline=Date().addingTimeInterval(120)
            while active() && Date()<deadline { try await Task.sleep(nanoseconds:10_000_000) }
            try check(!active(),"Operation timed out")
        }
        var grid:[GeoBounds]=[]
        for y in 0..<100 { for x in 0..<100 {
            let latitude=50.0+Double(y)*0.01,longitude=Double(x)*0.01
            grid.append(GeoBounds(minLatitude:latitude,minLongitude:longitude,maxLatitude:latitude+0.01,maxLongitude:longitude+0.01))
        } }
        try check(WorldOfflineCoverage.displayBounds(grid).count==1,"A full saved region draws one fill instead of 10,000 tiles")
        let hole=grid[5050],withHole=grid.filter { $0 != hole }
        let displayed=WorldOfflineCoverage.displayBounds(withHole)
        try check(!displayed.contains { $0.contains(hole.center) },"Display merging preserves undownloaded holes")
        try check(withHole.allSatisfy { tile in displayed.contains { $0.contains(tile.center) } },"Display merging preserves every saved tile")
        let root=try WorldLibrary.root(mode:"local",local:ProcessInfo.processInfo.environment["RIDGE_TEST_SERVER"] ?? "http://127.0.0.1:8787")
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("ridge-region-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let catalog=try await WorldCatalogStore(cacheURL:cache).open(root:root)
        let packs=try WorldRegionPack.load(url:URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("uk-download-zones.json"))
        try check(packs.count==216,"Park areas and smaller surrounding regions")
        try check(Set(packs.compactMap(\.parkID)).count==15,"All fifteen prepared park boundaries have selectable areas")
        let wholeParks=WorldRegionPack.wholeParks(in:packs)
        for whole in wholeParks {
            let parts=packs.filter { $0.parkID==whole.id }
            try check(parts.count>1 && Set(whole.cells.map(\.id))==Set(parts.flatMap(\.cells).map(\.id)),"Whole park is exactly the union of its smaller areas")
            try check(Set(whole.sources(in:catalog).map(\.id))==Set(parts.flatMap { $0.sources(in:catalog) }.map(\.id)),"Whole park uses the same source files without extra surrounding regions")
        }
        let overlays=packs.map { WorldRegionMapOverlay(pack:$0,catalog:catalog) }
        for overlay in overlays {
            try check(overlay.labelFontScale>0,"Each label has a stable geographic fit")
            var previous=overlay.labelAppearance(at:0)
            for step in 1...400 {
                let current=overlay.labelAppearance(at:Double(step)*0.12/overlay.labelFontScale)
                try check(current.size>=previous.size && current.opacity>=previous.opacity,"Zoom label size and opacity are monotonic")
                try check(current.size-previous.size<0.121 && current.opacity-previous.opacity<0.023,"No discrete fitting or visibility jumps")
                previous=current
            }
            try check(previous.size==40 && previous.opacity==1,"Large labels settle at their maximum size")
            try check(WorldRegionMapOverlay.at(overlay.labelPoint,in:overlays)?.id==overlay.id,"Region labels are anchored inside their region")
            for cell in overlay.pack.cells {
                try check(WorldRegionMapOverlay.at(cell.bounds.center,in:overlays)?.id==overlay.id,"Map taps use the same grid partition as the download")
            }
        }
        try check(WorldRegionMapOverlay.at(.init(latitude:0,longitude:0),in:overlays)==nil,"Tapping outside UK packs selects nothing")
        let emptyOverlay=WorldRegionMapOverlay(pack:packs[0],catalog:nil)
        try check(emptyOverlay.available.isEmpty && !emptyOverlay.fills.isEmpty,"Missing catalogue cannot invent downloadable coverage")
        let members=packs.flatMap { $0.sources(in:catalog).map(\.id) }
        try check(Set(members).count==members.count && Set(members)==Set(catalog.sources.map(\.id)),"Every current source assigned exactly once")
        let cells=packs.flatMap(\.cells).map(\.id)
        try check(Set(cells).count==cells.count,"Preset map cells do not overlap")
        struct OriginalGrid:Decodable { struct Region:Decodable { let cells:[WorldRegionPack.Cell] };let regions:[Region] }
        let gridURL=URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("uk-pack-regions.json")
        let original=try JSONDecoder().decode(OriginalGrid.self,from:Data(contentsOf:gridURL))
        let expectedCells=Set(original.regions.flatMap(\.cells).flatMap { parent in
            [0,16,32].flatMap { row in [0,16,32].map { column in
                "world-"+parent.id+String(format:"-c%02d-r%02d",column,row)
            } }
        })
        try check(Set(cells)==expectedCells,"Subdivision retains all source sections, including unpublished areas")
        try check(Set(packs.map(\.id)).count==packs.count,"Every smaller pack has a stable unique ID")
        try check(packs.filter { $0.id.hasPrefix("area-fermanagh-sperrins") || $0.id.hasPrefix("area-antrim-down") }.allSatisfy { $0.sources(in:catalog).isEmpty },"Unpublished Northern Ireland is explicitly unavailable")
        let northern=packs.filter { $0.id.hasPrefix("area-aberdeenshire") }
        try check(northern.contains { $0.coveredCells(in:catalog).count<$0.cells.count },"Partial Scotland coverage is distinguishable from a full region")
        let regions=[catalog.sources[0],catalog.sources.last!]
        let fixture=WorldRegionPack(id:"fixture",name:"Test region",subtitle:"",landmark:"",cells:regions.map { .init(id:$0.id,bounds:$0.bounds) })
        try check(fixture.bounds.widthMeters>24_000,"Region fixture exceeds the custom-area size limit")
        let started=Date()
        let eryri=packs.first { $0.id=="park-eryri-nw" }!
        let allEryri=wholeParks.first { $0.id=="park-eryri" }!
        let eryriSize=WorldRegionDownloadPlan.estimate(pack:eryri,catalog:catalog,root:root)!
        let wholeSize=WorldRegionDownloadPlan.estimate(pack:allEryri,catalog:catalog,root:root)!
        try check(eryriSize.bytes<wholeSize.bytes/2 && eryriSize.parts.count<20,"North-west Eryri is a much smaller download than the whole park")
        try check(WorldRegionMapOverlay.at(.init(latitude:53.0685,longitude: -4.0763),in:overlays)?.pack.parkID=="park-eryri","Yr Wyddfa selects an Eryri park area")
        try check(WorldRegionMapOverlay.at(.init(latitude:53.30,longitude: -4.35),in:overlays)?.pack.parkID==nil,"Anglesey is separate from the Eryri download")
        let quick=WorldRegionDownloadPlan.estimate(pack:eryri,catalog:catalog,root:root)
        let offerSeconds=Date().timeIntervalSince(started)
        try check(quick?.isEstimate==true && quick?.parts.isEmpty==false,"Real Eryri region offers catalogue size immediately")
        try check(try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil).allSatisfy { !$0.pathExtension.contains("index") },"Quick offer fetches no section indexes")
        print("Catalogue-only Eryri offer: \(offerSeconds) s, \(quick!.parts.count) sections, upper estimate \(quick!.bytes) bytes")
        let store=WorldRegionDownloadStore(cacheURL:cache)
        let plan=try await store.plan(pack:fixture,catalog:catalog,root:root)
        try check(plan.parts.count==2 && plan.tileCount==regions.reduce(0) { $0+$1.tileCount },"Region plan includes every tile, beyond custom-area radius rules")
        try check(plan.bytes>0 && plan.bytes==plan.totalBytes,"Fresh download estimates actual unique assets")
        try check(try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil).allSatisfy { $0.lastPathComponent.count != 64 },"Planning only downloads metadata")
        let first=WorldRegionPack(id:"first",name:"First half",subtitle:"",landmark:"",cells:[fixture.cells[0]])
        let half=try await store.plan(pack:first,catalog:catalog,root:root)
        try await store.download(half,progress: { _,_ in })
        let partialOverlay=WorldRegionMapOverlay.make(packs:[fixture],catalog:catalog,offline:WorldOfflineCoverage.savedBounds(at:cache))[0]
        try check(partialOverlay.downloadState == .partial,"Saving one section marks a region partly downloaded")
        try check(partialOverlay.savedPoint.map { regions[0].bounds.contains($0) } == true,"Explore partial region opens an actually saved tile")
        let remaining=try await store.plan(pack:fixture,catalog:catalog,root:root)
        try check(remaining.bytes<plan.bytes && remaining.bytes>0,"Previously saved overlap reduces transfer")
        try check(WorldOfflineCoverage.savedBounds(at:cache).count==regions[0].tileCount,"Regional receipts are visible to normal exploration")
        // The model uses the same cache, but a regional save must not prepare a
        // country-sized scene or automatically fly to the centre of the pack.
        let model=WorldModel(cacheURL:cache)
        await model.configure(mode:"local",local:root.absoluteString)
        model.offerRegionDownload(fixture)
        try await wait { model.checkingDownload }
        try check(model.regionPlan?.isEstimate==true && !model.checkingDownload && model.source==nil,"Model presents the download immediately without rendering or preflight")
        model.downloadRegionPack()
        try await wait { model.isSavingOffline }
        try check(model.regionTileProgress.tiles.isEmpty && model.regionTileProgress.active.isEmpty,"Finished animation hands over to saved region shading")
        try check(model.regionComplete && model.downloadError==nil,model.downloadError ?? "Region did not finish")
        try check(model.downloadedBytes==remaining.bytes,"Estimated offer still transfers only missing bytes")
        try check(model.source==nil && model.downloadedDestination==nil && !model.in3D,"Saving a large region never enters 3D")
        try check(model.offlineBounds.count==plan.tileCount,"All regional tiles become usable in normal exploration")
        let receipts=WorldOfflineCoverage.savedBounds(at:cache)
        let savedOverlay=WorldRegionMapOverlay.make(packs:[fixture],catalog:catalog,offline:receipts+receipts)[0]
        try check(savedOverlay.downloadState == .saved && savedOverlay.savedTileCount==plan.tileCount,"Fully saved region is green; overlapping receipts are not double counted")
        let unsavedOverlay=WorldRegionMapOverlay.make(packs:[fixture],catalog:catalog,offline:[])[0]
        try check(unsavedOverlay.downloadState == .notSaved,"Available region without receipts is not downloaded")
        let unknownOverlay=WorldRegionMapOverlay.make(packs:[fixture],catalog:nil,offline:receipts)[0]
        try check(unknownOverlay.downloadState == .unavailable,"No catalogue does not invent available or complete downloads")
        let missingPoint=catalog.sources[1].bounds.center
        model.visit(missingPoint)
        try check(model.requestedDownloadPoint==missingPoint && model.downloadCenter==nil,"Unsaved destination requests a region instead of starting custom selection")
        model.requestedDownloadPoint=nil
        let repeated=try await store.plan(pack:fixture,catalog:catalog,root:root)
        try check(repeated.bytes==0 && repeated.totalBytes==plan.totalBytes,"Repeated regional download requires no new files")
        let custom=try await WorldDownloadStore(cacheURL:cache).plan(center:regions[0].bounds.center,radius:600,catalog:catalog,root:root)
        try check(custom.bytes==0 && custom.readyBounds.count==custom.bounds.count,"Custom areas reuse the regional save")
        let files=WorldSourceStore(cacheURL:cache,allowsNetwork:false)
        let source=try await files.manifest(address:root.appendingPathComponent(regions[0].path).absoluteString,routing:regions[0].routing,preferCached:true)
        let tile=source.tiles[0]
        _=try await files.prepare(tile,request:.init(id:tile.id,pixels:32,fine:false),sourceBounds:source.bounds)
        try check(true,"Regional vector files render through the cache-only terrain path")
        let asset=cache.appendingPathComponent(tile.mesh.sha256)
        var damaged=try Data(contentsOf:asset);damaged[0] ^= 1;try damaged.write(to:asset,options:.atomic)
        let repair=try await store.plan(pack:fixture,catalog:catalog,root:root)
        try check(repair.bytes==Int64(tile.mesh.byteCount),"Corrupt regional asset requests only its repair")
        model.offerRegionDownload(fixture);model.downloadRegionPack()
        try await wait { model.isSavingOffline }
        try check(model.regionComplete && model.downloadedBytes==Int64(tile.mesh.byteCount),"Fast download verifies saved bytes and repairs only the corrupt asset")
        let streamingCache=cache.appendingPathComponent("streaming-proof")
        let streamingStore=WorldRegionDownloadStore(cacheURL:streamingCache)
        let streamed=WorldRegionDownloadPlan.estimate(pack:fixture,catalog:catalog,root:root)!
        let lastAddress=root.appendingPathComponent(streamed.parts.last!.region.path).absoluteString
        let lastIndex=streamingCache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(lastAddress.utf8))+".index")
        let audit=RegionTransferAudit()
        try await streamingStore.download(streamed,tileProgress: { await audit.recordTiles($0) }) { bytes,saved in await audit.record(bytes,saved:saved,finalIndex:lastIndex) }
        let animation=await (audit.tileEvents,audit.maximumTiles,audit.sawActive,audit.validTiles,audit.completedTiles,audit.sawPreviousSection)
        try check(animation.0>2 && animation.1<=256 && animation.2,"Real transfers emit bounded live tile animation")
        try check(animation.3 && animation.4.count==plan.tileCount,"Every tile completes geographically across sections without active/completed overlap")
        try check(animation.5,"Completed sections remain as compact static fills when the next section starts")
        let beforeFinal=await audit.streamedBeforeFinalIndex,actual=await audit.bytes
        try check(beforeFinal,"Terrain starts transferring before the remaining section indexes are fetched")
        try check(actual==plan.bytes && actual<=streamed.bytes,"Reported transfer is actual unique bytes, within the catalogue upper estimate")
        let reuseAudit=RegionTransferAudit()
        try await streamingStore.download(streamed,tileProgress: { await reuseAudit.recordTiles($0) }) { bytes,saved in await reuseAudit.record(bytes,saved:saved,finalIndex:lastIndex) }
        let reuseAnimation=await (reuseAudit.sawActive,reuseAudit.completedTiles,reuseAudit.tileEvents)
        try check(!reuseAnimation.0 && reuseAnimation.1.count==plan.tileCount && reuseAnimation.2==plan.parts.count,"Reused tiles appear saved immediately without fake download pulses")
        let reusedBytes=await reuseAudit.bytes
        try check(reusedBytes==0,"Repeating a fast-plan download transfers zero saved asset bytes")
        model.offerRegionDownload(fixture);model.pauseRegionDownload()
        try await Task.sleep(nanoseconds:100_000_000)
        try check(!model.checkingDownload && !model.isSavingOffline && model.regionPlan==nil && model.downloadError?.hasPrefix("Paused") == true,"Cancelled region check cannot publish stale results")
        try check(model.regionTileProgress.active.isEmpty,"Paused download leaves no active tile pulses")
        try check(WorldOfflineCoverage.savedBounds(at:cache).count==plan.tileCount,"Pausing preserves completed receipts")
        model.cancelDownload()
        try check(model.downloadRegion==nil && model.regionPlan==nil && !model.regionComplete,"Switching to custom clears regional selection")
        print("PASS \(checks) region partition, storage, overlap, offline rendering, repair, pause and model checks; \(plan.tileCount) tiles, \(plan.bytes) bytes")
    }
}
