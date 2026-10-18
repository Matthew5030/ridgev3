import Foundation

actor RegionTransferAudit {
    var streamedBeforeFinalIndex=false
    var bytes:Int64=0
    var byteEvents=0
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
        bytes=value;byteEvents+=1
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
        let published=try await WorldCatalogStore(cacheURL:cache).open(root:root)
        // Keep the loose-file migration/repair regression independently covered.
        let catalog=WorldCatalog(schemaVersion:published.schemaVersion,revision:published.revision,sources:published.sources.map { var source=$0;source.pack=nil;return source })
        let upgradeCache=cache.appendingPathComponent("legacy-catalogue")
        try FileManager.default.createDirectory(at:upgradeCache,withIntermediateDirectories:true)
        let oldSource=catalog.sources.first { $0.tileCount<256 }!
        let legacy:[String:Any]=["schemaVersion":1,"revision":"legacy", "sources":[[
            "id":oldSource.id,"path":oldSource.path,"tileCount":oldSource.tileCount,
            "bounds":["minLatitude":oldSource.bounds.minLatitude,"minLongitude":oldSource.bounds.minLongitude,
                      "maxLatitude":oldSource.bounds.maxLatitude,"maxLongitude":oldSource.bounds.maxLongitude]]]]
        let cacheName=AdaptiveTerrainCodec.hash(Data(root.appendingPathComponent("catalog.json").absoluteString.utf8))+".catalog"
        try JSONSerialization.data(withJSONObject:legacy).write(to:upgradeCache.appendingPathComponent(cacheName))
        let upgraded=try await WorldCatalogStore(cacheURL:upgradeCache).open(root:root,preferCached:true)
        try check(upgraded.revision==catalog.revision && upgraded.sources.count==catalog.sources.count,"Legacy cached coverage refreshes instead of remaining permanently unavailable")
        let library=try WorldRegionPack.loadLibrary(url:URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("uk-download-zones.json"))
        let packs=library.areas
        try check(packs.count==84,"Reviewed coastal blocks are bundled in the app")
        let wholeParks=library.parks
        try check(wholeParks.count==15,"All fifteen national parks remain grouped downloads")
        for whole in wholeParks {
            try check(whole.id==whole.parkID && !whole.cells.isEmpty,"Park download has an independent footprint")
            let ids=whole.sources(in:catalog).map(\.id)
            try check(Set(ids).count==ids.count,"Park download does not repeat shared source sections")
        }
        let baselineURL=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/region_zones/baseline-download-zones.json")
        let baseline=try WorldRegionPack.loadLibrary(url:baselineURL)
        for old in baseline.parks {
            let current=wholeParks.first { $0.id==old.id }!
            let downloads=Set((current.downloadCells ?? current.cells).map(\.id))
            try check(Set(old.cells.map(\.id)).isSubset(of:downloads),"Every original park edge section remains included")
            try check(Set(current.cells.map(\.id)).isSubset(of:downloads),"The entire displayed block belongs to its download")
        }
        // Reject malformed download memberships rather than silently dropping
        // visible terrain or requesting sections outside the known source grid.
        let indexURL=URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("uk-download-zones.json")
        let originalIndex=try JSONSerialization.jsonObject(with:Data(contentsOf:indexURL)) as! [String:Any]
        let invalidURL=cache.appendingPathComponent("invalid-zones.json")
        for mutation in 0..<4 {
            var object=originalIndex,zones=object["regions"] as! [[String:Any]]
            let index=zones.firstIndex { $0["downloadCells"] != nil }!
            var downloads=zones[index]["downloadCells"] as! [[String:Any]]
            switch mutation {
            case 0: downloads=[]
            case 1: downloads.append(downloads[0])
            case 2: downloads[0]["id"]="world-unknown"
            default: downloads[0]["bounds"]=["minLatitude":0,"maxLatitude":1,"minLongitude":0,"maxLongitude":1]
            }
            zones[index]["downloadCells"]=downloads;object["regions"]=zones
            try JSONSerialization.data(withJSONObject:object).write(to:invalidURL)
            do { _=try WorldRegionPack.loadLibrary(url:invalidURL);throw RidgeError.message("Invalid download membership accepted") }
            catch { try check(error.localizedDescription=="A region has invalid download sections.","Invalid park membership is rejected") }
        }
        let overlays=packs.map { WorldRegionMapOverlay(pack:$0,catalog:catalog) }
        for overlay in overlays {
            if overlay.pack.mapShapes?.isEmpty == true {
                try check(overlay.labelFontScale==0 && overlay.totalTileCount==0,"Empty ocean areas have neither labels nor published terrain")
                continue
            }
            try check(overlay.pack.contains(overlay.labelPoint),"Labels stay on the land footprint")
            try check(overlay.labelFontScale>0,"Each label has a stable geographic fit")
            var previous=overlay.labelAppearance(at:0)
            for step in 1...400 {
                let current=overlay.labelAppearance(at:Double(step)*0.12/overlay.labelFontScale)
                try check(current.size>=previous.size && current.opacity>=previous.opacity,"Zoom label size and opacity are monotonic")
                try check(current.size-previous.size<0.121 && current.opacity-previous.opacity<0.046,"No discrete fitting or visibility jumps")
                previous=current
            }
            try check(previous.size==24 && previous.opacity==1,"Large labels settle at their maximum size")
            let readable=overlay.labelAppearance(at:16/overlay.labelFontScale)
            try check(readable.size>=15 && readable.opacity==1,"Every area name is fully visible once the area spans 96 points")
            try check(overlay.label.split(separator:"\n").count<=2,"Area labels use at most two short lines")
            try check(WorldRegionMapOverlay.at(overlay.labelPoint,in:overlays)?.id==overlay.id,"Region labels are anchored inside their region")
            for cell in overlay.pack.cells {
                let hit=WorldRegionMapOverlay.at(cell.bounds.center,in:overlays)
                try check(overlay.pack.contains(cell.bounds.center) ? hit?.id==overlay.id : hit==nil,"Map taps follow the visible footprint, not an offshore storage rectangle")
            }
        }
        try check(WorldRegionMapOverlay.at(.init(latitude:53.5,longitude: -4.5),in:overlays)==nil,"Sea north of Anglesey is not selectable")
        try check(WorldRegionMapOverlay.at(.init(latitude:0,longitude:0),in:overlays)==nil,"Tapping outside UK packs selects nothing")
        let emptyOverlay=WorldRegionMapOverlay(pack:packs[0],catalog:nil)
        try check(emptyOverlay.available.isEmpty && !emptyOverlay.fills.isEmpty,"Missing catalogue cannot invent downloadable coverage")
        let members=packs.flatMap { $0.displaySources(in:catalog).map(\.id) }
        try check(Set(members).count==members.count && Set(members)==Set(catalog.sources.map(\.id)),"Every current source has exactly one display owner")
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
        try check(Set(packs.map(\.id)).count==packs.count,"Every coastal block has a stable unique ID")
        try check(packs.filter { ["area-fermanagh-sperrins","area-antrim-derry","area-mournes-down"].contains($0.id) }.allSatisfy { $0.sources(in:catalog).isEmpty },"Unpublished Northern Ireland is explicitly unavailable")
        let northern=packs.filter { $0.bounds.center.latitude>56 && !$0.sources(in:catalog).isEmpty }
        try check(northern.contains { $0.coveredCells(in:catalog).count<$0.cells.count },"Partial Scotland coverage is distinguishable from a full region")
        let completeSources=catalog.sources.filter { $0.tileCount==256 }
        let regions=[completeSources[0],completeSources.last!]
        let fixture=WorldRegionPack(id:"fixture",name:"Test region",subtitle:"",landmark:"",cells:regions.map { .init(id:$0.id,bounds:$0.bounds) })
        try check(fixture.bounds.widthMeters>24_000,"Region fixture exceeds the custom-area size limit")
        let started=Date()
        let eryri=packs.first { $0.contains(.init(latitude:53.0685,longitude: -4.0763)) }!
        let allEryri=wholeParks.first { $0.id=="park-eryri" }!
        let expandedPlan=WorldRegionDownloadPlan.estimate(pack:allEryri,catalog:published,root:root)!
        try check(expandedPlan.archive==nil && expandedPlan.parts.count>57,"The larger Eryri block cannot reuse the smaller pilot archive as a complete download")
        try check(WorldRegionDownloadPlan.estimate(pack:allEryri,catalog:catalog,root:root) != nil,"Eryri remains downloadable despite small coverage gaps")
        try check(WorldRegionMapOverlay.at(.init(latitude:53.0685,longitude: -4.0763),in:overlays)?.pack.parkID=="park-eryri","Yr Wyddfa selects an Eryri park area")
        try check(WorldRegionMapOverlay.at(.init(latitude:53.30,longitude: -4.35),in:overlays)?.id != eryri.id,"Anglesey is a separate map area")
        let quick=WorldRegionDownloadPlan.estimate(pack:fixture,catalog:catalog,root:root)
        let offerSeconds=Date().timeIntervalSince(started)
        try check(quick?.isEstimate==true && quick?.parts.isEmpty==false,"Complete region offers catalogue size immediately")
        try check(try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil).allSatisfy { !$0.pathExtension.contains("index") },"Quick offer fetches no section indexes")
        print("Catalogue-only complete region offer: \(offerSeconds) s, \(quick!.parts.count) sections, upper estimate \(quick!.bytes) bytes")
        let store=WorldRegionDownloadStore(cacheURL:cache)
        let cairngorms=wholeParks.first { $0.id=="park-cairngorms" }!
        try check(cairngorms.terrainAvailability(in:catalog) == .incomplete,"Real Cairngorms is incomplete")
        try check(WorldRegionDownloadPlan.estimate(pack:cairngorms,catalog:catalog,root:root) != nil,"Cairngorms can download its available terrain")
        let missingCell=WorldRegionPack.Cell(id:"world-missing",bounds:GeoBounds(minLatitude:40,minLongitude:0,maxLatitude:41,maxLongitude:1))
        let incomplete=WorldRegionPack(id:"incomplete",name:"Incomplete",subtitle:"",landmark:"",cells:fixture.cells+[missingCell])
        let blocked=WorldRegionMapOverlay.make(packs:[incomplete],catalog:catalog,offline:[])[0]
        try check(!blocked.isBlocked && blocked.downloadState == .notSaved,"One missing section does not block available terrain")
        var falselySaved=blocked;falselySaved.savedTileCount=falselySaved.totalTileCount
        try check(falselySaved.downloadState == .saved && falselySaved.statusText.contains("gaps remain"),"Saving every published tile still explains that gaps remain")
        let noCatalog=WorldRegionMapOverlay(pack:incomplete,catalog:nil)
        try check(!noCatalog.isBlocked && noCatalog.terrainAvailability == .unknown,"Disconnected coverage stays unknown rather than red")
        let coastData=Data(#"{"rings":[[[0,0],[1,0],[1,1],[0,1],[0,0]]]}"#.utf8)
        let coast=try JSONDecoder().decode(WorldRegionPack.MapShape.self,from:coastData)
        let land=GeoBounds(minLatitude:0,minLongitude:0,maxLatitude:1,maxLongitude:1)
        let sea=GeoBounds(minLatitude:0,minLongitude:1,maxLatitude:1,maxLongitude:2)
        try check(coast.overlapsLand(land) && !coast.overlapsLand(sea),"Coast clipping excludes ocean and shared edges")
        let lakeShape=try JSONDecoder().decode(WorldRegionPack.MapShape.self,from:Data(#"{"rings":[[[0,0],[3,0],[3,3],[0,3],[0,0]],[[1,1],[2,1],[2,2],[1,2],[1,1]]]}"#.utf8))
        try check(!lakeShape.overlapsLand(.init(minLatitude:1.1,minLongitude:1.1,maxLatitude:1.9,maxLongitude:1.9)),"Water holes do not count as missing land")
        var coastalSource=WorldCatalog.Region(id:"world-coast",path:"sources/world-coast/world.json",bounds:.init(minLatitude:0,minLongitude:0,maxLatitude:1,maxLongitude:2),tileCount:128,downloadBytes:1024,missingTerrain:[sea])
        let coastal=WorldRegionPack(id:"coast",name:"Coast",subtitle:"",landmark:"",cells:[.init(id:coastalSource.id,bounds:coastalSource.bounds)],mapShapes:[coast])
        func coastalCatalog()->WorldCatalog { WorldCatalog(schemaVersion:1,revision:"coast",sources:[coastalSource]) }
        try check(coastal.terrainAvailability(in:coastalCatalog()) == .complete,"Sparse coastal source with only ocean gaps remains downloadable")
        coastalSource.missingTerrain=[land]
        try check(coastal.terrainAvailability(in:coastalCatalog()) == .unavailable,"A source with only offshore tiles does not make land downloadable")
        coastalSource.missingTerrain=[.init(minLatitude:0.2,minLongitude:0.2,maxLatitude:0.4,maxLongitude:0.4),sea]
        let innerGap=WorldRegionMapOverlay(pack:coastal,catalog:coastalCatalog())
        try check(!innerGap.isBlocked && innerGap.terrainAvailability == .incomplete,"An internal hole permits downloading surrounding terrain")
        try check(innerGap.missingTerrain.count==1 && innerGap.missingTerrain[0].contains(.init(latitude:0.3,longitude:0.3)),"Red mask retains the internal hole and omits offshore gaps")
        coastalSource.missingTerrain=nil
        try check(coastal.terrainAvailability(in:coastalCatalog()) == .incomplete,"Legacy sparse source does not pretend coverage is complete")
        let missingOnly=WorldRegionPack(id:"missing-only",name:"Missing",subtitle:"",landmark:"",cells:[missingCell])
        try check(WorldRegionMapOverlay(pack:missingOnly,catalog:catalog).isBlocked,"Wholly absent terrain remains unavailable")
        try check(WorldRegionDownloadPlan.estimate(pack:missingOnly,catalog:catalog,root:root)==nil,"Wholly absent terrain has no download offer")
        try check(blocked.missingTerrain.contains { $0.contains(missingCell.bounds.center) },"Absent section is included in the red mask")
        try check(!blocked.missingTerrain.contains { $0.contains(regions[0].bounds.center) },"Available section stays out of the red mask")
        let cairngormGaps=cairngorms.missingTerrain(in:catalog)
        try check(cairngormGaps.contains { $0.contains(.init(latitude:57.1167,longitude:-3.6446)) },"Actual missing Cairn Gorm summit is red")
        let eryriGaps=allEryri.missingTerrain(in:catalog)
        try check(!eryriGaps.contains { $0.contains(.init(latitude:53.0685,longitude:-4.0763)) },"Available Yr Wyddfa terrain is not red")
        do {
            _=try await store.plan(pack:missingOnly,catalog:catalog,root:root)
            throw RidgeError.message("Missing-only plan was allowed")
        } catch { try check(error.localizedDescription==WorldRegionPack.unavailableMessage,"Store rejects wholly missing pack before fetching metadata") }
        let blockedModel=WorldModel(cacheURL:cache)
        await blockedModel.configure(mode:"local",local:root.absoluteString)
        blockedModel.offerRegionDownload(missingOnly)
        blockedModel.downloadRegionPack()
        try check(blockedModel.regionPlan==nil && !blockedModel.isSavingOffline && !blockedModel.checkingDownload,"Unavailable selection cannot start a download or checking spinner")
        let emptyPlan=WorldRegionDownloadPlan(pack:missingOnly,root:root,parts:[],bytes:0,totalBytes:0,tileCount:0)
        do {
            try await store.download(emptyPlan,progress:{ _,_ in })
            throw RidgeError.message("Missing-only download was allowed")
        } catch { try check(error.localizedDescription==WorldRegionPack.unavailableMessage,"Executor rejects wholly missing downloads") }
        let availablePlan=try await store.plan(pack:incomplete,catalog:catalog,root:root)
        try check(availablePlan.parts.count==2 && availablePlan.tileCount==512,"Partial pack plan contains only published tiles")
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
        model.catalog=catalog
        model.offerRegionDownload(incomplete)
        try await wait { model.checkingDownload }
        try check(model.regionPlan?.isEstimate==true && !model.checkingDownload && model.source==nil,"Model presents the download immediately without rendering or preflight")
        model.downloadRegionPack()
        try await wait { model.isSavingOffline }
        try check(model.regionTileProgress.tiles.isEmpty && model.regionTileProgress.active.isEmpty,"Finished animation hands over to saved region shading")
        try check(model.regionComplete && model.downloadError==nil,model.downloadError ?? "Region did not finish")
        try check(model.downloadedBytes==remaining.bytes,"Estimated offer still transfers only missing bytes")
        try check(model.source==nil && model.downloadedDestination==nil && !model.in3D,"Saving a large region never enters 3D")
        try check(model.offlineBounds.count==plan.tileCount,"All regional tiles become usable in normal exploration")
        try check(!model.hasCoverage(missingCell.bounds.center),"Downloading available terrain never grants access to a gap")
        let downloadedPartial=WorldRegionMapOverlay.make(packs:[incomplete],catalog:catalog,offline:model.offlineBounds)[0]
        try check(downloadedPartial.downloadState == .saved && downloadedPartial.statusText.contains("gaps remain") && !downloadedPartial.missingTerrain.isEmpty,"Finished partial download preserves gap shading and explanation")
        let receipts=WorldOfflineCoverage.savedBounds(at:cache)
        let overlapping=WorldRegionPack(id:"overlapping-park",name:"Overlapping park",subtitle:"",landmark:"",cells:fixture.cells)
        let sharedEdge=WorldRegionPack(id:"shared-edge",name:"Shared edge",subtitle:"",landmark:"",cells:[fixture.cells[0]],downloadCells:fixture.cells)
        let edgePlan=try await store.plan(pack:sharedEdge,catalog:catalog,root:root)
        try check(edgePlan.parts.count==2 && edgePlan.bytes==0,"Park edge sections share the existing cache without redownloading")
        try check(sharedEdge.displaySources(in:catalog).count==1 && sharedEdge.sources(in:catalog).count==2,"Map ownership stays separate from shared download membership")
        let edgeOverlay=WorldRegionMapOverlay.make(packs:[sharedEdge],catalog:catalog,offline:receipts)[0]
        try check(edgeOverlay.downloadState == .saved && edgeOverlay.savedTileCount==plan.tileCount,"Shared edge terrain contributes to download completion")
        try check(edgeOverlay.savedPoint.map { sharedEdge.contains($0) } == true,"Explore starts inside the visible selected area")
        let overlappingStates=WorldRegionMapOverlay.make(packs:[fixture,overlapping],catalog:catalog,offline:receipts)
        try check(overlappingStates.allSatisfy { $0.savedTileCount==plan.tileCount && $0.downloadState == .saved },"Shared files update saved state in both area and park selections")
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
        let transferStarted=Date()
        try await streamingStore.download(streamed,tileProgress: { await audit.recordTiles($0) }) { bytes,saved in await audit.record(bytes,saved:saved,finalIndex:lastIndex) }
        let transferSeconds=Date().timeIntervalSince(transferStarted),byteEvents=await audit.byteEvents
        try check(byteEvents<=Int(ceil(transferSeconds/0.08))+streamed.parts.count*3,"Progress notifications are bounded by elapsed time, not the number of files")
        print("TRANSFER BENCH: \(transferSeconds) seconds; \(byteEvents) byte callbacks; \(await audit.tileEvents) tile callbacks; \(plan.bytes) bytes")
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
