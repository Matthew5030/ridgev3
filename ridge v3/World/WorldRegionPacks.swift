import Foundation
import CoreGraphics

/// Named groups of the existing UK grid. Each published source belongs to one
/// group; regional downloads use exactly the same assets as custom-area saves.
struct WorldRegionPack: Identifiable, Sendable {
    struct Cell: Decodable, Sendable { let id: String; let bounds: GeoBounds }
    /// Geographic display footprint, separate from immutable download files.
    /// Rings use longitude/latitude and even-odd filling (including water holes).
    struct MapShape: Decodable, Sendable {
        let rings:[[[Double]]]
        let bounds:GeoBounds
        private enum CodingKeys:String,CodingKey { case rings }
        init(from decoder:Decoder) throws {
            rings=try decoder.container(keyedBy:CodingKeys.self).decode([[[Double]]].self,forKey:.rings)
            guard !rings.isEmpty,rings.allSatisfy({ $0.count>=4 && $0.allSatisfy { $0.count==2 && $0.allSatisfy(\.isFinite) } }) else {
                throw RidgeError.message("Invalid map outline.")
            }
            let points=rings.flatMap { $0 }
            bounds=GeoBounds(minLatitude:points.map { $0[1] }.min()!,minLongitude:points.map { $0[0] }.min()!,
                             maxLatitude:points.map { $0[1] }.max()!,maxLongitude:points.map { $0[0] }.max()!)
        }
        func contains(_ point:GeoPoint)->Bool {
            guard bounds.contains(point) else { return false }
            var inside=false
            for ring in rings {
                var previous=ring.last!
                for current in ring {
                    if (current[1]>point.latitude) != (previous[1]>point.latitude) {
                        let crossing=(previous[0]-current[0])*(point.latitude-current[1])/(previous[1]-current[1])+current[0]
                        if point.longitude<crossing { inside.toggle() }
                    }
                    previous=current
                }
            }
            return inside
        }
        /// Clip each coast ring to the rectangle and measure its land area.
        /// Testing the centre alone misses islands and narrow coastal strips.
        func overlapsLand(_ rect:GeoBounds)->Bool {
            guard bounds.maxLongitude>rect.minLongitude,bounds.minLongitude<rect.maxLongitude,
                  bounds.maxLatitude>rect.minLatitude,bounds.minLatitude<rect.maxLatitude else { return false }
            var area=0.0
            for (index,ring) in rings.enumerated() {
                var polygon=ring
                for (axis,edge,greater) in [(0,rect.minLongitude,true),(0,rect.maxLongitude,false),
                                             (1,rect.minLatitude,true),(1,rect.maxLatitude,false)] {
                    guard let last=polygon.last else { break }
                    var clipped:[[Double]]=[],previous=last
                    for current in polygon {
                        let a=greater ? previous[axis]>=edge : previous[axis]<=edge
                        let b=greater ? current[axis]>=edge : current[axis]<=edge
                        if a != b {
                            let t=(edge-previous[axis])/(current[axis]-previous[axis])
                            clipped.append([previous[0]+t*(current[0]-previous[0]),previous[1]+t*(current[1]-previous[1])])
                        }
                        if b { clipped.append(current) }
                        previous=current
                    }
                    polygon=clipped
                }
                guard let origin=polygon.first else { continue }
                var signed=0.0,previous=polygon.last!
                for point in polygon {
                    signed+=(previous[0]-origin[0])*(point[1]-origin[1])-(point[0]-origin[0])*(previous[1]-origin[1])
                    previous=point
                }
                area+=(index==0 ? 1 : -1)*abs(signed)/2
            }
            return area>1e-12
        }
    }
    let id: String
    let name: String
    let subtitle: String
    let landmark: String
    let cells: [Cell]
    var mapShapes:[MapShape]? = nil
    var labelBounds:GeoBounds? = nil
    var mapLabel: String? = nil
    var parkID: String? = nil
    var parkName: String? = nil
    var artwork: String? = nil
    var artworkID:String {
        if let artwork { return artwork }
        switch id {
        case "skye-wester-ross": return "north-scotland"
        case "lochaber", "cairngorms", "sutherland": return "west-highlands"
        case "galloway", "scottish-borders", "lomond-trossachs": return "lowlands"
        case "fermanagh-sperrins", "antrim-down": return "northern-ireland"
        case "south-lakes", "north-lakes", "yorkshire-dales", "north-pennines": return "lakes-dales"
        case "north-york-moors", "northumberland": return "north-east"
        case "peak-district", "shropshire-marches": return "midlands"
        case "eryri-anglesey", "clwyd-berwyn", "bannau-mid-wales": return "wales"
        case "broads-east-coast": return "east-anglia"
        case "surrey-south-downs", "kent-east-sussex": return "south-east"
        case "wessex": return "south-west"
        default: return "countryside"
        }
    }
    func contains(_ point:GeoPoint)->Bool {
        if let mapShapes { return mapShapes.contains { $0.contains(point) } }
        return cells.contains { $0.bounds.contains(point) }
    }
    var bounds: GeoBounds {
        if let mapShapes,!mapShapes.isEmpty {
            return GeoBounds(minLatitude:mapShapes.map { $0.bounds.minLatitude }.min()!,minLongitude:mapShapes.map { $0.bounds.minLongitude }.min()!,
                             maxLatitude:mapShapes.map { $0.bounds.maxLatitude }.max()!,maxLongitude:mapShapes.map { $0.bounds.maxLongitude }.max()!)
        }
        return GeoBounds(minLatitude:cells.map { $0.bounds.minLatitude }.min()!,minLongitude:cells.map { $0.bounds.minLongitude }.min()!,
                  maxLatitude:cells.map { $0.bounds.maxLatitude }.max()!,maxLongitude:cells.map { $0.bounds.maxLongitude }.max()!)
    }
    func sources(in catalog: WorldCatalog) -> [WorldCatalog.Region] {
        let ids=Set(cells.map(\.id))
        // Published zones follow source sections exactly. Older/custom callers
        // may still supply broad cells, so retain their geographic matching.
        let sourceCells=cells.allSatisfy { $0.id.hasPrefix("world-") }
        return catalog.sources.filter { source in
            sourceCells ? ids.contains(source.id) : cells.contains { $0.bounds.contains(source.bounds.center) }
        }.sorted { $0.id < $1.id }
    }
    func coveredCells(in catalog: WorldCatalog) -> Set<String> {
        let sources=sources(in:catalog)
        return Set(cells.filter { cell in sources.contains { cell.bounds.contains($0.bounds.center) } }.map(\.id))
    }
    enum TerrainAvailability { case unknown, unavailable, incomplete, complete }
    static let incompleteMessage="Detailed terrain has gaps in this region. Downloads are unavailable until coverage is complete."
    func terrainAvailability(in catalog:WorldCatalog?)->TerrainAvailability {
        guard let catalog else { return .unknown }
        let sources=sources(in:catalog)
        guard !sources.isEmpty else { return .unavailable }
        func hasLand(_ bounds:GeoBounds)->Bool {
            mapShapes.map { $0.contains { $0.overlapsLand(bounds) } } ?? true
        }
        let ids=Set(sources.map(\.id))
        for cell in cells where !ids.contains(cell.id) && hasLand(cell.bounds) {
            if !sources.contains(where:{ cell.bounds.contains($0.bounds.center) }) { return .incomplete }
        }
        for source in sources {
            if let gaps=source.missingTerrain {
                if gaps.contains(where:hasLand) { return .incomplete }
            } else if source.tileCount<256 {
                // Fail closed for older sparse catalogues; their bounding box
                // cannot prove where the missing terrain lies.
                return .incomplete
            }
        }
        return .complete
    }
    struct Library { let areas:[WorldRegionPack];let parks:[WorldRegionPack] }
    static func load(url:URL? = nil) throws -> [WorldRegionPack] { try loadLibrary(url:url).areas }
    static func loadLibrary(url: URL? = nil) throws -> Library {
        struct Zone: Decodable {
            let id:String;let name:String;let subtitle:String;let mapLabel:String
            let parkID:String?;let parkName:String?;let artwork:String?;let cells:[Cell]
            let mapShapes:[MapShape]?;let labelBounds:GeoBounds?
        }
        struct Index: Decodable { let schemaVersion:Int;let regions:[Zone];let parks:[Zone] }
        guard let url = url ?? Bundle.main.url(forResource:"uk-download-zones",withExtension:"json")
            ?? Bundle.main.url(forResource:"uk-download-zones",withExtension:"json",subdirectory:"Resources") else {
            throw RidgeError.message("The region list is missing from this build.")
        }
        let index=try JSONDecoder().decode(Index.self,from:Data(contentsOf:url))
        let cells=index.regions.flatMap(\.cells)
        guard index.schemaVersion==3,!index.regions.isEmpty,
              Set(index.regions.map(\.id)).count==index.regions.count,
              Set(cells.map(\.id)).count==cells.count else { throw RidgeError.message("Invalid download zones.") }
        func convert(_ zone:Zone) throws -> WorldRegionPack {
            guard !zone.cells.isEmpty,Set(zone.cells.map(\.id)).count==zone.cells.count,zone.cells.allSatisfy({ $0.bounds.isValid }) else {
                throw RidgeError.message("A region has an invalid map boundary.")
            }
            return Self(id:zone.id,name:zone.name,subtitle:zone.subtitle,landmark:zone.parkName ?? zone.name,
                        cells:zone.cells,mapShapes:zone.mapShapes,labelBounds:zone.labelBounds,mapLabel:zone.mapLabel,parkID:zone.parkID,parkName:zone.parkName,artwork:zone.artwork)
        }
        return try Library(areas:index.regions.map(convert),parks:index.parks.map(convert))
    }
}

/// Keep only small source references in the plan, rather than thousands of
/// decoded tiles and a cache actor for every part of a country-sized download.
struct WorldRegionDownloadPlan: Sendable {
    struct Part: Sendable { let region:WorldCatalog.Region; let missingBytes:Int64 }
    let pack:WorldRegionPack
    let root:URL
    let parts:[Part]
    let bytes:Int64
    let totalBytes:Int64
    let tileCount:Int
    var isEstimate=false

    /// Catalogue-only offer: no section requests, disk scans or asset hashing.
    static func estimate(pack:WorldRegionPack,catalog:WorldCatalog,root:URL)->Self? {
        guard pack.terrainAvailability(in:catalog) == .complete else { return nil }
        let regions=pack.sources(in:catalog)
        guard !regions.isEmpty,regions.allSatisfy({ ($0.downloadBytes ?? 0)>0 }) else { return nil }
        let parts=regions.map { region in
            // Published folder sizes may predate the connected-path sidecar.
            // Include it conservatively; duplicate/cached bytes are skipped later.
            Part(region:region,missingBytes:region.downloadBytes!+Int64(region.routing?.byteCount ?? 0))
        }
        let total=parts.reduce(Int64(0)) { $0+$1.missingBytes }
        return Self(pack:pack,root:root,parts:parts,bytes:total,totalBytes:total,
                    tileCount:regions.reduce(0) { $0+$1.tileCount },isEstimate:true)
    }
}

/// Animate only the current section (at most 256 tiles). Previous sections
/// become merged static fills, preserving holes without retaining every tile.
struct WorldRegionTileProgress: Sendable {
    var tiles: [GeoBounds] = []
    var completed = Set<GeoBounds>()
    var active = Set<GeoBounds>()
    var savedFills: [GeoBounds] = []
    var savedTileCount = 0
}

private actor WorldRegionTileReporter {
    private let source: WorldSource
    private var state: WorldRegionTileProgress
    private var lastSent = Date.distantPast
    private let report: @Sendable (WorldRegionTileProgress) async -> Void
    init(source: WorldSource, savedFills: [GeoBounds], savedTileCount: Int,
         report: @escaping @Sendable (WorldRegionTileProgress) async -> Void) {
        self.source=source; self.report=report
        state=WorldRegionTileProgress(tiles:source.tiles.map { $0.mesh.bounds },
                                      savedFills:savedFills,savedTileCount:savedTileCount)
    }
    func update(verified: Set<String>, active: Set<String>) async {
        guard !Task.isCancelled else { return }
        var done=Set<GeoBounds>(),loading=Set<GeoBounds>()
        for tile in source.tiles {
            let own=Set([tile.map.sha256,tile.mesh.sha256]+[tile.background?.sha256].compactMap { $0 })
            let required=own.union([source.overview.sha256,source.graph.sha256])
            if required.isSubset(of:verified) { done.insert(tile.mesh.bounds) }
            else if !own.isDisjoint(with:active) || own.isSubset(of:verified) { loading.insert(tile.mesh.bounds) }
        }
        // Coalesce very fast cached/local transfers; always deliver the first
        // and final states, including a fully reused section with no transfers.
        let now=Date(),finished=done.count==state.tiles.count
        guard finished || now.timeIntervalSince(lastSent)>=0.08 else { return }
        guard lastSent == .distantPast || done != state.completed || loading != state.active else { return }
        state.completed=done;state.active=loading;lastSent=now
        await report(state)
    }
}

actor WorldRegionDownloadStore {
    private let cache:URL
    init(cacheURL:URL? = nil) { cache=WorldOfflineCoverage.cache(cacheURL) }
    private func open(_ region:WorldCatalog.Region,root:URL) async throws -> (WorldSourceStore,WorldSource) {
        let files=WorldSourceStore(cacheURL:cache)
        let source=try await files.manifest(address:root.appendingPathComponent(region.path).absoluteString,routing:region.routing,preferCached:true,recoverCoverage:false)
        guard source.id==region.id,source.bounds==region.bounds,source.tiles.count==region.tileCount else {
            throw RidgeError.message("The map does not match its catalogue.")
        }
        return (files,source)
    }
    func plan(pack:WorldRegionPack,catalog:WorldCatalog,root:URL,progress:@Sendable (Int,Int) async -> Void = { _,_ in }) async throws -> WorldRegionDownloadPlan {
        guard pack.terrainAvailability(in:catalog) == .complete else { throw RidgeError.message(WorldRegionPack.incompleteMessage) }
        let regions=pack.sources(in:catalog)
        guard !regions.isEmpty else { throw RidgeError.message("Maps for this region are not available from this source yet.") }
        var parts:[WorldRegionDownloadPlan.Part]=[],seen=Set<String>(),total:Int64=0,tiles=0
        await progress(0,regions.count)
        for region in regions {
            try Task.checkCancellation()
            let (files,source)=try await open(region,root:root)
            let assets=WorldSourceStore.assets(tiles:source.tiles,source:source)
            let cached=try await files.cachedAssetHashes(for:assets)
            var missing:Int64=0
            for asset in assets where seen.insert(asset.sha256).inserted {
                total += Int64(asset.byteCount)
                if !cached.contains(asset.sha256) { missing += Int64(asset.byteCount) }
            }
            parts.append(.init(region:region,missingBytes:missing));tiles+=source.tiles.count
            await progress(parts.count,regions.count)
        }
        return .init(pack:pack,root:root,parts:parts,bytes:parts.reduce(0) { $0+$1.missingBytes },totalBytes:total,tileCount:tiles)
    }
    func download(_ plan:WorldRegionDownloadPlan,tileProgress:@escaping @Sendable (WorldRegionTileProgress) async -> Void = { _ in },progress:@escaping @Sendable (Int64,Int) async -> Void) async throws {
        let catalog=WorldCatalog(schemaVersion:1,revision:"download-plan",sources:plan.parts.map(\.region))
        guard plan.pack.terrainAvailability(in:catalog) == .complete else { throw RidgeError.message(WorldRegionPack.incompleteMessage) }
        // Reserve headroom for temporary files. A large offline save is a disk
        // operation; it must never allocate or prepare the whole region in RAM.
        if !plan.isEstimate,plan.bytes>0,let capacity=try? cache.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           capacity < plan.bytes+256*1024*1024 { throw RidgeError.message("There isn’t enough free space for this pack. Free some storage and try again.") }
        var completed:Int64=0,checkedConnection=false
        var savedFills:[GeoBounds]=[],savedTileCount=0
        for (index,part) in plan.parts.enumerated() {
            try Task.checkCancellation()
            let (files,source)=try await open(part.region,root:plan.root)
            let missing:Int64
            if plan.isEstimate {
                let assets=WorldSourceStore.assets(tiles:source.tiles,source:source)
                let cached=try await files.cachedAssetHashes(for:assets)
                missing=assets.filter { !cached.contains($0.sha256) }.reduce(0) { $0+Int64($1.byteCount) }
                if missing>0,let capacity=try? cache.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   capacity<missing+256*1024*1024 { throw RidgeError.message("There isn’t enough free space. Completed sections are kept; free some storage to continue.") }
            } else { missing=part.missingBytes }
            if missing>0 && !checkedConnection { try await files.checkDownloadConnection();checkedConnection=true }
            let base=completed
            let reporter=WorldRegionTileReporter(source:source,savedFills:savedFills,savedTileCount:savedTileCount,report:tileProgress)
            try await files.pin(source.tiles,source:source,countCachedInProgress:false,coverageID:source.id,assetProgress: { verified,active in
                await reporter.update(verified:verified,active:active)
            },progress: { bytes in
                await progress(plan.isEstimate ? base+bytes : min(plan.bytes,base+bytes),index)
            })
            savedFills=WorldOfflineCoverage.displayBounds(savedFills+source.tiles.map { $0.mesh.bounds })
            savedTileCount+=source.tiles.count
            completed+=missing
            await progress(plan.isEstimate ? completed : min(plan.bytes,completed),index+1)
        }
        try Task.checkCancellation()
    }
}

/// Cached map geometry. Selection uses actual grid cells, never the enclosing
/// rectangle (which can include sea or another region).
struct WorldRegionMapOverlay: Identifiable, Sendable {
    let pack:WorldRegionPack
    let fills:[GeoBounds]
    let edges:[WorldOfflineCoverage.Edge]
    let available:[GeoBounds]
    let terrainAvailability:WorldRegionPack.TerrainAvailability
    var isBlocked:Bool { terrainAvailability == .unavailable || terrainAvailability == .incomplete }
    private(set) var labelPoint:GeoPoint
    private(set) var labelFontScale:Double=0
    enum DownloadState { case unavailable,notSaved,partial,saved }
    var savedTileCount=0
    var totalTileCount=0
    var savedPoint:GeoPoint?
    var downloadState:DownloadState {
        if isBlocked { return .unavailable }
        if totalTileCount==0 { return .unavailable }
        if savedTileCount==0 { return .notSaved }
        return savedTileCount>=totalTileCount ? .saved : .partial
    }
    var statusText:String {
        if terrainAvailability == .unknown { return "Coverage not checked" }
        if terrainAvailability == .incomplete { return "Incomplete terrain · unavailable" }
        switch downloadState {
        case .unavailable: return "Unavailable from this source"
        case .notSaved: return "Not downloaded"
        case .partial: return "Partly downloaded"
        case .saved: return "Downloaded"
        }
    }
    var id:String { pack.id }
    /// Short atlas lettering; the inspector retains the full pack name.
    var label:String {
        if let label=pack.mapLabel { return label }
        switch id {
        case "outer-hebrides": return "HEBRIDES"
        case "skye-wester-ross": return "SKYE &\nWESTER ROSS"
        case "caithness-moray": return "CAITHNESS\n& MORAY"
        case "mull-small-isles": return "MULL &\nISLES"
        case "argyll-islay": return "ARGYLL"
        case "lomond-trossachs": return "LOMOND"
        case "fife-lothians": return "FIFE &\nLOTHIANS"
        case "scottish-borders": return "BORDERS"
        case "fermanagh-sperrins": return "SPERRINS"
        case "antrim-down": return "ANTRIM\n& DOWN"
        case "tyne-wear-durham": return "DURHAM"
        case "northumberland": return "NORTHUMBERLAND"
        case "yorkshire-dales": return "DALES"
        case "north-pennines": return "PENNINES"
        case "north-york-moors": return "MOORS"
        case "yorkshire-wolds": return "WOLDS"
        case "peak-district": return "PEAKS"
        case "central-midlands": return "MIDLANDS"
        case "eryri-anglesey": return "ERYRI"
        case "clwyd-berwyn": return "CLWYD &\nBERWYN"
        case "pembrokeshire-ceredigion": return "WEST\nWALES"
        case "bannau-mid-wales": return "MID\nWALES"
        case "fens-cambridgeshire": return "FENS"
        case "suffolk-west-norfolk": return "SUFFOLK"
        case "broads-east-coast": return "BROADS"
        case "severn-cotswolds": return "COTSWOLDS"
        case "shropshire-marches": return "MARCHES"
        case "surrey-south-downs": return "SOUTH\nDOWNS"
        case "london-weald": return "LONDON &\nWEALD"
        case "kent-east-sussex": return "KENT"
        case "somerset-west-dorset": return "SOMERSET"
        case "cornwall-scilly": return "CORNWALL"
        default: return pack.name.uppercased().replacingOccurrences(of:" ",with:"\n")
        }
    }
    init(pack:WorldRegionPack,catalog:WorldCatalog?) {
        self.pack=pack
        terrainAvailability=pack.terrainAvailability(in:catalog)
        let cells=pack.cells.map(\.bounds)
        fills=WorldOfflineCoverage.displayBounds(cells)
        edges=WorldOfflineCoverage.outline(cells)
        let sources=catalog.map { pack.sources(in:$0) } ?? []
        available=WorldOfflineCoverage.displayBounds(sources.map(\.bounds))
        totalTileCount=sources.reduce(0) { $0+$1.tileCount }
        labelPoint=cells.min { $0.center.distance(to:pack.bounds.center)<$1.center.distance(to:pack.bounds.center) }!.center
        if let labelBounds=pack.labelBounds { labelPoint=labelBounds.center }
        if pack.mapShapes?.isEmpty != true {
            let bounds=pack.bounds
            func y(_ latitude:Double)->Double {
                let radians=min(85,max(-85,latitude)) * .pi/180
                return (1-log(tan(radians)+1/cos(radians)) / .pi)/2
            }
            // Visibility follows the area on screen, not whether a large text
            // rectangle can be squeezed into an irregular bit of coastline.
            let width=(bounds.maxLongitude-bounds.minLongitude)/360
            let height=abs(y(bounds.maxLatitude)-y(bounds.minLatitude))
            labelFontScale=max(width,height)/6
        }
    }
    func labelAppearance(at scale:Double)->(size:Double,opacity:Double) {
        guard labelFontScale>0 else { return (0,0) }
        let footprint=max(0,scale*labelFontScale)
        let size=min(24,max(15,footprint))
        let t=min(1,max(0,(footprint-5)/4))
        return (size,t*t*(3-2*t))
    }
    /// Receipt bounds are already verified against local pinned files. Index
    /// source rectangles in degree buckets so refreshing a large saved library
    /// doesn't scan every tile against every region on the main actor.
    static func make(packs:[WorldRegionPack],catalog:WorldCatalog?,offline:[GeoBounds])->[Self] {
        var result=packs.map { Self(pack:$0,catalog:catalog) }
        guard let catalog else { return result }
        struct Bucket:Hashable { let x:Int;let y:Int }
        struct Owner { let source:WorldCatalog.Region;let pack:Int }
        var buckets:[Bucket:[Owner]]=[:]
        for (index,pack) in packs.enumerated() {
            for source in pack.sources(in:catalog) {
                let b=source.bounds
                for x in Int(floor(b.minLongitude))...Int(floor(b.maxLongitude)) {
                    for y in Int(floor(b.minLatitude))...Int(floor(b.maxLatitude)) {
                        buckets[Bucket(x:x,y:y),default:[]].append(Owner(source:source,pack:index))
                    }
                }
            }
        }
        var counts:[String:Int]=[:]
        for bounds in Set(offline) {
            let point=bounds.center,key=Bucket(x:Int(floor(point.longitude)),y:Int(floor(point.latitude)))
            let owners=buckets[key]?.filter { $0.source.bounds.contains(point) } ?? []
            guard let source=owners.first?.source else { continue }
            let count=counts[source.id,default:0]
            guard count<source.tileCount else { continue }
            counts[source.id]=count+1
            // A saved source can contribute to a map area and more than one
            // park download. Count it once in each matching selection.
            for index in Set(owners.filter { $0.source.id==source.id }.map(\.pack)) {
                result[index].savedTileCount+=1
                let target=result[index].pack.bounds.center
                if result[index].savedPoint.map({ point.distance(to:target)<$0.distance(to:target) }) ?? true {
                    result[index].savedPoint=point
                }
            }
        }
        return result
    }
    static func at(_ point:GeoPoint,in overlays:[Self])->Self? {
        overlays.sorted { $0.id<$1.id }.first { $0.pack.contains(point) }
    }
}
