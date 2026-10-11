import Foundation
import CoreGraphics
import SceneKit

/// Storage regions remain immutable. One bounded landscape combines their tiles
/// into a common geographic frame and shares the existing fine-detail budget.
actor WorldLandscapeStore {
    struct Part: Sendable {
        var source: WorldSource
        var overview: WorldOverview
        var graph: WalkingGraph
        var files: WorldSourceStore
        var connected: Bool
        var routingLoaded: Bool = true
    }
    private let cacheURL: URL?
    private var parts: [Part] = []
    private var owners: [String:(Int,WorldTile)] = [:]
    init(cacheURL: URL? = nil) { self.cacheURL = cacheURL }

    struct Snapshot: @unchecked Sendable {
        var parts: [Part]
        var backdrop: WorldBackdrop
        var pages: [String:WorldPreparedTile]
    }
    private var residentBackdrop = WorldBackdrop(geometries:[:],meshes:[:])
    private var residentPages: [String:WorldPreparedTile] = [:]
    func snapshot() -> Snapshot { Snapshot(parts:parts,backdrop:residentBackdrop,pages:residentPages) }

    /// Build only newly exposed pieces. A candidate owns its state until the
    /// model commits it, so cancellation cannot invalidate the visible window.
    func window(center: GeoPoint, radius: Double, frame: GeoBounds, catalog: WorldCatalog, root: URL,
                previous: Snapshot?, priority: GeoPoint? = nil, offlineBounds: [GeoBounds]? = nil, progress: @escaping @Sendable (WorldSource,WorldOverview,WorldBackdrop,[String:WorldPreparedTile]) async -> Void = { _,_,_,_ in }) async throws -> (WorldSource,WorldOverview,WalkingGraph,WorldBackdrop,[String:WorldPreparedTile]) {
        let priority = priority ?? center
        let saved = offlineBounds.map { Set($0) }
        let regions = catalog.sources.filter { region in
            WorldWindow.distance(center,to:region.bounds) <= radius && (offlineBounds == nil || offlineBounds!.contains { region.bounds.contains($0.center) })
        }
            .sorted { WorldWindow.distance(priority,to:$0.bounds) < WorldWindow.distance(priority,to:$1.bounds) }
        guard !regions.isEmpty else { throw RidgeError.message("No terrain is available here.") }
        let oldParts = Dictionary(uniqueKeysWithValues:(previous?.parts ?? []).map { ($0.source.id,$0) })
        parts = []; owners = [:]
        for region in regions {
            try Task.checkCancellation()
            let needsPaths = WorldWindow.distance(center,to:region.bounds) <= WorldWindow.routingRadius
            if var old = oldParts[region.id], offlineBounds == nil || !old.files.allowsNetwork {
                if needsPaths && !old.routingLoaded { old.graph = try await old.files.walkingGraph(old.source) }
                if !needsPaths { old.graph = WalkingGraph(nodes:[],edges:[]) }
                old.routingLoaded = needsPaths
                parts.append(old); continue
            }
            let files = WorldSourceStore(cacheURL:cacheURL,allowsNetwork:offlineBounds == nil)
            let source = try await files.manifest(address:root.appendingPathComponent(region.path).absoluteString,routing:region.routing,preferCached:true,recoverCoverage:offlineBounds == nil)
            guard source.id == region.id, source.bounds == region.bounds else { throw RidgeError.message("The map does not match its catalogue.") }
            let (_,overview,graph) = try await files.contents(of:source,includeGraph:needsPaths)
            parts.append(Part(source:source,overview:overview,graph:graph,files:files,connected:region.routing != nil,routingLoaded:needsPaths))
        }
        let bounds = GeoBounds(minLatitude:parts.map { $0.source.bounds.minLatitude }.min()!,minLongitude:parts.map { $0.source.bounds.minLongitude }.min()!,maxLatitude:parts.map { $0.source.bounds.maxLatitude }.max()!,maxLongitude:parts.map { $0.source.bounds.maxLongitude }.max()!)
        var combined = parts[0].source
        combined.bounds = bounds; combined.renderBounds = frame
        combined.revision = UUID().uuidString
        combined.tiles = []; combined.places = []; combined.sources = []
        for (index,part) in parts.enumerated() {
            for original in part.source.tiles where WorldWindow.distance(center,to:original.mesh.bounds) <= radius && (saved == nil || saved!.contains(original.mesh.bounds)) {
                var tile = original; tile.id = part.source.id + "__" + original.id
                owners[tile.id] = (index,original); combined.tiles.append(tile)
            }
            combined.places += part.source.places; combined.sources += part.source.sources
        }
        guard !combined.tiles.isEmpty else { throw RidgeError.message("Detailed terrain is missing here.") }
        combined.sources = Array(Set(combined.sources))
        var names = Set<String>(); combined.places = combined.places.filter { names.insert($0.id).inserted }
        let routingParts=parts.map { part in
            var selected=part
            if let saved { selected.source.tiles=part.source.tiles.filter { saved.contains($0.mesh.bounds) } }
            return selected
        }
        let graph = try Self.joinGraphs(routingParts,center:center,radius:WorldWindow.routingRadius)
        // Route/camera fallback only; the visible surface uses the stored meshes.
        let size = 513
        var heights = [Float](repeating:0,count:size*size)
        for y in 0..<size {
            try Task.checkCancellation()
            for x in 0..<size {
                let point = bounds.point(u:Double(x)/Double(size-1),v:Double(y)/Double(size-1))
                if let part = parts.first(where: { $0.source.bounds.contains(point) }) {
                    heights[y*size+x] = part.overview.elevation(point,bounds:part.source.bounds)
                }
            }
        }
        let overview = WorldOverview(width:size,height:size,heights:heights)
        // This allowance includes retained backgrounds. New terrain cannot
        // multiply it by the number of storage regions in the window.
        let limit = WorldWindow.backgroundBudget
        var used: Int64 = 0, adaptive = Set<String>()
        let ranked = combined.tiles.sorted {
            $0.mesh.bounds.center.distance(to:center) - (previous?.backdrop.meshes[$0.id] == nil ? 0 : 1000)
            < $1.mesh.bounds.center.distance(to:center) - (previous?.backdrop.meshes[$1.id] == nil ? 0 : 1000)
        }
        for tile in ranked {
            if let mesh = tile.background, used + mesh.residentBytes <= limit {
                used += mesh.residentBytes; adaptive.insert(tile.id)
            }
        }
        var background = WorldBackdrop(geometries:[:],meshes:[:]), pages: [String:WorldPreparedTile] = [:]
        let work = parts, selected = combined.tiles, desiredAdaptive = adaptive, metadata = combined
        residentBackdrop = previous?.backdrop ?? WorldBackdrop(geometries:[:],meshes:[:])
        residentPages = previous?.pages ?? [:]
        // Jobs are small geographic additions, ranked toward travel. A completed
        // job is published immediately; another region's slow file cannot hold it.
        struct Job: Sendable { var part: Part; var tiles: [WorldTile]; var distance: Double }
        var jobs: [Job] = []
        for part in work {
            let tiles = selected.filter { $0.id.hasPrefix(part.source.id + "__") }.sorted {
                $0.mesh.bounds.center.distance(to:priority) < $1.mesh.bounds.center.distance(to:priority)
            }
            for offset in stride(from:0,to:tiles.count,by:32) {
                let batch=Array(tiles[offset..<min(offset+32,tiles.count)])
                jobs.append(Job(part:part,tiles:batch,distance:batch[0].mesh.bounds.center.distance(to:priority)))
            }
        }
        jobs.sort { $0.distance < $1.distance }
        try await withThrowingTaskGroup(of:(WorldBackdrop,[String:WorldPreparedTile],Bool).self) { group in
            func add(_ index: Int) {
                let job=jobs[index],part=job.part,selectedTiles=job.tiles
                group.addTask(priority:.utility) {
                    var result = WorldBackdrop(geometries:[:],meshes:[:]), maps: [String:WorldPreparedTile] = [:]
                    let originals = Dictionary(uniqueKeysWithValues:part.source.tiles.map { ($0.id,$0) })
                    var fetch = part.source
                    fetch.tiles = selectedTiles.compactMap { tile in
                        let originalID = String(tile.id.dropFirst(part.source.id.count+2))
                        guard previous?.pages[tile.id] == nil else { return nil }
                        return originals[originalID]
                    }
                    let newPages = try await part.files.mapPages(source:fetch,pixels:32)
                    var meshSource = part.source
                    meshSource.tiles = selectedTiles.compactMap { tile in
                        guard desiredAdaptive.contains(tile.id), previous?.backdrop.meshes[tile.id] == nil else { return nil }
                        return originals[String(tile.id.dropFirst(part.source.id.count+2))]
                    }
                    let newBackground = try await part.files.backdrop(source:meshSource,overview:part.overview,frame:frame)
                    var changed = false
                    for tile in selectedTiles {
                        try Task.checkCancellation()
                        let originalID = String(tile.id.dropFirst(part.source.id.count+2))
                        guard let original = originals[originalID] else { continue }
                        if let old = previous?.pages[tile.id] { maps[tile.id] = old }
                        else if var page = newPages[originalID] { page.request.id = tile.id; maps[tile.id] = page; changed=true }
                        let wantsAdaptive = desiredAdaptive.contains(tile.id)
                        if let old = previous?.backdrop.geometries[tile.id],
                           (previous?.backdrop.meshes[tile.id] != nil) == wantsAdaptive {
                            result.geometries[tile.id] = old; result.meshes[tile.id] = previous?.backdrop.meshes[tile.id]
                        } else if wantsAdaptive {
                            result.geometries[tile.id] = newBackground.geometries[originalID]; result.meshes[tile.id] = newBackground.meshes[originalID]; changed=true
                        } else {
                            result.geometries[tile.id] = WorldGeometry.coarse(tile:original,source:part.source,overview:part.overview,maximumDivisions:8,frame:frame); changed=true
                        }
                    }
                    return (result,maps,changed)
                }
            }
            var next = 0
            for _ in 0..<min(2,jobs.count) { add(next); next += 1 }
            while let (ready,maps,changed) = try await group.next() {
                background.geometries.merge(ready.geometries) { _,new in new }
                background.meshes.merge(ready.meshes) { _,new in new }
                pages.merge(maps) { _,new in new }
                // Snapshotting during a pan/cancellation retains already visible
                // additions, as well as the completed previous window.
                residentBackdrop.geometries.merge(ready.geometries) { _,new in new }
                for id in ready.geometries.keys { residentBackdrop.meshes[id]=ready.meshes[id] }
                residentPages.merge(maps) { _,new in new }
                try Task.checkCancellation()
                if changed { await progress(metadata,overview,ready,maps) }
                if next < jobs.count { add(next); next += 1 }
            }
        }
        residentBackdrop = background; residentPages = pages
        return (combined,overview,graph,background,pages)
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
    static func joinGraphs(_ parts: [Part], center: GeoPoint? = nil, radius: Double = .infinity) throws -> WalkingGraph {
        var nodes: [WalkingNode] = [], edges: [WalkingEdge] = [], identifiers: [String:Int] = [:], seen = Set<String>()
        let coverage = parts.map { part in (part.source, Set(part.source.tiles.map { $0.row*part.source.columns+$0.column })) }
        func covered(_ point: GeoPoint) -> Bool {
            if let center, point.distance(to:center) > radius { return false }
            return coverage.contains { source,cells in
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

/// Camera-centred coverage; storage boundaries never select the visible window.
enum WorldWindow {
    static let routingRadius = 12000.0
    static let movementThreshold = 750.0
    static func leadingPoint(from previous: GeoPoint?, to current: GeoPoint) -> GeoPoint {
        guard let previous else { return current }
        let distance=previous.distance(to:current)
        guard distance>100 else { return current }
        let fraction=min(1500,distance)/distance
        return GeoPoint(latitude:current.latitude+(current.latitude-previous.latitude)*fraction,
                        longitude:current.longitude+(current.longitude-previous.longitude)*fraction)
    }
    // Publish nearby additions regularly instead of making the first visible
    // window wait for every tile out to the full horizon.
    static let entryRadius = 4500.0
    static func nextRadius(desired: Double, loaded: Double) -> Double {
        loaded == 0 ? min(desired,entryRadius) : min(desired,loaded+3000)
    }
    static let backgroundBudget: Int64 = ProcessInfo.processInfo.physicalMemory >= 6*1024*1024*1024 ? 192*1024*1024 : 96*1024*1024
    static func radius(distance: Double, pitch: Float) -> Double {
        min(24000,max(16000,16000 + distance*0.6 + (pitch < 0.6 ? 2000 : 0)))
    }
    static func distance(_ point: GeoPoint, to bounds: GeoBounds) -> Double {
        point.distance(to:GeoPoint(latitude:min(bounds.maxLatitude,max(bounds.minLatitude,point.latitude)),longitude:min(bounds.maxLongitude,max(bounds.minLongitude,point.longitude))))
    }
    static func needsUpdate(center: GeoPoint, radius: Double, loadedCenter: GeoPoint?, loadedRadius: Double) -> Bool {
        guard let loadedCenter else { return true }
        return center.distance(to:loadedCenter) >= movementThreshold || radius > loadedRadius+1000
    }
}

/// A transfer plan holds metadata only. No terrain decoding or image rendering
/// takes place before the user has accepted the download size.
struct WorldDownloadPlan: Sendable {
    struct Part: Sendable {
        let source: WorldSource
        let files: WorldSourceStore
        let missingBytes: Int64
    }
    let center: GeoPoint
    let radius: Double
    let selection: GeoBounds?
    let parts: [Part]
    let bytes: Int64
    let bounds: [GeoBounds]
    let edges: [WorldOfflineCoverage.Edge]
    let readyBounds: Set<GeoBounds>
}

actor WorldDownloadStore {
    private let cache: URL
    init(cacheURL: URL? = nil) { cache=WorldOfflineCoverage.cache(cacheURL) }
    func plan(center: GeoPoint, radius: Double, catalog: WorldCatalog, root: URL, selection: GeoBounds? = nil) async throws -> WorldDownloadPlan {
        if let selection {
            guard selection.isValid, selection.widthMeters <= 24_000, selection.depthMeters <= 24_000 else {
                throw RidgeError.message("Draw an area up to 24 km across. Zoom in or move the corners closer together.")
            }
        }
        func includes(_ bounds: GeoBounds) -> Bool {
            if let selection {
                return bounds.minLatitude < selection.maxLatitude && bounds.maxLatitude > selection.minLatitude
                    && bounds.minLongitude < selection.maxLongitude && bounds.maxLongitude > selection.minLongitude
            }
            return WorldWindow.distance(center,to:bounds)<=radius
        }
        guard (400...12000).contains(radius),catalog.region(at:center) != nil else { throw RidgeError.message("Detailed terrain is not available here.") }
        var parts: [WorldDownloadPlan.Part] = [], bounds: [GeoBounds] = [], seen=Set<String>(), ready=Set<GeoBounds>()
        for region in catalog.sources.filter({ includes($0.bounds) }) {
            try Task.checkCancellation()
            let files=WorldSourceStore(cacheURL:cache)
            var source=try await files.manifest(address:root.appendingPathComponent(region.path).absoluteString,routing:region.routing,preferCached:true)
            guard source.id==region.id, source.bounds==region.bounds else { throw RidgeError.message("The map does not match its catalogue.") }
            source.tiles=source.tiles.filter { includes($0.mesh.bounds) }
            guard !source.tiles.isEmpty else { continue }
            let assets=WorldSourceStore.assets(tiles:source.tiles,source:source)
            let cached=try await files.cachedAssetHashes(for:assets)
            let missing=assets.filter { seen.insert($0.sha256).inserted && !cached.contains($0.sha256) }.reduce(Int64(0)) { $0+Int64($1.byteCount) }
            for tile in source.tiles {
                let required=Set([source.overview.sha256,source.graph.sha256,tile.map.sha256,tile.mesh.sha256]
                    + [tile.background?.sha256].compactMap { $0 })
                if required.isSubset(of:cached) { ready.insert(tile.mesh.bounds) }
            }
            parts.append(.init(source:source,files:files,missingBytes:missing))
            bounds += source.tiles.map { $0.mesh.bounds }
        }
        guard bounds.contains(where:{$0.contains(center)}) else { throw RidgeError.message("Detailed terrain is missing at this location. Choose a nearby area.") }
        return WorldDownloadPlan(center:center,radius:radius,selection:selection,parts:parts,bytes:parts.reduce(0) { $0+$1.missingBytes },bounds:bounds,edges:WorldOfflineCoverage.outline(bounds),readyBounds:ready)
    }
    func download(_ plan: WorldDownloadPlan, tilesProgress: @escaping @Sendable (Set<GeoBounds>,Set<GeoBounds>) async -> Void = { _,_ in }, progress: @escaping @Sendable (Int64) async -> Void) async throws {
        var completed: Int64=0
        var ready=plan.readyBounds
        await tilesProgress(ready,[])
        for part in plan.parts {
            try Task.checkCancellation()
            let base=completed, previous=ready.subtracting(part.source.tiles.map { $0.mesh.bounds })
            try await part.files.pin(part.source.tiles,source:part.source,countCachedInProgress:false,assetProgress: { verified,active in
                var done=previous, loading=Set<GeoBounds>()
                for tile in part.source.tiles {
                    let own=Set([tile.map.sha256,tile.mesh.sha256] + [tile.background?.sha256].compactMap { $0 })
                    let required=own.union([part.source.overview.sha256,part.source.graph.sha256])
                    if required.isSubset(of:verified) { done.insert(tile.mesh.bounds) }
                    else if !own.isDisjoint(with:active) || own.isSubset(of:verified) { loading.insert(tile.mesh.bounds) }
                }
                await tilesProgress(done,loading)
            }) { value in
                await progress(min(plan.bytes,base+value))
            }
            ready.formUnion(part.source.tiles.map { $0.mesh.bounds })
            completed += part.missingBytes
            await progress(min(plan.bytes,completed))
        }
        try Task.checkCancellation()
    }
}
