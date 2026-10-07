import Foundation
import CoreGraphics

/// Exercise the shipped source reader over HTTP(S), including decoded geometry,
/// cartography, route following, checksum-verified cache files and offline pins.
@main struct WorldHostedSourceTests {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { throw RidgeError.message("Supply hosted world.json URLs") }
        var reports: [[String: Any]] = []
        for address in CommandLine.arguments.dropFirst() {
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: cache) }
            // Only this command-line test accepts an operator-issued test token.
            // The shipped app always uses App Attest through WorldMapAccess.
            let token = ProcessInfo.processInfo.environment["RIDGE_MAP_TEST_TOKEN"]
            let origin = URL(string:address)!
            let store = WorldSourceStore(cacheURL: cache, download: { request in
                var request = request
                if let token, let url = request.url, WorldMapAccess.isProtected(url,service:origin) {
                    request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
                }
                return try await URLSession.shared.download(for:request)
            })
            let start = Date()
            let (source, overview, graph) = try await store.open(address: address)
            let indexSeconds = Date().timeIntervalSince(start)
            guard let tile = source.tiles.max(by: { $0.mesh.triangles < $1.mesh.triangles }) else { throw RidgeError.message("Empty hosted source") }
            let tileStart = Date()
            let prepared = try await store.prepare(tile, request: WorldTileRequest(id: tile.id, pixels: 512, fine: true), sourceBounds: source.bounds)
            guard let mesh = prepared.mesh, prepared.geometry != nil, prepared.image.width == 520,
                  mesh.elevation(at: tile.mesh.bounds.center) != nil else { throw RidgeError.message("Hosted terrain or vectors failed") }
            let tileSeconds = Date().timeIntervalSince(tileStart)
            let cachedStart = Date()
            let cached = try await store.prepare(tile, request: WorldTileRequest(id: tile.id, pixels: 256, fine: true), sourceBounds: source.bounds)
            let cacheSeconds = Date().timeIntervalSince(cachedStart)
            guard cached.mesh?.chunk.sha256 == tile.mesh.sha256, cached.image.width == 264 else { throw RidgeError.message("Cache reuse failed") }
            for asset in [source.overview, source.graph, tile.map, WorldMapAsset(file: tile.mesh.path, byteCount: tile.mesh.byteCount, sha256: tile.mesh.sha256)] {
                let bytes = try Data(contentsOf: cache.appendingPathComponent(asset.sha256))
                guard bytes.count == asset.byteCount, AdaptiveTerrainCodec.hash(bytes) == asset.sha256 else { throw RidgeError.message("Cached bytes differ from published manifest") }
            }
            let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.coordinate) })
            guard let edge = graph.edges.first(where: { $0.kind == "footpath" && $0.access != "private" }),
                  let from = nodes[edge.from], let to = nodes[edge.to] else { throw RidgeError.message("No walking edge in hosted region") }
            let route = try RouteEngine.walkingSegment(from: from, to: to, graph: graph)
            guard route.mode == "paths", route.points.count >= 2 else { throw RidgeError.message("Hosted routing failed") }
            let backgroundStart = Date()
            let background = try await store.backdrop(source: source, overview: overview)
            guard background.meshes.count == source.tiles.count else { throw RidgeError.message("Incomplete hosted background") }
            let backgroundSeconds = Date().timeIntervalSince(backgroundStart)
            try await store.pin([tile], source: source)
            let pins = try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: cache.appendingPathComponent("pins.json")))
            let required = [source.overview.sha256, source.graph.sha256, tile.map.sha256, tile.mesh.sha256] + source.tiles.compactMap { $0.background?.sha256 }
            guard required.allSatisfy(pins.contains) else { throw RidgeError.message("Offline pins incomplete") }
            reports.append(["url": address, "sourceID": source.id, "tiles": source.tiles.count,
                            "indexSeconds": indexSeconds, "fineTileSeconds": tileSeconds,
                            "cachedTileSeconds": cacheSeconds, "backgroundSeconds": backgroundSeconds,
                            "cachedPinnedAssets": pins.count, "routePoints": route.points.count])
            print("PASS hosted region: \(source.id)")
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
