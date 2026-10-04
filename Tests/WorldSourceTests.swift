import Foundation
import CoreGraphics

@main struct WorldSourceTests {
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let source=try JSONDecoder().decode(WorldSource.self,from:Data(contentsOf:root.appendingPathComponent("world.json")))
        try source.validate();var checks=0
        func check(_ condition:Bool,_ message:String)throws{checks+=1;if !condition{throw RidgeError.message(message)}}
        var maxMesh:Int64=0,maxTexture:Int64=0
        for distance in [200.0,1500,5000,10000,22000] {
            for tile in source.tiles {
                let requests=WorldWorkingSet.requests(source:source,center:tile.mesh.bounds.center,distance:distance)
                try check(requests.count<=WorldWorkingSet.maximumTextures,"Working set cap")
                let mesh=requests.filter(\.fine).reduce(Int64(0)){sum,r in sum+source.tiles.first(where:{$0.id==r.id})!.mesh.residentBytes}
                let textures=requests.reduce(Int64(0)){$0+Int64(($1.pixels+8)*($1.pixels+8)*4)*4/3}
                maxMesh=max(maxMesh,mesh);maxTexture=max(maxTexture,textures)
                try check(mesh<=WorldWorkingSet.meshBudget,"Mesh budget")
                try check(textures<=WorldWorkingSet.textureBudget,"Texture mip budget")
                try check(requests.filter{$0.pixels==1024}.count<=8,"High-resolution count")
                try check(Set(requests.map(\.id)).count==requests.count,"No duplicate tiles")
            }
        }
        // Simulate travel and repeated boundary crossings with retained requests.
        // The queue must retain a complete textured world and shed old image
        // allocations before admitting higher-resolution replacements.
        var previous:[WorldTileRequest]=[]
        var current:[String:WorldTileRequest]=[:]
        var swaps=0
        for step in 0..<90 {
            let fraction=Double(step<45 ? step : 89-step)/44
            let center=source.bounds.point(u:0.2+fraction*0.6,v:0.55)
            let next=WorldWorkingSet.requests(source:source,center:center,distance:1800,previous:previous)
            let mesh=next.filter(\.fine).reduce(Int64(0)) { sum, request in sum+source.tiles.first(where:{$0.id==request.id})!.mesh.residentBytes }
            try check(mesh<=WorldWorkingSet.meshBudget,"Retained fine geometry remains bounded")
            let wanted=Dictionary(uniqueKeysWithValues:next.map { ($0.id,$0) })
            for id in Array(current.keys) where wanted[id]?.fine == false { current[id]?.fine=false }
            let initialCount=current.count
            var operations=0
            while let request=WorldWorkingSet.pending(wanted:next,current:current).first {
                try check(current.count>=initialCount,"Detail changes must not remove texture pages")
                current[request.id]=request;operations+=1
                let textures=current.values.reduce(Int64(0)) { $0+Int64(($1.pixels+8)*($1.pixels+8)*4)*4/3 }
                try check(textures<=WorldWorkingSet.textureBudget,"Transition image allocation stays bounded")
                if operations>1024 { throw RidgeError.message("Queue did not converge") }
            }
            swaps+=operations; previous=next
        }
        let compact=WorldWorkingSet.requests(source:source,center:source.bounds.center,distance:1800,meshLimit:96*1024*1024)
        let compactBytes=compact.filter(\.fine).reduce(Int64(0)) { sum, request in sum+source.tiles.first(where:{$0.id==request.id})!.mesh.residentBytes }
        try check(compactBytes<=96*1024*1024,"Smaller-device fine budget")
        print("Travel simulation: \(swaps) completed replacements, no texture holes")
        let selected=source.tiles.first(where:{$0.id=="c06-r09"})!
        let mesh=try AdaptiveTerrainCodec.decode(Data(contentsOf:root.appendingPathComponent(selected.mesh.path)),chunk:selected.mesh)
        try check(mesh.elevation(at:selected.mesh.bounds.center) != nil,"Adaptive picking")
        let compressed=try Data(contentsOf:root.appendingPathComponent(selected.map.file))
        try check(AdaptiveTerrainCodec.hash(compressed)==selected.map.sha256,"Vector integrity")
        let map=try JSONDecoder().decode(WorldVectorMap.self,from:AdaptiveTerrainCodec.inflate(compressed,byteCount:selected.map.decodedByteCount!))
        let low=try WorldCartography.draw(map,pixels:128),high=try WorldCartography.draw(map,pixels:1024)
        try check(low.width==136 && high.width==1032,"One source at two resolutions")
        let graph=try JSONDecoder().decode(WalkingGraph.self,from:Data(contentsOf:root.appendingPathComponent(source.graph.file)))
        let edge=graph.edges.first(where:{$0.kind=="footpath" && $0.access != "private"})!
        let a=graph.nodes.first(where:{$0.id==edge.from})!.coordinate,b=graph.nodes.first(where:{$0.id==edge.to})!.coordinate
        let route=try RouteEngine.walkingSegment(from:a,to:b,graph:graph)
        try check(route.mode=="paths" && route.points.count>=2,"Follow paths from published graph")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = WorldSourceStore(bundledURL: root, cacheURL: cache)
        let (opened,overview,_) = try await store.open(address: "")
        try check(opened.id == source.id, "Open bundled world")
        let start=Date()
        let backdrop=try await store.backdrop(source:opened,overview:overview)
        let backdropBytes=backdrop.geometries.values.reduce(0) { sum, geometry in sum+geometry.sources.reduce(0) { $0+$1.data.count }+geometry.elements.reduce(0) { $0+$1.data.count } }
        try check(overview.width==1025 && backdrop.geometries.count==source.tiles.count,"8 m world backdrop is complete")
        try check(backdropBytes<80*1024*1024,"Background geometry allocation")
        print("8 m backdrop: \(backdropBytes) geometry bytes, \(Date().timeIntervalSince(start)) seconds off main thread")
        let ready = try await store.prepare(selected, request:WorldTileRequest(id:selected.id,pixels:256,fine:true),sourceBounds:source.bounds)
        try check(ready.mesh != nil && ready.geometry != nil && ready.image.width == 264,"Native streamed tile")
        let resized=try await store.prepare(selected,request:WorldTileRequest(id:selected.id,pixels:512,fine:true),sourceBounds:source.bounds,previous:ready)
        try check(resized.geometry === ready.geometry,"Texture changes reuse fine geometry")
        let demoted=try await store.prepare(selected,request:WorldTileRequest(id:selected.id,pixels:256,fine:false),sourceBounds:source.bounds,previous:ready)
        try check(demoted.image === ready.image && demoted.mesh == nil,"Geometry downgrade retains the exact texture")
        if CommandLine.arguments.contains("--http") {
            let remote = WorldSourceStore(bundledURL:root,cacheURL:cache)
            let (published,_,_) = try await remote.open(address:"http://127.0.0.1:8776/world.json")
            let first = try await remote.prepare(selected,request:WorldTileRequest(id:selected.id,pixels:256,fine:true),sourceBounds:source.bounds)
            let cached = try await remote.prepare(selected,request:WorldTileRequest(id:selected.id,pixels:512,fine:true),sourceBounds:source.bounds)
            try check(published.id==source.id && first.mesh?.chunk.sha256==cached.mesh?.chunk.sha256,"Hosted tile and cache reuse")
            try await remote.pin([selected],source:source)
            let pins=try JSONDecoder().decode(Set<String>.self,from:Data(contentsOf:cache.appendingPathComponent("pins.json")))
            try check(pins.contains(selected.map.sha256) && pins.contains(selected.mesh.sha256),"Pin exact shared assets")
        }
        var invalid = source; invalid.tiles[0].column = 300
        var rejected=false
        do { try invalid.validate() } catch { rejected=true }
        try check(rejected,"Invalid grid rejected")
        print("PASS \(checks) assertions; maximum estimated mesh \(maxMesh) bytes; textures with mips \(maxTexture) bytes; \(source.tiles.count) source tiles")
    }
}
