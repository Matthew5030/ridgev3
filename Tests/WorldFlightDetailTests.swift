import Foundation
import CoreGraphics
import SceneKit

@main struct WorldFlightDetailTests {
    static func main() async throws {
        setbuf(stdout,nil)
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let source=try JSONDecoder().decode(WorldSource.self,from:Data(contentsOf:root.appendingPathComponent("world.json")))
        var checks=0
        func check(_ value:Bool,_ message:String) throws { checks+=1;if !value { throw RidgeError.message(message) } }
        let byID=Dictionary(uniqueKeysWithValues:source.tiles.map { ($0.id,$0) })
        let row=source.tiles.filter { $0.row==9 }.sorted { $0.column<$1.column }
        let first=row[2].mesh.bounds.center,last=row[12].mesh.bounds.center,length=first.distance(to:last)
        var distances=Array(stride(from:0.0,to:length,by:60));distances.append(length)
        func point(_ distance:Double)->GeoPoint {
            let t=min(1,max(0,distance/length))
            return .init(latitude:first.latitude+(last.latitude-first.latitude)*t,longitude:first.longitude+(last.longitude-first.longitude)*t)
        }
        let stations=distances.map { WorldFlightDetailStation(distance:$0,points:[point($0)]) }
        let detail=try WorldFlightDetailIndex(stations:stations,tiles:source.tiles)
        let lookup=WorldTileIndex(tiles:source.tiles)
        let cameraElsewhere=source.tiles.first!.mesh.bounds.center
        let initial=WorldWorkingSet.flightRequests(source:source,priorities:detail.priorities(at:0),center:cameraElsewhere)
        try check(initial.first?.id==row[2].id && initial.first?.fine==true,"Flight prepares the route start even while the browsing camera is elsewhere")
        try check(initial.first(where: { $0.id==row[4].id })?.fine == true,"Fine terrain is prepared a kilometre along the route before the camera moves")
        let old=WorldWorkingSet.requests(source:source,center:cameraElsewhere,distance:1000,closePreview:true)
        try check(old.first?.id != initial.first?.id,"Route detail no longer follows the browsing camera's position")

        let short=try WorldFlightDetailIndex(stations:Array(stations.prefix(12)),tiles:source.tiles)
        let shortRequests=WorldWorkingSet.flightRequests(source:source,priorities:short.priorities(at:0),center:cameraElsewhere)
        for station in stations.prefix(12) {
            let id=lookup.tile(at:station.points[0])!.id
            try check(shortRequests.contains { $0.id==id && $0.fine && $0.pixels==1024 },"An entire short route can be prepared together")
        }

        // A repeated geographic tile has multiple ordered visits. Advancing
        // along the outbound leg cannot erase the later inbound encounter.
        let loop=[(0.0,row[2]),(500.0,row[3]),(1000.0,row[4]),(1500.0,row[3]),(2000.0,row[2])]
        let returned=try WorldFlightDetailIndex(stations:loop.map { .init(distance:$0.0,points:[$0.1.mesh.bounds.center]) },tiles:source.tiles,margin:0)
        let priorities=returned.priorities(at:1200)
        try check(priorities[row[3].id]!<priorities[row[2].id]! && priorities[row[2].id]!<priorities[row[4].id]!,"Return encounters outrank passed terrain in route order")
        let restarted=WorldWorkingSet.flightRequests(source:source,priorities:returned.priorities(at:0),center:cameraElsewhere)
        try check(restarted.first?.id==row[2].id,"Scrubbing back restores route priority without accumulated streaming state")

        // At a tile boundary, both sides must be warm before a tiny steering
        // change crosses it. Outside saved/source coverage no tile is invented.
        let edge=row[5].mesh.bounds.point(u:1,v:0.5)
        let adjacent=Set(lookup.tiles(near:edge,radius:200).map(\.id))
        try check(adjacent.contains(row[5].id) && adjacent.contains(row[6].id),"The route corridor includes both sides of a tile edge")
        try check(lookup.tiles(near:.init(latitude:0,longitude:0),radius:200).isEmpty,"Unavailable terrain is not fabricated")

        var current:[String:WorldTileRequest]=[:],maxMesh:Int64=0,maxTextures:Int64=0
        for limit in [96,192] {
            for distance in stride(from:0.0,through:length,by:120) {
                let requests=WorldWorkingSet.flightRequests(source:source,priorities:detail.priorities(at:distance),center:cameraElsewhere,meshLimit:Int64(limit)*1024*1024)
                let mesh=requests.filter(\.fine).reduce(Int64(0)) { $0+byID[$1.id]!.mesh.residentBytes }
                let textures=requests.reduce(Int64(0)) { $0+Int64(($1.pixels+8)*($1.pixels+8)*4)*4/3 }
                maxMesh=max(maxMesh,mesh);maxTextures=max(maxTextures,textures)
                try check(mesh<=Int64(limit)*1024*1024,"Route preparation respects smaller and larger fine-mesh budgets")
                try check(textures<=WorldWorkingSet.textureBudget && requests.count<=WorldWorkingSet.maximumTextures,"Whole-route preparation has bounded texture residency")
                let id=lookup.tile(at:point(distance))!.id
                try check(requests.contains { $0.id==id && $0.fine && $0.pixels==1024 },"Terrain beneath the progressing route stays detailed")
                let wanted=Dictionary(uniqueKeysWithValues:requests.map { ($0.id,$0) })
                current=current.filter { wanted[$0.key] != nil }
                for request in WorldWorkingSet.pending(wanted:requests,current:current) {
                    current[request.id]=request
                    let resident=current.values.reduce(Int64(0)) { $0+Int64(($1.pixels+8)*($1.pixels+8)*4)*4/3 }
                    try check(resident<=WorldWorkingSet.textureBudget,"Demotions precede new route pages without exceeding the texture budget")
                }
            }
        }
        // More route tiles than can remain fine at once exercise actual
        // admission/retirement, rather than an entire route that trivially fits.
        let longStations=source.tiles.enumerated().map { WorldFlightDetailStation(distance:Double($0.offset)*80,points:[$0.element.mesh.bounds.center]) }
        let longRoute=try WorldFlightDetailIndex(stations:longStations,tiles:source.tiles,margin:0)
        for step in stride(from:0,to:source.tiles.count,by:7) {
            let requests=WorldWorkingSet.flightRequests(source:source,priorities:longRoute.priorities(at:Double(step)*80),center:cameraElsewhere,meshLimit:96*1024*1024)
            let mesh=requests.filter(\.fine).reduce(Int64(0)) { $0+byID[$1.id]!.mesh.residentBytes }
            let textures=requests.reduce(Int64(0)) { $0+Int64(($1.pixels+8)*($1.pixels+8)*4)*4/3 }
            maxMesh=max(maxMesh,mesh);maxTextures=max(maxTextures,textures)
            try check(mesh<=96*1024*1024 && textures<=WorldWorkingSet.textureBudget,"Long routes keep bounded forward detail instead of loading the whole region into memory")
            try check(requests.contains { $0.id==source.tiles[step].id && $0.fine },"Long-route admission keeps the current path detailed")
            let wanted=Dictionary(uniqueKeysWithValues:requests.map { ($0.id,$0) })
            current=current.filter { wanted[$0.key] != nil }
            for request in WorldWorkingSet.pending(wanted:requests,current:current) {
                current[request.id]=request
                let bytes=current.values.reduce(Int64(0)) { $0+Int64(($1.pixels+8)*($1.pixels+8)*4)*4/3 }
                try check(bytes<=WorldWorkingSet.textureBudget,"Long-route page replacements release old large allocations first")
            }
        }
        let cancelled=Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try WorldFlightDetailIndex(stations:stations,tiles:source.tiles)
        }
        do { _=try await cancelled.value;throw RidgeError.message("Cancelled route index completed") }
        catch is CancellationError { checks+=1 }
        // Prepare actual vector pages and fine geometry from saved local files,
        // ahead of playback. There is no network-capable store in this check.
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("ridge-flight-detail-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        let reader=WorldSourceStore(bundledURL:root,cacheURL:cache,allowsNetwork:false)
        _=try await reader.manifest(address:"")
        var prepared:[String:WorldPreparedTile]=[:]
        let start=Date()
        for request in initial.prefix(3) {
            let tile=byID[request.id]!
            let ready=try await reader.prepare(tile,request:request,sourceBounds:source.frame)
            try check(ready.geometry != nil && ready.mesh != nil && ready.image.width==1032,"Upcoming route detail has a real fine mesh and 1K texture before playback")
            prepared[request.id]=ready
        }
        let pending=WorldWorkingSet.pending(wanted:initial,current:prepared.mapValues(\.request))
        try check(Set(pending.map(\.id)).isDisjoint(with:prepared.keys),"Already prepared route pages are reused instead of decoded at camera arrival")
        print("Three cache-only route tiles prepared in \(Date().timeIntervalSince(start)) s; peak mesh estimate \(maxMesh), mip textures \(maxTextures) bytes")
        print("PASS \(checks) route-first terrain, ahead preparation, repeated visits, boundaries, reuse and memory checks")
    }
}
