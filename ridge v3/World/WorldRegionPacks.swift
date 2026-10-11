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
        let definitions: [(String,String,String,String,[String])] = [
            ("north-scotland","Northern Highlands & Isles","Skye, the far north, Orkney & Shetland","The Old Man of Storr",["northern-isles","north-west-scotland","north-east-scotland"]),
            ("west-highlands","Highlands & West Coast","Lochaber, Cairngorms, Argyll & the islands","Ben Nevis",["central-highlands","argyll-western-isles"]),
            ("lowlands","Lowlands & Borders","Loch Lomond, the central belt & southern hills","The Eildon Hills",["central-scotland","southern-scotland"]),
            ("northern-ireland","Northern Ireland","The Mournes, Antrim & the Sperrins","The Mourne Mountains",["northern-ireland"]),
            ("lakes-dales","Lakes & Dales","Cumbria, the Yorkshire Dales & North Pennines","Scafell Pike",["cumbria","dales-north-pennines"]),
            ("north-east","North East & Yorkshire","Northumberland, the coast & North York Moors","Roseberry Topping",["north-east-england","north-east-yorkshire"]),
            ("midlands","Peak District & Midlands","The Peaks, Welsh borders & Cotswolds","Stanage Edge",["peak-district-midlands","marches-cotswolds"]),
            ("wales","Wales","Eryri, the Cambrians & Bannau Brycheiniog","Yr Wyddfa",["north-wales","mid-south-wales"]),
            ("east-anglia","East Anglia","The Broads, fens & east coast","The Norfolk Broads",["east-anglia"]),
            ("south-east","South East","The Downs, Weald, London & Kent","The Seven Sisters",["south-east"]),
            ("south-west","South West","Dorset, Somerset, Devon & Cornwall","Durdle Door",["central-south","devon-cornwall"])
        ]
        guard Set(definitions.flatMap { $0.4 }) == Set(index.regions.map(\.id)),
              definitions.flatMap({ $0.4 }).count == index.regions.count else { throw RidgeError.message("The region groups do not match the map grid.") }
        return try definitions.map { id,name,subtitle,landmark,groups in
            let cells=index.regions.filter { groups.contains($0.id) }.flatMap(\.cells)
            guard !cells.isEmpty,cells.allSatisfy({ $0.bounds.isValid }) else { throw RidgeError.message("A region has an invalid map boundary.") }
            return WorldRegionPack(id:id,name:name,subtitle:subtitle,landmark:landmark,cells:cells)
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
    var id:String { pack.id }
    var label:String {
        switch id {
        case "north-scotland": return "North Highlands\n& Isles"
        case "west-highlands": return "Highlands &\nWest Coast"
        case "lowlands": return "Lowlands\n& Borders"
        case "northern-ireland": return "Northern Ireland"
        case "lakes-dales": return "Lakes & Dales"
        case "north-east": return "North East\n& Yorkshire"
        case "midlands": return "Peak District\n& Midlands"
        case "east-anglia": return "East Anglia"
        default: return pack.name
        }
    }
    init(pack:WorldRegionPack,catalog:WorldCatalog?) {
        self.pack=pack
        let cells=pack.cells.map(\.bounds)
        fills=WorldOfflineCoverage.displayBounds(cells)
        edges=WorldOfflineCoverage.outline(cells)
        available=WorldOfflineCoverage.displayBounds(catalog.map { pack.sources(in:$0).map(\.bounds) } ?? [])
        labelPoint=cells.min { $0.center.distance(to:pack.bounds.center)<$1.center.distance(to:pack.bounds.center) }!.center
    }
    static func at(_ point:GeoPoint,in overlays:[Self])->Self? {
        overlays.sorted { $0.id<$1.id }.first { $0.pack.cells.contains { $0.bounds.contains(point) } }
    }
}
