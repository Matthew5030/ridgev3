import Foundation
import CryptoKit
#if os(iOS)
import BackgroundAssets
import System
#endif

/// The URL is an internal resource identifier. It is never sent to URLSession.
/// Keeping catalogue-relative paths stable preserves existing offline receipts.
struct WorldAppleAssetIndex: Decodable, Sendable {
    struct Section: Decodable, Sendable {
        let metadataPack: String
        let terrainPack: String
        let metadataPath: String
        let metadataSHA256: String
        let packPath: String
        let pack: WorldMapAsset
    }
    let schemaVersion: Int
    let revision: String
    let catalogPath: String
    let catalogSHA256: String
    let sections: [String: Section]
    let downloadBytes: [String: Int64]

    static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") &&
        path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    func validate() throws {
        guard schemaVersion == 1, !revision.isEmpty, sections.count <= 20_000,
              catalogPath == "world/catalog.json", catalogSHA256.count == 64,
              catalogSHA256.allSatisfy(\.isHexDigit), downloadBytes.count <= 99,
              downloadBytes.values.allSatisfy({ $0 > 0 && $0 <= 4_000_000_000 }) else {
            throw RidgeError.message("The Apple map library is invalid.")
        }
        for (id, section) in sections {
            guard id.hasPrefix("world-"), id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
                  section.metadataPath == "world/sources/\(id)/world.json",
                  section.packPath == "world/sources/\(id)/\(section.pack.file)",
                  Self.safePath(section.packPath), WorldSectionPack.valid(section.pack),
                  section.metadataSHA256.count == 64, section.metadataSHA256.allSatisfy(\.isHexDigit),
                  section.metadataPack != section.terrainPack,
                  downloadBytes[section.metadataPack] != nil, downloadBytes[section.terrainPack] != nil else {
                throw RidgeError.message("An Apple map section is invalid.")
            }
        }
    }
}

protocol WorldAppleAssetBackend: Sendable {
    func data(path: String, pack: String) async throws -> Data
    func ensure(pack: String, progress: @escaping @Sendable (Int64) async -> Void) async throws -> Int64
    func available(pack: String) async -> Bool
    func size(pack: String) async throws -> Int64
}

#if os(iOS)
private final class WorldAppleDownloadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var progress: Progress?
    func attach(_ value: Progress) {
        lock.lock(); progress = value; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = progress; lock.unlock()
        value?.cancel()
    }
}
private struct WorldAppleSystemBackend: WorldAppleAssetBackend {
    private func manager() throws -> AssetPackManager {
        // AssetPackManager.shared traps instead of throwing if its group is
        // inaccessible (for example, an unsigned simulator build). Check first
        // so the bundled maps still work in local development.
        guard let group=Bundle.main.object(forInfoDictionaryKey:"BAAppGroupID") as? String,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group) != nil else {
            throw RidgeError.message("Additional map downloads need a Ridge installation from TestFlight or the App Store. Your bundled maps are ready to use.")
        }
        return AssetPackManager.shared
    }
    func data(path: String, pack: String) async throws -> Data {
        try manager().contents(at:FilePath(path),searchingInAssetPackWithID:pack)
    }
    func available(pack: String) async -> Bool {
        guard let status = try? await manager().status(ofAssetPackWithID:pack) else { return false }
        return status.contains(.downloaded) && !status.contains(.obsolete) && !status.contains(.outOfDate) && !status.contains(.updateAvailable)
    }
    func size(pack: String) async throws -> Int64 {
        Int64(try await manager().assetPack(withID:pack).downloadSize)
    }
    func ensure(pack: String, progress: @escaping @Sendable (Int64) async -> Void) async throws -> Int64 {
        try Task.checkCancellation()
        let manager = try manager()
        let cancellation = WorldAppleDownloadCancellation()
        if await available(pack:pack) { return 0 }
        let asset = try await manager.assetPack(withID:pack)
        let updates = Task {
            for await update in manager.statusUpdates(forAssetPackWithID:pack) {
                if Task.isCancelled { break }
                switch update {
                case .downloading(_,let value):
                    cancellation.attach(value)
                    await progress(max(0,min(Int64(asset.downloadSize),value.completedUnitCount)))
                case .finished: return
                case .failed: return
                default: break
                }
            }
        }
        defer { updates.cancel() }
        try await withTaskCancellationHandler {
            if #available(iOS 26.4, *) {
                try await manager.ensureLocalAvailability(of:asset,requireLatestVersion:true)
            } else {
                try await manager.ensureLocalAvailability(of:asset)
            }
        } onCancel: {
            // Keep observing until the native progress arrives, including when
            // cancellation happens before the first download status update.
            cancellation.cancel()
        }
        try Task.checkCancellation()
        await progress(Int64(asset.downloadSize))
        return Int64(asset.downloadSize)
    }
}
#else
private struct WorldAppleSystemBackend: WorldAppleAssetBackend {
    func data(path:String,pack:String) async throws -> Data { throw RidgeError.message("Apple map downloads require the iOS app.") }
    func ensure(pack:String,progress:@escaping @Sendable(Int64) async -> Void) async throws -> Int64 { throw RidgeError.message("Apple map downloads require the iOS app.") }
    func available(pack:String) async -> Bool { false }
    func size(pack:String) async throws -> Int64 { throw RidgeError.message("Apple map downloads require the iOS app.") }
}
#endif

actor WorldAppleAssets {
    static let root = URL(string:"https://apple-maps.ridge.invalid/world/")!
    static let libraryPack = "ridge-uk-v1-metadata-081-051"
    static let shared = WorldAppleAssets(backend:WorldAppleSystemBackend())
    static func handles(_ url:URL) -> Bool {
        url.scheme == "https" && url.host == root.host && url.port == nil && url.query == nil && url.fragment == nil
    }
    static func sectionID(_ url:URL) throws -> String {
        let pieces=url.path.split(separator:"/")
        guard handles(url),pieces.count==4,pieces[0]=="world",pieces[1]=="sources",
              WorldAppleAssetIndex.safePath(String(pieces[2])) else { throw RidgeError.message("Invalid Apple map path.") }
        return String(pieces[2])
    }
    private let backend: any WorldAppleAssetBackend
    private var savedIndex: WorldAppleAssetIndex?
    private var imports: [String:Task<Void,Error>] = [:]
    init(backend:any WorldAppleAssetBackend) { self.backend=backend }

    private func index() async throws -> WorldAppleAssetIndex {
        if let savedIndex { return savedIndex }
        _ = try await backend.ensure(pack:Self.libraryPack) { _ in }
        let data = try await backend.data(path:"RidgeMaps/library.json",pack:Self.libraryPack)
        guard data.count <= 16_000_000 else { throw RidgeError.message("The Apple map index is too large.") }
        let index = try JSONDecoder().decode(WorldAppleAssetIndex.self,from:data)
        try index.validate(); savedIndex=index;return index
    }
    func catalogData() async throws -> Data {
        let index = try await index()
        let data = try await backend.data(path:index.catalogPath,pack:Self.libraryPack)
        guard data.count <= 16_000_000, AdaptiveTerrainCodec.hash(data)==index.catalogSHA256 else {
            throw RidgeError.message("The Apple map catalogue failed verification.")
        }
        let catalog=try JSONDecoder().decode(WorldCatalog.self,from:data);try catalog.validate()
        guard Set(catalog.sources.map(\.id))==Set(index.sections.keys),catalog.sources.allSatisfy({ source in
            index.sections[source.id]?.pack.sha256 == source.pack?.sha256 && index.sections[source.id]?.pack.byteCount == source.pack?.byteCount
        }) else { throw RidgeError.message("The Apple map catalogue and downloads do not match.") }
        return data
    }
    func sourceData(_ url:URL) async throws -> Data {
        let id=try Self.sectionID(url),index=try await index()
        guard url.lastPathComponent=="world.json",let section=index.sections[id] else { throw RidgeError.message("This area is not in the Apple map library.") }
        _ = try await backend.ensure(pack:section.metadataPack) { _ in }
        let data=try await backend.data(path:section.metadataPath,pack:section.metadataPack)
        guard data.count <= 16_000_000,AdaptiveTerrainCodec.hash(data)==section.metadataSHA256 else {
            throw RidgeError.message("The map index failed verification. Check for updated map downloads.")
        }
        return data
    }
    func downloadBytes(sections:[String]) async throws -> Int64 {
        let index=try await index()
        var bytes:Int64=0
        for id in Set(try sections.map { id -> String in
            guard let section=index.sections[id] else { throw RidgeError.message("This area is not available from Apple yet.") }
            return section.terrainPack
        }).sorted() {
            if await backend.available(pack:id) { continue }
            bytes += (try? await backend.size(pack:id)) ?? index.downloadBytes[id]!
        }
        return bytes
    }
    @discardableResult
    func ensureTerrain(sections:[String],progress:@escaping @Sendable(Int64) async -> Void) async throws -> Int64 {
        let index=try await index()
        let packs=try Set(sections.map { id -> String in
            guard let section=index.sections[id] else { throw RidgeError.message("This area is not available from Apple yet.") }
            return section.terrainPack
        })
        var completed:Int64=0
        for pack in packs.sorted() {
            try Task.checkCancellation()
            let base=completed
            completed += try await backend.ensure(pack:pack) { value in await progress(base+value) }
            await progress(completed)
        }
        return completed
    }
    /// Copies authenticated Apple content into the existing encrypted cache.
    /// Terrain copies happen only after the caller commits a download/read.
    func copySection(url:URL,asset:WorldMapAsset,cache:URL,
                     progress:@escaping @Sendable(Int64,Int64) async -> Void) async throws -> Int64 {
        let id=try Self.sectionID(url),index=try await index()
        guard let section=index.sections[id],section.pack.file==url.lastPathComponent,
              section.pack.sha256==asset.sha256,section.pack.byteCount==asset.byteCount else {
            throw RidgeError.message("The Apple map download does not match its catalogue.")
        }
        let transferred=try await ensureTerrain(sections:[id]) { value in await progress(0,value) }
        let data=try await backend.data(path:section.packPath,pack:section.terrainPack)
        guard data.count==asset.byteCount else { throw RidgeError.message("The Apple map download has an incorrect size.") }
        let directory=WorldSectionPack.directory(cache)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let partial=WorldSectionPack.partial(asset,cache:cache)
        let writer=try ProtectedMapStorage.Writer(url:partial,expected:asset.byteCount,encrypt:true,initial:0)
        do {
            var digest=SHA256(),offset=0
            while offset<data.count {
                try Task.checkCancellation()
                let end=min(data.count,offset+65_536),chunk=data.subdata(in:offset..<end)
                digest.update(data:chunk);try writer.write(contentsOf:chunk);offset=end
                if offset % (1024*1024)==0 || offset==data.count {
                    await progress(Int64(writer.committedLength),transferred)
                    await Task.yield()
                }
            }
            let sha=digest.finalize().map { String(format:"%02x",$0) }.joined()
            guard sha==asset.sha256 else { throw RidgeError.message("The Apple map download failed its checksum.") }
            try writer.finish();try writer.close()
        } catch {
            try? writer.close();try? FileManager.default.removeItem(at:partial);throw error
        }
        return transferred
    }
    func prepareSection(id:String,cache:URL) async throws {
        let index=try await index()
        guard let section=index.sections[id] else { throw RidgeError.message("This area is not in the Apple map library.") }
        if let reader=WorldSectionPack.open(sourceID:id,cache:cache),reader.asset.sha256==section.pack.sha256 { return }
        let key=cache.path+":"+section.pack.sha256
        try Task.checkCancellation()
        if let task=imports[key] {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); return
        }
        let task=Task {
            let url=Self.root.appendingPathComponent("sources/\(id)/\(section.pack.file)")
            _ = try await self.copySection(url:url,asset:section.pack,cache:cache) { _,_ in }
            let partial=WorldSectionPack.partial(section.pack,cache:cache)
            try WorldSectionPack.Reader(url:partial,asset:section.pack,sourceID:id).verify()
            try Task.checkCancellation()
            let final=WorldSectionPack.file(section.pack,cache:cache)
            if FileManager.default.fileExists(atPath:final.path) {
                _ = try FileManager.default.replaceItemAt(final,withItemAt:partial)
            } else { try FileManager.default.moveItem(at:partial,to:final) }
            try WorldSectionPack.install(section.pack,sourceID:id,cache:cache)
        }
        imports[key]=task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); imports[key]=nil
        } catch { imports[key]=nil;throw error }
    }
    func readAsset(_ asset:WorldMapAsset,base:URL,cache:URL) async throws -> Data {
        let id=try Self.sectionID(base.appendingPathComponent(asset.file))
        try await prepareSection(id:id,cache:cache)
        guard let reader=WorldSectionPack.open(sourceID:id,cache:cache) else { throw RidgeError.message("The saved Apple map could not be opened.") }
        return try reader.read(asset)
    }
}
