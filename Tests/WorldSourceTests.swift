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
                try check(textures<80*1024*1024,"Texture mip budget")
                try check(requests.filter{$0.pixels==1024}.count<=4,"High-resolution count")
                try check(Set(requests.map(\.id)).count==requests.count,"No duplicate tiles")
            }
        }
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
        let (opened,_,_) = try await store.open(address: "")
        try check(opened.id == source.id, "Open bundled world")
        let ready = try await store.prepare(selected, request:WorldTileRequest(id:selected.id,pixels:256,fine:true),sourceBounds:source.bounds)
        try check(ready.mesh != nil && ready.geometry != nil && ready.image.width == 264,"Native streamed tile")
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
