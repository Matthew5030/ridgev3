import Foundation
import SceneKit
import AppKit
@main struct WorldDistantTerrainTests {
    static func main() async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent()
        let store=WorldDistantTerrainStore(root:resources.appendingPathComponent("WorldContext.bundle"),atlas:resources.appendingPathComponent("WorldAtlas.bundle"))
        let center=GeoPoint(latitude:53.0685,longitude:-4.0763)
        let frame=WorldDistantTerrain.pageBounds(x:500,y:333)
        let start=Date()
        guard let terrain=try await store.build(center:center,frame:frame) else { fatalError("Missing bundled context") }
        var checks=0
        func check(_ condition:Bool,_ text:String) { precondition(condition,text);checks+=1 }
        check(terrain.image.width==2048 && terrain.image.height==2048,"Bounded one-texture context")
        check(terrain.cells.count==81*48*48,"Bounded surface including sea/context")
        let full=terrain.geometry(excluding:[])
        check(full.elements.count==1,"One terrain draw element")
        check(full.elements[0].primitiveCount==81*48*48*2,"Complete uncut surface")
        let key="500:333:20:11",cell=terrain.cells.first { $0.key==key }!
        let cut=terrain.geometry(excluding:[key])
        check(cut.elements[0].primitiveCount==full.elements[0].primitiveCount-2,"Only the loaded cell is removed")
        let b=frame,a=b.point(u:20.0/48,v:11.0/48),z=b.point(u:21.0/48,v:12.0/48)
        let tile=GeoBounds(minLatitude:z.latitude,minLongitude:a.longitude,maxLatitude:a.latitude,maxLongitude:z.longitude)
        check(WorldDistantTerrain.key(for:tile)==key,"Detailed-grid alignment")
        check(WorldDistantTerrain.key(for:frame)==nil,"Larger or partial coverage never punches a false hole")
        check(cell.indices.count==6,"Exactly one coarse cell per detailed tile")
        let corners=cell.indices.prefix(3).map { terrain.positions[Int($0)] }
        let corner4=terrain.positions[Int(cell.indices.last!)]
        var elevated=[corners[0],corners[2],corners[1],corner4]
        for i in elevated.indices { elevated[i].y=2000 }
        let testGeometry=WorldGeometry.build(positions:elevated,uv:[CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:0,y:1),CGPoint(x:1,y:1)],indices:[0,2,1,1,2,3])
        let allSides=terrain.seams([.init(key:key,geometry:testGeometry)],covered:[key])
        check(allSides?.elements[0].primitiveCount==8,"All four exposed edges are stitched to real coarse elevations")
        let neighbors=Set((0..<4).map { WorldDistantTerrain.neighbor(key,edge:$0) }).union([key])
        check(terrain.seams([.init(key:key,geometry:testGeometry)],covered:neighbors)==nil,"No seam walls between adjacent detailed tiles")
        check(WorldDistantTerrain.neighbor("500:333:0:0",edge:0)=="499:333:47:0","Seams cross storage boundaries correctly")

        let bytes=full.sources.reduce(0){$0+$1.data.count}+full.elements.reduce(0){$0+$1.data.count}
        check(bytes<16*1024*1024,"Geometry within 16 MiB")
        let index=try JSONSerialization.jsonObject(with:Data(contentsOf:resources.appendingPathComponent("WorldContext.bundle/index.json"))) as! [String:Any]
        let parts=index["parts"] as! [[String:Any]]
        for part in parts {
            let path=resources.appendingPathComponent("WorldContext.bundle").appendingPathComponent(part["file"] as! String)
            let data=try Data(contentsOf:path)
            check(data.count==49*49*2 && AdaptiveTerrainCodec.hash(data)==part["sha256"] as! String,"Verified bundled elevation")
        }
        let root=try WorldLibrary.root(mode:"local",local:"http://127.0.0.1:8787")
        let catalog=try await WorldCatalogStore().open(root:root)
        let region=catalog.region(at:center)!
        let source=try await WorldSourceStore().manifest(address:root.appendingPathComponent(region.path).absoluteString)
        for tile in source.tiles { check(WorldDistantTerrain.key(for:tile.mesh.bounds) != nil,"Actual published terrain aligns with context holes") }
        if CommandLine.arguments.count>2 {
            let output=URL(fileURLWithPath:CommandLine.arguments[2]);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let window=WorldLandscapeStore()
            let (near,_,_,background,pages)=try await window.window(center:center,radius:3500,frame:frame,catalog:catalog,root:root,previous:nil)
            try await MainActor.run {
                let scene=SCNScene();scene.background.contents=NSColor(calibratedRed:0.76,green:0.86,blue:0.91,alpha:1)
                let context=SCNNode();scene.rootNode.addChildNode(context)
                let m=SCNMaterial();m.lightingModel = .constant;m.diffuse.contents=terrain.image;m.isDoubleSided=true
                context.geometry=terrain.geometry(excluding:[]);context.geometry?.materials=[m]
                let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.fieldOfView=43;camera.camera!.zNear=2;camera.camera!.zFar=150000;scene.rootNode.addChildNode(camera)
                let s=frame.uv(center),target=SIMD3<Float>(Float((s.u-0.5)*frame.widthMeters),500,Float((s.v-0.5)*frame.depthMeters))
                camera.simdPosition=target+SIMD3(1000,1800,6500);WorldCameraOrientation.aim(camera,at:target)
                let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
                func save(_ name:String) throws {
                    let result=renderer.snapshot(atTime:0,with:CGSize(width:1500,height:1000),antialiasingMode:.multisampling4X)
                    try NSBitmapImageRep(data:result.tiffRepresentation!)!.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
                }
                try save("context-only")
                let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=400;scene.rootNode.addChildNode(ambient)
                let sun=SCNNode();sun.light=SCNLight();sun.light!.type = .directional;sun.light!.intensity=600;sun.eulerAngles=SCNVector3(-0.8,-0.7,0);scene.rootNode.addChildNode(sun)
                for tile in near.tiles {
                    let geometry=background.geometries[tile.id]!,material=SCNMaterial();material.diffuse.contents=pages[tile.id]!.image;material.lightingModel = .lambert;material.isDoubleSided=true
                    var t=SCNMatrix4Identity;t.m11=32.0/40;t.m22=32.0/40;t.m41=4.0/40;t.m42=4.0/40;material.diffuse.contentsTransform=t
                    geometry.materials=[material];scene.rootNode.addChildNode(SCNNode(geometry:geometry))
                }
                context.geometry=terrain.geometry(excluding:Set(near.tiles.compactMap { WorldDistantTerrain.key(for:$0.mesh.bounds) }));context.geometry?.materials=[m]
                let covered=Set(near.tiles.compactMap { WorldDistantTerrain.key(for:$0.mesh.bounds) })
                let boundaries=near.tiles.compactMap { tile -> WorldDistantTerrain.Boundary? in
                    guard let key=WorldDistantTerrain.key(for:tile.mesh.bounds) else { return nil }
                    return .init(key:key,geometry:background.geometries[tile.id]!)
                }
                let seams=terrain.seams(boundaries,covered:covered);seams?.materials=[m];scene.rootNode.addChildNode(SCNNode(geometry:seams))
                try save("detail-over-context")
                // Synthetic saved extent on real terrain, not a claim about
                // this machine's offline downloads. Exercise the actual shader.
                let saved=GeoBounds(minLatitude:center.latitude-0.06,minLongitude:center.longitude-0.06,maxLatitude:center.latitude+0.06,maxLongitude:center.longitude+0.008)
                let boundary=WorldOfflineBoundary.geometry(edges:WorldOfflineCoverage.outline([saved]),focus:center,frame:frame) { point in
                    guard let tile=near.tiles.first(where:{$0.mesh.bounds.contains(point)}),let mesh=background.meshes[tile.id],let h=mesh.elevation(at:point) else { return 0 }
                    return Float(h)
                }
                boundary?.firstMaterial?.setValue(NSValue(scnVector4:SCNVector4(target.x,target.z,1,0)),forKey:"ridgeBoundaryFocus")
                scene.rootNode.addChildNode(SCNNode(geometry:boundary))
                try save("offline-boundary")
                camera.simdPosition=target+SIMD3(3000,1800,2500);WorldCameraOrientation.aim(camera,at:target)
                try save("offline-boundary-side")
            }
        }
        print("PASS \(checks) distant terrain checks; geometry \(bytes) bytes, local preparation \(Date().timeIntervalSince(start)) s")
    }
}
