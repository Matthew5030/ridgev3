import Foundation
import CoreGraphics
import SceneKit

/// Storage regions remain immutable. One bounded landscape combines their tiles
/// into a common geographic frame and shares the existing fine-detail budget.
struct WorldDownloadSummary: Sendable {
    var bounds: GeoBounds
    var totalBytes: Int64
    var cachedBytes: Int64
    var remainingBytes: Int64 { max(0,totalBytes-cachedBytes) }
}

actor WorldLandscapeStore {
    struct Part: Sendable {
        var source: WorldSource
        var overview: WorldOverview
        var graph: WalkingGraph
        var files: WorldSourceStore
        var connected: Bool
    }
    private let cacheURL: URL?
    private var downloads: [(WorldSource,WorldSourceStore)] = []
    private var parts: [Part] = []
    private var owners: [String:(Int,WorldTile)] = [:]
    init(cacheURL: URL? = nil) { self.cacheURL = cacheURL }

    static func neighbours(_ anchor: WorldCatalog.Region, catalog: WorldCatalog) -> [WorldCatalog.Region] {
        let b = anchor.bounds, p = b.center
        let dx = b.maxLongitude-b.minLongitude, dy = b.maxLatitude-b.minLatitude
        return catalog.sources.filter {
            abs($0.bounds.center.longitude-p.longitude) < dx*1.1 && abs($0.bounds.center.latitude-p.latitude) < dy*1.1
        }.sorted {
            if $0.id == $1.id { return false }
            if $0.id == anchor.id { return true }; if $1.id == anchor.id { return false }
            return $0.bounds.center.distance(to:p) < $1.bounds.center.distance(to:p)
        }.prefix(9).map { $0 }
    }
    /// Read small manifests and verify cached payloads without loading terrain.
    func inspect(anchor: WorldCatalog.Region, catalog: WorldCatalog, root: URL) async throws -> WorldDownloadSummary {
        downloads = []
        var total: Int64 = 0, cached: Int64 = 0
        for region in Self.neighbours(anchor,catalog:catalog) {
            try Task.checkCancellation()
            let store = WorldSourceStore(cacheURL:cacheURL)
            let source = try await store.manifest(address:root.appendingPathComponent(region.path).absoluteString,routing:region.routing,preferCached:true)
            guard source.id == region.id, source.bounds == region.bounds else { throw RidgeError.message("The map does not match its catalogue.") }
            let assets = WorldSourceStore.assets(tiles:source.tiles,source:source)
            total += assets.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
            cached += try await store.cachedBytes(for:assets)
            downloads.append((source,store))
        }
        let bounds = GeoBounds(minLatitude:downloads.map { $0.0.bounds.minLatitude }.min()!,minLongitude:downloads.map { $0.0.bounds.minLongitude }.min()!,maxLatitude:downloads.map { $0.0.bounds.maxLatitude }.max()!,maxLongitude:downloads.map { $0.0.bounds.maxLongitude }.max()!)
        return WorldDownloadSummary(bounds:bounds,totalBytes:total,cachedBytes:cached)
    }
    func download(progress: @Sendable (Int64) async -> Void) async throws {
        guard !downloads.isEmpty else { throw RidgeError.message("Choose an area first.") }
        var needed: Int64 = 0, total: Int64 = 0
        var missingByRegion: [Int64] = []
        for (source,store) in downloads {
            let assets = WorldSourceStore.assets(tiles:source.tiles,source:source)
            let cached = try await store.cachedBytes(for:assets)
            let size = assets.reduce(Int64(0)) { $0 + Int64($1.byteCount) }
            total += size; needed += size - cached
            missingByRegion.append(size-cached)
        }
        let disk = cacheURL ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        if let free = try FileManager.default.attributesOfFileSystem(forPath:disk.path)[.systemFreeSize] as? NSNumber,
           free.int64Value < needed + 128*1024*1024 {
            throw RidgeError.message("There isn’t enough free storage for this area. Free some space and retry.")
        }
        var completed = total-needed
        await progress(completed)
        for (index,entry) in downloads.enumerated() {
            let (source,store) = entry
            try Task.checkCancellation()
            let offset = completed
            try await store.pin(source.tiles,source:source,countCachedInProgress:false,progress: { bytes in await progress(offset+bytes) })
            completed += missingByRegion[index]
            await progress(completed)
        }
    }
    func open(anchor: WorldCatalog.Region, catalog: WorldCatalog, root: URL, includeNeighbours: Bool = true) async throws -> (WorldSource, WorldOverview, WalkingGraph, WorldBackdrop, CGImage, [String:WorldPreparedTile]) {
        parts = []; owners = [:]
        for region in (includeNeighbours ? Self.neighbours(anchor,catalog:catalog) : [anchor]) {
            try Task.checkCancellation()
            let saved = downloads.first { $0.0.id == region.id }
            let store = saved?.1 ?? WorldSourceStore(cacheURL:cacheURL)
            let (source,overview,graph): (WorldSource,WorldOverview,WalkingGraph)
            if let saved { (source,overview,graph) = try await store.contents(of:saved.0) }
            else { (source,overview,graph) = try await store.open(address:root.appendingPathComponent(region.path).absoluteString,routing:region.routing) }
            guard source.id == region.id, source.bounds == region.bounds else { throw RidgeError.message("The map does not match its catalogue.") }
            parts.append(.init(source:source,overview:overview,graph:graph,files:store,connected:region.routing != nil))
        }
        let bounds = GeoBounds(minLatitude:parts.map { $0.source.bounds.minLatitude }.min()!, minLongitude:parts.map { $0.source.bounds.minLongitude }.min()!, maxLatitude:parts.map { $0.source.bounds.maxLatitude }.max()!, maxLongitude:parts.map { $0.source.bounds.maxLongitude }.max()!)
        var combined = parts[0].source
        combined.bounds = bounds
        combined.columns = 48; combined.rows = 48
        combined.revision += "-landscape-" + parts.map { $0.source.id + ($0.connected ? "-connected" : "") }.sorted().joined(separator:"-")
        combined.tiles = []; combined.places = []; combined.sources = []
        for (index,part) in parts.enumerated() {
            for original in part.source.tiles {
                var tile = original; tile.id = part.source.id + "__" + original.id
                owners[tile.id] = (index,original); combined.tiles.append(tile)
            }
            combined.places += part.source.places
            combined.sources += part.source.sources
        }
        combined.sources = Array(Set(combined.sources))
        var names = Set<String>()
        combined.places = combined.places.filter { names.insert($0.id).inserted }
        let graph = try Self.joinGraphs(parts)
        for index in parts.indices { parts[index].graph = WalkingGraph(nodes:[],edges:[]) }
        // This grid supports route elevation and camera fallback only. Visible
        // ground uses the adaptive meshes, with missing cells kept as holes.
        let size = 769
        var heights = [Float](repeating:.nan,count:size*size)
        for y in 0..<size { for x in 0..<size {
            let point = bounds.point(u:Double(x)/Double(size-1),v:Double(y)/Double(size-1))
            if let part = parts.first(where: { $0.source.bounds.contains(point) }) {
                heights[y*size+x] = part.overview.elevation(point,bounds:part.source.bounds)
            }
        } }
        let overview = WorldOverview(width:size,height:size,heights:heights)
        var backdrop = WorldBackdrop(geometries:[:],meshes:[:]), pages: [String:WorldPreparedTile] = [:]
        // Admission is global, not multiplied by the number of regions. Keep
        // adaptive surroundings nearest the focus; only over-budget distant
        // chunks use the existing elevation overview as a fallback.
        let limit: Int64 = ProcessInfo.processInfo.physicalMemory >= 6*1024*1024*1024 ? 384*1024*1024 : 160*1024*1024
        var used: Int64 = 0
        var admittedSources: [WorldSource] = []
        for part in parts {
            var admitted = part.source
            admitted.tiles = part.source.tiles.filter { tile in
                let bytes = tile.background?.residentBytes ?? 0
                guard used + bytes <= limit else { return false }; used += bytes; return true
            }
            admittedSources.append(admitted)
        }
        let work = parts, admissions = admittedSources
        try await withThrowingTaskGroup(of:(Int,WorldBackdrop,[String:WorldPreparedTile]).self) { group in
            func add(_ index: Int) {
                let part = work[index], admitted = admissions[index]
                group.addTask {
                    let ready = try await part.files.backdrop(source:admitted,overview:part.overview,frame:bounds)
                    let maps = try await part.files.mapPages(source:part.source,pixels:64)
                    return (index,ready,maps)
                }
            }
            var next = 0
            for _ in 0..<min(2,work.count) { add(next); next += 1 }
            while let (index,ready,maps) = try await group.next() {
                let part = work[index]
                for tile in part.source.tiles {
                    let id = part.source.id + "__" + tile.id
                    if let geometry = ready.geometries[tile.id] { backdrop.geometries[id] = geometry }
                    else { backdrop.geometries[id] = WorldGeometry.coarse(tile:tile,source:combined,overview:overview,maximumDivisions:16) }
                    backdrop.meshes[id] = ready.meshes[tile.id]
                    if var page = maps[tile.id] { page.request.id = id; pages[id] = page }
                }
                try Task.checkCancellation()
                if next < work.count { add(next); next += 1 }
            }
        }
        let preview = try WorldPreview.render(source:combined,backdrop:backdrop,tiles:pages)
        return (combined,overview,graph,backdrop,preview,pages)
    }
    func prepare(_ tile: WorldTile, request: WorldTileRequest, sourceBounds: GeoBounds, previous: WorldPreparedTile?) async throws -> WorldPreparedTile {
        guard let (index,original) = owners[tile.id] else { throw RidgeError.message("Missing terrain source.") }
        var prepared = try await parts[index].files.prepare(original,request:request,sourceBounds:sourceBounds,previous:previous)
        prepared.request.id = tile.id
        return prepared
    }
    func pin(_ selected: [WorldTile], source: WorldSource) async throws {
        for part in parts {
            let ids = Set(selected.filter { owners[$0.id].map { parts[$0.0].source.id == part.source.id } ?? false }.compactMap { owners[$0.id]?.1.id })
            try await part.files.pin(part.source.tiles.filter { ids.contains($0.id) },source:part.source,surroundings:part.source.tiles.map(\.map))
        }
    }
    static func joinGraphs(_ parts: [Part]) throws -> WalkingGraph {
        var nodes: [WalkingNode] = [], edges: [WalkingEdge] = [], identifiers: [String:Int] = [:], seen = Set<String>()
        let coverage = parts.map { part in (part.source, Set(part.source.tiles.map { $0.row*part.source.columns+$0.column })) }
        func covered(_ point: GeoPoint) -> Bool {
            coverage.contains { source,cells in
                guard source.bounds.contains(point) else { return false }
                let uv = source.bounds.uv(point)
                let x = min(source.columns-1,max(0,Int(uv.u*Double(source.columns))))
                let y = min(source.rows-1,max(0,Int(uv.v*Double(source.rows))))
                return cells.contains(y*source.columns+x)
            }
        }
        for part in parts {
            let namespace = part.connected ? "joined" : part.source.id.components(separatedBy:"-c")[0]
            var local: [Int:Int] = [:]
            for node in part.graph.nodes where covered(node.coordinate) {
                let key = namespace + ":" + String(node.id)
                let id: Int
                if let existing = identifiers[key] {
                    guard nodes[existing].coordinate.distance(to:node.coordinate) < 0.2 else { throw RidgeError.message("Conflicting walking-path junctions.") }; id = existing
                } else { id = nodes.count; identifiers[key] = id; var copy = node; copy.id = id; nodes.append(copy) }
                local[node.id] = id
            }
            for edge in part.graph.edges {
                guard let from = local[edge.from], let to = local[edge.to] else { continue }
                let key = "\(from):\(to):\(edge.bidirectional):\(edge.access):\(edge.kind)"
                if seen.insert(key).inserted { var copy = edge; copy.from = from; copy.to = to; edges.append(copy) }
            }
        }
        guard nodes.count <= RouteEngine.maximumGraphNodes, edges.count <= RouteEngine.maximumGraphEdges else { throw RouteError.invalidGraph }
        return WalkingGraph(nodes:nodes,edges:edges)
    }
}
