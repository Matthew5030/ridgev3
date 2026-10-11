import Foundation

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
        let packs=try WorldRegionPack.load(url:URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("uk-pack-regions.json"))
        try check(packs.count==11,"Eleven named regions")
        let members=packs.flatMap { $0.sources(in:catalog).map(\.id) }
        try check(Set(members).count==members.count && Set(members)==Set(catalog.sources.map(\.id)),"Every current source assigned exactly once")
        let cells=packs.flatMap(\.cells).map(\.id)
        try check(Set(cells).count==cells.count,"Preset map cells do not overlap")
        try check(packs.first { $0.id=="northern-ireland" }!.sources(in:catalog).isEmpty,"Unpublished Northern Ireland is explicitly unavailable")
        let northern=packs.first { $0.id=="north-scotland" }!
        try check(northern.coveredCells(in:catalog).count<northern.cells.count,"Partial Scotland coverage is distinguishable from a full region")
        let regions=[catalog.sources[0],catalog.sources.last!]
        let fixture=WorldRegionPack(id:"fixture",name:"Test region",subtitle:"",landmark:"",cells:regions.map { .init(id:$0.id,bounds:$0.bounds) })
        try check(fixture.bounds.widthMeters>24_000,"Region fixture exceeds the custom-area size limit")
        let store=WorldRegionDownloadStore(cacheURL:cache)
        let plan=try await store.plan(pack:fixture,catalog:catalog,root:root)
        try check(plan.parts.count==2 && plan.tileCount==regions.reduce(0) { $0+$1.tileCount },"Region plan includes every tile, beyond custom-area radius rules")
        try check(plan.bytes>0 && plan.bytes==plan.totalBytes,"Fresh download estimates actual unique assets")
        try check(try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil).allSatisfy { $0.lastPathComponent.count != 64 },"Planning only downloads metadata")
        let first=WorldRegionPack(id:"first",name:"First half",subtitle:"",landmark:"",cells:[fixture.cells[0]])
        let half=try await store.plan(pack:first,catalog:catalog,root:root)
        try await store.download(half,progress: { _,_ in })
        let remaining=try await store.plan(pack:fixture,catalog:catalog,root:root)
        try check(remaining.bytes<plan.bytes && remaining.bytes>0,"Previously saved overlap reduces transfer")
        try check(WorldOfflineCoverage.savedBounds(at:cache).count==regions[0].tileCount,"Regional receipts are visible to normal exploration")
        // The model uses the same cache, but a regional save must not prepare a
        // country-sized scene or automatically fly to the centre of the pack.
        let model=WorldModel(cacheURL:cache)
        await model.configure(mode:"local",local:root.absoluteString)
        model.offerRegionDownload(fixture)
        try await wait { model.checkingDownload }
        try check(model.regionPlan?.bytes==remaining.bytes && model.source==nil,"Model shows missing bytes without rendering")
        model.downloadRegionPack()
        try await wait { model.isSavingOffline }
        try check(model.regionComplete && model.downloadError==nil,model.downloadError ?? "Region did not finish")
        try check(model.source==nil && model.downloadedDestination==nil && !model.in3D,"Saving a large region never enters 3D")
        try check(model.offlineBounds.count==plan.tileCount,"All regional tiles become usable in normal exploration")
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
        model.offerRegionDownload(fixture);model.pauseRegionDownload()
        try await Task.sleep(nanoseconds:100_000_000)
        try check(!model.checkingDownload && !model.isSavingOffline && model.regionPlan==nil && model.downloadError?.hasPrefix("Paused") == true,"Cancelled region check cannot publish stale results")
        try check(WorldOfflineCoverage.savedBounds(at:cache).count==plan.tileCount,"Pausing preserves completed receipts")
        model.cancelDownload()
        try check(model.downloadRegion==nil && model.regionPlan==nil && !model.regionComplete,"Switching to custom clears regional selection")
        print("PASS \(checks) region partition, storage, overlap, offline rendering, repair, pause and model checks; \(plan.tileCount) tiles, \(plan.bytes) bytes")
    }
}
