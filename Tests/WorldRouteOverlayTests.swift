import Foundation
import simd
import SceneKit
import AppKit
import Metal

@main struct WorldRouteOverlayTests {
    @MainActor static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let source=try JSONDecoder().decode(WorldSource.self,from:Data(contentsOf:root.appendingPathComponent("world.json")))
        var checks=0
        func check(_ pass:Bool,_ message:String)throws { checks+=1;if !pass { throw RidgeError.message(message) } }
        let point={ (u:Double,v:Double) in source.bounds.point(u:u,v:v) }
        let paths=[[point(0.3,0.4),point(0.5,0.5),point(0.7,0.4)], [point(0.7,0.65),point(0.8,0.7)]]
        func position(_ p:GeoPoint)->SIMD2<Float> { let uv=source.bounds.uv(p);return SIMD2(Float((uv.u-0.5)*source.bounds.widthMeters),Float((uv.v-0.5)*source.bounds.depthMeters)) }
        func distance(_ p:SIMD2<Float>,_ a:SIMD2<Float>,_ b:SIMD2<Float>)->Float {
            let ab=b-a;let t=max(0,min(1,simd_dot(p-a,ab)/simd_dot(ab,ab)));return simd_length(p-(a+t*ab))
        }
        let segments=paths.flatMap { p in zip(p,p.dropFirst()).map { (position($0),position($1)) } }
        let tiles=WorldRouteOverlay.build(source:source,paths:paths,waypoints:[point(0.5,0.5)])
        var shiftedCoverage = source
        shiftedCoverage.renderBounds = source.bounds
        shiftedCoverage.bounds = GeoBounds(minLatitude:source.bounds.minLatitude-0.1,minLongitude:source.bounds.minLongitude-0.1,maxLatitude:source.bounds.maxLatitude+0.1,maxLongitude:source.bounds.maxLongitude+0.1)
        let retainedInk = WorldRouteOverlay.build(source:shiftedCoverage,paths:paths,waypoints:[point(0.5,0.5)])
        try check(retainedInk.count == tiles.count,"Moving coverage retains the same route tiles")
        for (id,tile) in tiles {
            try check(retainedInk[id]?.origin == tile.origin && retainedInk[id]?.extent == tile.extent && retainedInk[id]?.records == tile.records,"Window shifts cannot move route ink away from the terrain")
        }
        var tested=0
        for tile in tiles.values {
            try check(tile.records.count>=256,"Cell table exists")
            for header in tile.records.prefix(256) {
                try check(Int(header.x+header.y)<=tile.records.count && Int(header.z+header.w)<=tile.records.count,"GPU offsets stay inside buffer")
            }
            for y in 0...64 { for x in 0...64 {
                let local=SIMD2(Float(x),Float(y))*tile.extent/64,world=tile.origin+local
                let expected=segments.map {distance(world,$0.0,$0.1)}.min()!
                if expected<=32 {
                    let bx=min(15,Int(local.x/tile.extent.x*16)),by=min(15,Int(local.y/tile.extent.y*16))
                    let header=tile.records[by*16+bx]
                    var actual=Float.infinity
                    for index in Int(header.x)..<Int(header.x+header.y) {
                        let s=tile.records[index];actual=min(actual,distance(local,SIMD2(s.x,s.y),SIMD2(s.z,s.w)))
                    }
                    try check(abs(expected-actual)<0.01,"Spatial bins preserve route across every tile edge/cell")
                    tested+=1
                }
            } }
        }
        try check(tested>1000,"Test covers the route corridor")
        try check(WorldRouteOverlay.build(source:source,paths:[],waypoints:[]).isEmpty,"Clearing route removes all ink")
        try check(WorldRouteOverlay.build(source:source,paths:[[point(0.5,0.5),point(0.5,0.5)]],waypoints:[]).isEmpty,"Duplicate points do not create invalid shader segments")
        let disconnected=WorldRouteOverlay.build(source:source,paths:[[point(0.2,0.2),point(0.3,0.2)],[point(0.7,0.2),point(0.8,0.2)]],waypoints:[])
        let gap=source.tiles.first(where:{$0.mesh.bounds.contains(point(0.5,0.2))})!
        try check(disconnected[gap.id]==nil,"Disconnected GPX sections are never joined")
        let crossing=WorldRouteOverlay.build(source:source,paths:[[point(-1,0.5),point(2,0.5)]],waypoints:[])
        try check(!crossing.isEmpty,"Long off-source segment is clipped without losing crossing")
        let markers=WorldRouteOverlay.build(source:source,paths:[],waypoints:[point(0.5,0.5)])
        try check(markers.count==4,"Waypoint on a four-tile corner reaches every neighbour")
        // Render the real Metal modifier: compilation failures paint magenta,
        // which a Swift-only build cannot catch. Verify width and depth occlusion.
        let testTile=source.tiles.first(where:{$0.id=="c08-r08"})!
        let ends=[testTile.mesh.bounds.point(u:0.1,v:0.5),testTile.mesh.bounds.point(u:0.9,v:0.5)]
        let inkTile=WorldRouteOverlay.build(source:source,paths:[ends],waypoints:[])[testTile.id]!
        let device=MTLCreateSystemDefaultDevice()!
        let binding=WorldRouteOverlay.binding(inkTile,device:device)!
        let scene=SCNScene();scene.background.contents=NSColor.black
        let material=SCNMaterial();material.diffuse.contents=NSColor.green;material.lightingModel = .constant;material.isDoubleSided=true
        binding.apply(to:material,pixelScale:1)
        let o=inkTile.origin,e=inkTile.extent
        let p=[SCNVector3(o.x,0,o.y),SCNVector3(o.x+e.x,0,o.y),SCNVector3(o.x,0,o.y+e.y),SCNVector3(o.x+e.x,0,o.y+e.y)]
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:p)],elements:[SCNGeometryElement(indices:[Int32(0),2,1,1,2,3],primitiveType:.triangles)])
        geometry.materials=[material];let ground=SCNNode(geometry:geometry);scene.rootNode.addChildNode(ground)
        let center=SIMD3<Float>(o.x+e.x/2,0,o.y+e.y/2)
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.fieldOfView=43;camera.camera!.zNear=1;camera.camera!.zFar=5000;scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        func render(_ height:Float)->NSBitmapImageRep {
            camera.simdPosition=center+SIMD3(0,height,10);WorldCameraOrientation.aim(camera,at:center)
            return NSBitmapImageRep(data:renderer.snapshot(atTime:0,with:CGSize(width:400,height:400),antialiasingMode:.multisampling4X).tiffRepresentation!)!
        }
        func colour(_ image:NSBitmapImageRep,_ x:Int,_ y:Int)->NSColor { image.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)! }
        func red(_ c:NSColor)->Bool { c.redComponent>0.6 && c.redComponent>c.greenComponent*1.4 && c.redComponent>c.blueComponent*1.4 }
        let near=render(600),far=render(1200)
        let nearWidth=(0..<400).filter {red(colour(near,200,$0))}.count
        let farWidth=(0..<400).filter {red(colour(far,200,$0))}.count
        try check((3...7).contains(nearWidth) && abs(nearWidth-farWidth)<=1,"Route keeps its pixel width through zoom; shader actually renders")
        let obstacle=SCNNode(geometry:SCNBox(width:80,height:80,length:80,chamferRadius:0));obstacle.simdPosition=center+SIMD3(0,40,0)
        let blue=SCNMaterial();blue.diffuse.contents=NSColor.blue;blue.lightingModel = .constant;obstacle.geometry!.materials=[blue];scene.rootNode.addChildNode(obstacle)
        let blocked=colour(render(600),200,200)
        try check(blocked.blueComponent>0.8 && blocked.redComponent<0.2,"Foreground geometry occludes route naturally")
        obstacle.removeFromParentNode()
        material.shaderModifiers=nil;material.setValue(nil,forKey:"ridgeRouteRecords")
        let cleared=colour(render(600),200,200)
        try check(cleared.greenComponent>0.8 && cleared.redComponent<0.2,"Clearing route removes shader ink from the terrain")
        // Reuse the exact vector buffer on a replacement terrain surface/material.
        let replacement=SCNMaterial();replacement.diffuse.contents=NSColor.green;replacement.lightingModel = .constant;replacement.isDoubleSided=true
        binding.apply(to:replacement,pixelScale:1)
        let raised=SCNGeometry(sources:[SCNGeometrySource(vertices:p.map { SCNVector3($0.x,30,$0.z) })],elements:geometry.elements)
        raised.materials=[replacement];ground.geometry=raised
        let replaced=render(600)
        try check((196...204).contains(where:{red(colour(replaced,200,$0))}),"Terrain replacement keeps route attached without rebuilding vector data")
        print("Rendered route width: \(nearWidth) px near / \(farWidth) px far; occlusion and clearing verified")
        print("PASS \(checks) route overlay checks; \(tested) corridor samples")
    }
}
