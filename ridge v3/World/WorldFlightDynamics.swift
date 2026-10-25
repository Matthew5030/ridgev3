import Foundation
import simd

/// Terrain clearance and banking use damped motion rather than inheriting each
/// mesh sample. The desired height already anticipates hills along the rail.
struct WorldFlightDynamics {
    private(set) var altitude: Float?
    private var verticalVelocity: Float = 0
    private(set) var bank: Float = 0
    mutating func reset() { self=Self() }
    mutating func update(height:Float,floor:Float,bank targetBank:Float,seconds:Double)->(height:Float,bank:Float) {
        let dt=Float(max(0,min(0.1,seconds)))
        guard let previous=altitude else { altitude=max(floor,height);bank=targetBank;return (altitude!,bank) }
        let omega:Float=4,offset=previous-height,impulse=verticalVelocity+omega*offset,decay=exp(-omega*dt)
        let next=height+(offset+impulse*dt)*decay
        verticalVelocity=(verticalVelocity-omega*impulse*dt)*decay
        altitude=max(floor,next)
        if next<floor { verticalVelocity=max(0,verticalVelocity) }
        bank+=(targetBank-bank)*(1-exp(-dt*2.2))
        return (altitude!,bank)
    }
}

/// Ease speed changes and anticipate tight turns rather than turning the camera
/// faster than it can follow its rail. Straight flight uses the chosen speed.
struct WorldFlightPace {
    private var speed:Double?
    private var acceleration=0.0
    var currentSpeed:Double { speed ?? 0 }
    mutating func reset() { speed=nil;acceleration=0 }
    mutating func metres(target:Double,seconds:Double)->Double {
        let dt=max(0,min(0.1,seconds)),old=speed ?? target
        let wanted=min(4,max(-6,(target-old)*2))
        acceleration+=min(8*dt,max(-8*dt,wanted-acceleration))
        let next=max(0,old+acceleration*dt)
        speed=next
        return (old+next)*0.5*dt
    }
}

/// A coordinated turn: radius and actual speed determine the lean. Busy
/// switchbacks use a higher, calmer view and a smaller maximum bank.
enum WorldFlightTurn {
    static func maximumBank(overview:Double)->Double { (18-6*min(1,max(0,overview))) * .pi/180 }
    static func bank(curvature:Double,speed:Double,overview:Double)->Float {
        let limit=maximumBank(overview:overview)
        return Float(min(limit,max(-limit,-atan(speed*speed*curvature/9.81))))
    }
}

/// A bounded steering manoeuvre around the prepared rail. The offset is a
/// critically damped position, not a camera rotation: its analytic velocity is
/// added to the rail velocity, and that same vector determines where we look.
/// Positive spline/response weights keep the eye within the sampled lateral
/// corridor and above its prepared clearance envelope. Release rejoins gently;
/// pause/seek never integrate hidden movement.
struct WorldFlightGlide {
    static let lateralLimit=80.0
    private var offset=SIMD3<Double>.zero
    private var derivative=SIMD3<Double>.zero
    private var previousVelocity:SIMD3<Double>?
    mutating func reset() { self=Self() }
    mutating func advance(reference:WorldFlightPlan.Sample,yaw:Float,pitch:Float,
                          speedScale:Double,seconds:Double,frame:GeoBounds,reduceMotion:Bool)->WorldFlightPlan.Sample {
        let dt=max(0,min(0.1,seconds)),baseVelocity=SIMD3<Double>(reference.velocity)*speedScale
        let horizontal=SIMD2(baseVelocity.x,baseVelocity.z),speed=simd_length(baseVelocity)
        let forward=simd_length_squared(horizontal)>0.00001 ? simd_normalize(horizontal) : SIMD2<Double>(0,-1)
        let right=SIMD3(-forward.y,0,forward.x)
        let target=right*(Self.lateralLimit*tanh(Double(yaw)*1.5))
            + SIMD3(0,60*max(0,tanh(Double(pitch)*2)),0)
        // Response is spatial: slow flight turns gently over the same corridor
        // rather than making a fast sideways step at a low selected speed.
        let responseSpeed=min(64.8,speed),travel=responseSpeed*dt,omega=1/(Self.lateralLimit*0.9)
        let error=offset-target,impulse=derivative+error*omega,decay=exp(-omega*travel)
        offset=target+(error+impulse*travel)*decay
        derivative=(derivative-impulse*(omega*travel))*decay
        let eye=reference.pose.eye+SIMD3<Float>(offset),velocity=baseVelocity+derivative*responseSpeed
        let direction=simd_length_squared(velocity)>0.00001 ? SIMD3<Float>(simd_normalize(velocity)) : simd_normalize(reference.pose.look-reference.pose.eye)
        var bank=reference.pose.bank
        if let previousVelocity,dt>0 {
            let a=(velocity-previousVelocity)/dt,v=SIMD2(velocity.x,velocity.z),square=simd_length_squared(v)
            let curvature=square>0.0001 ? (v.x*a.z-v.y*a.x)/pow(square,1.5) : 0
            bank=WorldFlightTurn.bank(curvature:curvature,speed:sqrt(square),overview:0)
        }
        previousVelocity=velocity
        let point=frame.point(u:Double(eye.x)/frame.widthMeters+0.5,v:Double(eye.z)/frame.depthMeters+0.5)
        var result=reference
        result.pose = .init(eye:eye,look:eye+direction*80,focus:point,bank:reduceMotion ? 0 : bank)
        result.velocity=SIMD3<Float>(velocity);result.speed=simd_length(velocity)
        result.heightAboveGround += offset.y;result.cameraPoint=point
        return result
    }
}
