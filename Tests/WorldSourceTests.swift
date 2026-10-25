import Foundation
import CoreGraphics
import SceneKit
import AppKit
import simd

@main struct WorldSourceTests {
    @MainActor static func renderClose(map:WorldVectorMap,images:[(Int,CGImage)],directory:String) throws {
        let output=URL(fileURLWithPath:directory,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let lines=map.paths.filter { $0.kind=="footpath" && !$0.closed }.flatMap(\.rings).flatMap { ring in zip(ring,ring.dropFirst()).map { ($0,$1) } }
        guard let line=lines.filter({ hypot($0.1[0]-$0.0[0],$0.1[1]-$0.0[1])>10 }).min(by:{ a,b in
            hypot((a.0[0]+a.1[0])/2-map.width/2,(a.0[1]+a.1[1])/2-map.height/2)<hypot((b.0[0]+b.1[0])/2-map.width/2,(b.0[1]+b.1[1])/2-map.height/2)
        }) else { throw RidgeError.message("No footpath for close-up fixture") }
        let scene=SCNScene();scene.background.contents=NSColor(red:0.76,green:0.86,blue:0.91,alpha:1)
        let w=Float(map.width),h=Float(map.height)
        let ground=SCNGeometry(sources:[SCNGeometrySource(vertices:[SCNVector3(0,0,0),SCNVector3(w,0,0),SCNVector3(0,0,h),SCNVector3(w,0,h)]),
            SCNGeometrySource(textureCoordinates:[CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:0,y:1),CGPoint(x:1,y:1)])],
            elements:[SCNGeometryElement(indices:[Int32(0),2,1,1,2,3],primitiveType:.triangles)])
        scene.rootNode.addChildNode(SCNNode(geometry:ground))
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.fieldOfView=58;camera.camera!.zNear=0.1;camera.camera!.zFar=20000
        let center=SIMD3<Float>(Float((line.0[0]+line.1[0])/2),0,Float((line.0[1]+line.1[1])/2))
        let forward=simd_normalize(SIMD3<Float>(Float(line.1[0]-line.0[0]),0,Float(line.1[1]-line.0[1])))
        scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        for (pixels,image) in images {
            let material=SCNMaterial();material.diffuse.contents=image;material.lightingModel = .constant;material.isDoubleSided=true
            material.diffuse.minificationFilter = .linear;material.diffuse.magnificationFilter = .linear;material.diffuse.mipFilter = .linear;material.diffuse.maxAnisotropy=16
            var transform=SCNMatrix4Identity;let size=CGFloat(image.width)
            transform.m11=(size-8)/size;transform.m22=(size-8)/size;transform.m41=4/size;transform.m42=4/size;material.diffuse.contentsTransform=transform
            ground.materials=[material]
            for height: Float in [1.7,10] {
                camera.simdPosition=center+SIMD3(0,height,0)
                camera.look(at:SCNVector3(center+forward*80+SIMD3(0,height+3,0)))
                let image=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:700),antialiasingMode:.multisampling4X)
                let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
                try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("saved-map-\(pixels)-\(height).png"))
            }
        }
    }
    static func main() async throws {
        try testGroundColour()
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let source=try JSONDecoder().decode(WorldSource.self,from:Data(contentsOf:root.appendingPathComponent("world.json")))
        try source.validate();var checks=0
        func check(_ condition:Bool,_ message:String)throws{checks+=1;if !condition{throw RidgeError.message(message)}}
        let near = WorldTileRequest(id:"near",pixels:1024,fine:true)
        let far = WorldTileRequest(id:"far",pixels:256,fine:false)
        let down = WorldTileRequest(id:"down",pixels:256,fine:false)
        try check(WorldWorkingSet.pending(wanted:[near,far],current:[:]).first == near,"Nearby detail does not wait for all distant pages")
        try check(WorldWorkingSet.pending(wanted:[near,far],current:[near.id:near]).first == far,"Finished nearby detail makes way for surroundings")
        try check(WorldWorkingSet.pending(wanted:[near,down],current:[down.id:.init(id:down.id,pixels:1024,fine:true)]).first == down,"Free old high-detail allocations before increasing residency")
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
        // Flight favours bounded upload sizes and a small fine-mesh working
        // set, while preserving a textured fallback during every replacement.
        var closeCurrent:[String:WorldTileRequest]=[:]
        var closePrevious:[WorldTileRequest]=[]
        for step in 0..<48 {
            let point=source.bounds.point(u:0.2+Double(step%24)/24*0.6,v:0.45)
            let close=step<36
            let requests=WorldWorkingSet.requests(source:source,center:point,distance:300,previous:closePrevious,closePreview:close)
            let bytes=requests.reduce(Int64(0)) { $0+Int64(($1.pixels+8)*($1.pixels+8)*4)*4/3 }
            try check(bytes<=WorldWorkingSet.textureBudget,"Close-view mips stay within the existing texture budget")
            if close {
                try check(requests.first?.pixels==1024 && source.tiles.first(where:{ $0.id==requests.first?.id })?.mesh.bounds.contains(point) == true,"The moving camera gets a bounded 1K texture page")
                try check(requests.allSatisfy { $0.pixels<=1024 },"Flight never requests a large 2K/4K GPU upload")
                try check(requests.filter(\.fine).count<=6,"Only six nearby fine meshes are streamed during flight")
                try check(bytes<80*1024*1024,"Moving-flight mip residency stays below 80 MiB")
            }
            for request in WorldWorkingSet.pending(wanted:requests,current:closeCurrent) {
                closeCurrent[request.id]=request
                let resident=closeCurrent.values.reduce(Int64(0)) { $0+Int64(($1.pixels+8)*($1.pixels+8)*4)*4/3 }
                try check(resident<=WorldWorkingSet.textureBudget,"Entering, moving and leaving close preview releases old large pages before replacements")
            }
            closePrevious=requests
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
        let sharpStart=Date()
        let sharp=try WorldCartography.draw(map,pixels:4096)
        try check(sharp.width==4104 && sharp.height==4104,"Close-up vectors rasterize at 4K with the same geographic gutter")
        print("4K saved-map raster: \(Date().timeIntervalSince(sharpStart)) seconds (Mac)")
        if let index=CommandLine.arguments.firstIndex(of:"--render-close"),CommandLine.arguments.indices.contains(index+1) {
            try await MainActor.run { try renderClose(map:map,images:[(1024,high),(4096,sharp)],directory:CommandLine.arguments[index+1]) }
        }
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
        try check(backdrop.meshes.count==source.tiles.count && backdrop.geometries.count==source.tiles.count,"Entire background is adaptive")
        try check(backdropBytes<59_777_024,"Adaptive geometry is smaller than the 8 m grid")
        let backgroundCPUBytes=backdrop.meshes.values.reduce(0) { $0+$1.data.count+$1.buckets.reduce(0) { $0+$1.count*4 } }
        print("Adaptive backdrop: \(backdropBytes) geometry bytes, \(backgroundCPUBytes) CPU mesh/bucket payload bytes, \(Date().timeIntervalSince(start)) seconds off main thread")
        for tile in source.tiles {
            let background=backdrop.meshes[tile.id]!
            try check(background.chunk.maxErrorMetres<=2,"Background meets its error contract")
            try check(background.elevation(at:tile.mesh.bounds.center) != nil,"Background supports terrain picking")
        }
        var relaxed=selected.mesh;relaxed.maxErrorMetres=2
        do { try relaxed.validate();throw RidgeError.message("Legacy fine validation accepted background error") }
        catch is AdaptiveTerrainError { checks+=1 }
        var incomplete=source;incomplete.tiles[0].background=nil
        var rejectedIncomplete=false
        do { try incomplete.validate() } catch { rejectedIncomplete=true }
        try check(rejectedIncomplete,"Incomplete adaptive source is rejected")
        let previewStart=Date()
        let (preview,pages)=try await store.preview(source:opened,backdrop:backdrop)
        try check(preview.height==2048 && pages.count==source.tiles.count,"Overhead preview and warm map pages cover the same source")
        try check(pages.values.allSatisfy { !$0.request.fine && $0.request.pixels==128 },"Overview startup does not load fine terrain")
        print("Overhead preview prepared in \(Date().timeIntervalSince(previewStart)) seconds")
        let ready = try await store.prepare(selected, request:WorldTileRequest(id:selected.id,pixels:256,fine:true),sourceBounds:source.bounds)
        try check(ready.mesh != nil && ready.geometry != nil && ready.image.width == 264,"Native streamed tile")
        let heightOnly=WorldSourceStore(bundledURL:root,cacheURL:cache,allowsNetwork:false)
        _=try await heightOnly.manifest(address:"")
        let flightPoints=[selected.mesh.bounds.center,source.tiles.first(where:{$0.id != selected.id})!.mesh.bounds.center]
        let flightHeights=try await heightOnly.flightElevations(flightPoints,source:source,saved:[selected.mesh.bounds])
        try check(!heightOnly.allowsNetwork && abs((flightHeights[0] ?? -9999)-Float(ready.mesh!.elevation(at:flightPoints[0])!))<0.001,"Cache-only flight preflight samples the actual fine mesh without drawing textures")
        try check(flightHeights[1] == nil,"Flight preflight leaves unsaved terrain unavailable")
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
