import Foundation
import CoreGraphics
import SceneKit

/// A transient overhead view of the same terrain and cartography used in 3D.
/// It is built once per source, not published as another map-image level.
enum WorldPreview {
    static func render(source: WorldSource, backdrop: WorldBackdrop, tiles: [String:WorldPreparedTile]) throws -> CGImage {
        let scene=SCNScene();scene.background.contents=CGColor(gray:0,alpha:0)
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=400;scene.rootNode.addChildNode(ambient)
        let sun=SCNNode();sun.light=SCNLight();sun.light!.type = .directional;sun.light!.intensity=600;sun.eulerAngles=SCNVector3(-0.8,-0.7,0);scene.rootNode.addChildNode(sun)
        for tile in source.tiles {
            guard let geometry=backdrop.geometries[tile.id]?.copy() as? SCNGeometry, let image=tiles[tile.id]?.image else { continue }
            let material=SCNMaterial();material.diffuse.contents=image;material.lightingModel = .lambert;material.isDoubleSided=true
            material.diffuse.minificationFilter = .linear;material.diffuse.magnificationFilter = .linear;material.diffuse.mipFilter = .linear
            let size=Float(image.width);var transform=SCNMatrix4Identity
            transform.m11 = .init((size-8)/size);transform.m22 = .init((size-8)/size);transform.m41 = .init(4/size);transform.m42 = .init(4/size);material.diffuse.contentsTransform=transform
            geometry.materials=[material];scene.rootNode.addChildNode(SCNNode(geometry:geometry))
        }
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.usesOrthographicProjection=true
        camera.camera!.orthographicScale=source.bounds.depthMeters/2;camera.camera!.zNear=1;camera.camera!.zFar=20000
        let uv = source.frame.uv(source.bounds.center)
        camera.simdPosition=SIMD3<Float>(Float((uv.u-0.5)*source.frame.widthMeters),10000,Float((uv.v-0.5)*source.frame.depthMeters));camera.eulerAngles=SCNVector3(-Float.pi/2,0,0);scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        let image=renderer.snapshot(atTime:0,with:CGSize(width:2048*source.bounds.widthMeters/source.bounds.depthMeters,height:2048),antialiasingMode:.multisampling4X)
        #if canImport(UIKit)
        guard let cg=image.cgImage else { throw RidgeError.message("Could not prepare the map overview.") }
        #else
        guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw RidgeError.message("Could not prepare the map overview.") }
        #endif
        return cg
    }
}
