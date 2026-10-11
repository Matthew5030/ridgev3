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
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:100,y:130),b:CGPoint(x:300,y:130)) == .angle,"Parallel vertical motion tilts")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:80,y:125),b:CGPoint(x:320,y:125)) == .transform,"Off-centre pinch must not tilt")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:110,y:80),b:CGPoint(x:290,y:120)) == .transform,"Twist must not enter viewing-angle mode")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:130,y:104),b:CGPoint(x:330,y:104)) == .angle,"Horizontal two-finger drag changes heading")
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
        func finger(_ id:Int,_ x:Double,_ y:Double) -> WorldGestureMotion.Finger { .init(id:id,point:CGPoint(x:x,y:y)) }
        var motion=WorldGestureMotion()
        try check(motion.update([finger(1,100,100)]) == .rebase && !motion.recognized,"A stationary first touch must still permit a route tap")
        try check(motion.update([finger(1,102,101)]) == .none,"One-finger jitter does not move the camera")
        try check(motion.update([finger(1,110,100)]) == .rebase && motion.recognized,"Pan begins without replaying the recognition threshold")
        try check(motion.update([finger(1,115,103)]) == .pan(CGPoint(x:110,y:100),CGPoint(x:115,y:103)),"Pan applies only new movement")
        try check(motion.update([finger(1,115,103),finger(2,300,103)]) == .rebase,"Adding a distant second finger cannot jump the camera")
        _=motion.update([finger(1,95,103),finger(2,320,103)])
        try check(motion.intent == .transform,"Pinch takes over an existing pan")
        if case let .zoom(_,_,scale)=motion.update([finger(2,330,103),finger(1,85,103)]) {
            try check(abs(scale-245.0/225.0)<0.000001,"Touch enumeration order cannot affect incremental pinch scale")
        } else { try check(false,"Pinch should continue") }
        try check(motion.update([finger(2,330,103)]) == .rebase,"Lifting either finger rebases without a midpoint jump")
        _=motion.update([finger(2,340,103)])
        try check(motion.update([finger(2,345,103)]) == .pan(CGPoint(x:340,y:103),CGPoint(x:345,y:103)),"The remaining finger continues panning without lifting again")
        _=motion.update([finger(2,345,103),finger(3,100,100),finger(4,200,100)])
        try check(motion.update([finger(2,350,103),finger(3,100,100),finger(4,200,100)]) == .none,"A third finger pauses navigation")
        try check(motion.update([finger(2,350,103),finger(3,100,100)]) == .rebase,"Returning from three fingers starts cleanly")
        motion=WorldGestureMotion()
        _=motion.update([finger(1,100,100),finger(2,300,100)])
        _=motion.update([finger(1,109,100),finger(2,300,100)])
        try check(motion.intent != .angle,"A single moving finger cannot select tilt")
        motion=WorldGestureMotion()
        _=motion.update([finger(1,100,100),finger(2,300,100)])
        _=motion.update([finger(1,101,120),finger(2,301,120)])
        try check(motion.update([finger(1,104,130),finger(2,304,130)]) == .angle(0,10),"Vertical drag tilts without accidental heading wobble")
        try check(motion.update([finger(1,80,130),finger(2,328,130)]) == .rebase && motion.intent == .transform,"A clear pinch can escape an initial tilt classification without a jump")
        if case let .zoom(_,_,scale)=motion.update([finger(1,70,130),finger(2,338,130)]) {
            try check(abs(scale-268.0/248.0)<0.000001,"Pinch takeover does not replay earlier span changes")
        } else { try check(false,"Expected zoom after tilt-to-pinch handoff") }
        motion=WorldGestureMotion()
        _=motion.update([finger(1,100,100),finger(2,300,100)])
        _=motion.update([finger(1,120,101),finger(2,320,101)])
        try check(motion.update([finger(1,130,104),finger(2,330,104)]) == .angle(10,0),"Horizontal drag turns without accidental tilt")
        _=motion.update([])
        try check(!motion.recognized && motion.intent == .undecided,"Lifting all fingers clears gesture intent")
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
