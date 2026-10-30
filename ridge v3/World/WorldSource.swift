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
    /// North-up, pixel-centred colour samples including a neighbour border.
    /// Alpha is source confidence; zero retains the original map palette.
    /// Stored inside the checksummed vector asset, so offline packs need no new requests.
    struct GroundColour: Codable, Sendable {
        var version: Int
        var width: Int
        var height: Int
        var border: Int
        var rgba: Data
        func validate(maximumSide:Int=256,minimumBorder:Int?=nil) throws {
            guard version == 1, (3...maximumSide).contains(width), (3...maximumSide).contains(height),
                  (1...32).contains(border), width > 2 * border, height > 2 * border,
                  border >= (minimumBorder ?? Int(ceil(Double(max(width, height) - 2 * border) / 8)) + 1),
                  rgba.count == width * height * 4 else { throw RidgeError.message("Invalid ground colour samples.") }
        }
    }
    var width: Double
    var height: Double
    var paths: [Path]
    var groundColour: GroundColour? = nil
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

/// A preview's known walking line and smoothed flight corridor. Distances are
/// ordered route progress, so overlapping switchbacks keep their later visits.
struct WorldFlightDetailStation: Sendable {
    var distance:Double
    var points:[GeoPoint]
}
struct WorldFlightDetailIndex: Sendable {
    private var visits:[String:[Double]]=[:]
    private var coreVisits:[String:[Double]]=[:]
    init(stations:[WorldFlightDetailStation],tiles:[WorldTile],margin:Double=200) throws {
        let index=WorldTileIndex(tiles:tiles)
        for (i,station) in stations.enumerated() {
            if i%64==0 { try Task.checkCancellation() }
            var selected=Set<String>()
            var core=Set<String>()
            for point in station.points {
                if let tile=index.tile(at:point) { core.insert(tile.id) }
                for tile in index.tiles(near:point,radius:margin) { selected.insert(tile.id) }
            }
            for id in selected { visits[id,default:[]].append(station.distance) }
            for id in core { coreVisits[id,default:[]].append(station.distance) }
        }
    }
    func priorities(at distance:Double)->[String:Double] {
        func priority(_ distances:[Double])->Double {
            var a=0,b=distances.count
            while a<b { let m=(a+b)/2;if distances[m]<distance-100 { a=m+1 } else { b=m } }
            // Keep short routes resident when they fit. On longer routes the
            // next encounter wins over passed scenery, including on a return.
            return a<distances.count ? max(0,distances[a]-distance) : 1e12+distance-distances.last!
        }
        var result=visits.mapValues { priority($0)+800 }
        for (id,distances) in coreVisits { result[id]=min(result[id] ?? .infinity,priority(distances)) }
        return result
    }
}

/// Bounded residency with a retention margin, independent of download size.
enum WorldWorkingSet {
    static let maximumTextures = 256
    static let meshBudget: Int64 = ProcessInfo.processInfo.physicalMemory >= 6 * 1024 * 1024 * 1024 ? 192 * 1024 * 1024 : 96 * 1024 * 1024
    static let textureBudget: Int64 = 192 * 1024 * 1024
    /// Route tiles, in encounter order, consume the fine budget before scenery
    /// beside the camera. A short route can stay prepared in its entirety; a
    /// long one keeps a bounded forward buffer instead of filling GPU memory.
    static func flightRequests(source:WorldSource,priorities:[String:Double],center:GeoPoint,meshLimit:Int64=meshBudget)->[WorldTileRequest] {
        let ranges=Dictionary(uniqueKeysWithValues:source.tiles.map { ($0.id,$0.mesh.bounds.center.distance(to:center)) })
        let sorted=source.tiles.sorted { a,b in
            let x=priorities[a.id],y=priorities[b.id]
            if let x,let y { return x == y ? a.id<b.id : x<y }
            if x != nil || y != nil { return x != nil }
            let nearA=ranges[a.id]!,nearB=ranges[b.id]!
            return nearA == nearB ? a.id<b.id : nearA<nearB
        }
        var memory:Int64=0,rank=0
        return sorted.prefix(maximumTextures).map { tile in
            guard priorities[tile.id] != nil else { return .init(id:tile.id,pixels:128,fine:false) }
            defer { rank+=1 }
            let fine=rank<24 && memory+tile.mesh.residentBytes<=meshLimit
            if fine { memory+=tile.mesh.residentBytes }
            return .init(id:tile.id,pixels:rank<24 ? 1024 : rank<48 ? 512 : 128,fine:fine)
        }
    }
    static func requests(source: WorldSource, center: GeoPoint, distance: Double, previous: [WorldTileRequest] = [], meshLimit: Int64 = meshBudget, closePreview: Bool = false) -> [WorldTileRequest] {
        let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.id,$0) })
        let ranges = Dictionary(uniqueKeysWithValues: source.tiles.map { ($0.id,$0.mesh.bounds.center.distance(to:center)) })
        let sorted = source.tiles.sorted {
            // A ground-level camera must promote the tile under it, including
            // corners where retention would otherwise favour the previous tile.
            if closePreview, $0.mesh.bounds.contains(center) != $1.mesh.bounds.contains(center) {
                return $0.mesh.bounds.contains(center)
            }
            let retention=closePreview ? 150.0 : 650.0
            let a = ranges[$0.id]! - (old[$0.id]?.fine == true ? retention : 0)
            let b = ranges[$1.id]! - (old[$1.id]?.fine == true ? retention : 0)
            return a == b ? $0.id < $1.id : a < b
        }
        var memory:Int64=0, native=0, medium=0, closeRank=0
        return sorted.prefix(maximumTextures).map { tile in
            let near=ranges[tile.id]!, retained=old[tile.id]
            let nearby=closePreview ? closeRank<6 : near < (retained?.fine == true ? 4500 : 3200)
            let fine=nearby && memory+tile.mesh.residentBytes <= meshLimit
            if fine { memory += tile.mesh.residentBytes }
            if closePreview {
                let rank=closeRank;closeRank+=1
                // Flying prioritises frame time: six 1K pages and twelve 512px
                // neighbours replace 4K/2K uploads. Retain coarse surroundings.
                let pixels=rank<6 ? 1024 : rank<18 ? 512 : 128
                return WorldTileRequest(id:tile.id,pixels:pixels,fine:fine)
            }
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
    private var sectionPack:WorldSectionPack.Reader?
    private var packedSourceID:String?
    private var originalGraph:WorldMapAsset?
    private var publishedGraph:WorldMapAsset?
    private var stagedManifest:(url:URL,data:Data,sourceID:String,tileIDs:Set<String>)?
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
        if allowsNetwork, let data = try? Data(contentsOf: cache.appendingPathComponent("pins.json")), let saved = try? JSONDecoder().decode(Set<String>.self, from: data) { pins = saved }
    }
    func manifest(address: String, routing: WorldMapAsset? = nil, preferCached: Bool = false, recoverCoverage: Bool = true, stageForDownload: Bool = false) async throws -> WorldSource {
        stagedManifest=nil
        let manifest: Data
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = bundled; manifest = try Data(contentsOf: bundled.appendingPathComponent("world.json"))
        } else {
            guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw RidgeError.message("Enter the full address of a world.json file.") }
            base = url.deletingLastPathComponent()
            let cached = cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8)) + ".index")
            if !stageForDownload, (preferCached || !allowsNetwork), let raw = try? Data(contentsOf:cached),
               let saved = try? JSONDecoder().decode(WorldSource.self,from:raw), (try? saved.validate()) != nil {
                manifest = raw
            } else {
                guard allowsNetwork else { throw RidgeError.message("This map index is missing. Download the area again while connected.") }
                do {
                    let raw:Data
                    if WorldAppleAssets.handles(url) {
                        raw=try await WorldAppleAssets.shared.sourceData(url)
                    } else {
                    var request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData); request.timeoutInterval = 15
                    let authorised=try await WorldProtectedAccess.shared.authorised(request)
                    let (temporary, response) = try await URLSession.shared.download(for: authorised)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let size = try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
                    guard size < 16_000_000 else { throw RidgeError.message("World index is too large.") }
                    raw = try Data(contentsOf: temporary)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200, raw.count < 16_000_000 else { throw RidgeError.message("The world source could not be read.") }
                    }
                    let source = try JSONDecoder().decode(WorldSource.self, from: raw); try source.validate()
                    if stageForDownload {
                        // A refresh must not replace the offline index until its
                        // complete section is verified and saved successfully.
                        stagedManifest=(cached,raw,source.id,Set(source.tiles.map(\.id)))
                        try raw.write(to:cached.deletingPathExtension().appendingPathExtension("download-index"),options:.atomic)
                    } else { try raw.write(to:cached,options:.atomic) }
                    manifest = raw
                } catch {
                    try Task.checkCancellation()
                    guard !stageForDownload,let raw = try? Data(contentsOf: cached) else { throw error }; manifest = raw
                }
            }
        }
        var source = try JSONDecoder().decode(WorldSource.self, from: manifest); try source.validate()
        originalGraph=source.graph;publishedGraph=routing
        if let routing { source.graph = routing }
        packedSourceID=source.id
        sectionPack=WorldSectionPack.open(sourceID:source.id,cache:cache)
        // Recover the outline of completed saves made before coverage receipts existed.
        if recoverCoverage,!FileManager.default.fileExists(atPath:cache.appendingPathComponent("coverage-managed").path) { try? recordSavedCoverage(source.tiles, source:source) }
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
        try await routingGraph(source).1
    }
    func routingGraph(_ source:WorldSource) async throws -> (WorldMapAsset,WalkingGraph) {
        do {
            let data=try await read(source.graph,maximumBytes:64_000_000)
            return (source.graph,try JSONDecoder().decode(WalkingGraph.self,from:data))
        } catch {
            try Task.checkCancellation()
            guard !allowsNetwork,publishedGraph?.sha256==source.graph.sha256 else { throw error }
            // A catalogue refresh must not invalidate a previously admitted
            // offline save. Recover its verified connected sidecar from the
            // receipt/pack index; geometry and cartography are never candidates.
            var known=Set(Self.assets(tiles:source.tiles,source:source).map(\.sha256))
            if let originalGraph { known.insert(originalGraph.sha256) }
            let shared=WorldOfflineCoverage.sharedAssets(source:source,at:cache)
            var candidates=shared.filter { !known.contains($0.hash) }
                .map { WorldMapAsset(file:"paths-connected-saved.json",byteCount:$0.bytes,sha256:$0.hash) }
            if let sectionPack {
                candidates += sectionPack.ordered.filter { !known.contains($0.sha256) }
                    .map { WorldMapAsset(file:"paths-connected-saved.json",byteCount:$0.byteCount,sha256:$0.sha256) }
            }
            if let originalGraph,shared.contains(where:{ $0.hash==originalGraph.sha256 }) {
                candidates.append(originalGraph)
            }
            for asset in candidates {
                try Task.checkCancellation()
                guard let data=try? await read(asset,maximumBytes:64_000_000),
                      let graph=try? JSONDecoder().decode(WalkingGraph.self,from:data) else { continue }
                return (asset,graph)
            }
            throw error
        }
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
    /// Preflight only the saved mesh heights. No textures, SceneKit geometry or
    /// network fallbacks are needed to prepare a complete camera journey.
    func flightElevations(_ points:[GeoPoint],source:WorldSource,saved:Set<GeoBounds>) async throws -> [Float?] {
        let tiles=source.tiles.filter { saved.contains($0.mesh.bounds) },index=WorldTileIndex(tiles:tiles)
        var groups:[String:[Int]]=[:],result=[Float?](repeating:nil,count:points.count)
        for i in points.indices { if let tile=index.tile(at:points[i]) { groups[tile.id,default:[]].append(i) } }
        for tile in tiles {
            guard let indices=groups[tile.id] else { continue }
            try Task.checkCancellation()
            let chunk=tile.mesh
            let data=try await read(WorldMapAsset(file:chunk.path,byteCount:chunk.byteCount,sha256:chunk.sha256))
            let mesh=try AdaptiveTerrainCodec.decode(data,chunk:chunk)
            for i in indices { result[i]=mesh.elevation(at:points[i]).map(Float.init) }
        }
        return result
    }
    static func assets(tiles: [WorldTile], source: WorldSource, surroundings: [WorldMapAsset] = []) -> [WorldMapAsset] {
        var keep = [source.overview, source.graph] + surroundings
        keep += source.tiles.compactMap(\.background).map { WorldMapAsset(file:$0.path,byteCount:$0.byteCount,sha256:$0.sha256) }
        for tile in tiles { keep += [tile.map, WorldMapAsset(file:tile.mesh.path,byteCount:tile.mesh.byteCount,sha256:tile.mesh.sha256)] }
        var seen = Set<String>()
        return keep.filter { seen.insert($0.sha256).inserted }
    }
    private struct VerifiedFile: Equatable {
        let size: Int
        let modified: Date
        let created: Date
    }
    private var verifiedFiles: [String:VerifiedFile] = [:]
    /// Reuse a hash check within this store only while the file's size and dates
    /// are unchanged. A new planning store verifies the bytes again; receipts
    /// alone never establish integrity for a download.
    func cachedAssetHashes(for assets: [WorldMapAsset]) throws -> Set<String> {
        var hashes=Set<String>()
        if let sectionPack {
            do { try sectionPack.verify() }
            catch { self.sectionPack=nil }
        }
        for asset in assets {
            try Task.checkCancellation()
            guard PackStore.safeName(asset.file), (1...64_000_000).contains(asset.byteCount),
                  asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit) else { throw RidgeError.message("Invalid world asset.") }
            if let sectionPack,sectionPack.contains(asset) { hashes.insert(asset.sha256);continue }
            let url=base.isFileURL ? base.appendingPathComponent(asset.file) : cache.appendingPathComponent(asset.sha256)
            let key=url.absoluteString+"|"+asset.sha256
            guard let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey,.creationDateKey]),
                  (try? ProtectedMapStorage.logicalSize(url))==asset.byteCount else { verifiedFiles.removeValue(forKey:key);continue }
            let stamp: VerifiedFile?
            if let modified=values.contentModificationDate,let created=values.creationDate {
                stamp=VerifiedFile(size:asset.byteCount,modified:modified,created:created)
            } else { stamp=nil }
            if let stamp,verifiedFiles[key]==stamp { hashes.insert(asset.sha256);continue }
            if let data=try? ProtectedMapStorage.read(url),data.count==asset.byteCount,AdaptiveTerrainCodec.hash(data)==asset.sha256 {
                hashes.insert(asset.sha256);verifiedFiles[key]=stamp
            } else { verifiedFiles.removeValue(forKey:key) }
        }
        return hashes
    }
    func cachedBytes(for assets: [WorldMapAsset]) throws -> Int64 {
        let hashes=try cachedAssetHashes(for:assets)
        return assets.filter { hashes.contains($0.sha256) }.reduce(Int64(0)) { $0+Int64($1.byteCount) }
    }
    // Shared cache writers reserve hashes atomically before starting downloads.
    // Partial saves remain reserved so a cancelled operation can be resumed.
    private static let pinLock = NSLock()
    static func reserve(_ hashes: Set<String>, cache: URL) throws -> Set<String> {
        pinLock.lock(); defer { pinLock.unlock() }
        let url = cache.appendingPathComponent("pins.json")
        let saved = (try? JSONDecoder().decode(Set<String>.self,from:Data(contentsOf:url))) ?? []
        let merged = saved.union(hashes)
        try JSONEncoder().encode(merged).write(to:url,options:.atomic)
        return merged
    }
    /// Probe the actual source, bypassing URL cache and without waiting for the
    /// network to return. Cached catalogues must not imply a live download server.
    func checkDownloadConnection() async throws {
        guard !base.isFileURL else { return }
        guard allowsNetwork else { throw RidgeError.message("This map source is offline. Choose a download source in Settings.") }
        if WorldAppleAssets.handles(base) {
            _ = try await WorldAppleAssets.shared.catalogData();return
        }
        let configuration=URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity=false
        configuration.timeoutIntervalForRequest=6
        configuration.timeoutIntervalForResource=8
        let session=URLSession(configuration:configuration)
        defer { session.invalidateAndCancel() }
        var request=URLRequest(url:base.appendingPathComponent("world.json"),cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:6)
        request.httpMethod="HEAD"
        do {
            request=try await WorldProtectedAccess.shared.authorised(request)
            let (_,response)=try await session.data(for:request)
            try Task.checkCancellation()
            guard let http=response as? HTTPURLResponse,http.statusCode==200 else {
                throw RidgeError.message("The download server isn’t serving this map. Check the map source in Settings and retry.")
            }
        } catch {
            try Task.checkCancellation()
            if error is URLError {
                throw RidgeError.message("Cannot reach \(base.host ?? "the download server"). Check that the server is running and your device is connected to its network, then retry.")
            }
            throw error
        }
    }
    func pin(_ tiles: [WorldTile], source: WorldSource, surroundings: [WorldMapAsset] = [], countCachedInProgress: Bool = true, coverageID: String? = nil, assetProgress: @Sendable (Set<String>, Set<String>) async -> Void = { _,_ in }, progress: @Sendable (Int64) async -> Void = { _ in }) async throws {
        // Keep each tile's files together so usable tiles complete throughout a download.
        var seen = Set<String>()
        let ordered = [source.overview, source.graph] + tiles.flatMap { tile in
            [tile.background].compactMap { $0 }.map { WorldMapAsset(file:$0.path,byteCount:$0.byteCount,sha256:$0.sha256) }
                + [tile.map, WorldMapAsset(file:tile.mesh.path,byteCount:tile.mesh.byteCount,sha256:tile.mesh.sha256)]
        } + Self.assets(tiles:tiles,source:source,surroundings:surroundings)
        let assets = ordered.filter { seen.insert($0.sha256).inserted }
        var cached=try cachedAssetHashes(for:assets)
        if WorldAppleAssets.handles(base),allowsNetwork,!assets.allSatisfy({ cached.contains($0.sha256) }) {
            try await WorldAppleAssets.shared.prepareSection(id:source.id,cache:cache)
            sectionPack=WorldSectionPack.open(sourceID:source.id,cache:cache)
            cached=try cachedAssetHashes(for:assets)
        }
        if let sectionPack,assets.allSatisfy({ sectionPack.contains($0) && cached.contains($0.sha256) }) {
            pins=try Self.reserve([sectionPack.physicalAsset.sha256],cache:cache)
            try recordSavedCoverage(tiles,source:source,coverageID:coverageID)
            try commitStagedManifest(tiles,source:source)
            await progress(countCachedInProgress ? assets.reduce(0) { $0+Int64($1.byteCount) } : 0)
            await assetProgress(cached,[])
            return
        }
        pins = try Self.reserve(Set(assets.map(\.sha256)),cache:cache)
        let pending=assets.filter { !cached.contains($0.sha256) }
        try await withThrowingTaskGroup(of:(String,Int64).self) { group in
            var next = 0
            var completed: Int64 = countCachedInProgress ? assets.filter { cached.contains($0.sha256) }.reduce(0) { $0+Int64($1.byteCount) } : 0
            var verified=cached, active=Set<String>()
            func add(_ asset: WorldMapAsset) {
                active.insert(asset.sha256)
                group.addTask {
                    _ = try await self.read(asset,maximumBytes:asset.file == source.graph.file ? 64_000_000 : 32_000_000)
                    return (asset.sha256, Int64(asset.byteCount))
                }
            }
            for _ in 0..<min(6,pending.count) { add(pending[next]); next += 1 }
            await progress(completed)
            await assetProgress(verified,active)
            var lastReport=Date()
            while let (hash,bytes) = try await group.next() {
                try Task.checkCancellation()
                verified.insert(hash); active.remove(hash)
                completed += bytes
                // Refill the network queue before yielding to the UI. Thousands
                // of tiny files must not each wait for a map redraw to finish.
                if next < pending.count { add(pending[next]); next += 1 }
                let now=Date()
                if active.isEmpty || now.timeIntervalSince(lastReport)>=0.08 {
                    await progress(completed)
                    await assetProgress(verified,active)
                    lastReport=Date()
                }
            }
        }
        try Task.checkCancellation()
        try recordSavedCoverage(tiles,source:source,coverageID:coverageID)
        try commitStagedManifest(tiles,source:source)
    }
    func downloadPack(_ asset:WorldMapAsset,source:WorldSource,
                      assetProgress:@escaping @Sendable (Set<String>,Set<String>) async -> Void,
                      progress:@escaping @Sendable (Int64) async -> Void) async throws -> Int64 {
        guard allowsNetwork,!base.isFileURL else { throw RidgeError.message("Connect to the map server to download this pack.") }
        let tracker=WorldPackProgress(asset:asset,sourceID:source.id,cache:cache)
        let count=try await WorldSectionPack.download(url:base.appendingPathComponent(asset.file),asset:asset,cache:cache) { received,transferred in
            let (verified,active)=await tracker.update(received:received)
            await progress(transferred);await assetProgress(verified,active)
        }
        try Task.checkCancellation()
        let partial=WorldSectionPack.partial(asset,cache:cache)
        do { try await tracker.finish(required:Self.assets(tiles:source.tiles,source:source)) }
        catch { try? FileManager.default.removeItem(at:partial);throw error }
        let final=WorldSectionPack.file(asset,cache:cache)
        if FileManager.default.fileExists(atPath:final.path) { try FileManager.default.removeItem(at:final) }
        try FileManager.default.moveItem(at:partial,to:final)
        try WorldSectionPack.install(asset,sourceID:source.id,cache:cache)
        sectionPack=try WorldSectionPack.Reader(url:final,asset:asset,sourceID:source.id)
        pins=try Self.reserve([asset.sha256],cache:cache)
        try recordSavedCoverage(source.tiles,source:source,coverageID:source.id)
        try commitStagedManifest(source.tiles,source:source)
        return count
    }
    private func commitStagedManifest(_ tiles:[WorldTile],source:WorldSource) throws {
        guard let staged=stagedManifest,staged.sourceID==source.id,
              staged.tileIDs==Set(tiles.map(\.id)) else { return }
        try Task.checkCancellation()
        try staged.data.write(to:staged.url,options:.atomic)
        try? FileManager.default.removeItem(at:staged.url.deletingPathExtension().appendingPathExtension("download-index"))
        stagedManifest=nil
    }
    private func recordSavedCoverage(_ tiles: [WorldTile], source: WorldSource, coverageID: String? = nil) throws {
        guard !base.isFileURL, !pins.isEmpty else { return }
        if let sectionPack,Self.assets(tiles:tiles,source:source).allSatisfy({ sectionPack.contains($0) }),pins.contains(sectionPack.physicalAsset.sha256) {
            let receiptAsset=WorldOfflineCoverage.Asset(hash:sectionPack.physicalAsset.sha256,bytes:sectionPack.physicalAsset.byteCount,packed:true)
            try WorldOfflineCoverage.record(tiles.map { .init(bounds:$0.mesh.bounds,assets:[receiptAsset]) },at:cache,identifier:coverageID)
            return
        }
        var present: [String:Bool] = [:]
        let receipts = tiles.compactMap { tile -> WorldOfflineCoverage.Receipt? in
            let assets = [source.overview,source.graph,tile.map,
                WorldMapAsset(file:tile.mesh.path,byteCount:tile.mesh.byteCount,sha256:tile.mesh.sha256)]
                + [tile.background].compactMap { $0 }.map { WorldMapAsset(file:$0.path,byteCount:$0.byteCount,sha256:$0.sha256) }
            guard assets.allSatisfy({ asset in
                if let value=present[asset.sha256] { return value }
                let packed=sectionPack.flatMap { $0.contains(asset) ? $0.physicalAsset : nil }
                let hash=packed?.sha256 ?? asset.sha256,bytes=packed?.byteCount ?? asset.byteCount
                let file=packed.map { WorldSectionPack.file($0,cache:cache) } ?? cache.appendingPathComponent(hash)
                let value=hash.count==64 && hash.allSatisfy(\.isHexDigit) && pins.contains(hash) && (try? ProtectedMapStorage.logicalSize(file))==bytes
                present[asset.sha256]=value;return value
            }) else { return nil }
            let receipts=assets.map { asset -> WorldOfflineCoverage.Asset in
                if let sectionPack,sectionPack.contains(asset) { return .init(hash:sectionPack.physicalAsset.sha256,bytes:sectionPack.physicalAsset.byteCount,packed:true) }
                return .init(hash:asset.sha256,bytes:asset.byteCount)
            }
            return .init(bounds:tile.mesh.bounds,assets:Array(Set(receipts)))
        }
        try WorldOfflineCoverage.record(receipts,at:cache,identifier:coverageID)
    }
    /// Fetch at most six files at a time. Geometry and image work stays serial.
    private func prefetch(_ assets: [WorldMapAsset]) async throws {
        // Offline rendering reads and verifies each asset when it uses it.
        // Prefetching cannot download here and would read/hash every file twice.
        guard allowsNetwork, !base.isFileURL else { return }
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
        if let sectionPack,sectionPack.contains(asset) {
            do { return try sectionPack.read(asset) }
            catch { self.sectionPack=nil } // A repair may have replaced the open inode.
        }
        if let data = try? ProtectedMapStorage.read(saved), checked(data) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: saved.path); return data
        }
        // Another download actor can install a pack while this landscape lives.
        if let packedSourceID,let installed=WorldSectionPack.open(sourceID:packedSourceID,cache:cache),installed.contains(asset) {
            sectionPack=installed;return try installed.read(asset)
        }
        guard allowsNetwork else { throw RidgeError.message("A downloaded map file is missing. Download this area again while connected.") }
        if WorldAppleAssets.handles(base) {
            let data=try await WorldAppleAssets.shared.readAsset(asset,base:base,cache:cache)
            sectionPack=packedSourceID.flatMap { WorldSectionPack.open(sourceID:$0,cache:cache) }
            return data
        }
        var request = URLRequest(url: base.appendingPathComponent(asset.file)); request.timeoutInterval = 20
        let authorised=try await WorldProtectedAccess.shared.authorised(request)
                    let (temporary, response) = try await URLSession.shared.download(for: authorised)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize == asset.byteCount else { throw RidgeError.message("Incomplete map download.") }
        let data = try Data(contentsOf: temporary)
        guard (response as? HTTPURLResponse)?.statusCode == 200, checked(data) else { throw RidgeError.message("A map file is incomplete. Move back to retry.") }
        if WorldProtectedAccess.protected(base) { try ProtectedMapStorage.write(data,to:saved) } else { try data.write(to:saved,options:.atomic) }
        // Explicit downloads reserve these files before transfer. Scanning the
        // whole cache every few MB cannot evict them and becomes quadratic for
        // regional packs. Only opportunistic, unpinned writes need cache pruning.
        if !pins.contains(asset.sha256) { prune(protecting:asset.sha256,writtenBytes:data.count) }
        return data
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
    func tiles(near point:GeoPoint,radius:Double)->[WorldTile] {
        guard point.isValid else { return [] }
        let dy=max(0,radius)/111195,dx=dy/max(0.01,cos(point.latitude * .pi/180))
        var result:[WorldTile]=[],seen=Set<String>()
        for y in Self.cell(point.latitude-dy)...Self.cell(point.latitude+dy) {
            for x in Self.cell(point.longitude-dx)...Self.cell(point.longitude+dx) {
                for tile in cells[y*100_000+x] ?? [] where seen.insert(tile.id).inserted {
                    let b=tile.mesh.bounds
                    let closest=GeoPoint(latitude:min(b.maxLatitude,max(b.minLatitude,point.latitude)),longitude:min(b.maxLongitude,max(b.minLongitude,point.longitude)))
                    if point.distance(to:closest)<=max(0,radius) { result.append(tile) }
                }
            }
        }
        return result
    }
}
