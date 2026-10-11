import Foundation

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
    func download(_ plan:WorldRegionDownloadPlan,progress:@escaping @Sendable (Int64,Int) async -> Void) async throws {
        // Reserve headroom for temporary files. A large offline save is a disk
        // operation; it must never allocate or prepare the whole region in RAM.
        if plan.bytes>0,let capacity=try? cache.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           capacity < plan.bytes+256*1024*1024 { throw RidgeError.message("There isn’t enough free space for this pack. Free some storage and try again.") }
        var completed:Int64=0,checkedConnection=false
        for (index,part) in plan.parts.enumerated() {
            try Task.checkCancellation()
            let (files,source)=try await open(part.region,root:plan.root)
            if part.missingBytes>0 && !checkedConnection { try await files.checkDownloadConnection();checkedConnection=true }
            let base=completed
            try await files.pin(source.tiles,source:source,countCachedInProgress:false,coverageID:source.id,progress: { bytes in
                await progress(min(plan.bytes,base+bytes),index)
            })
            completed+=part.missingBytes
            await progress(min(plan.bytes,completed),index+1)
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
    var label:String {
        let words=pack.name.split(separator:" ")
        guard pack.name.count>16,words.count>1 else { return pack.name }
        let split=(1..<words.count).min { a,b in
            abs(words[..<a].joined(separator:" ").count-words[a...].joined(separator:" ").count)
                < abs(words[..<b].joined(separator:" ").count-words[b...].joined(separator:" ").count)
        }!
        return words[..<split].joined(separator:" ")+"\n"+words[split...].joined(separator:" ")
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
