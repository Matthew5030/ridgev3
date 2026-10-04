import Foundation
import SceneKit
import AppKit

@main struct BackgroundStudy {
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), output=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let store=WorldSourceStore(bundledURL:root)
        let (source,overview,_)=try await store.open(address:"")
        let background=try await store.backdrop(source:source,overview:overview)
        var images:[String:CGImage]=[:]
        for tile in source.tiles {
            images[tile.id]=try await store.prepare(tile,request:WorldTileRequest(id:tile.id,pixels:512,fine:false),sourceBounds:source.bounds).image
        }
        try await MainActor.run {
            for adaptive in [false,true] {
                let scene=SCNScene();scene.background.contents=NSColor(calibratedRed:0.76,green:0.87,blue:0.94,alpha:1)
                let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=400;scene.rootNode.addChildNode(ambient)
                let sun=SCNNode();sun.light=SCNLight();sun.light!.type = .directional;sun.light!.intensity=600;sun.eulerAngles=SCNVector3(-0.8,-0.7,0);scene.rootNode.addChildNode(sun)
                for tile in source.tiles {
                    let geometry=adaptive ? background.geometries[tile.id]! : WorldGeometry.coarse(tile:tile,source:source,overview:overview)
                    let material=SCNMaterial();material.diffuse.contents=images[tile.id]!;material.lightingModel = .lambert;material.isDoubleSided=true
                    material.diffuse.minificationFilter = .linear;material.diffuse.magnificationFilter = .linear;material.diffuse.mipFilter = .linear
                    material.diffuse.maxAnisotropy=16
                    let pixels=512.0,gutter=4.0,total=pixels+2*gutter
                    material.diffuse.contentsTransform=SCNMatrix4Mult(SCNMatrix4MakeScale(pixels/total,pixels/total,1),SCNMatrix4MakeTranslation(gutter/total,gutter/total,0))
                    geometry.materials=[material];scene.rootNode.addChildNode(SCNNode(geometry:geometry))
                }
                let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.fieldOfView=43;camera.camera!.zNear=2;camera.camera!.zFar=60000;scene.rootNode.addChildNode(camera)
                let targetPoint=source.places.first(where:{$0.name=="Crib Goch"})!.coordinate
                let uv=source.bounds.uv(targetPoint)
                let target=SIMD3<Float>(Float((uv.u-0.5)*source.bounds.widthMeters),overview.elevation(targetPoint,bounds:source.bounds),Float((uv.v-0.5)*source.bounds.depthMeters))
                let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
                for (label,offset) in [("wide",SIMD3<Float>(1000,2300,3600)),("ridge",SIMD3<Float>(100,500,950))] {
                    camera.simdPosition=target+offset;WorldCameraOrientation.aim(camera,at:target)
                    let snapshot=renderer.snapshot(atTime:0,with:CGSize(width:1600,height:1100),antialiasingMode:.multisampling4X)
                    let bitmap=NSBitmapImageRep(data:snapshot.tiffRepresentation!)!
                    try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("\(adaptive ? "adaptive-2m" : "grid-8m")-\(label).png"))
                }
            }
        }
        print("Rendered fixed-camera grid/adaptive comparisons")
    }
}
