import Foundation

/// Completed, pinned downloads only. Cache residency and rendered tiles are not
/// evidence that a landscape will still be available on the next offline trip.
enum WorldOfflineCoverage {
    struct Asset: Codable, Hashable { var hash: String; var bytes: Int }
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
                let valid = asset.hash.count == 64 && asset.hash.allSatisfy(\.isHexDigit) && pins.contains(asset.hash)
                    && (try? cache.appendingPathComponent(asset.hash).resourceValues(forKeys:[.fileSizeKey]).fileSize) == asset.bytes
                present[asset] = valid
                return valid
            }
        }.map(\.bounds)
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
