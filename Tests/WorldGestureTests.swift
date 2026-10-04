import Foundation
import SceneKit
import simd

@main struct WorldGestureTests {
    static func main() throws {
        var count=0
        func check(_ value:Bool,_ message:String) throws {
            count+=1
            if !value { throw NSError(domain:message,code:1) }
        }
        let a=CGPoint(x:100,y:100),b=CGPoint(x:300,y:100)
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:101,y:102),b:CGPoint(x:300,y:103)) == .undecided,"Touch jitter must not tilt")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:100,y:130),b:CGPoint(x:300,y:130)) == .tilt,"Parallel vertical motion tilts")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:80,y:125),b:CGPoint(x:320,y:125)) == .transform,"Off-centre pinch must not tilt")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:110,y:80),b:CGPoint(x:290,y:120)) == .transform,"Twist changes heading without entering tilt mode")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:130,y:104),b:CGPoint(x:330,y:104)) == .transform,"Horizontal two-finger translation must not orbit")
        // Both orientations and both zoom directions, with a moving midpoint.
        for direction in [-1.0,1.0] {
            for angle in stride(from:0.0,to:6.28,by:0.2) {
                let dx=cos(angle)*100,dy=sin(angle)*100
                let p=CGPoint(x:200-dx,y:200-dy),q=CGPoint(x:200+dx,y:200+dy)
                let factor=1+direction*0.15
                let u=CGPoint(x:204-dx*factor,y:230-dy*factor),v=CGPoint(x:204+dx*factor,y:230+dy*factor)
                try check(WorldGestureIntent.resolve(startA:p,startB:q,a:u,b:v) == .transform,"Rotated pinch must keep its camera pitch")
            }
        }
        // Check the real camera orientation over a full turn and the usable tilt
        // range: its screen-right vector must remain horizontal (no roll).
        let camera=SCNNode()
        for yaw in stride(from:Float(-Float.pi),through:Float.pi,by:0.15) {
            for pitch: Float in [0.3,0.85,1.49] {
                camera.simdPosition=SIMD3(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))*1000
                WorldCameraOrientation.aim(camera,at:.zero)
                let right=camera.simdWorldTransform.columns.0
                let front = -SIMD3(camera.simdWorldTransform.columns.2.x,camera.simdWorldTransform.columns.2.y,camera.simdWorldTransform.columns.2.z)
                try check(abs(right.y)<0.00001,"Camera must not roll while turning")
                try check(simd_dot(front,simd_normalize(-camera.simdPosition))>0.9999,"Camera must face the orbit target")
            }
        }
        print("PASS \(count) gesture and camera checks")
    }
}
