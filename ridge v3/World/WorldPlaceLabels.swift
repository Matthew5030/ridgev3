import UIKit
import SceneKit
import simd

/// Names are part of the scene, so camera and text use the same rendered frame.
/// Selection changes only after navigation settles; terrain can occlude names.
@MainActor final class WorldPlaceLabels {
    private struct Label {
        var node: SCNNode
        var size: CGSize
        var name: String
    }
    private var labels: [String:Label] = [:]

    func reconcile(places: [MapPlace], scene: SCNScene, position: (GeoPoint) -> SIMD3<Float>) {
        let keep = Set(places.map(\.id))
        for id in Array(labels.keys) where !keep.contains(id) {
            labels.removeValue(forKey:id)?.node.removeFromParentNode()
        }
        for place in places {
            if labels[place.id]?.name != place.name {
                labels.removeValue(forKey:place.id)?.node.removeFromParentNode()
                labels[place.id] = makeLabel(place.name)
            }
            guard let label = labels[place.id] else { continue }
            var p = position(place.coordinate); p.y += 8
            label.node.simdPosition = p
            if label.node.parent !== scene.rootNode { scene.rootNode.addChildNode(label.node) }
        }
    }

    func scale(camera: SCNNode, viewport: CGSize) {
        let forward = camera.simdWorldFront
        let factor = 2 * tan(Float(camera.camera?.fieldOfView ?? 43) * .pi/360) / Float(max(1,viewport.height))
        for label in labels.values {
            let depth = simd_dot(label.node.simdPosition-camera.simdPosition,forward)
            let size = max(0.01,depth*factor)
            label.node.simdScale = SIMD3(repeating:size)
        }
    }

    func select(in view: SCNView, focus: SIMD3<Float>) {
        var occupied: [CGRect] = []
        // Prefer already visible names to prevent small changes swapping labels.
        let ranked = labels.sorted {
            let a = simd_distance($0.value.node.simdPosition,focus) - ($0.value.node.isHidden ? 0 : 600)
            let b = simd_distance($1.value.node.simdPosition,focus) - ($1.value.node.isHidden ? 0 : 600)
            return a == b ? $0.key < $1.key : a < b
        }
        for (_,label) in ranked {
            let p = view.projectPoint(label.node.position)
            let rect = CGRect(x:CGFloat(p.x)-label.size.width/2,y:CGFloat(p.y)-label.size.height,width:label.size.width,height:label.size.height)
            let visible = p.z > 0 && p.z < 1 && view.bounds.insetBy(dx:16,dy:16).contains(rect)
                && occupied.count < 12 && !occupied.contains { $0.intersects(rect.insetBy(dx:-12,dy:-8)) }
            label.node.isHidden = !visible
            if visible { occupied.append(rect) }
        }
    }

    private func makeLabel(_ name: String) -> Label {
        var attributes: [NSAttributedString.Key:Any] = [
            .font: UIFont.systemFont(ofSize:14,weight:.semibold),
            .foregroundColor: UIColor(red:0.16,green:0.21,blue:0.19,alpha:1),
            .strokeColor: UIColor(white:1,alpha:0.92), .strokeWidth: -3
        ]
        let outline = NSAttributedString(string:name,attributes:attributes)
        attributes.removeValue(forKey:.strokeColor); attributes.removeValue(forKey:.strokeWidth)
        let text = NSAttributedString(string:name,attributes:attributes)
        let measured = text.boundingRect(with:CGSize(width:180,height:80),options:[.usesLineFragmentOrigin,.usesFontLeading],context:nil)
        let size = CGSize(width:ceil(measured.width)+8,height:ceil(measured.height)+12)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
        let image = UIGraphicsImageRenderer(size:size,format:format).image { context in
            let rect = CGRect(x:4,y:2,width:size.width-8,height:size.height-10)
            outline.draw(with:rect,options:[.usesLineFragmentOrigin,.usesFontLeading],context:nil)
            text.draw(with:rect,options:[.usesLineFragmentOrigin,.usesFontLeading],context:nil)
            UIColor(white:1,alpha:0.9).setFill()
            context.cgContext.fillEllipse(in:CGRect(x:size.width/2-2.5,y:size.height-6,width:5,height:5))
            UIColor(red:0.16,green:0.21,blue:0.19,alpha:1).setFill()
            context.cgContext.fillEllipse(in:CGRect(x:size.width/2-1.5,y:size.height-5,width:3,height:3))
        }
        let material = SCNMaterial(); material.lightingModel = .constant
        material.diffuse.contents = image; material.isDoubleSided = true
        material.readsFromDepthBuffer = true; material.writesToDepthBuffer = false
        material.diffuse.mipFilter = .linear
        let plane = SCNPlane(width:size.width,height:size.height); plane.materials = [material]
        let child = SCNNode(geometry:plane); child.position.y = Float(size.height/2)
        child.categoryBitMask = 2
        let node = SCNNode(); node.addChildNode(child); node.isHidden = true; node.categoryBitMask = 2
        let billboard = SCNBillboardConstraint(); billboard.freeAxes = .all; node.constraints = [billboard]
        return Label(node:node,size:size,name:name)
    }
}
