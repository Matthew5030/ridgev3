import SceneKit
import simd

/// Construct the camera basis explicitly: screen-right is horizontal at every
/// heading. Pitch changes the view direction, never banks the horizon.
enum WorldCameraOrientation {
    static func aim(_ camera: SCNNode, at target: SIMD3<Float>) {
        let offset = camera.simdWorldPosition - target
        guard simd_length_squared(offset) > 0.000001 else { return }
        let backward = simd_normalize(offset)
        let horizontal = simd_cross(SIMD3<Float>(0,1,0), backward)
        guard simd_length_squared(horizontal) > 0.000001 else { return }
        let right = simd_normalize(horizontal)
        let up = simd_cross(backward, right)
        camera.simdWorldOrientation = simd_quatf(simd_float3x3(columns:(right,up,backward)))
    }
}
