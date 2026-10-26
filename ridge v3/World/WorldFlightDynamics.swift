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
    struct Limits {
        let lateralAcceleration:Double
        let yawRate:Double
        let rollRate:Double
        let acceleration:Double
        let smoothingDistance:Double
        let bankResponseAcceleration:Double
        let pitchRate:Double
        // Map-scale FPV needs quick, local manoeuvres. Bank still follows the
        // actual turn, with a cinematic response scale rather than literal
        // Earth-gravity aircraft limits at the 600 km/h preview pace.
        static let cinematic=Self(lateralAcceleration:120,yawRate:1.8,rollRate:2.0,acceleration:30,smoothingDistance:30,bankResponseAcceleration:64,pitchRate:0.7)
        static let gentle=Self(lateralAcceleration:3.2,yawRate:0.20,rollRate:0.18,acceleration:4,smoothingDistance:20,bankResponseAcceleration:9.81,pitchRate:0.2)
    }
    static func pitchRate(velocity:SIMD3<Double>,acceleration:SIMD3<Double>)->Double {
        let horizontal=hypot(velocity.x,velocity.z)
        guard horizontal>0.00001 else { return 0 }
        let along=(velocity.x*acceleration.x+velocity.z*acceleration.z)/horizontal
        return (acceleration.y*horizontal-velocity.y*along)/max(0.000001,simd_length_squared(velocity))
    }
    /// Map actual normal acceleration to a coordinated bank. The response
    /// scale is shared by preparation and steering; no independent roll lag.
    static func coordinatedBank(velocity:SIMD3<Double>,acceleration:SIMD3<Double>,responseAcceleration:Double=9.81)->Float {
        let speed=hypot(velocity.x,velocity.z)
        guard speed>0.00001 else { return 0 }
        let lateral=(velocity.x*acceleration.z-velocity.z*acceleration.x)/speed
        return Float(-atan(lateral/responseAcceleration))
    }
    static func maximumBank(overview:Double)->Double { (18-6*min(1,max(0,overview))) * .pi/180 }
    static func bank(curvature:Double,speed:Double,overview:Double)->Float {
        let limit=maximumBank(overview:overview)
        return Float(min(limit,max(-limit,-atan(speed*speed*curvature/9.81))))
    }
}

/// A bounded steering manoeuvre around the prepared rail. The offset is a
/// critically damped position, not a camera rotation: its analytic velocity is
/// added to the rail velocity. Movement-aligned FPV includes steering's velocity
/// and acceleration in both its forward view and coordinated bank. The older
/// subject-framed choreography remains available to isolated camera fixtures.
/// Positive spline/response weights keep the eye within the sampled lateral
/// corridor, including a small descent using the prepared clearance buffer.
/// Release rejoins gently;
/// pause/seek never integrate hidden movement.
struct WorldFlightGlide {
    static let lateralLimit=24.0
    private var offset=SIMD3<Double>.zero
    private var derivative=SIMD3<Double>.zero
    private var previousVelocity:SIMD3<Double>?
    private var previousBaseVelocity:SIMD3<Double>?
    private var steeringBank=0.0
    private var first=SIMD3<Double>.zero
    private var second=SIMD3<Double>.zero
    mutating func reset() { self=Self() }
    mutating func advance(reference:WorldFlightPlan.Sample,yaw:Float,pitch:Float,
                          speedScale:Double,seconds:Double,frame:GeoBounds,reduceMotion:Bool,clearance:Double=15)->WorldFlightPlan.Sample {
        if reference.movementAligned {
            return coordinated(reference:reference,yaw:yaw,pitch:pitch,speedScale:speedScale,seconds:seconds,frame:frame,reduceMotion:reduceMotion,clearance:clearance)
        }
        let dt=max(0,min(0.1,seconds)),baseVelocity=SIMD3<Double>(reference.velocity)*speedScale
        let horizontal=SIMD2(baseVelocity.x,baseVelocity.z),speed=simd_length(baseVelocity)
        let forward=simd_length_squared(horizontal)>0.00001 ? simd_normalize(horizontal) : SIMD2<Double>(0,-1)
        let right=SIMD3(-forward.y,0,forward.x)
        let descent=min(10,max(0,clearance-5))
        let vertical=(pitch<0 ? descent : 12)*tanh(Double(pitch)*2)
        let target=right*(Self.lateralLimit*tanh(Double(yaw)*1.5))+SIMD3(0,vertical,0)
        // Response is spatial: slow flight turns gently over the same corridor
        // rather than making a fast sideways step at a low selected speed.
        let responseSpeed=min(64.8,speed),travel=responseSpeed*dt,omega=1/72.0
        let error=offset-target,impulse=derivative+error*omega,decay=exp(-omega*travel)
        offset=target+(error+impulse*travel)*decay
        derivative=(derivative-impulse*(omega*travel))*decay
        let eye=reference.pose.eye+SIMD3<Float>(offset),velocity=baseVelocity+derivative*responseSpeed
        let direction=simd_length_squared(velocity)>0.00001 ? SIMD3<Float>(simd_normalize(velocity)) : simd_normalize(reference.pose.look-reference.pose.eye)
        var bank=reference.pose.bank
        if let previousVelocity,dt>0 {
            let a=(velocity-previousVelocity)/dt,v=SIMD2(velocity.x,velocity.z),square=simd_length_squared(v)
            let curvature=square>0.0001 ? (v.x*a.z-v.y*a.x)/pow(square,1.5) : 0
            if reference.routeTarget != nil,let previousBaseVelocity {
                func yawRate(_ old:SIMD3<Double>,_ next:SIMD3<Double>)->Double {
                    let a=SIMD2(old.x,old.z),b=SIMD2(next.x,next.z)
                    return atan2(a.x*b.y-a.y*b.x,simd_dot(a,b))/dt
                }
                let extra=yawRate(previousVelocity,velocity)-yawRate(previousBaseVelocity,baseVelocity)
                let limit=6 * Double.pi/180,target=min(limit,max(-limit,-atan(speed*extra/9.81)))
                steeringBank+=(target-steeringBank)*(1-exp(-dt/0.5))
                let totalLimit=24.0 * Double.pi/180
                bank=Float(min(totalLimit,max(-totalLimit,Double(reference.pose.bank)+steeringBank)))
            } else if reference.routeTarget == nil {
                bank=WorldFlightTurn.bank(curvature:curvature,speed:sqrt(square),overview:0)
            }
        }
        previousVelocity=velocity;previousBaseVelocity=baseVelocity
        let point=frame.point(u:Double(eye.x)/frame.widthMeters+0.5,v:Double(eye.z)/frame.depthMeters+0.5)
        var result=reference
        result.pose = .init(eye:eye,look:reference.routeTarget ?? eye+direction*80,focus:point,bank:reduceMotion ? 0 : bank)
        result.velocity=SIMD3<Float>(velocity);result.speed=simd_length(velocity)
        result.heightAboveGround += offset.y;result.cameraPoint=point
        return result
    }
    /// Three positive response stages make manual steering a continuous
    /// manoeuvre, including acceleration and therefore bank. Position, gaze and
    /// roll all use these same derivatives; the input never pans a camera alone.
    private mutating func coordinated(reference:WorldFlightPlan.Sample,yaw:Float,pitch:Float,
                                      speedScale:Double,seconds:Double,frame:GeoBounds,reduceMotion:Bool,clearance:Double)->WorldFlightPlan.Sample {
        let dt=seconds.isFinite ? max(0,seconds) : 0,baseVelocity=SIMD3<Double>(reference.velocity)*speedScale
        let horizontal=SIMD2(baseVelocity.x,baseVelocity.z)
        let forward=simd_length_squared(horizontal)>0.000001 ? simd_normalize(horizontal) : SIMD2<Double>(0,-1)
        let right=SIMD3(-forward.y,0,forward.x),descent=min(10,max(0,clearance-5))
        let vertical=(pitch<0 ? descent : 12)*tanh(Double(pitch)*2)
        let target=right*(12*tanh(Double(yaw)*1.5))+SIMD3(0,vertical,0)
        let omega=0.45,u=omega*dt,decay=exp(-u)
        let a=first-target,b=second-target,c=offset-target
        first=target+a*decay
        second=target+(b+a*u)*decay
        offset=target+(c+b*u+a*(u*u/2))*decay
        let steeringVelocity=(second-offset)*omega
        let steeringAcceleration=(first-second*2+offset)*(omega*omega)
        let velocity=baseVelocity+steeringVelocity
        let acceleration=SIMD3<Double>(reference.acceleration)*speedScale*speedScale+steeringAcceleration
        let eye=reference.pose.eye+SIMD3<Float>(offset)
        let direction=simd_length_squared(velocity)>0.000001 ? SIMD3<Float>(simd_normalize(velocity)) : simd_normalize(reference.pose.look-reference.pose.eye)
        let point=frame.point(u:Double(eye.x)/frame.widthMeters+0.5,v:Double(eye.z)/frame.depthMeters+0.5)
        var result=reference
        result.pose = .init(eye:eye,look:eye+direction*80,focus:point,bank:reduceMotion ? 0 : WorldFlightTurn.coordinatedBank(velocity:velocity,acceleration:acceleration,responseAcceleration:reference.bankResponseAcceleration))
        result.velocity=SIMD3<Float>(velocity);result.acceleration=SIMD3<Float>(acceleration);result.speed=simd_length(velocity)
        result.heightAboveGround+=offset.y;result.cameraPoint=point
        return result
    }
}
