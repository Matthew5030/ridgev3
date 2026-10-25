import Foundation
import CoreGraphics
import SceneKit

/// A transient overhead view of the same terrain and cartography used in 3D.
/// It is built once per source, not published as another map-image level.
enum WorldPreview {
    static let cacheRevision="terrain-overhead-v3"
    static let sky=CGColor(srgbRed:0.76,green:0.86,blue:0.91,alpha:1)
    static func installLighting(in scene:SCNScene) {
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=400;scene.rootNode.addChildNode(ambient)
        let sun=SCNNode();sun.light=SCNLight();sun.light!.type = .directional;sun.light!.intensity=600;sun.eulerAngles=SCNVector3(-0.8,-0.7,0);scene.rootNode.addChildNode(sun)
    }
    static func material(_ image:CGImage?,gutter:Bool=true,lit:Bool=true)->SCNMaterial {
        let material=SCNMaterial();material.diffuse.contents=image ?? sky as Any
        material.lightingModel = lit ? .lambert : .constant;material.isDoubleSided=true
        material.diffuse.minificationFilter = .linear;material.diffuse.magnificationFilter = .linear;material.diffuse.mipFilter = .linear;material.diffuse.maxAnisotropy=4
        if gutter,let image {
            let size=Float(image.width);var transform=SCNMatrix4Identity
            transform.m11 = .init((size-8)/size);transform.m22 = .init((size-8)/size);transform.m41 = .init(4/size);transform.m42 = .init(4/size)
            material.diffuse.contentsTransform=transform
        }
        return material
    }
    struct Surface:@unchecked Sendable {
        var geometry:SCNGeometry
        var image:CGImage
        var bounds:GeoBounds
    }
    /// One scene, camera, material palette and lighting for all overhead output.
    /// Distant terrain fills gaps in the mesh; JPEG and vector layers are never
    /// composited directly on top of each other as separate flat map styles.
    static func overhead(viewport:GeoBounds,frame:GeoBounds,surfaces:[Surface],background:Surface?,width:Int,height:Int,transparentBackground:Bool=false) throws -> CGImage {
        let scene=SCNScene();scene.background.contents=transparentBackground ? CGColor(gray:0,alpha:0) : sky;installLighting(in:scene)
        if let background {
            background.geometry.materials=[material(background.image,gutter:false,lit:false)]
            scene.rootNode.addChildNode(SCNNode(geometry:background.geometry))
        }
        for surface in surfaces {
            guard let geometry=surface.geometry.copy() as? SCNGeometry else { continue }
            geometry.materials=[material(surface.image)]
            scene.rootNode.addChildNode(SCNNode(geometry:geometry))
        }
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.usesOrthographicProjection=true
        camera.camera!.orthographicScale=viewport.depthMeters/2;camera.camera!.projectionDirection = .vertical
        camera.camera!.zNear=1;camera.camera!.zFar=250000
        let uv=frame.uv(viewport.center)
        camera.position=SCNVector3(Float((uv.u-0.5)*frame.widthMeters),100000,Float((uv.v-0.5)*frame.depthMeters))
        camera.eulerAngles=SCNVector3(-Float.pi/2,0,0);scene.rootNode.addChildNode(camera)
        return try snapshot(scene:scene,camera:camera,width:width,height:height)
    }
    private static func snapshot(scene:SCNScene,camera:SCNNode,width:Int,height:Int) throws -> CGImage {
        let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        let image=renderer.snapshot(atTime:0,with:CGSize(width:width,height:height),antialiasingMode:.multisampling2X)
        #if canImport(UIKit)
        guard let cg=image.cgImage else { throw RidgeError.message("Could not prepare the map overview.") }
        #else
        guard let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw RidgeError.message("Could not prepare the map overview.") }
        #endif
        return cg
    }
    static func render(source: WorldSource, backdrop: WorldBackdrop, tiles: [String:WorldPreparedTile]) throws -> CGImage {
        let scene=SCNScene();scene.background.contents=CGColor(gray:0,alpha:0)
        installLighting(in:scene)
        for tile in source.tiles {
            guard let geometry=backdrop.geometries[tile.id]?.copy() as? SCNGeometry, let image=tiles[tile.id]?.image else { continue }
            let material=material(image)
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
