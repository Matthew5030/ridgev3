import Foundation
import CoreGraphics

/// Named groups of the existing UK grid. Each published source belongs to one
/// group; regional downloads use exactly the same assets as custom-area saves.
struct WorldRegionPack: Identifiable, Sendable {
    struct Cell: Decodable, Sendable { let id: String; let bounds: GeoBounds }
    let id: String
    let name: String
    let subtitle: String
    let landmark: String
    let cells: [Cell]
    var artworkID:String {
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
    var bounds: GeoBounds {
        GeoBounds(minLatitude:cells.map { $0.bounds.minLatitude }.min()!,minLongitude:cells.map { $0.bounds.minLongitude }.min()!,
                  maxLatitude:cells.map { $0.bounds.maxLatitude }.max()!,maxLongitude:cells.map { $0.bounds.maxLongitude }.max()!)
    }
    func sources(in catalog: WorldCatalog) -> [WorldCatalog.Region] {
        catalog.sources.filter { source in cells.contains { $0.bounds.contains(source.bounds.center) } }.sorted { $0.id < $1.id }
    }
    func coveredCells(in catalog: WorldCatalog) -> Set<String> {
        let sources=sources(in:catalog)
        return Set(cells.filter { cell in sources.contains { cell.bounds.contains($0.bounds.center) } }.map(\.id))
    }
    static func load(url: URL? = nil) throws -> [WorldRegionPack] {
        struct Group: Decodable { let id:String; let cells:[Cell] }
        struct Index: Decodable { let schemaVersion:Int; let regions:[Group] }
        guard let url = url ?? Bundle.main.url(forResource:"uk-pack-regions",withExtension:"json")
            ?? Bundle.main.url(forResource:"uk-pack-regions",withExtension:"json",subdirectory:"Resources") else {
            throw RidgeError.message("The region list is missing from this build.")
        }
        let index=try JSONDecoder().decode(Index.self,from:Data(contentsOf:url))
        guard index.schemaVersion == 1 else { throw RidgeError.message("Unsupported region list.") }
        // Geographic bands split the original publication grid into smaller
        // presets. Split on cell centres, never through a source or asset.
        struct Division {
            let group:String
            let latitude:Bool
            let cuts:[Double]
            let names:[(String,String)]
        }
        let divisions:[Division] = [
            .init(group:"northern-isles",latitude:true,cuts:[59.6],names:[("orkney","Orkney"),("shetland","Shetland")]),
            .init(group:"north-west-scotland",latitude:false,cuts:[-6.1, -4.9],names:[("outer-hebrides","Outer Hebrides"),("skye-wester-ross","Skye & Wester Ross"),("sutherland","Sutherland")]),
            .init(group:"north-east-scotland",latitude:true,cuts:[57.5],names:[("aberdeenshire","Aberdeenshire"),("caithness-moray","Caithness & Moray")]),
            .init(group:"central-highlands",latitude:false,cuts:[-4.1],names:[("lochaber","Lochaber"),("cairngorms","Cairngorms")]),
            .init(group:"argyll-western-isles",latitude:true,cuts:[56.2],names:[("argyll-islay","Argyll & Islay"),("mull-small-isles","Mull & Small Isles")]),
            .init(group:"central-scotland",latitude:false,cuts:[-3.7],names:[("lomond-trossachs","Lomond & Trossachs"),("fife-lothians","Fife & Lothians")]),
            .init(group:"southern-scotland",latitude:false,cuts:[-3.7],names:[("galloway","Galloway"),("scottish-borders","Scottish Borders")]),
            .init(group:"northern-ireland",latitude:false,cuts:[-6.7],names:[("fermanagh-sperrins","Fermanagh & Sperrins"),("antrim-down","Antrim & Down")]),
            .init(group:"north-east-england",latitude:true,cuts:[55.1],names:[("tyne-wear-durham","Tyne, Wear & Durham"),("northumberland","Northumberland")]),
            .init(group:"cumbria",latitude:true,cuts:[54.5],names:[("south-lakes","South Lakes"),("north-lakes","North Lakes")]),
            .init(group:"dales-north-pennines",latitude:true,cuts:[54.0],names:[("yorkshire-dales","Yorkshire Dales"),("north-pennines","North Pennines")]),
            .init(group:"north-east-yorkshire",latitude:true,cuts:[53.8],names:[("yorkshire-wolds","Yorkshire Wolds"),("north-york-moors","North York Moors")]),
            .init(group:"peak-district-midlands",latitude:true,cuts:[52.55, 53.0],names:[("central-midlands","Central Midlands"),("trent-valley","Trent Valley"),("peak-district","Peak District")]),
            .init(group:"north-wales",latitude:false,cuts:[-3.7],names:[("eryri-anglesey","Eryri & Anglesey"),("clwyd-berwyn","Clwyd & Berwyn")]),
            .init(group:"mid-south-wales",latitude:false,cuts:[-4.2],names:[("pembrokeshire-ceredigion","Pembrokeshire & Ceredigion"),("bannau-mid-wales","Bannau & Mid Wales")]),
            .init(group:"east-anglia",latitude:false,cuts:[0.0, 0.8],names:[("fens-cambridgeshire","Fens & Cambridgeshire"),("suffolk-west-norfolk","Suffolk & West Norfolk"),("broads-east-coast","Broads & East Coast")]),
            .init(group:"marches-cotswolds",latitude:true,cuts:[52.05],names:[("severn-cotswolds","Severn & Cotswolds"),("shropshire-marches","Shropshire & Marches")]),
            .init(group:"south-east",latitude:false,cuts:[-0.4, 0.65],names:[("surrey-south-downs","Surrey & South Downs"),("london-weald","London & Weald"),("kent-east-sussex","Kent & East Sussex")]),
            .init(group:"central-south",latitude:false,cuts:[-2.3],names:[("somerset-west-dorset","Somerset & West Dorset"),("wessex","Wessex")]),
            .init(group:"devon-cornwall",latitude:false,cuts:[-4.5],names:[("cornwall-scilly","Cornwall & Scilly"),("devon","Devon")]),
        ]
        guard Set(divisions.map(\.group)) == Set(index.regions.map(\.id)),
              divisions.count == index.regions.count else { throw RidgeError.message("The region groups do not match the map grid.") }
        return try divisions.flatMap { division -> [WorldRegionPack] in
            let cells=index.regions.first { $0.id==division.group }!.cells
            var bands=Array(repeating:[Cell](),count:division.names.count)
            for cell in cells {
                let center=cell.bounds.center
                let coordinate=division.latitude ? center.latitude : center.longitude
                bands[division.cuts.filter { coordinate >= $0 }.count].append(cell)
            }
            return try division.names.enumerated().map { offset,definition in
                let (id,name)=definition,cells=bands[offset]
                guard !cells.isEmpty,cells.allSatisfy({ $0.bounds.isValid }) else { throw RidgeError.message("A region has an invalid map boundary.") }
                return WorldRegionPack(id:id,name:name,subtitle:"Approximate map area · follows the tile grid",landmark:name,cells:cells)
            }
        }
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
    let labelPoint:GeoPoint
    private(set) var labelFontScale:Double=0
    enum DownloadState { case unavailable,notSaved,partial,saved }
    var savedTileCount=0
    var totalTileCount=0
    var savedPoint:GeoPoint?
    var downloadState:DownloadState {
        if totalTileCount==0 { return .unavailable }
        if savedTileCount==0 { return .notSaved }
        return savedTileCount>=totalTileCount ? .saved : .partial
    }
    var statusText:String {
        switch downloadState {
        case .unavailable: return "Unavailable from this source"
        case .notSaved: return "Not downloaded"
        case .partial: return "Partly downloaded"
        case .saved: return "Available maps downloaded"
        }
    }
    var id:String { pack.id }
    /// Short atlas lettering; the inspector retains the full pack name.
    var label:String {
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
        let cells=pack.cells.map(\.bounds)
        fills=WorldOfflineCoverage.displayBounds(cells)
        edges=WorldOfflineCoverage.outline(cells)
        let sources=catalog.map { pack.sources(in:$0) } ?? []
        available=WorldOfflineCoverage.displayBounds(sources.map(\.bounds))
        totalTileCount=sources.reduce(0) { $0+$1.tileCount }
        labelPoint=cells.min { $0.center.distance(to:pack.bounds.center)<$1.center.distance(to:pack.bounds.center) }!.center
        labelFontScale=Self.fittedLabelScale(label,anchor:labelPoint,fills:fills)
    }
    /// Fit once in projected map coordinates, independent of camera/selection.
    /// Every zoom then uses the same footprint, so adjacent labels cannot swap
    /// priority or change size in discrete fitting steps during a gesture.
    private static func fittedLabelScale(_ label:String,anchor:GeoPoint,fills:[GeoBounds])->Double {
        func projected(_ p:GeoPoint)->CGPoint {
            let latitude=min(85,max(-85,p.latitude)) * .pi/180
            return CGPoint(x:(p.longitude+180)/360,y:(1-log(tan(latitude)+1/cos(latitude)) / .pi)/2)
        }
        let origin=projected(anchor)
        let rectangles=fills.map { bounds -> CGRect in
            let a=projected(.init(latitude:bounds.maxLatitude,longitude:bounds.minLongitude))
            let b=projected(.init(latitude:bounds.minLatitude,longitude:bounds.maxLongitude))
            return CGRect(x:a.x-origin.x,y:a.y-origin.y,width:b.x-a.x,height:b.y-a.y)
        }
        let lines=label.split(separator:"\n")
        let width=Double(lines.map(\.count).max() ?? 1)*0.72+0.5,height=Double(lines.count)*1.2+0.4
        let extent=rectangles.reduce(CGRect.null) { $0.union($1) }
        var low=0.0,high=min(extent.width/width,extent.height/height)
        for _ in 0..<28 {
            let font=(low+high)/2
            let rect=CGRect(x:-width*font/2,y:-height*font/2,width:width*font,height:height*font)
            let covered=rectangles.reduce(0.0) { total,part in
                let intersection=part.intersection(rect)
                return total+(intersection.isNull ? 0 : intersection.width*intersection.height)
            }
            if covered>=rect.width*rect.height*(1-1e-8) { low=font } else { high=font }
        }
        return low*0.92
    }
    func labelAppearance(at scale:Double)->(size:Double,opacity:Double) {
        let size=min(40,max(0,scale*labelFontScale))
        let t=min(1,max(0,(size-16)/8))
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
            guard let owner=buckets[key]?.first(where: { $0.source.bounds.contains(point) }) else { continue }
            let count=counts[owner.source.id,default:0]
            guard count<owner.source.tileCount else { continue }
            counts[owner.source.id]=count+1
            result[owner.pack].savedTileCount+=1
            let target=result[owner.pack].pack.bounds.center
            if result[owner.pack].savedPoint.map({ point.distance(to:target)<$0.distance(to:target) }) ?? true {
                result[owner.pack].savedPoint=point
            }
        }
        return result
    }
    static func at(_ point:GeoPoint,in overlays:[Self])->Self? {
        overlays.sorted { $0.id<$1.id }.first { $0.pack.cells.contains { $0.bounds.contains(point) } }
    }
}
