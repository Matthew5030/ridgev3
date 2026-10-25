import Foundation

actor ArchiveAudit {
    var bytes:Int64=0
    var tileEvents=0
    var maxTiles=0
    var completed=Set<GeoBounds>()
    var sawActive=false,sawPriorFills=false
    func progress(_ bytes:Int64) { self.bytes=bytes }
    func tiles(_ value:WorldRegionTileProgress) {
        tileEvents+=1;maxTiles=max(maxTiles,value.tiles.count);completed.formUnion(value.completed)
        sawActive = sawActive || !value.active.isEmpty
        sawPriorFills = sawPriorFills || (value.savedTileCount>0 && !value.savedFills.isEmpty)
    }
}

@main struct WorldRegionArchiveTests {
    @MainActor static func main() async throws {
        var checks=0
        func check(_ value:Bool,_ message:String) throws {
            guard value else { throw RidgeError.message(message) }
            checks+=1;print("PASS: \(message)");fflush(stdout)
        }
        let root=try WorldLibrary.root(mode:"local",local:ProcessInfo.processInfo.environment["RIDGE_TEST_SERVER"] ?? "http://127.0.0.1:8787")
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("region-archive-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let catalog=try await WorldCatalogStore(cacheURL:cache).open(root:root)
        // Existing archives retain their old memberships after the app's map recut.
        let baseline=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/region_zones/baseline-download-zones.json")
        let regionID=CommandLine.arguments.count>2 ? CommandLine.arguments[2] : "park-eryri"
        let current=try WorldRegionPack.loadLibrary(url:URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("uk-download-zones.json"))
        let library=(current.areas+current.parks).contains { $0.id==regionID } ? current : try WorldRegionPack.loadLibrary(url:baseline)
        let region=(library.areas+library.parks).first { $0.id==regionID }!
        let plan=WorldRegionDownloadPlan.estimate(pack:region,catalog:catalog,root:root)!
        let archives=plan.archives.isEmpty ? [plan.archive!] : plan.archives
        let archive=archives[0]
        try check(plan.parts.count==archives.flatMap(\.sourceIDs).count && plan.bytes==archives.reduce(0,{ $0+Int64($1.asset.byteCount) }),"Named region offers large archive chunks at their real wire size")
        try check(archives.allSatisfy { WorldSectionPack.validRegion($0.asset) },"Every chunk remains compatible with the legacy one-GiB format")
        let store=WorldRegionDownloadStore(cacheURL:cache),audit=ArchiveAudit(),started=Date()
        let checked=try await store.plan(pack:region,catalog:catalog,root:root)
        try check(checked.bytes==plan.bytes && !checked.isEstimate,"Fresh preflight resolves the exact bulk download")
        try await store.download(plan,tileProgress:{ await audit.tiles($0) },progress:{ bytes,_ in await audit.progress(bytes) })
        let elapsed=Date().timeIntervalSince(started),bytes=await audit.bytes
        try check(bytes==plan.bytes,"Fresh region transfers exactly its archive bytes")
        let packed=try FileManager.default.contentsOfDirectory(at:WorldSectionPack.directory(cache),includingPropertiesForKeys:nil).filter { $0.pathExtension=="ridgepack" }
        try check(packed.count==archives.count,"Sections remain in the archive chunks without extraction")
        try check(WorldOfflineCoverage.savedBounds(at:cache).count==plan.tileCount,"Every available tile receives offline coverage")
        let animation=await (audit.maxTiles,audit.completed,audit.tileEvents)
        try check(animation.0<=256 && animation.1.count==plan.tileCount && animation.2>plan.parts.count,"Geographic progress stays bounded and completes across all sections")
        let active=await audit.sawActive,priorFills=await audit.sawPriorFills
        try check(active && priorFills,"Active pulses and completed fills persist across section/chunk boundaries")
        for part in plan.parts {
            let files=WorldSourceStore(cacheURL:cache,allowsNetwork:false)
            let source=try await files.manifest(address:root.appendingPathComponent(part.region.path).absoluteString,routing:part.region.routing,preferCached:true)
            _=try await files.contents(of:source,includeGraph:part.region.id==plan.parts[0].region.id)
            for tile in [source.tiles.first!,source.tiles.last!] {
                _=try await files.prepare(tile,request:.init(id:tile.id,pixels:32,fine:true),sourceBounds:source.bounds)
            }
            try check(true,"Offline terrain and vector reads work in section \(source.id)")
        }
        let repeated=try await store.plan(pack:region,catalog:catalog,root:root)
        try check(repeated.bytes==0,"Re-selecting the region reuses every section")
        let offline=try await WorldRegionDownloadStore(cacheURL:cache,allowsNetwork:false).plan(pack:region,catalog:catalog,root:root)
        try check(offline.bytes==0,"A new offline store recognises saved chunks without network access")
        let model=WorldModel(cacheURL:cache)
        await model.configure(mode:"local",local:root.absoluteString)
        let reopenStart=Date()
        model.offerRegionDownload(region)
        try check(model.regionComplete && !model.checkingDownload,"Opening a fully saved region does not rescan the terrain payload")
        print("Completed region inventory lookup: \(Date().timeIntervalSince(reopenStart)) seconds")
        let deadline=Date().addingTimeInterval(120)
        while (model.checkingDownload || model.regionPlan?.isEstimate==true),Date()<deadline { try await Task.sleep(for:.milliseconds(20)) }
        try check(model.regionPlan?.bytes==0 && model.offlineBounds.count==plan.tileCount && model.downloadError==nil,"Reopening the app model preserves saved terrain and offers zero download bytes")
        let saved=WorldRegionMapOverlay.make(packs:[region],catalog:catalog,offline:model.offlineBounds)[0]
        try check(saved.downloadState == .saved,"The reopened region is shown as saved")
        for ids in [[archive.id,archive.id],["unknown-archive"]] {
            do { try WorldRegionArchiveGroup(id:"bad",archiveIDs:ids).validate(archives:archives);throw RidgeError.message("Invalid group accepted") }
            catch { try check(error.localizedDescription=="Invalid region download group.","Invalid chunk memberships are rejected") }
        }
        let reuse=ArchiveAudit()
        try await store.download(plan,progress:{ bytes,_ in await reuse.progress(bytes) })
        let reused=await reuse.bytes
        try check(reused==0,"An old download offer never redownloads an already saved archive")
        // Simulate termination after the archive rename, before references and
        // manifests were committed. Reinstall from disk without another request.
        for part in plan.parts {
            try FileManager.default.removeItem(at:WorldSectionPack.reference(part.region.id,cache:cache))
            let address=root.appendingPathComponent(part.region.path).absoluteString
            let index=cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8))+".index")
            try Data("damaged metadata".utf8).write(to:index)
        }
        try check(WorldRegionDownloadPlan.completed(pack:region,catalog:catalog,root:root,cache:cache,saved:model.offlineBounds)==nil,
                  "Missing installed references cannot pass the completed inventory lookup")
        let recovered=ArchiveAudit()
        try await store.download(plan,progress:{ bytes,_ in await recovered.progress(bytes) })
        let recoveryBytes=await recovered.bytes
        try check(recoveryBytes==0,"Interrupted installation and damaged manifests recover from the existing region file")
        try check(plan.parts.allSatisfy { WorldSectionPack.open(sourceID:$0.region.id,cache:cache) != nil },"Recovery restores every nested section reference")
        // Nested range validation rejects metadata that points outside the file.
        let first=plan.parts[0].region,section=first.pack!,file=WorldSectionPack.file(archive.asset,cache:cache)
        do {
            _=try WorldSectionPack.Reader(url:file,asset:section,sourceID:first.id,container:.init(asset:archive.asset,offset:archive.asset.byteCount))
            throw RidgeError.message("Invalid nested range accepted")
        } catch { try check(error.localizedDescription.contains("range"),"Out-of-bounds nested section is rejected") }
        let handle=try FileHandle(forReadingFrom:file)
        let prefix=try handle.read(upToCount:5_000_000)!
        try handle.close()
        let resumeCache=cache.appendingPathComponent("resume")
        try FileManager.default.createDirectory(at:WorldSectionPack.directory(resumeCache),withIntermediateDirectories:true)
        try prefix.write(to:WorldSectionPack.partial(archive.asset,cache:resumeCache))
        let resume=WorldRegionDownloadStore(cacheURL:resumeCache),resumeAudit=ArchiveAudit()
        try await resume.download(plan,progress:{ bytes,_ in await resumeAudit.progress(bytes) })
        let resumed=await resumeAudit.bytes
        try check(resumed==plan.bytes-Int64(prefix.count),"Region chunks resume only their missing bytes")
        try check(WorldOfflineCoverage.savedBounds(at:resumeCache).count==plan.tileCount,"Resumed archive grants complete available coverage")
        // Existing independent section saves must not be resent merely to use
        // a new bulk archive. Other untouched chunks can still use bulk.
        let warmCache=cache.appendingPathComponent("section-reuse")
        let warm=WorldRegionDownloadStore(cacheURL:warmCache)
        let seed=WorldRegionPack(id:"seed",name:"Seed",subtitle:"",landmark:"",cells:[.init(id:first.id,bounds:first.bounds)])
        let seedPlan=try await warm.plan(pack:seed,catalog:catalog,root:root)
        try await warm.download(seedPlan,progress:{ _,_ in })
        let useFirst=try await warm.shouldDownloadArchive(archive,regions:plan.parts.map(\.region).filter { archive.sourceIDs.contains($0.id) },root:root)
        try check(!useFirst,"A completed independent section prevents downloading it again inside a bulk chunk")
        let warmPlan=try await warm.plan(pack:region,catalog:catalog,root:root)
        try check(warmPlan.parts.first(where:{ $0.region.id==first.id })?.missingBytes==0 && warmPlan.bytes<plan.bytes,
                  "Partly saved region preflight reuses its section and reduces the remaining transfer")
        if archives.count>1 {
            try check(warmPlan.archives.count==archives.count,"Untouched chunks retain bulk transport beside reused section saves")
        }
        print("PASS \(checks) region archive checks; \(bytes) bytes, \(plan.tileCount) tiles, \(elapsed) seconds")
    }
}
