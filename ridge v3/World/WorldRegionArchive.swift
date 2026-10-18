import Foundation
import CryptoKit

/// A transport container preserves the existing independently indexed sections.
/// Each renderer opens only its section range in the shared on-disk file.
struct WorldRegionArchive:Decodable,Sendable {
    let id:String
    let asset:WorldMapAsset
    let sourceIDs:[String]
    func validate(sources:[WorldCatalog.Region]) throws {
        guard WorldSectionPack.validRegion(asset),!id.isEmpty,(1...128).contains(sourceIDs.count),
              Set(sourceIDs).count==sourceIDs.count,Set(sourceIDs).isSubset(of:Set(sources.map(\.id))) else {
            throw RidgeError.message("Invalid region download.")
        }
    }
    struct Member:Decodable {
        let sourceID:String
        let offset:Int
        let asset:WorldMapAsset
        let manifest:String
        let manifestBytes:Int
    }
    struct Header:Decodable { let schemaVersion:Int;let regionID:String;let members:[Member] }
    struct Section {
        let member:Member
        let source:WorldSource
        let manifest:Data
        let container:WorldSectionPack.Container
        var end:Int { container.offset+member.asset.byteCount }
    }
    func sections(file:URL,regions:[WorldCatalog.Region]) throws -> [Section]? {
        let handle=try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        let prefix=try handle.read(upToCount:12) ?? Data()
        guard prefix.count==12 else { return nil }
        guard String(data:prefix.prefix(8),encoding:.utf8)=="RIDGERG1" else { throw RidgeError.message("Invalid region header.") }
        let count=prefix.dropFirst(8).enumerated().reduce(0) { $0 | (Int($1.element)<<($1.offset*8)) }
        guard (1...8_000_000).contains(count),count+12<asset.byteCount else { throw RidgeError.message("Invalid region index.") }
        let data=try handle.read(upToCount:count) ?? Data()
        guard data.count==count else { return nil }
        let header=try JSONDecoder().decode(Header.self,from:data)
        guard header.schemaVersion==1,header.regionID==id,header.members.count==sourceIDs.count,
              Set(header.members.map(\.sourceID))==Set(sourceIDs),Set(regions.map(\.id))==Set(sourceIDs) else { throw RidgeError.message("Region contents do not match the catalogue.") }
        var result:[Section]=[],end=0,manifestBytes=0
        for member in header.members {
            guard WorldSectionPack.valid(member.asset),member.offset==end,
                  member.asset.byteCount<=asset.byteCount-12-count-end,(1...16_000_000).contains(member.manifestBytes),
                  let compressed=Data(base64Encoded:member.manifest),let region=regions.first(where: { $0.id==member.sourceID }),
                  member.asset.sha256==region.pack?.sha256,member.asset.byteCount==region.pack?.byteCount else { throw RidgeError.message("Invalid region section.") }
            manifestBytes+=member.manifestBytes
            guard manifestBytes<=32_000_000 else { throw RidgeError.message("Region metadata is too large.") }
            let raw=try AdaptiveTerrainCodec.inflate(compressed,byteCount:member.manifestBytes)
            let source=try JSONDecoder().decode(WorldSource.self,from:raw)
            try source.validate()
            guard source.id==region.id,source.bounds==region.bounds,source.tiles.count==region.tileCount,
                  region.routing.map({ $0.sha256==source.graph.sha256 && $0.byteCount==source.graph.byteCount }) ?? true else {
                throw RidgeError.message("Region terrain does not match the catalogue.")
            }
            result.append(Section(member:member,source:source,manifest:raw,container:.init(asset:asset,offset:12+count+end)))
            end+=member.asset.byteCount
        }
        guard 12+count+end==asset.byteCount else { throw RidgeError.message("Invalid region length.") }
        return result
    }
}

private actor WorldArchiveTransfer {
    let archive:WorldRegionArchive
    let regions:[WorldCatalog.Region]
    let cache:URL
    let file:URL
    let report:@Sendable (WorldRegionTileProgress) async -> Void
    var sections:[WorldRegionArchive.Section]?
    var failure:Error?
    var current=0
    var tracker:WorldPackProgress?
    var reporter:WorldRegionTileReporter?
    var savedFills:[GeoBounds]=[]
    var savedCount=0
    init(archive:WorldRegionArchive,regions:[WorldCatalog.Region],cache:URL,file:URL,report:@escaping @Sendable (WorldRegionTileProgress) async -> Void) {
        self.archive=archive;self.regions=regions;self.cache=cache;self.file=file;self.report=report
    }
    func update(received:Int64) async {
        guard failure==nil else { return }
        do {
            if sections==nil { sections=try archive.sections(file:file,regions:regions) }
            guard let sections else { return }
            while current<sections.count {
                try Task.checkCancellation()
                let section=sections[current]
                if tracker==nil {
                    tracker=WorldPackProgress(asset:section.member.asset,sourceID:section.source.id,cache:cache,container:section.container,file:file)
                    reporter=WorldRegionTileReporter(source:section.source,savedFills:savedFills,savedTileCount:savedCount,report:report)
                }
                let (verified,active)=await tracker!.update(received:received)
                await reporter!.update(verified:verified,active:active)
                guard received>=section.end else { return }
                try await tracker!.finish(required:WorldSourceStore.assets(tiles:section.source.tiles,source:section.source))
                savedFills=WorldOfflineCoverage.displayBounds(savedFills+section.source.tiles.map { $0.mesh.bounds })
                savedCount+=section.source.tiles.count;current+=1;tracker=nil;reporter=nil
            }
        } catch { failure=error }
    }
    func finish() throws -> [WorldRegionArchive.Section] {
        if let failure { throw failure }
        guard let sections,current==sections.count else { throw RidgeError.message("The region download is incomplete.") }
        let handle=try FileHandle(forReadingFrom:file)
        defer { try? handle.close() }
        var digest=SHA256(),count=0
        while let data=try handle.read(upToCount:1024*1024),!data.isEmpty {
            try Task.checkCancellation();digest.update(data:data);count+=data.count
        }
        guard count==archive.asset.byteCount,digest.finalize().map({ String(format:"%02x",$0) }).joined()==archive.asset.sha256 else {
            throw RidgeError.message("The region download is damaged. Download it again to repair it.")
        }
        return sections
    }
}

extension WorldRegionDownloadStore {
    /// A new region needs no section metadata requests: manifests arrive in the
    /// same file. Existing saves are checked locally before choosing the bundle.
    func shouldDownloadArchive(_ archive:WorldRegionArchive,regions:[WorldCatalog.Region],root:URL) async throws -> Bool {
        var missing:Int64=0,total:Int64=0
        for region in regions {
            try Task.checkCancellation()
            let address=root.appendingPathComponent(region.path).absoluteString
            let index=cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8))+".index")
            if !FileManager.default.fileExists(atPath:index.path) {
                let bytes=Int64(region.pack?.byteCount ?? 0);missing+=bytes;total+=bytes;continue
            }
            let files=WorldSourceStore(cacheURL:cache,allowsNetwork:false)
            let source:WorldSource
            do { source=try await files.manifest(address:address,routing:region.routing,preferCached:true,recoverCoverage:false) }
            catch {
                try Task.checkCancellation()
                let bytes=Int64(region.pack?.byteCount ?? 0);missing+=bytes;total+=bytes;continue
            }
            let assets=WorldSourceStore.assets(tiles:source.tiles,source:source)
            let cached=try await files.cachedAssetHashes(for:assets)
            for asset in assets {
                total+=Int64(asset.byteCount)
                if !cached.contains(asset.sha256) { missing+=Int64(asset.byteCount) }
            }
        }
        // Preserve sparse repair and overlap reuse, rather than redownloading a
        // whole region just because a small part of it is missing.
        return missing>0 && (FileManager.default.fileExists(atPath:WorldSectionPack.file(archive.asset,cache:cache).path) || Double(missing)>=Double(total)*0.7)
    }
    func downloadArchive(_ archive:WorldRegionArchive,regions:[WorldCatalog.Region],root:URL,
                         tileProgress:@escaping @Sendable (WorldRegionTileProgress) async -> Void,
                         progress:@escaping @Sendable (Int64,Int) async -> Void) async throws {
        try archive.validate(sources:regions)
        let final=WorldSectionPack.file(archive.asset,cache:cache)
        let installed=FileManager.default.fileExists(atPath:final.path)
        let partial=WorldSectionPack.partial(archive.asset,cache:cache)
        let remaining=installed ? 0 : WorldSectionPack.remainingBytes(archive.asset,cache:cache)
        if let capacity=try? cache.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           capacity<remaining+256*1024*1024 { throw RidgeError.message("There isn’t enough free space for this region.") }
        let tracker=WorldArchiveTransfer(archive:archive,regions:regions,cache:cache,file:installed ? final : partial,report:tileProgress)
        let transferred:Int64
        if installed {
            // Recover an interrupted metadata installation from the intact file.
            await tracker.update(received:Int64(archive.asset.byteCount));transferred=0
        } else {
            transferred=try await WorldSectionPack.download(url:root.appendingPathComponent("region-packs").appendingPathComponent(archive.asset.file),asset:archive.asset,cache:cache) { received,bytes in
                await tracker.update(received:received)
                await progress(bytes,0)
            }
        }
        try Task.checkCancellation()
        let sections:[WorldRegionArchive.Section]
        do { sections=try await tracker.finish() }
        catch {
            if !Task.isCancelled { try? FileManager.default.removeItem(at:installed ? final : partial) }
            throw error
        }
        if !installed { try FileManager.default.moveItem(at:partial,to:final) }
        _=try WorldSourceStore.reserve([archive.asset.sha256],cache:cache)
        for section in sections {
            let region=regions.first { $0.id==section.source.id }!
            let address=root.appendingPathComponent(region.path).absoluteString
            let manifest=cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8))+".index")
            try section.manifest.write(to:manifest,options:.atomic)
            try WorldSectionPack.install(section.member.asset,sourceID:region.id,cache:cache,container:section.container)
            let receipt=WorldOfflineCoverage.Asset(hash:archive.asset.sha256,bytes:archive.asset.byteCount,packed:true)
            try WorldOfflineCoverage.record(section.source.tiles.map { .init(bounds:$0.mesh.bounds,assets:[receipt]) },at:cache,identifier:region.id)
        }
        await progress(transferred,regions.count)
    }
}
