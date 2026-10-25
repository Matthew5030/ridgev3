import SceneKit
import simd

/// Construct a stable basis at every heading. Browsing and manual look default
/// to a level horizon; cinematic flight can add a small, explicit bank.
enum WorldCameraOrientation {
    static func aim(_ camera: SCNNode, at target: SIMD3<Float>,bank:Float=0,up referenceUp:SIMD3<Float> = SIMD3(0,1,0)) {
        let offset = camera.simdWorldPosition - target
        guard simd_length_squared(offset) > 0.000001 else { return }
        let backward = simd_normalize(offset)
        var horizontal = simd_cross(referenceUp, backward)
        // A true vertical overview needs a deterministic north-up basis.
        if simd_length_squared(horizontal) <= 0.000001 { horizontal=simd_cross(SIMD3<Float>(0,0,-1),backward) }
        guard simd_length_squared(horizontal) > 0.000001 else { return }
        let right = simd_normalize(horizontal)
        let up = simd_cross(backward, right)
        let bankedRight=right*cos(bank)+up*sin(bank)
        let bankedUp=up*cos(bank)-right*sin(bank)
        camera.simdWorldOrientation = simd_quatf(simd_float3x3(columns:(bankedRight,bankedUp,backward)))
    }
}
