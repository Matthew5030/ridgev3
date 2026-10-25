import Foundation
import simd

/// User look is an offset from the cinematic heading. It stays still under a
/// resting finger, then eases back after release without interrupting travel.
struct WorldCinematicLook {
    private(set) var touching=false
    private(set) var yaw: Float = 0
    private(set) var pitch: Float = 0
    private var releaseDelay=0.0
    var needsAnimation: Bool { !touching && (abs(yaw)>0.0001 || abs(pitch)>0.0001) }
    mutating func begin() { touching=true;releaseDelay=0.6 }
    mutating func end() { touching=false;releaseDelay=0.6 }
    mutating func reset() { self=Self() }
    mutating func drag(dx: Double,dy: Double) {
        yaw-=Float(dx)*0.0045
        yaw=atan2(sin(yaw),cos(yaw))
        pitch=min(1.35,max(-1.35,pitch+Float(dy)*0.0035))
    }
    mutating func advance(seconds: Double) {
        guard !touching else { return }
        let step=max(0,seconds),waiting=min(step,releaseDelay)
        releaseDelay-=waiting
        let decay=Float(exp(-(step-waiting)/2.5))
        yaw*=decay;pitch*=decay
        if abs(yaw)<0.0001 { yaw=0 }
        if abs(pitch)<0.0001 { pitch=0 }
    }
    func direction(from automatic: SIMD3<Float>)->SIMD3<Float> {
        let heading=atan2(automatic.x,-automatic.z)+yaw
        let tilt=min(Float.pi*0.46,max(-Float.pi*0.46,asin(max(-1,min(1,automatic.y)))+pitch))
        return SIMD3(sin(heading)*cos(tilt),sin(tilt),-cos(heading)*cos(tilt))
    }
}

/// Ease automatic pans with explicit angular speed limits and a level horizon.
struct WorldCinematicHeading {
    private var yaw: Float?
    private var pitch: Float = 0
    mutating func reset() { yaw=nil;pitch=0 }
    mutating func direction(toward desired: SIMD3<Float>,seconds: Double)->SIMD3<Float> {
        let heading=atan2(desired.x,-desired.z)
        let tilt=min(0.50,max(-0.20,asin(max(-1,min(1,desired.y)))))
        guard let old=yaw else { yaw=heading;pitch=tilt;return vector(heading,tilt) }
        let step=Float(max(0,min(0.1,seconds)))
        let delta=atan2(sin(heading-old),cos(heading-old))
        let eased=1-exp(-step*5)
        let turn=min(step*1.8,max(-step*1.8,delta*eased))
        let rise=min(step*0.40,max(-step*0.40,(tilt-pitch)*eased))
        yaw=old+turn;pitch+=rise
        return vector(yaw!,pitch)
    }
    private func vector(_ yaw: Float,_ pitch: Float)->SIMD3<Float> {
        SIMD3(sin(yaw)*cos(pitch),sin(pitch),-cos(yaw)*cos(pitch))
    }
}
