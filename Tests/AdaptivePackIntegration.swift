import Foundation

@MainActor @main struct AdaptivePackIntegration {
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count == 3 else { fatalError("Pass source directory and isolated test directory") }
        let source=URL(fileURLWithPath:args[1]), work=URL(fileURLWithPath:args[2])
        let fm=FileManager.default
        try fm.createDirectory(at:work,withIntermediateDirectories:true)
        let manifest=try JSONDecoder().decode(RegionManifest.self,from:Data(contentsOf:source.appendingPathComponent("index.json")))
        try PackStore.validate(manifest)
        let grid=manifest.grid!
        let point=manifest.places.first(where:{$0.name.lowercased()=="crib goch"})?.coordinate ?? GeoPoint(latitude:53.0793,longitude:-4.0539)
        let uv=manifest.tileUV(point), x=Int(uv.u*Double(grid.columns)),y=Int(uv.v*Double(grid.rows))
        let selection=grid.rectangle(from:TerrainCell(column:x-1,row:y-1),to:TerrainCell(column:x+1,row:y+1))!
        let preview=AdaptiveArea.preview(manifest,selection:selection)
        try PackStore.validate(preview)
        let allowance=AdaptiveArea.allowance(preview,context:TerrainBudget.Context(physicalMemory:8*1_073_741_824,gpuTier:.modern))
        guard allowance.allowed else { fatalError(allowance.reason ?? "Not admitted") }
        print("Crib Goch: \(preview.adaptive!.chunks.count) chunks, \(preview.adaptive!.downloadBytes) geometry bytes, estimated scene \(allowance.estimatedMemory) bytes")
        let cache=work.appendingPathComponent("cache"), saved=work.appendingPathComponent("areas")
        try fm.createDirectory(at:cache,withIntermediateDirectories:true)
        // Existing verified map cache, as after the first offline area download.
        var receipt:[String:String]=[:]
        for asset in AdaptiveArea.assets(preview) where asset.remoteFile == nil {
            let target=cache.appendingPathComponent(asset.file)
            if !fm.fileExists(atPath:target.path) {
                do { try fm.linkItem(at:source.appendingPathComponent(asset.file),to:target) }
                catch { try fm.copyItem(at:source.appendingPathComponent(asset.file),to:target) }
            }
            receipt[asset.file]=asset.sha256
        }
        try JSONEncoder().encode(receipt).write(to:cache.appendingPathComponent("downloaded.json"))
        let entry=PackEntry(manifest:manifest,directory:cache,installed:false,remoteSource:URL(string:"http://127.0.0.1:8787/"+manifest.id)!)
        let store=PackStore(root:saved,bundledDirectory:nil,sourceDirectory:work.appendingPathComponent("sources"))
        let start=Date()
        let loaded=try await store.prepareAdaptive(entry,selection:selection,displayName:"Crib Goch") { _ in }
        print("Download + prepare with cached maps: \(Date().timeIntervalSince(start)) seconds")
        guard loaded.adaptiveMeshes.count==9,let z=loaded.elevation(at:point),z>800,z<1000 else {fatalError("Wrong terrain selected")}
        print("Crib Goch elevation: \(z) m")
        guard let graph=loaded.graph,let edge=graph.edges.first,
              let a=graph.nodes.first(where:{$0.id==edge.from}),let b=graph.nodes.first(where:{$0.id==edge.to}) else {fatalError("Paths missing")}
        let route=try RouteEngine.segment(from:a.coordinate,to:b.coordinate,mode:.paths,terrain:loaded)
        guard route.points.count>=2,route.points.allSatisfy({abs(($0.elevation ?? -999)-(loaded.elevation(at:$0.coordinate) ?? -9999))<0.01}) else {fatalError("Route does not follow adaptive surface")}
        let gpx=try GPXCodec.encode(RidgeRoute(name:"Adaptive path check",regionID:loaded.manifest.id,segments:[route]))
        let imported=try GPXCodec.decode(gpx,regionID:loaded.manifest.id)
        guard imported.points.count==route.points.count else {fatalError("GPX changed")}
        let reopen=Date(),offline=try await store.load(id:loaded.manifest.id)
        guard offline.manifest.places.contains(where: { $0.name == "Yr Wyddfa" && !offline.manifest.bounds.contains($0.coordinate) }) else { fatalError("Standalone adaptive save dropped surrounding peak names") }
        print("Offline reopen: \(Date().timeIntervalSince(reopen)) seconds")
        guard offline.adaptiveMeshes.count==9,offline.elevation(at:point)==loaded.elevation(at:point) else {fatalError("Offline mismatch")}
        let smaller=grid.selection(column:x,row:y)!
        let second=try await store.prepareAdaptive(entry,selection:smaller,displayName:"Crib Goch single tile") { _ in }
        guard second.manifest.bounds != loaded.manifest.bounds,second.adaptiveMeshes.count==1 else {fatalError("Selection ignored")}
        // Reinstall same immutable selection exercises atomic replacement.
        _ = try await store.prepareAdaptive(entry,selection:smaller,displayName:"Crib Goch single tile") { _ in }
        // Explicit expansion across a storage partition boundary keeps native axes.
        let byCell = Dictionary(uniqueKeysWithValues: manifest.adaptive!.chunks.map { chunk -> (Int, AdaptiveChunk) in
            let uv = manifest.tileUV(chunk.bounds.center)
            return (Int(uv.v * Double(grid.rows)) * grid.columns + Int(uv.u * Double(grid.columns)), chunk)
        })
        var pairs: [(Int, Int, Double)] = []
        for (cell, chunk) in byCell {
            if let other = byCell[cell + grid.columns], other.path != chunk.path {
                pairs.append((cell, cell + grid.columns, chunk.bounds.center.distance(to: point)))
            }
        }
        if let pair = pairs.min(by: { $0.2 < $1.2 }) {
            let across = grid.rectangle(from: TerrainCell(column: pair.0 % grid.columns, row: pair.0 / grid.columns),
                                        to: TerrainCell(column: pair.1 % grid.columns, row: pair.1 / grid.columns))!
            let expanded = try await store.prepareAdaptive(entry, selection: across, displayName: "Native partition join") { _ in }
            guard Set(expanded.adaptiveMeshes.map { $0.chunk.path }).count == 2 else { fatalError("Partition boundary lost") }
            let north = expanded.adaptiveMeshes.max(by: { $0.chunk.bounds.maxLatitude < $1.chunk.bounds.maxLatitude })!
            let south = expanded.adaptiveMeshes.min(by: { $0.chunk.bounds.maxLatitude < $1.chunk.bounds.maxLatitude })!
            for i in 0...512 {
                let p = GeoPoint(latitude: north.chunk.bounds.minLatitude, longitude: north.chunk.bounds.point(u: Double(i) / 512, v: 1).longitude)
                guard let a = north.elevation(at: p), let b = south.elevation(at: p), abs(a - b) <= 0.051 else { fatalError("Native partition seam mismatch") }
            }
            print("Cross-partition expansion: 513 shared-edge elevations agree")
        }
        print("PASS: native geometry, range download, independent maps, walking route, GPX, offline reopen, different selections, atomic replacement")
    }
}
