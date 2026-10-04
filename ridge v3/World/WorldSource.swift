import Foundation
import CoreGraphics
import SceneKit

struct WorldMapAsset: Codable, Sendable {
    var file: String
    var byteCount: Int
    var sha256: String
    var decodedByteCount: Int?
}
struct WorldTile: Codable, Sendable, Identifiable {
    var id: String
    var column: Int
    var row: Int
    var mesh: AdaptiveChunk
    var map: WorldMapAsset
}
struct WorldSource: Codable, Sendable {
    var schemaVersion: Int
    var id: String
    var name: String
    var revision: String
    var bounds: GeoBounds
    var columns: Int
    var rows: Int
    var overview: WorldMapAsset
    var graph: WorldMapAsset
    var tiles: [WorldTile]
    var places: [MapPlace]
    var sources: [SourceCredit]
    func validate() throws {
        guard schemaVersion == 1, id.hasPrefix("world-"), bounds.isValid,
              (1...64).contains(columns), (1...64).contains(rows), tiles.count <= min(256, columns * rows),
              Set(tiles.map(\.id)).count == tiles.count, Set(tiles.map { $0.row * columns + $0.column }).count == tiles.count else { throw RidgeError.message("Unsupported world source.") }
        for tile in tiles {
            try tile.mesh.validate()
            let nw = bounds.point(u: Double(tile.column)/Double(columns), v: Double(tile.row)/Double(rows))
            let se = bounds.point(u: Double(tile.column+1)/Double(columns), v: Double(tile.row+1)/Double(rows))
            guard abs(tile.mesh.bounds.minLongitude-nw.longitude)<1e-8, abs(tile.mesh.bounds.maxLongitude-se.longitude)<1e-8,
                  abs(tile.mesh.bounds.maxLatitude-nw.latitude)<1e-8, abs(tile.mesh.bounds.minLatitude-se.latitude)<1e-8, tile.id == tile.mesh.id, (0..<columns).contains(tile.column), (0..<rows).contains(tile.row),
                  bounds.contains(tile.mesh.bounds.center), (1...8_000_000).contains(tile.map.decodedByteCount ?? 0) else {
                throw RidgeError.message("Invalid world tile.")
            }
        }
    }
}
struct WorldOverview: Codable, Sendable {
    var width: Int
    var height: Int
    var heights: [Float]
    func elevation(_ point: GeoPoint, bounds: GeoBounds) -> Float {
        let uv = bounds.uv(point)
        let x = max(0, min(Float(width - 1), Float(uv.u) * Float(width - 1)))
        let y = max(0, min(Float(height - 1), Float(uv.v) * Float(height - 1)))
        let ix = Int(x), iy = Int(y), jx = min(width - 1, ix + 1), jy = min(height - 1, iy + 1)
        let tx = x - Float(ix), ty = y - Float(iy)
        return (heights[iy * width + ix] * (1 - tx) + heights[iy * width + jx] * tx) * (1 - ty)
            + (heights[jy * width + ix] * (1 - tx) + heights[jy * width + jx] * tx) * ty
    }
}
struct WorldVectorMap: Codable, Sendable {
    struct Path: Codable, Sendable { var kind: String; var closed: Bool; var rings: [[[Double]]]; var phase: Double? }
    var width: Double
    var height: Double
    var paths: [Path]
}
struct WorldTileRequest: Equatable, Sendable {
    var id: String
    var pixels: Int
    var fine: Bool
}
struct WorldPreparedTile: @unchecked Sendable {
    var request: WorldTileRequest
    var mesh: AdaptiveMesh?
    var image: CGImage
    var geometry: SCNGeometry?
}

/// Pure camera-to-working-set policy. Disk downloads and resident rendering are independent.
enum WorldWorkingSet {
    static let maximumTextures = 256
    static let meshBudget: Int64 = 96 * 1024 * 1024
    static func requests(source: WorldSource, center: GeoPoint, distance: Double) -> [WorldTileRequest] {
        let sorted = source.tiles.sorted { $0.mesh.bounds.center.distance(to: center) < $1.mesh.bounds.center.distance(to: center) }
        var memory: Int64 = 0
        return sorted.prefix(maximumTextures).enumerated().map { index, tile in
            let near = tile.mesh.bounds.center.distance(to: center)
            let fine = distance < 6500 && index < 16 && near < max(1000, distance * 0.8)
                && memory + tile.mesh.residentBytes <= meshBudget
            if fine { memory += tile.mesh.residentBytes }
            // A 1024 core plus gutter is reserved for the immediate foreground.
            let pixels = distance < 2300 && index < 4 ? 1024 : distance < 7000 && index < 16 ? 512 : index < 36 ? 256 : 128
            return WorldTileRequest(id: tile.id, pixels: pixels, fine: fine)
        }
    }
}

actor WorldSourceStore {
    private let bundled: URL
    private let cache: URL
    private var base: URL
    private var pins: Set<String> = []
    private let diskLimit: Int64 = 256 * 1024 * 1024
    init(bundledURL: URL? = nil, cacheURL: URL? = nil) {
        bundled = bundledURL ?? Bundle.main.url(forResource: "WorldData", withExtension: "bundle") ?? Bundle.main.bundleURL
        base = bundled
        cache = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorldCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var url = cache; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values)
        if let data = try? Data(contentsOf: cache.appendingPathComponent("pins.json")), let saved = try? JSONDecoder().decode(Set<String>.self, from: data) { pins = saved }
    }
    func open(address: String) async throws -> (WorldSource, WorldOverview, WalkingGraph) {
        let manifest: Data
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = bundled; manifest = try Data(contentsOf: bundled.appendingPathComponent("world.json"))
        } else {
            guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw RidgeError.message("Enter the full address of a world.json file.") }
            base = url.deletingLastPathComponent()
            let cached = cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8)) + ".index")
            do {
                var request = URLRequest(url: url); request.timeoutInterval = 15
                let (temporary, response) = try await URLSession.shared.download(for: request)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let size = try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
                guard size < 16_000_000 else { throw RidgeError.message("World index is too large.") }
                let raw = try Data(contentsOf: temporary)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, raw.count < 16_000_000 else { throw RidgeError.message("The world source could not be read.") }
                let source = try JSONDecoder().decode(WorldSource.self, from: raw); try source.validate()
                try raw.write(to: cached, options: .atomic); manifest = raw
            } catch {
                try Task.checkCancellation()
                guard let raw = try? Data(contentsOf: cached) else { throw error }; manifest = raw
            }
        }
        let source = try JSONDecoder().decode(WorldSource.self, from: manifest); try source.validate()
        let overview = try JSONDecoder().decode(WorldOverview.self, from: await read(source.overview))
        guard (2...2049).contains(overview.width), (2...2049).contains(overview.height), overview.heights.count == overview.width * overview.height, overview.heights.allSatisfy(\.isFinite) else { throw RidgeError.message("Invalid world overview.") }
        let graph = try JSONDecoder().decode(WalkingGraph.self, from: await read(source.graph))
        return (source, overview, graph)
    }
    func prepare(_ tile: WorldTile, request: WorldTileRequest, sourceBounds: GeoBounds) async throws -> WorldPreparedTile {
        let compressed = try await read(tile.map)
        guard let count = tile.map.decodedByteCount else { throw RidgeError.message("Missing vector size.") }
        let vector = try JSONDecoder().decode(WorldVectorMap.self, from: AdaptiveTerrainCodec.inflate(compressed, byteCount: count))
        try Task.checkCancellation()
        let image = try WorldCartography.draw(vector, pixels: request.pixels)
        var mesh: AdaptiveMesh?
        if request.fine {
            let chunk = tile.mesh
            let data = try await read(WorldMapAsset(file: chunk.path, byteCount: chunk.byteCount, sha256: chunk.sha256))
            mesh = try AdaptiveTerrainCodec.decode(data, chunk: chunk)
        }
        try Task.checkCancellation()
        let geometry = mesh.map { WorldGeometry.fine($0, sourceBounds: sourceBounds, pixels: request.pixels) }
        return WorldPreparedTile(request: request, mesh: mesh, image: image, geometry: geometry)
    }
    func pin(_ tiles: [WorldTile], source: WorldSource, surroundings: [WorldMapAsset] = []) async throws {
        var keep = [source.overview, source.graph] + surroundings
        for tile in tiles { keep += [tile.map, WorldMapAsset(file: tile.mesh.path, byteCount: tile.mesh.byteCount, sha256: tile.mesh.sha256)] }
        // Reserve completed files as they arrive; eviction must not remove the
        // beginning of a large offline operation before the final asset arrives.
        let previous = pins
        do {
            for asset in keep { _ = try await read(asset); pins.insert(asset.sha256) }
            try JSONEncoder().encode(pins).write(to: cache.appendingPathComponent("pins.json"), options: .atomic)
        } catch { pins = previous; throw error }
    }
    private func read(_ asset: WorldMapAsset) async throws -> Data {
        guard PackStore.safeName(asset.file), (1...32_000_000).contains(asset.byteCount), asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit) else { throw RidgeError.message("Invalid world asset.") }
        let saved = cache.appendingPathComponent(asset.sha256)
        func checked(_ data: Data) -> Bool { data.count == asset.byteCount && AdaptiveTerrainCodec.hash(data) == asset.sha256 }
        if base.isFileURL {
            let data = try Data(contentsOf: base.appendingPathComponent(asset.file)); guard checked(data) else { throw RidgeError.message("A bundled world file is damaged.") }; return data
        }
        if let data = try? Data(contentsOf: saved), checked(data) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: saved.path); return data
        }
        var request = URLRequest(url: base.appendingPathComponent(asset.file)); request.timeoutInterval = 20
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize == asset.byteCount else { throw RidgeError.message("Incomplete map download.") }
        let data = try Data(contentsOf: temporary)
        guard (response as? HTTPURLResponse)?.statusCode == 200, checked(data) else { throw RidgeError.message("A map file is incomplete. Move back to retry.") }
        try data.write(to: saved, options: .atomic); prune(protecting: asset.sha256); return data
    }
    private func prune(protecting hash: String) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.fileSizeKey,.contentModificationDateKey])) ?? []
        let files = urls.filter { $0.lastPathComponent.count == 64 }.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey]) else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var bytes = files.reduce(Int64(0)) { $0 + $1.1 }
        for (url, size, _) in files.sorted(by: { $0.2 < $1.2 }) where bytes > diskLimit && url.lastPathComponent != hash && !pins.contains(url.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: url)) != nil { bytes -= size }
        }
    }
}
