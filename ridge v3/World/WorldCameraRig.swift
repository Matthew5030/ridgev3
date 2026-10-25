import SceneKit
import simd

/// A single camera writer. Terrain uploads may update a scene while a tour is
/// waiting for detail; they must never replace its last pose with an orbit.
final class WorldCameraRig {
    struct Pose {
        var eye: SIMD3<Float>
        var look: SIMD3<Float>
        var fieldOfView: Double = 58
        var near: Double = 2
        var bank: Float = 0
        var up: SIMD3<Float> = SIMD3(0,1,0)
    }
    private(set) var touring=false
    private(set) var heldPose: Pose?

    func beginTour(on camera: SCNNode) {
        guard !touring else { return }
        let forward = -SIMD3(camera.simdWorldTransform.columns.2.x,camera.simdWorldTransform.columns.2.y,camera.simdWorldTransform.columns.2.z)
        heldPose=Pose(eye:camera.simdWorldPosition,look:camera.simdWorldPosition+forward*80,
                      fieldOfView:Double(camera.camera?.fieldOfView ?? 43),near:camera.camera?.zNear ?? 2)
        touring=true
    }
    func endTour() { touring=false;heldPose=nil }
    @discardableResult func orbit(on camera: SCNNode, eye: SIMD3<Float>, look: SIMD3<Float>) -> Bool {
        guard !touring else { return false }
        write(Pose(eye:eye,look:look,fieldOfView:Double(camera.camera?.fieldOfView ?? 43),near:camera.camera?.zNear ?? 2),to:camera)
        return true
    }
    func fly(on camera: SCNNode, pose: Pose) {
        guard touring else { return }
        heldPose=pose;write(pose,to:camera)
    }
    func restoreTour(on camera: SCNNode) {
        if touring,let pose=heldPose { write(pose,to:camera) }
    }
    func rebaseTour(from old: GeoBounds,to next: GeoBounds,on camera: SCNNode) {
        guard touring,var pose=heldPose,old != next else { return }
        func convert(_ value: SIMD3<Float>)->SIMD3<Float> {
            let point=old.point(u:Double(value.x)/old.widthMeters+0.5,v:Double(value.z)/old.depthMeters+0.5)
            let uv=next.uv(point)
            return SIMD3(Float((uv.u-0.5)*next.widthMeters),value.y,Float((uv.v-0.5)*next.depthMeters))
        }
        pose.eye=convert(pose.eye);pose.look=convert(pose.look);heldPose=pose;write(pose,to:camera)
    }
    private func write(_ pose: Pose,to camera: SCNNode) {
        SCNTransaction.begin();SCNTransaction.animationDuration=0
        camera.camera?.fieldOfView=CGFloat(pose.fieldOfView);camera.camera?.zNear=pose.near
        camera.simdPosition=pose.eye;WorldCameraOrientation.aim(camera,at:pose.look,bank:pose.bank,up:pose.up)
        SCNTransaction.commit()
    }
}
