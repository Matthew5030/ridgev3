import Foundation

/// Cloud and LAN publish the same relative catalogue; geography chooses a source.
enum WorldLibrary {
    /// A live check, deliberately independent of the offline catalogue cache.
    static func checkConnection(root: URL) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: root.appendingPathComponent("catalog.json"), cachePolicy: .reloadIgnoringLocalCacheData)
        do {
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw RidgeError.message("The server responded with HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Check the address ends in /world/.")
            }
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max < 16_000_000 else {
                throw RidgeError.message("The server returned an oversized map catalogue.")
            }
            let catalog = try JSONDecoder().decode(WorldCatalog.self, from: Data(contentsOf: file))
            try catalog.validate()
            return catalog.sources.count
        } catch let error as URLError {
            try Task.checkCancellation()
            let help: String
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                help = "The server name could not be found. Try the Mac’s Wi-Fi IP address instead of its .local name."
            case .notConnectedToInternet:
                help = "Check Wi-Fi and allow Local Network access for Ridge in iPad or iPhone Settings."
            case .timedOut, .cannotConnectToHost, .networkConnectionLost:
                help = "Keep the Mac awake with the download server running, and connect both devices to the same network."
            default: help = "Check Wi-Fi and Local Network access for Ridge in Settings."
            }
            throw RidgeError.message("Cannot reach \(root.host ?? "the server"). \(help) \(error.localizedDescription) (\(error.errorCode))")
        }
    }
    static let defaultMode = "local"
    static let defaultLocalServer = "http://Matthews-MacBook-Pro.local:8787/world/"
    static let cloud = "https://pub-a3a39b39506c41c5b291f2f895122777.r2.dev/pilot-2026-10-07/"
    static func root(mode: String, local: String) throws -> URL {
        if mode != "local" { return URL(string: cloud)! }
        let text = local.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw RidgeError.message("Enter your local server address, such as http://your-mac.local:8787.")
        }
        if parts.path.isEmpty || parts.path == "/" { parts.path = "/world/" }
        else if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw RidgeError.message("The local server address is invalid.") }
        return url
    }
}

struct WorldCatalog: Decodable, Sendable {
    struct Region: Decodable, Sendable, Identifiable {
        let id: String
        let path: String
        let bounds: GeoBounds
        let tileCount: Int
        var downloadBytes: Int64? = nil
        var routing: WorldMapAsset? = nil
        /// Actual holes within the source rectangle; an empty list certifies
        /// complete coverage. Older sparse catalogues cannot certify this.
        var missingTerrain: [GeoBounds]? = nil
        var pack: WorldMapAsset? = nil
        /// Standard surface-model coverage; omitted for retained LiDAR sources.
        var standardTerrain: [GeoBounds]? = nil
        var standardTileCount: Int? = nil
    }
    let schemaVersion: Int
    let revision: String
    let sources: [Region]
    var packVersion:Int? = nil
    var regionArchives:[WorldRegionArchive]? = nil
    func validate() throws {
        guard schemaVersion == 1, !revision.isEmpty, sources.count <= 20_000,
              Set(sources.map(\.id)).count == sources.count else { throw RidgeError.message("Unsupported map catalogue.") }
        if let regionArchives {
            guard regionArchives.count<=1000,Set(regionArchives.map(\.id)).count==regionArchives.count else { throw RidgeError.message("Invalid region downloads.") }
            for archive in regionArchives { try archive.validate(sources:sources) }
        }
        for region in sources {
            if let count=region.standardTileCount {
                guard (0...region.tileCount).contains(count),region.standardTerrain != nil else { throw RidgeError.message("Invalid terrain quality metadata.") }
            }
            if let standard=region.standardTerrain {
                guard standard.count<=256,standard.allSatisfy({ $0.isValid &&
                    $0.minLongitude>=region.bounds.minLongitude-1e-8 && $0.maxLongitude<=region.bounds.maxLongitude+1e-8 &&
                    $0.minLatitude>=region.bounds.minLatitude-1e-8 && $0.maxLatitude<=region.bounds.maxLatitude+1e-8 }) else { throw RidgeError.message("Invalid standard terrain coverage.") }
            }
            if let pack=region.pack,!WorldSectionPack.valid(pack) { throw RidgeError.message("Invalid section pack in catalogue.") }
            if let gaps=region.missingTerrain {
                guard gaps.count<=256,gaps.allSatisfy({ $0.isValid &&
                    $0.minLongitude>=region.bounds.minLongitude-1e-8 && $0.maxLongitude<=region.bounds.maxLongitude+1e-8 &&
                    $0.minLatitude>=region.bounds.minLatitude-1e-8 && $0.maxLatitude<=region.bounds.maxLatitude+1e-8 }) else {
                    throw RidgeError.message("The map catalogue contains invalid terrain coverage.")
                }
            }
            let pieces = region.path.split(separator: "/", omittingEmptySubsequences: false)
            guard region.bounds.isValid, (1...256).contains(region.tileCount), region.id.hasPrefix("world-"),
                  region.downloadBytes.map({ (1...64_000_000_000).contains($0) }) ?? true,
                  pieces.count == 3, pieces[0] == "sources", pieces[1] == Substring(region.id), pieces[2] == "world.json",
                  region.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw RidgeError.message("The map catalogue contains an invalid region.")
            }
        }
    }
    /// Retain the current region on a shared edge to prevent back-and-forth loads.
    func region(at point: GeoPoint, retaining id: String? = nil) -> Region? {
        if let id, let old = sources.first(where: { $0.id == id && $0.bounds.contains(point) }) { return old }
        return sources.filter { $0.bounds.contains(point) }.min { $0.id < $1.id }
    }
}

actor WorldCatalogStore {
    private let cache: URL
    init(cacheURL: URL? = nil) {
        cache = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorldCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
    func open(root: URL, preferCached: Bool = false) async throws -> WorldCatalog {
        let url = root.appendingPathComponent("catalog.json")
        let saved = cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(url.absoluteString.utf8)) + ".catalog")
        func decode(_ data: Data) throws -> WorldCatalog {
            guard data.count < 16_000_000 else { throw RidgeError.message("The map catalogue is too large.") }
            let value = try JSONDecoder().decode(WorldCatalog.self, from: data); try value.validate(); return value
        }
        // Upgrade catalogues predating coverage holes or complete pack publication. If
        // offline, the fallback below still opens them conservatively.
        if preferCached, let data=try? Data(contentsOf:saved),let value=try? decode(data),
           value.packVersion==1,value.sources.allSatisfy({ $0.pack != nil && ($0.missingTerrain != nil || $0.tileCount==256) }) { return value }
        do {
            var request = URLRequest(url: url); request.timeoutInterval = 10
            let (file, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max < 16_000_000 else {
                throw RidgeError.message("The map server could not be reached. Check the source in Settings.")
            }
            let data = try Data(contentsOf: file), value = try decode(data)
            try data.write(to: saved, options: .atomic); return value
        } catch {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: saved), let value = try? decode(data) { return value }
            throw error
        }
    }
}
