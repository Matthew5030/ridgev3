import Foundation
import SceneKit
import AppKit
import Metal

@main struct BackgroundStudy {
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), output=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let store=WorldSourceStore(bundledURL:root)
        let (source,overview,graph)=try await store.open(address:"")
        let background=try await store.backdrop(source:source,overview:overview)
        var images:[String:CGImage]=[:]
        for tile in source.tiles {
            images[tile.id]=try await store.prepare(tile,request:WorldTileRequest(id:tile.id,pixels:512,fine:false),sourceBounds:source.bounds).image
        }
        let routeMode=CommandLine.arguments.contains("--route")
        let start=source.places.first(where:{$0.name=="Crib Goch"})!.coordinate
        let end=source.places.first(where:{$0.name=="Yr Wyddfa"})!.coordinate
        let path=routeMode ? try RouteEngine.walkingSegment(from:start,to:end,graph:graph).points.map(\.coordinate) : []
        let routeTiles=WorldRouteOverlay.build(source:source,paths:[path],waypoints:routeMode ? [start,end] : [])
        let device=MTLCreateSystemDefaultDevice()!
        let bindings=routeTiles.compactMapValues { WorldRouteOverlay.binding($0,device:device) }
        var fine:[String:SCNGeometry]=[:]
        if routeMode {
            for request in WorldWorkingSet.requests(source:source,center:start,distance:1800).filter(\.fine) {
                let tile=source.tiles.first(where:{$0.id==request.id})!
                fine[tile.id]=try await store.prepare(tile,request:request,sourceBounds:source.bounds).geometry
            }
            print("Route: \(path.count) points; \(routeTiles.count) tiles; \(routeTiles.values.reduce(0) {$0+$1.records.count*16}) buffer bytes; largest bucket \(routeTiles.values.map(\.largestBucket).max() ?? 0)")
        }
        try await MainActor.run {
            for adaptive in [false,true] {
                let scene=SCNScene();scene.background.contents=NSColor(calibratedRed:0.76,green:0.87,blue:0.94,alpha:1)
                let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=400;scene.rootNode.addChildNode(ambient)
                let sun=SCNNode();sun.light=SCNLight();sun.light!.type = .directional;sun.light!.intensity=600;sun.eulerAngles=SCNVector3(-0.8,-0.7,0);scene.rootNode.addChildNode(sun)
                for tile in source.tiles {
                    let geometry=routeMode ? (adaptive ? (fine[tile.id] ?? background.geometries[tile.id]!) : background.geometries[tile.id]!) : (adaptive ? background.geometries[tile.id]! : WorldGeometry.coarse(tile:tile,source:source,overview:overview))
                    let material=SCNMaterial();material.diffuse.contents=images[tile.id]!;material.lightingModel = .lambert;material.isDoubleSided=true
                    material.diffuse.minificationFilter = .linear;material.diffuse.magnificationFilter = .linear;material.diffuse.mipFilter = .linear
                    material.diffuse.maxAnisotropy=16
                    let pixels=512.0,gutter=4.0,total=pixels+2*gutter
                    material.diffuse.contentsTransform=SCNMatrix4Mult(SCNMatrix4MakeScale(pixels/total,pixels/total,1),SCNMatrix4MakeTranslation(gutter/total,gutter/total,0))
                    bindings[tile.id]?.apply(to:material,pixelScale:1)
                    geometry.materials=[material];scene.rootNode.addChildNode(SCNNode(geometry:geometry))
                }
                let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.fieldOfView=43;camera.camera!.zNear=2;camera.camera!.zFar=60000;scene.rootNode.addChildNode(camera)
                let targetPoint=source.places.first(where:{$0.name=="Crib Goch"})!.coordinate
                let uv=source.bounds.uv(targetPoint)
                let target=SIMD3<Float>(Float((uv.u-0.5)*source.bounds.widthMeters),overview.elevation(targetPoint,bounds:source.bounds),Float((uv.v-0.5)*source.bounds.depthMeters))
                let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=camera
                for (label,offset) in [("wide",SIMD3<Float>(1000,2300,3600)),("ridge",SIMD3<Float>(100,500,950)),("low",SIMD3<Float>(800,150,1400)),("overhead",SIMD3<Float>(0,5000,20))] {
                    camera.simdPosition=target+offset;WorldCameraOrientation.aim(camera,at:target)
                    let snapshot=renderer.snapshot(atTime:0,with:CGSize(width:1600,height:1100),antialiasingMode:.multisampling4X)
                    let bitmap=NSBitmapImageRep(data:snapshot.tiffRepresentation!)!
                    try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(routeMode ? (adaptive ? "route-fine" : "route-background") : (adaptive ? "adaptive-2m" : "grid-8m"))-\(label).png"))
                }
            }
        }
        print("Rendered fixed-camera grid/adaptive comparisons")
    }
}
