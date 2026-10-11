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
    var background: AdaptiveChunk?
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
    var backgroundToleranceMetres: Double?
    // Runtime-only geographic frame; storage bounds still describe coverage.
    var renderBounds: GeoBounds? = nil
    var frame: GeoBounds { renderBounds ?? bounds }
    func validate() throws {
        guard schemaVersion == 1, id.hasPrefix("world-"), bounds.isValid,
              (1...64).contains(columns), (1...64).contains(rows), tiles.count <= min(256, columns * rows),
              Set(tiles.map(\.id)).count == tiles.count, Set(tiles.map { $0.row * columns + $0.column }).count == tiles.count else { throw RidgeError.message("Unsupported world source.") }
        for tile in tiles {
            try tile.mesh.validate()
            if let tolerance = backgroundToleranceMetres {
                guard let background = tile.background, background.id == tile.id,
                      background.bounds == tile.mesh.bounds else { throw RidgeError.message("Incomplete adaptive background.") }
                try background.validate(maximumErrorMetres:tolerance)
            } else if tile.background != nil { throw RidgeError.message("Missing background tolerance.") }
            let nw = bounds.point(u: Double(tile.column)/Double(columns), v: Double(tile.row)/Double(rows))
            let se = bounds.point(u: Double(tile.column+1)/Double(columns), v: Double(tile.row+1)/Double(rows))
            guard abs(tile.mesh.bounds.minLongitude-nw.longitude)<1e-8, abs(tile.mesh.bounds.maxLongitude-se.longitude)<1e-8,
                  abs(tile.mesh.bounds.maxLatitude-nw.latitude)<1e-8, abs(tile.mesh.bounds.minLatitude-se.latitude)<1e-8, tile.id == tile.mesh.id, (0..<columns).contains(tile.column), (0..<rows).contains(tile.row),
                  bounds.contains(tile.mesh.bounds.center), (1...8_000_000).contains(tile.map.decodedByteCount ?? 0) else {
                throw RidgeError.message("Invalid world tile.")
            }
        }
        guard tiles.compactMap(\.background).reduce(Int64(0), { $0+$1.residentBytes }) <= 256*1024*1024 else {
            throw RidgeError.message("Adaptive background exceeds this source's memory allowance.")
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

struct WorldBackdrop: @unchecked Sendable {
    var geometries: [String: SCNGeometry]
    var meshes: [String: AdaptiveMesh]
}

/// Bounded residency with a retention margin, independent of download size.
enum WorldWorkingSet {
    static let maximumTextures = 256
    static let meshBudget: Int64 = ProcessInfo.processInfo.physicalMemory >= 6 * 1024 * 1024 * 1024 ? 192 * 1024 * 1024 : 96 * 1024 * 1024
    static let textureBudget: Int64 = 192 * 1024 * 1024
    static func requests(source: WorldSource, center: GeoPoint, distance: Double, previous: [WorldTileRequest] = [], meshLimit: Int64 = meshBudget) -> [WorldTileRequest] {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id,$0) })
        let ranges = Dictionary(uniqueKeysWithValues: source.tiles.map { ($0.id,$0.mesh.bounds.center.distance(to:center)) })
        let sorted = source.tiles.sorted {
            let a = ranges[$0.id]! - (old[$0.id]?.fine == true ? 650 : 0)
            let b = ranges[$1.id]! - (old[$1.id]?.fine == true ? 650 : 0)
            return a == b ? $0.id < $1.id : a < b
        }
        var memory:Int64=0, native=0, medium=0
        return sorted.prefix(maximumTextures).map { tile in
            let near=ranges[tile.id]!, retained=old[tile.id]
            let fine=near < (retained?.fine == true ? 4500 : 3200) && memory+tile.mesh.residentBytes <= meshLimit
            if fine { memory += tile.mesh.residentBytes }
            var pixels=256
            if native<8 && distance < (retained?.pixels == 1024 ? 3200 : 2300) && near < (retained?.pixels == 1024 ? 1600 : 1050) {
                pixels=1024;native+=1
            } else if medium<24 && distance < ((retained?.pixels ?? 0) >= 512 ? 11000 : 9000) && near < ((retained?.pixels ?? 0) >= 512 ? 3400 : 2600) {
                pixels=512;medium+=1
            }
            return WorldTileRequest(id:tile.id,pixels:pixels,fine:fine)
        }
    }
    /// Every tile already has a textured horizon fallback. Retire oversized
    /// pages first, then finish the nearest requested detail before spending
    /// time on distant pages. Do not rasterize a throwaway 256px intermediate.
    static func pending(wanted: [WorldTileRequest], current: [String: WorldTileRequest]) -> [WorldTileRequest] {
        let changed = wanted.filter { current[$0.id] != $0 }
        let down = changed.filter {
            guard let old = current[$0.id] else { return false }
            return old.pixels > $0.pixels || (old.fine && !$0.fine)
        }
        let ids = Set(down.map(\.id))
        return down + changed.filter { !ids.contains($0.id) }
    }

}

actor WorldSourceStore {
    nonisolated let allowsNetwork: Bool
    private let bundled: URL
    private let cache: URL
    private var base: URL
    private var pins: Set<String> = []
    private var bytesSincePrune = 0
    private var writesSincePrune = 0
    private let diskLimit: Int64 = 2 * 1024 * 1024 * 1024
    init(bundledURL: URL? = nil, cacheURL: URL? = nil, allowsNetwork: Bool = true) {
        self.allowsNetwork = allowsNetwork
        bundled = bundledURL ?? Bundle.main.url(forResource: "WorldData", withExtension: "bundle") ?? Bundle.main.bundleURL
        base = bundled
        cache = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorldCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var url = cache; var values = URLResourceValues(); values.isExcludedFromBackup = true; try? url.setResourceValues(values)
        if let data = try? Data(contentsOf: cache.appendingPathComponent("pins.json")), let saved = try? JSONDecoder().decode(Set<String>.self, from: data) { pins = saved }
    }
    func manifest(address: String, routing: WorldMapAsset? = nil, preferCached: Bool = false) async throws -> WorldSource {
        let manifest: Data
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = bundled; manifest = try Data(contentsOf: bundled.appendingPathComponent("world.json"))
        } else {
            guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw RidgeError.message("Enter the full address of a world.json file.") }
            base = url.deletingLastPathComponent()
            let cached = cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8)) + ".index")
            if (preferCached || !allowsNetwork), let raw = try? Data(contentsOf:cached),
               let saved = try? JSONDecoder().decode(WorldSource.self,from:raw), (try? saved.validate()) != nil {
                manifest = raw
            } else {
                guard allowsNetwork else { throw RidgeError.message("This map index is missing. Download the area again while connected.") }
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
        }
        var source = try JSONDecoder().decode(WorldSource.self, from: manifest); try source.validate()
        if let routing { source.graph = routing }
        // Recover the outline of completed saves made before coverage receipts existed.
        try? recordSavedCoverage(source.tiles, source:source)
        return source
    }
    func open(address: String, routing: WorldMapAsset? = nil) async throws -> (WorldSource, WorldOverview, WalkingGraph) {
        try await contents(of: manifest(address:address,routing:routing))
    }
    func contents(of source: WorldSource, includeGraph: Bool = true) async throws -> (WorldSource, WorldOverview, WalkingGraph) {
        let overview = try JSONDecoder().decode(WorldOverview.self, from: await read(source.overview))
        guard (2...2049).contains(overview.width), (2...2049).contains(overview.height), overview.heights.count == overview.width * overview.height, overview.heights.allSatisfy(\.isFinite) else { throw RidgeError.message("Invalid world overview.") }
        let graph = includeGraph ? try await walkingGraph(source) : WalkingGraph(nodes:[],edges:[])
        return (source, overview, graph)
    }
    func walkingGraph(_ source: WorldSource) async throws -> WalkingGraph {
        try JSONDecoder().decode(WalkingGraph.self,from:await read(source.graph,maximumBytes:64_000_000))
    }
    func backdrop(source: WorldSource, overview: WorldOverview, frame: GeoBounds? = nil) async throws -> WorldBackdrop {
        try await prefetch(source.tiles.compactMap(\.background).map { WorldMapAsset(file:$0.path,byteCount:$0.byteCount,sha256:$0.sha256) })
        var geometries:[String:SCNGeometry]=[:]
        var meshes:[String:AdaptiveMesh]=[:]
        let maximumDivisions = ProcessInfo.processInfo.physicalMemory >= 6 * 1024 * 1024 * 1024 ? 64 : 32
        for tile in source.tiles {
            try Task.checkCancellation()
            if let chunk=tile.background, let tolerance=source.backgroundToleranceMetres {
                let compressed=try await read(WorldMapAsset(file:chunk.path,byteCount:chunk.byteCount,sha256:chunk.sha256))
                let mesh=try AdaptiveTerrainCodec.decode(compressed,chunk:chunk,maximumErrorMetres:tolerance)
                meshes[tile.id]=mesh
                geometries[tile.id]=WorldGeometry.fine(mesh,sourceBounds:frame ?? source.bounds,pixels:256)
            } else {
                geometries[tile.id]=WorldGeometry.coarse(tile:tile,source:source,overview:overview,maximumDivisions:maximumDivisions,frame:frame)
            }
        }
        return WorldBackdrop(geometries:geometries,meshes:meshes)
    }
    func preview(source: WorldSource, backdrop: WorldBackdrop) async throws -> (CGImage,[String:WorldPreparedTile]) {
        try await prefetch(source.tiles.map(\.map))
        var pages:[String:WorldPreparedTile]=[:]
        for tile in source.tiles {
            try Task.checkCancellation()
            pages[tile.id]=try await prepare(tile,request:WorldTileRequest(id:tile.id,pixels:128,fine:false),sourceBounds:source.bounds)
        }
        let image=try WorldPreview.render(source:source,backdrop:backdrop,tiles:pages)
        try Task.checkCancellation()
        return (image,pages)
    }
    func mapPages(source: WorldSource, pixels: Int) async throws -> [String:WorldPreparedTile] {
        try await prefetch(source.tiles.map(\.map))
        var result: [String:WorldPreparedTile] = [:]
        for tile in source.tiles {
            try Task.checkCancellation()
            result[tile.id] = try await prepare(tile, request: .init(id:tile.id,pixels:pixels,fine:false), sourceBounds:source.bounds)
            await Task.yield() // Let nearby-detail requests interleave with horizon work.
        }
        return result
    }
    func prepare(_ tile: WorldTile, request: WorldTileRequest, sourceBounds: GeoBounds, previous: WorldPreparedTile? = nil) async throws -> WorldPreparedTile {
        let image:CGImage
        if let previous,previous.request.pixels == request.pixels { image=previous.image }
        else {
            let compressed = try await read(tile.map)
            guard let count = tile.map.decodedByteCount else { throw RidgeError.message("Missing vector size.") }
            let vector = try JSONDecoder().decode(WorldVectorMap.self, from: AdaptiveTerrainCodec.inflate(compressed, byteCount: count))
            try Task.checkCancellation()
            image = try WorldCartography.draw(vector, pixels: request.pixels)
        }
        var mesh:AdaptiveMesh?, geometry:SCNGeometry?
        if request.fine {
            if let previous,let existing=previous.mesh {
                mesh=existing;geometry=previous.geometry
            } else {
                let chunk=tile.mesh
                let data=try await read(WorldMapAsset(file:chunk.path,byteCount:chunk.byteCount,sha256:chunk.sha256))
                mesh=try AdaptiveTerrainCodec.decode(data,chunk:chunk)
                try Task.checkCancellation()
                geometry=mesh.map { WorldGeometry.fine($0,sourceBounds:sourceBounds,pixels:request.pixels) }
            }
        }
        try Task.checkCancellation()
        return WorldPreparedTile(request:request,mesh:mesh,image:image,geometry:geometry)
    }
    static func assets(tiles: [WorldTile], source: WorldSource, surroundings: [WorldMapAsset] = []) -> [WorldMapAsset] {
        var keep = [source.overview, source.graph] + surroundings
        keep += source.tiles.compactMap(\.background).map { WorldMapAsset(file:$0.path,byteCount:$0.byteCount,sha256:$0.sha256) }
        for tile in tiles { keep += [tile.map, WorldMapAsset(file:tile.mesh.path,byteCount:tile.mesh.byteCount,sha256:tile.mesh.sha256)] }
        var seen = Set<String>()
        return keep.filter { seen.insert($0.sha256).inserted }
    }
    func cachedBytes(for assets: [WorldMapAsset]) throws -> Int64 {
        var bytes: Int64 = 0
        for asset in assets {
            try Task.checkCancellation()
            guard PackStore.safeName(asset.file), (1...64_000_000).contains(asset.byteCount),
                  asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit) else { throw RidgeError.message("Invalid world asset.") }
            let url = base.isFileURL ? base.appendingPathComponent(asset.file) : cache.appendingPathComponent(asset.sha256)
            if let data = try? Data(contentsOf:url), data.count == asset.byteCount, AdaptiveTerrainCodec.hash(data) == asset.sha256 { bytes += Int64(asset.byteCount) }
        }
        return bytes
    }
    // Shared cache writers reserve hashes atomically before starting downloads.
    // Partial saves remain reserved so a cancelled operation can be resumed.
    private static let pinLock = NSLock()
    private static func reserve(_ hashes: Set<String>, cache: URL) throws -> Set<String> {
        pinLock.lock(); defer { pinLock.unlock() }
        let url = cache.appendingPathComponent("pins.json")
        let saved = (try? JSONDecoder().decode(Set<String>.self,from:Data(contentsOf:url))) ?? []
        let merged = saved.union(hashes)
        try JSONEncoder().encode(merged).write(to:url,options:.atomic)
        return merged
    }
    func pin(_ tiles: [WorldTile], source: WorldSource, surroundings: [WorldMapAsset] = [], countCachedInProgress: Bool = true, progress: @Sendable (Int64) async -> Void = { _ in }) async throws {
        let assets = Self.assets(tiles:tiles,source:source,surroundings:surroundings)
        pins = try Self.reserve(Set(assets.map(\.sha256)),cache:cache)
        try await withThrowingTaskGroup(of:Int64.self) { group in
            var next = 0, completed: Int64 = 0
            func add(_ asset: WorldMapAsset) {
                group.addTask {
                    let cached = countCachedInProgress ? 0 : try await self.cachedBytes(for:[asset])
                    _ = try await self.read(asset,maximumBytes:asset.file == source.graph.file ? 64_000_000 : 32_000_000)
                    return Int64(asset.byteCount) - cached
                }
            }
            for _ in 0..<min(6,assets.count) { add(assets[next]); next += 1 }
            while let bytes = try await group.next() {
                try Task.checkCancellation()
                completed += bytes; await progress(completed)
                if next < assets.count { add(assets[next]); next += 1 }
            }
        }
        try Task.checkCancellation()
        try recordSavedCoverage(tiles,source:source)
    }
    private func recordSavedCoverage(_ tiles: [WorldTile], source: WorldSource) throws {
        guard !base.isFileURL, !pins.isEmpty else { return }
        var present: [String:Bool] = [:]
        let receipts = tiles.compactMap { tile -> WorldOfflineCoverage.Receipt? in
            let assets = [source.overview,source.graph,tile.map,
                WorldMapAsset(file:tile.mesh.path,byteCount:tile.mesh.byteCount,sha256:tile.mesh.sha256)]
                + [tile.background].compactMap { $0 }.map { WorldMapAsset(file:$0.path,byteCount:$0.byteCount,sha256:$0.sha256) }
            guard assets.allSatisfy({ asset in
                if let value=present[asset.sha256] { return value }
                let value=asset.sha256.count==64 && asset.sha256.allSatisfy(\.isHexDigit) && pins.contains(asset.sha256) && (try? cache.appendingPathComponent(asset.sha256).resourceValues(forKeys:[.fileSizeKey]).fileSize)==asset.byteCount
                present[asset.sha256]=value;return value
            }) else { return nil }
            return .init(bounds:tile.mesh.bounds,assets:assets.map { .init(hash:$0.sha256,bytes:$0.byteCount) })
        }
        try WorldOfflineCoverage.record(receipts,at:cache)
    }
    /// Fetch at most six files at a time. Geometry and image work stays serial.
    private func prefetch(_ assets: [WorldMapAsset]) async throws {
        guard !base.isFileURL else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<min(6, assets.count) {
                let asset = assets[next]; next += 1
                group.addTask { _ = try await self.read(asset) }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if next < assets.count {
                    let asset = assets[next]; next += 1
                    group.addTask { _ = try await self.read(asset) }
                }
            }
        }
    }
    private func read(_ asset: WorldMapAsset, maximumBytes: Int = 32_000_000) async throws -> Data {
        guard PackStore.safeName(asset.file), (1...maximumBytes).contains(asset.byteCount), asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit) else { throw RidgeError.message("Invalid world asset.") }
        let saved = cache.appendingPathComponent(asset.sha256)
        func checked(_ data: Data) -> Bool { data.count == asset.byteCount && AdaptiveTerrainCodec.hash(data) == asset.sha256 }
        if base.isFileURL {
            let data = try Data(contentsOf: base.appendingPathComponent(asset.file)); guard checked(data) else { throw RidgeError.message("A bundled world file is damaged.") }; return data
        }
        if let data = try? Data(contentsOf: saved), checked(data) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: saved.path); return data
        }
        guard allowsNetwork else { throw RidgeError.message("A downloaded map file is missing. Download this area again while connected.") }
        var request = URLRequest(url: base.appendingPathComponent(asset.file)); request.timeoutInterval = 20
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize == asset.byteCount else { throw RidgeError.message("Incomplete map download.") }
        let data = try Data(contentsOf: temporary)
        guard (response as? HTTPURLResponse)?.statusCode == 200, checked(data) else { throw RidgeError.message("A map file is incomplete. Move back to retry.") }
        try data.write(to: saved, options: .atomic); prune(protecting: asset.sha256, writtenBytes:data.count); return data
    }
    private func refreshPins() {
        if let data = try? Data(contentsOf: cache.appendingPathComponent("pins.json")),
           let saved = try? JSONDecoder().decode(Set<String>.self, from: data) { pins.formUnion(saved) }
    }
    private func prune(protecting hash: String, writtenBytes: Int) {
        bytesSincePrune += writtenBytes; writesSincePrune += 1
        guard bytesSincePrune >= 4*1024*1024 || writesSincePrune >= 32 else { return }
        bytesSincePrune = 0; writesSincePrune = 0
        refreshPins()
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

/// Geographic lookup shared by the camera and label placement. Small buckets
/// avoid scanning thousands of resident chunks for every elevation query.
struct WorldTileIndex {
    private var cells: [Int:[WorldTile]] = [:]
    init(tiles: [WorldTile]) {
        for tile in tiles {
            let b = tile.mesh.bounds
            for y in Self.cell(b.minLatitude)...Self.cell(b.maxLatitude) {
                for x in Self.cell(b.minLongitude)...Self.cell(b.maxLongitude) {
                    cells[y*100_000+x,default:[]].append(tile)
                }
            }
        }
    }
    private static func cell(_ value: Double) -> Int { Int(floor((value+180)*100)) }
    func tile(at point: GeoPoint) -> WorldTile? {
        guard point.isValid else { return nil }
        return cells[Self.cell(point.latitude)*100_000+Self.cell(point.longitude)]?.first { $0.mesh.bounds.contains(point) }
    }
}
