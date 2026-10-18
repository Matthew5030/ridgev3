import Foundation

actor ArchiveAudit {
    var bytes:Int64=0
    var tileEvents=0
    var maxTiles=0
    var completed=Set<GeoBounds>()
    func progress(_ bytes:Int64) { self.bytes=bytes }
    func tiles(_ value:WorldRegionTileProgress) {
        tileEvents+=1;maxTiles=max(maxTiles,value.tiles.count);completed.formUnion(value.completed)
    }
}

@main struct WorldRegionArchiveTests {
    static func main() async throws {
        var checks=0
        func check(_ value:Bool,_ message:String) throws {
            guard value else { throw RidgeError.message(message) }
            checks+=1;print("PASS: \(message)");fflush(stdout)
        }
        let root=try WorldLibrary.root(mode:"local",local:"http://127.0.0.1:8787")
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("region-archive-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let catalog=try await WorldCatalogStore(cacheURL:cache).open(root:root)
        let library=try WorldRegionPack.loadLibrary(url:URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("uk-download-zones.json"))
        let region=library.areas.first { $0.id=="sheet-explorer-ol17" }!
        let plan=WorldRegionDownloadPlan.estimate(pack:region,catalog:catalog,root:root)!
        let archive=plan.archive!
        try check(plan.parts.count==19 && plan.bytes==archive.asset.byteCount,"Named region offers one archive at its real wire size")
        let store=WorldRegionDownloadStore(cacheURL:cache),audit=ArchiveAudit(),started=Date()
        try await store.download(plan,tileProgress:{ await audit.tiles($0) },progress:{ bytes,_ in await audit.progress(bytes) })
        let elapsed=Date().timeIntervalSince(started),bytes=await audit.bytes
        try check(bytes==archive.asset.byteCount,"Fresh region transfers one complete archive")
        let packed=try FileManager.default.contentsOfDirectory(at:WorldSectionPack.directory(cache),includingPropertiesForKeys:nil).filter { $0.pathExtension=="ridgepack" }
        try check(packed.count==1,"Nineteen sections remain in one physical file without extraction")
        try check(WorldOfflineCoverage.savedBounds(at:cache).count==plan.tileCount,"Every available tile receives offline coverage")
        let animation=await (audit.maxTiles,audit.completed,audit.tileEvents)
        try check(animation.0<=256 && animation.1.count==plan.tileCount && animation.2>19,"Geographic progress stays bounded and completes across all sections")
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
        try check(resumed==archive.asset.byteCount-prefix.count,"Region archive resumes only its missing bytes")
        try check(WorldOfflineCoverage.savedBounds(at:resumeCache).count==plan.tileCount,"Resumed archive grants complete available coverage")
        print("PASS \(checks) region archive checks; \(bytes) bytes, \(plan.tileCount) tiles, \(elapsed) seconds")
    }
}
