import Foundation

struct UKPackRegion: Decodable, Identifiable, Sendable {
    struct Cell: Decodable, Sendable { var id: String; var bounds: GeoBounds }
    var id: String
    var name: String
    var cells: [Cell]
    var terrainBytes: Int64
    var detailedSections: Int
    static func load() throws -> [UKPackRegion] {
        struct Plan: Decodable { var schemaVersion: Int; var regions: [UKPackRegion] }
        guard let url = Bundle.main.url(forResource: "uk-pack-regions", withExtension: "json")
            ?? Bundle.main.url(forResource: "uk-pack-regions", withExtension: "json", subdirectory: "Resources") else {
            throw RidgeError.message("The UK region index is missing from this build.")
        }
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url))
        guard plan.schemaVersion == 1 else { throw RidgeError.message("Unsupported UK region index.") }
        return plan.regions
    }
}

struct OfflinePackSummary: Sendable {
    var entry: PackEntry
    var download: AreaDownloadEstimate
    var complete: Bool { download.downloadBytes == 0 }
}
struct DownloadedSourceStorage:Identifiable,Sendable {
    var entry:PackEntry
    var bytes:Int64
    var id:String { entry.id }
}

extension PackStore {
    func downloadedSourceStorage() throws -> [DownloadedSourceStorage] {
        try sourceEntriesForStorage().compactMap { entry in
            let receipt=entry.directory.appendingPathComponent("downloaded.json")
            guard let data=try? Data(contentsOf:receipt) else { return nil }
            let hashes=try JSONDecoder().decode([String:String].self,from:data)
            var bytes:Int64=0
            for name in hashes.keys {
                let file=try Self.assetPathForDownload(name,in:entry.directory)
                bytes+=Int64((try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)
            }
            return bytes>0 ? DownloadedSourceStorage(entry:entry,bytes:bytes) : nil
        }
    }
    func removeDownloadedSource(_ entry:PackEntry) throws {
        let entries=try sourceEntriesForStorage()
        guard let current=entries.first(where:{ $0.id==entry.id && $0.directory.standardizedFileURL.path==entry.directory.standardizedFileURL.path }) else {
            throw RidgeError.message("This downloaded pack could not be found.")
        }
        let receipt=current.directory.appendingPathComponent("downloaded.json")
        guard FileManager.default.fileExists(atPath:receipt.path) else { return }
        let hashes=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:receipt))
        let files=try hashes.keys.map { try Self.assetPathForDownload($0,in:current.directory) }
        for file in files where FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
        try JSONEncoder().encode([String:String]()).write(to:receipt,options:.atomic)
    }
    /// A storage operation, deliberately independent of scene admission and decoding.
    static func offlinePackAssets(_ manifest: RegionManifest) throws -> [SourceAsset] {
        guard let adaptive = manifest.adaptive, adaptive.isSource, adaptive.index == nil,
              manifest.cartography != nil, !adaptive.chunks.isEmpty else {
            throw RidgeError.message("This pack does not yet include the maps needed for exploration.")
        }
        var complete = manifest
        // Full context strips are retained in the shared source cache; scenes crop only what they need.
        complete.horizon = adaptive.context ?? manifest.horizon
        return AdaptiveArea.assets(complete)
    }

    func offlinePackSummary(_ entry: PackEntry) async throws -> OfflinePackSummary {
        let local = try inspect(directory: entry.directory)
        if local.adaptive?.index != nil {
            _ = try await hydrateAdaptiveSources(covering: entry.manifest.bounds, candidates: [entry])
        }
        let current = PackEntry(manifest: try inspect(directory: entry.directory), directory: entry.directory,
                                installed: false, remoteSource: entry.remoteSource)
        let assets = try Self.offlinePackAssets(current.manifest)
        return OfflinePackSummary(entry: current, download: try SourceDownloads.estimate(assets, at: current.directory))
    }

    func downloadOfflinePack(_ entry: PackEntry, transfer: @escaping @Sendable (Int64, Int64) async -> Void,
                             progress: @escaping @Sendable (Double) async -> Void) async throws {
        let summary = try await offlinePackSummary(entry)
        guard let remote = entry.remoteSource else { throw RidgeError.message("Reconnect this pack’s download server in Settings.") }
        let assets = try Self.offlinePackAssets(summary.entry.manifest)
        try await SourceDownloads.ensure(assets, at: entry.directory, remote: remote, transfer: transfer, progress: progress)
        try Task.checkCancellation()
        // No decoded mesh, texture allocation, new scene folder or RAM admission check.
        let result = try SourceDownloads.estimate(assets, at: entry.directory)
        guard result.downloadBytes == 0 else { throw RidgeError.message("Some pack files are missing. Resume the download to finish.") }
    }

    func removeOfflinePack(_ entry: PackEntry) throws {
        let manifest = try inspect(directory: entry.directory)
        let assets = try Self.offlinePackAssets(manifest)
        for asset in assets {
            try Task.checkCancellation()
            let url = try Self.assetPathForDownload(asset.file, in: entry.directory)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        // Preserve catalogue/index/overview and saved scenes (which own their hard links).
        let receipt = entry.directory.appendingPathComponent("downloaded.json")
        var hashes = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipt))) ?? [:]
        for asset in assets { hashes.removeValue(forKey: asset.file) }
        try JSONEncoder().encode(hashes).write(to: receipt, options: .atomic)
    }
}
