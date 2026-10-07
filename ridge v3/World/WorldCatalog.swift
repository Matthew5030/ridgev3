import Foundation

/// Cloud and LAN publish the same relative catalogue; geography chooses a source.
enum WorldLibrary {
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
    }
    let schemaVersion: Int
    let revision: String
    let sources: [Region]
    func validate() throws {
        guard schemaVersion == 1, !revision.isEmpty, sources.count <= 20_000,
              Set(sources.map(\.id)).count == sources.count else { throw RidgeError.message("Unsupported map catalogue.") }
        for region in sources {
            let pieces = region.path.split(separator: "/", omittingEmptySubsequences: false)
            guard region.bounds.isValid, (1...256).contains(region.tileCount), region.id.hasPrefix("world-"),
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
    func open(root: URL) async throws -> WorldCatalog {
        let url = root.appendingPathComponent("catalog.json")
        let saved = cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(url.absoluteString.utf8)) + ".catalog")
        func decode(_ data: Data) throws -> WorldCatalog {
            guard data.count < 16_000_000 else { throw RidgeError.message("The map catalogue is too large.") }
            let value = try JSONDecoder().decode(WorldCatalog.self, from: data); try value.validate(); return value
        }
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
