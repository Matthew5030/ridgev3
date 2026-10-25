import Foundation

/// Completed, pinned downloads only. Cache residency and rendered tiles are not
/// evidence that a landscape will still be available on the next offline trip.
enum WorldOfflineCoverage {
    struct Asset: Codable, Hashable { var hash: String; var bytes: Int; var packed:Bool? = nil }
    struct Receipt: Codable { var bounds: GeoBounds; var assets: [Asset] }
    struct Edge: Equatable, Sendable {
        var start: GeoPoint
        var end: GeoPoint
        func nearest(to point: GeoPoint) -> GeoPoint {
            GeoPoint(latitude: min(max(point.latitude,min(start.latitude,end.latitude)),max(start.latitude,end.latitude)),
                     longitude: min(max(point.longitude,min(start.longitude,end.longitude)),max(start.longitude,end.longitude)))
        }
        func distance(to point: GeoPoint) -> Double { point.distance(to:nearest(to:point)) }
    }
    static func cache(_ override: URL?) -> URL {
        override ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WorldCache",isDirectory:true)
    }
    private static let lock = NSLock()
    private static func receipts(in file: URL) -> [Receipt] {
        (try? JSONDecoder().decode([Receipt].self,from:Data(contentsOf:file))) ?? []
    }
    private static func receipts(at cache: URL) -> [Receipt] {
        // Keep legacy custom-area receipts readable. Big region saves write one
        // small receipt per source instead of rewriting the entire UK per block.
        var result=Dictionary(receipts(in:cache.appendingPathComponent("offline-coverage.json")).map { ($0.bounds,$0) },uniquingKeysWith: { _,new in new })
        let directory=cache.appendingPathComponent("offline-regions",isDirectory:true)
        for file in (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] where file.pathExtension=="json" {
            for receipt in receipts(in:file) { result[receipt.bounds]=receipt }
        }
        return Array(result.values)
    }
    static func record(_ additions: [Receipt], at cache: URL, identifier: String? = nil) throws {
        guard !additions.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let file:URL
        if let identifier {
            let directory=cache.appendingPathComponent("offline-regions",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            file=directory.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(identifier.utf8))+".json")
        } else { file=cache.appendingPathComponent("offline-coverage.json") }
        var current = Dictionary(receipts(in:file).map { ($0.bounds,$0) },uniquingKeysWith: { _,new in new })
        for receipt in additions { current[receipt.bounds] = receipt }
        try JSONEncoder().encode(Array(current.values)).write(to:file,options:.atomic)
    }
    static func savedBounds(at cache: URL) -> [GeoBounds] {
        lock.lock(); defer { lock.unlock() }
        let pins = (try? JSONDecoder().decode(Set<String>.self,from:Data(contentsOf:cache.appendingPathComponent("pins.json")))) ?? []
        var present: [Asset:Bool] = [:]
        return receipts(at:cache).filter { receipt in
            receipt.bounds.isValid && !receipt.assets.isEmpty && receipt.assets.allSatisfy { asset in
                if let value = present[asset] { return value }
                let file=asset.packed == true ? WorldSectionPack.directory(cache).appendingPathComponent(asset.hash+".ridgepack") : cache.appendingPathComponent(asset.hash)
                let valid = asset.hash.count == 64 && asset.hash.allSatisfy(\.isHexDigit) && pins.contains(asset.hash)
                    && (try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) == asset.bytes
                present[asset] = valid
                return valid
            }
        }.map(\.bounds)
    }
    struct StorageSummary:Sendable {
        var bytes:Int64 = 0
        var areas:[WorldRegionPack] = []
    }
    static func storageSummary(at cache:URL,areas:[WorldRegionPack],catalog:WorldCatalog?)->StorageSummary {
        let saved=savedBounds(at:cache)
        let partial=Set(((try? FileManager.default.contentsOfDirectory(at:WorldSectionPack.directory(cache),includingPropertiesForKeys:nil)) ?? [])
            .filter { $0.pathExtension=="partial" }.map { $0.deletingPathExtension().lastPathComponent })
        let pending=((try? FileManager.default.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)) ?? [])
            .filter { $0.pathExtension=="download-index" }.compactMap { file -> WorldSource? in
                guard let data=try? Data(contentsOf:file) else { return nil }
                return try? JSONDecoder().decode(WorldSource.self,from:data)
            }
        let savedIDs=Set(WorldRegionMapOverlay.make(packs:areas,catalog:catalog,offline:saved).filter { $0.savedTileCount>0 }.map(\.id))
        let visible=areas.filter { area in
            savedIDs.contains(area.id) || pending.contains { source in area.cells.contains { $0.bounds.contains(source.bounds.center) } }
                || catalog?.regionArchives?.contains { $0.id==area.id && partial.contains($0.asset.sha256) } == true
                || area.sources(in:catalog ?? WorldCatalog(schemaVersion:1,revision:"storage",sources:[])).contains { region in
                    region.pack.map { partial.contains($0.sha256) } ?? false
                }
        }
        return StorageSummary(bytes:diskBytes(at:cache),areas:visible)
    }
    private static func diskBytes(at root:URL)->Int64 {
        guard let files=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey]) else { return 0 }
        return files.compactMap { $0 as? URL }.reduce(0) { total,file in
            let values=try? file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
            return total+(values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
        }
    }
    /// Remove geographic receipts first; delete only objects unreferenced by
    /// every remaining save. A combined regional pack may serve several areas.
    static func removeDownloads(in area:WorldRegionPack?,catalog:WorldCatalog?,at cache:URL) throws {
        lock.lock();defer { lock.unlock() }
        let fm=FileManager.default
        guard fm.fileExists(atPath:cache.path) else { return }
        if area == nil {
            for file in try fm.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil) { try fm.removeItem(at:file) }
            try Data().write(to:cache.appendingPathComponent("coverage-managed"),options:.atomic)
            return
        }
        guard let area else { return }
        func selected(_ bounds:GeoBounds)->Bool { area.cells.contains { $0.bounds.contains(bounds.center) } }
        let coverage=cache.appendingPathComponent("offline-coverage.json")
        let folder=cache.appendingPathComponent("offline-regions",isDirectory:true)
        let records=((try? fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).filter { $0.pathExtension=="json" }
            + (fm.fileExists(atPath:coverage.path) ? [coverage] : [])
        var updates:[(URL,[Receipt])]=[],removed:[Receipt]=[],retained:[Receipt]=[]
        for file in records {
            let values=try JSONDecoder().decode([Receipt].self,from:Data(contentsOf:file))
            let keep=values.filter { !selected($0.bounds) }
            removed+=values.filter { selected($0.bounds) };retained+=keep
            updates.append((file,keep))
        }
        let retainedHashes=Set(retained.flatMap { $0.assets.map(\.hash) })
        var loose=Set(removed.flatMap { $0.assets.filter { $0.packed != true }.map(\.hash) })
        var packed=Set(removed.flatMap { $0.assets.filter { $0.packed == true }.map(\.hash) })
        let files=try fm.contentsOfDirectory(at:cache,includingPropertiesForKeys:nil)
        var indices:[URL]=[],sourceIDs=Set<String>()
        for file in files where ["index","download-index"].contains(file.pathExtension) {
            guard let data=try? Data(contentsOf:file),let source=try? JSONDecoder().decode(WorldSource.self,from:data),selected(source.bounds) else { continue }
            indices.append(file);sourceIDs.insert(source.id)
            loose.formUnion(WorldSourceStore.assets(tiles:source.tiles,source:source).map(\.sha256))
        }
        if let catalog {
            for source in area.displaySources(in:catalog) {
                sourceIDs.insert(source.id)
                if let pack=source.pack { packed.insert(pack.sha256) }
                if let routing=source.routing { loose.insert(routing.sha256) }
            }
            for archive in catalog.regionArchives ?? [] where archive.id==area.id { packed.insert(archive.asset.sha256) }
        }
        for id in sourceIDs {
            if let data=try? Data(contentsOf:WorldSectionPack.reference(id,cache:cache)),
               let installed=try? JSONDecoder().decode(WorldSectionPack.Installed.self,from:data) {
                packed.insert((installed.container?.asset ?? installed.asset).sha256)
            }
        }
        // Disable migration recovery so a shared container cannot silently
        // recreate coverage that the user explicitly removed.
        try Data().write(to:cache.appendingPathComponent("coverage-managed"),options:.atomic)
        for (file,values) in updates { try JSONEncoder().encode(values).write(to:file,options:.atomic) }
        for file in indices { try fm.removeItem(at:file) }
        for id in sourceIDs {
            let file=WorldSectionPack.reference(id,cache:cache)
            if let data=try? Data(contentsOf:file),let installed=try? JSONDecoder().decode(WorldSectionPack.Installed.self,from:data),
               retainedHashes.contains((installed.container?.asset ?? installed.asset).sha256) { continue }
            if fm.fileExists(atPath:file.path) { try fm.removeItem(at:file) }
        }
        loose.subtract(retainedHashes);packed.subtract(retainedHashes)
        let pinsURL=cache.appendingPathComponent("pins.json")
        var pins=(try? JSONDecoder().decode(Set<String>.self,from:Data(contentsOf:pinsURL))) ?? []
        pins.subtract(loose.union(packed))
        try JSONEncoder().encode(pins).write(to:pinsURL,options:.atomic)
        for hash in loose.union(packed) where hash.count==64 && hash.allSatisfy(\.isHexDigit) {
            var candidates:[URL]=[]
            if loose.contains(hash) { candidates.append(cache.appendingPathComponent(hash)) }
            if packed.contains(hash) { candidates += [WorldSectionPack.directory(cache).appendingPathComponent(hash+".ridgepack"),WorldSectionPack.directory(cache).appendingPathComponent(hash+".partial")] }
            for file in candidates where fm.fileExists(atPath:file.path) { try fm.removeItem(at:file) }
        }
    }
    /// Coalesce saved tiles for the atlas fill. Admission still uses the exact
    /// receipts; drawing a whole region should not submit 100,000 rectangles
    /// every time the user moves the map. Holes remain holes.
    static func displayBounds(_ bounds:[GeoBounds]) -> [GeoBounds] {
        struct Span:Hashable { let lo:Int64;let hi:Int64 }
        let scale=100_000_000.0
        func q(_ value:Double)->Int64 { Int64((value*scale).rounded()) }
        func merged(_ spans:[Span])->[Span] {
            var result:[Span]=[]
            for span in spans.sorted(by: { $0.lo<$1.lo }) {
                if let last=result.last,span.lo<=last.hi {
                    result[result.count-1]=Span(lo:last.lo,hi:max(last.hi,span.hi))
                } else { result.append(span) }
            }
            return result
        }
        var rows:[Span:[Span]]=[:]
        for b in bounds where b.isValid {
            rows[Span(lo:q(b.minLatitude),hi:q(b.maxLatitude)),default:[]].append(Span(lo:q(b.minLongitude),hi:q(b.maxLongitude)))
        }
        var columns:[Span:[Span]]=[:]
        for (row,spans) in rows { for span in merged(spans) { columns[span,default:[]].append(row) } }
        return columns.flatMap { column,spans in merged(spans).map { row in
            GeoBounds(minLatitude:Double(row.lo)/scale,minLongitude:Double(column.lo)/scale,
                      maxLatitude:Double(row.hi)/scale,maxLongitude:Double(column.hi)/scale)
        } }
    }
    /// Tiles use one aligned geographic grid. Sweep collinear edge intervals so
    /// neighbours (including partial shared edges) disappear and saves join up.
    static func outline(_ bounds: [GeoBounds]) -> [Edge] {
        struct Line: Hashable { var horizontal: Bool; var fixed: Int64 }
        struct Event { var position: Int64; var delta: Int }
        let scale = 100_000_000.0
        func q(_ value: Double) -> Int64 { Int64((value*scale).rounded()) }
        var lines: [Line:[Event]] = [:]
        func add(_ horizontal: Bool,_ fixed: Double,_ lo: Double,_ hi: Double,_ sign: Int) {
            let line=Line(horizontal:horizontal,fixed:q(fixed))
            lines[line,default:[]] += [Event(position:q(lo),delta:sign),Event(position:q(hi),delta:-sign)]
        }
        for b in Set(bounds) where b.isValid {
            add(true,b.minLatitude,b.minLongitude,b.maxLongitude,1)
            add(true,b.maxLatitude,b.minLongitude,b.maxLongitude,-1)
            add(false,b.minLongitude,b.minLatitude,b.maxLatitude,1)
            add(false,b.maxLongitude,b.minLatitude,b.maxLatitude,-1)
        }
        var edges: [Edge] = []
        for (line,events) in lines {
            let changes=Dictionary(grouping:events,by:\.position).mapValues { $0.reduce(0) { $0+$1.delta } }
            var count=0, beginning: Int64?
            for position in changes.keys.sorted() {
                let next=count+changes[position]!
                if count==0 && next != 0 { beginning=position }
                if count != 0 && next==0, let start=beginning {
                    func point(_ p: Int64) -> GeoPoint {
                        GeoPoint(latitude:Double(line.horizontal ? line.fixed : p)/scale,longitude:Double(line.horizontal ? p : line.fixed)/scale)
                    }
                    if start < position { edges.append(Edge(start:point(start),end:point(position))) }
                    beginning=nil
                }
                count=next
            }
        }
        return edges.sorted { a,b in a.start.latitude == b.start.latitude ? a.start.longitude < b.start.longitude : a.start.latitude < b.start.latitude }
    }
    static func visibility(distance: Double) -> Double {
        max(0,min(1,(1800-distance)/1200))
    }
}
