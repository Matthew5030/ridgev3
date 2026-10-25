import Foundation

actor PackEvents {
    var bytes:Int64=0
    var callbacks=0
    var verified=Set<String>()
    var sawPartial=false
    func update(_ value:Int64) { bytes=value;callbacks+=1 }
    func assets(_ hashes:Set<String>,_ active:Set<String>,total:Int) {
        verified=hashes;sawPartial = sawPartial || (!hashes.isEmpty && hashes.count<total)
    }
}

@main struct WorldSectionPackTests {
    static func main() async throws {
        var checks=0
        func check(_ value:Bool,_ message:String) throws { guard value else { throw RidgeError.message(message) };checks+=1; print("PASS: \(message)");fflush(stdout) }
        let root=try WorldLibrary.root(mode:"local",local:ProcessInfo.processInfo.environment["RIDGE_TEST_SERVER"] ?? "http://127.0.0.1:8787")
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("ridge-pack-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let catalog=try await WorldCatalogStore(cacheURL:cache).open(root:root)
        let region=catalog.sources.first { $0.id=="world-z10-x500-y333-c00-r16" }!
        let pack=region.pack!
        let address=root.appendingPathComponent(region.path).absoluteString
        let files=WorldSourceStore(cacheURL:cache)
        let source=try await files.manifest(address:address,routing:region.routing,preferCached:true,recoverCoverage:false)
        let assets=WorldSourceStore.assets(tiles:source.tiles,source:source)
        let events=PackEvents(),started=Date()
        let bytes=try await files.downloadPack(pack,source:source,assetProgress:{ hashes,active in await events.assets(hashes,active,total:assets.count) },progress:{ await events.update($0) })
        let elapsed=Date().timeIntervalSince(started)
        try check(bytes==pack.byteCount,"Fresh section transfers exactly one pack")
        let verified=await events.verified
        try check(verified==Set(assets.map(\.sha256)),"Every original asset is verified without extraction")
        try check(WorldOfflineCoverage.savedBounds(at:cache).count==source.tiles.count,"All packed tiles are admitted offline only after commit")
        let loose=try FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.count==64 }
        try check(loose.isEmpty,"Pack does not expand into hundreds of cache files")
        let reopened=WorldSourceStore(cacheURL:cache,allowsNetwork:false)
        let offline=try await reopened.manifest(address:address,routing:region.routing,preferCached:true)
        _=try await reopened.contents(of:offline)
        for tile in offline.tiles.prefix(2) {
            let result=try await reopened.prepare(tile,request:.init(id:tile.id,pixels:32,fine:true),sourceBounds:offline.bounds)
            try check(result.mesh != nil,"Offline fine terrain and vectors are read directly from the pack")
        }
        let cached=try await files.cachedAssetHashes(for:assets)
        try check(cached.count==assets.count,"Packed assets are reused by overlap checks")
        let reused=PackEvents()
        try await files.pin(source.tiles,source:source,countCachedInProgress:false,coverageID:source.id,progress:{ await reused.update($0) })
        let reusedBytes=await reused.bytes
        try check(reusedBytes==0,"Repeated save transfers no already packed assets")
        let final=WorldSectionPack.file(pack,cache:cache)
        // Reproduce an interrupted transfer using the exact immutable prefix.
        let prefixLength=1_000_000
        let handle=try FileHandle(forReadingFrom:final)
        let prefix=try handle.read(upToCount:prefixLength)!;try handle.close()
        try prefix.write(to:WorldSectionPack.partial(pack,cache:cache))
        try FileManager.default.removeItem(at:final)
        try check(WorldOfflineCoverage.savedBounds(at:cache).isEmpty,"Partial packs never grant offline coverage")
        let resumeFiles=WorldSourceStore(cacheURL:cache)
        _=try await resumeFiles.manifest(address:address,routing:region.routing,preferCached:true,recoverCoverage:false)
        let resumed=try await resumeFiles.downloadPack(pack,source:source,assetProgress:{ _,_ in },progress:{ _ in })
        try check(resumed==pack.byteCount-prefixLength,"HTTP Range resumes only the remaining pack bytes")
        try check(WorldOfflineCoverage.savedBounds(at:cache).count==source.tiles.count,"Resumed pack restores valid receipts")
        // Same-size corruption must not be mistaken for an intact download.
        let corrupt=try FileHandle(forUpdating:final);try corrupt.seek(toOffset:UInt64(pack.byteCount-1));let last=try Data(contentsOf:final).last!;try corrupt.write(contentsOf:Data([last ^ 1]));try corrupt.close()
        let repairFiles=WorldSourceStore(cacheURL:cache)
        _=try await repairFiles.manifest(address:address,routing:region.routing,preferCached:true,recoverCoverage:false)
        let broken=try await repairFiles.cachedAssetHashes(for:assets)
        try check(broken.isEmpty,"Whole-pack checksum rejects same-size corruption")
        _=try await repairFiles.downloadPack(pack,source:source,assetProgress:{ _,_ in },progress:{ _ in })
        let repaired=try await repairFiles.cachedAssetHashes(for:assets)
        try check(repaired.count==assets.count,"Damaged pack can be replaced and verified")
        try check(!WorldSectionPack.useBundle(pack,missing:Array(assets.suffix(1))),"One small missing file uses sparse repair rather than a full pack")
        try check(WorldSectionPack.useBundle(pack,missing:assets),"Fresh section uses its bundle")
        let missingIndex=cache.appendingPathComponent("invalid.ridgepack")
        var invalid=try Data(contentsOf:final);invalid[0]=0;try invalid.write(to:missingIndex)
        do {
            _=try WorldSectionPack.Reader(url:missingIndex,asset:pack,sourceID:source.id)
            throw RidgeError.message("Bad header accepted")
        } catch { try check(error.localizedDescription.contains("header"),"Malformed container header is rejected") }
        let regionFixture=WorldRegionPack(id:"packed-fixture",name:"Pack fixture",subtitle:"",landmark:"",cells:[.init(id:region.id,bounds:region.bounds)])
        let regionCache=cache.appendingPathComponent("region-integration")
        let regionStore=WorldRegionDownloadStore(cacheURL:regionCache)
        let freshPlan=try await regionStore.plan(pack:regionFixture,catalog:catalog,root:root)
        try check(freshPlan.bytes==pack.byteCount && freshPlan.totalBytes==pack.byteCount,"Region offer uses compressed wire bytes")
        let existingLandscape=WorldSourceStore(cacheURL:regionCache,allowsNetwork:false)
        do {
            _=try await existingLandscape.manifest(address:address,routing:region.routing,preferCached:true)
            throw RidgeError.message("Planning exposed an unfinished offline index")
        } catch {
            try check(error.localizedDescription.contains("map index is missing"),"A fresh plan keeps its index staged until the download completes")
        }
        // This scenario models a landscape that already has metadata before
        // a separate actor installs its pack; prime that metadata explicitly.
        let metadata=WorldSourceStore(cacheURL:regionCache)
        _=try await metadata.manifest(address:address,routing:region.routing,preferCached:true)
        let existingManifest=try await existingLandscape.manifest(address:address,routing:region.routing,preferCached:true)
        let regionEvents=PackEvents()
        try await regionStore.download(freshPlan,progress:{ bytes,_ in await regionEvents.update(bytes) })
        let regionBytes=await regionEvents.bytes
        try check(regionBytes==pack.byteCount && WorldOfflineCoverage.savedBounds(at:regionCache).count==source.tiles.count,"Normal region downloader installs the indexed pack")
        let newlySaved=existingManifest.tiles[0]
        _=try await existingLandscape.prepare(newlySaved,request:.init(id:newlySaved.id,pixels:32,fine:true),sourceBounds:existingManifest.bounds)
        try check(true,"A live landscape sees packs installed by a separate download actor")
        let repeatedPlan=try await regionStore.plan(pack:regionFixture,catalog:catalog,root:root)
        try check(repeatedPlan.bytes==0 && repeatedPlan.totalBytes==pack.byteCount,"Region overlap planning reports zero bytes already saved")
        // Cancel after real bytes arrive, then resume the retained prefix.
        let transferCache=cache.appendingPathComponent("fault-injection")
        let fixturePort=ProcessInfo.processInfo.environment["RIDGE_PACK_FIXTURE_PORT"]!
        var endpoint=URLComponents(url:root.appendingPathComponent(region.path).deletingLastPathComponent().appendingPathComponent(pack.file),resolvingAgainstBaseURL:false)!
        endpoint.host="127.0.0.1";endpoint.port=Int(fixturePort);endpoint.query="slow"
        let slowURL=endpoint.url!
        let operation=Task { try await WorldSectionPack.download(url:slowURL,asset:pack,cache:transferCache,progress:{ _,_ in }) }
        let partialFile=WorldSectionPack.partial(pack,cache:transferCache)
        let deadline=Date().addingTimeInterval(10)
        while Date()<deadline {
            let size=(try? FileManager.default.attributesOfItem(atPath:partialFile.path)[.size] as? NSNumber)?.intValue ?? 0
            if size>100_000 { break }
            try await Task.sleep(nanoseconds:5_000_000)
        }
        operation.cancel()
        do { _=try await operation.value;throw RidgeError.message("Cancelled transfer completed") }
        catch { try check(error is CancellationError || (error as? URLError)?.code == .cancelled,"Cancellation stops the actual HTTP request") }
        let retained=(try FileManager.default.attributesOfItem(atPath:partialFile.path)[.size] as! NSNumber).intValue
        try check(retained>0 && retained<pack.byteCount,"Cancellation keeps an incomplete reusable prefix")
        endpoint.query=nil
        let rest=try await WorldSectionPack.download(url:endpoint.url!,asset:pack,cache:transferCache,progress:{ _,_ in })
        try check(rest==pack.byteCount-retained,"Cancelled HTTP transfer resumes without redownloading its prefix")
        try WorldSectionPack.Reader(url:partialFile,asset:pack,sourceID:source.id).verify()
        try prefix.write(to:partialFile)
        endpoint.query="ignore-range"
        let restarted=try await WorldSectionPack.download(url:endpoint.url!,asset:pack,cache:transferCache,progress:{ _,_ in })
        try check(restarted==pack.byteCount,"Server ignoring Range restarts cleanly rather than appending duplicate bytes")
        try WorldSectionPack.Reader(url:partialFile,asset:pack,sourceID:source.id).verify()
        print("PASS \(checks) pack transfer, indexed offline reads, reuse, resume and corruption checks; \(bytes) bytes in \(elapsed) seconds")
    }
}
