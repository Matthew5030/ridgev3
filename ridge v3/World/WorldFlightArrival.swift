import Foundation
import simd

/// The unobstructed forward approach descends into the prepared FPV flight,
/// matching its position, forward gaze and velocity at the handoff.
struct WorldFlightArrival {
    let frame:GeoBounds
    let opening:WorldRouteTourCamera.Pose
    let hold=0.0
    let diveDuration:Double
    var duration:Double { hold+diveDuration }
    private let finish:WorldFlightPlan.Sample
    private let openingFieldOfView:Double
    private let openingOrientation:simd_quatf,finishOrientation:simd_quatf
    private let p:SIMD3<Double>,c1:SIMD3<Double>,c2:SIMD3<Double>,c3:SIMD3<Double>,c4:SIMD3<Double>,c5:SIMD3<Double>

    init(path:WorldRouteTourPath,flight:WorldFlightPlan.Sample,frame:GeoBounds,aspect:Double,
         from current:WorldRouteTourCamera.Pose? = nil,fieldOfView:Double = WorldRouteTour.fieldOfView) {
        self.frame=frame;finish=flight
        opening=current ?? Self.approach(path:path,frame:frame,velocity:flight.velocity,fallbackAltitude:Double(flight.pose.eye.y),focus:flight.pose.focus)
        openingFieldOfView=fieldOfView
        openingOrientation=Self.orientation(opening);finishOrientation=Self.orientation(flight.pose)
        let start=SIMD3<Double>(opening.eye)
        diveDuration=min(4.2,max(2.8,simd_distance(start,SIMD3<Double>(flight.pose.eye))/max(90,Double(simd_length(flight.velocity)))))
        let dt=diveDuration,end=SIMD3<Double>(flight.pose.eye),delta=end-start
        let v1=SIMD3<Double>(flight.velocity)*dt
        let initial=simd_normalize(SIMD3<Double>(opening.look-opening.eye))*max(18,min(65,Double(simd_length(flight.velocity))))
        // The browsing camera is stationary while preparation runs. Start its
        // one continuous approach at rest and join the exact flight velocity.
        let v0=current == nil ? initial*dt : .zero
        p=start;c1=v0;c2 = .zero
        c3=delta*10-v0*6-v1*4;c4=delta * -15+v0*8+v1*7;c5=delta*6-v0*3-v1*3
    }
    private static func orientation(_ pose:WorldRouteTourCamera.Pose)->simd_quatf {
        let back=simd_normalize(pose.eye-pose.look)
        var right=simd_cross(pose.up,back)
        if simd_length_squared(right)<0.000001 { right=simd_cross(SIMD3<Float>(0,0,-1),back) }
        right=simd_normalize(right)
        return simd_quatf(simd_float3x3(columns:(right,simd_cross(back,right),back)))
    }
    func fieldOfView(elapsed:Double)->Double {
        let t=min(1,max(0,elapsed/diveDuration)),weight=t*t*t*(10+t*(-15+6*t))
        return openingFieldOfView+(WorldRouteTour.fieldOfView-openingFieldOfView)*weight
    }
    static func approach(path:WorldRouteTourPath,frame:GeoBounds,velocity:SIMD3<Float>,fallbackAltitude:Double,focus:GeoPoint? = nil)->WorldRouteTourCamera.Pose {
        let point=focus ?? path.points[0].coordinate,uv=frame.uv(point)
        let origin=SIMD3((uv.u-0.5)*frame.widthMeters,fallbackAltitude,(uv.v-0.5)*frame.depthMeters)
        let v=SIMD3<Double>(velocity),horizontal=SIMD3(v.x,0,v.z)
        let forward=simd_length_squared(horizontal)>0.001 ? simd_normalize(horizontal) : SIMD3(0,0,-1)
        let right=SIMD3(-forward.z,0,forward.x)
        let start=origin-forward*max(180,simd_length(v)*5.8)+right*60+SIMD3(0,110,0)
        return .init(eye:SIMD3<Float>(start),look:SIMD3<Float>(start+forward*500-right*60+SIMD3(0,-75,0)),focus:point)
    }
    func sample(elapsed:Double,in outputFrame:GeoBounds? = nil)->WorldRouteTourCamera.Pose {
        let t=min(1,max(0,(elapsed-hold)/diveDuration)),weight=t*t*t*(10+t*(-15+6*t))
        var eye=SIMD3<Float>(p+t*(c1+t*(c2+t*(c3+t*(c4+t*c5)))))
        let rotation=simd_slerp(openingOrientation,finishOrientation,Float(weight))
        var look=eye+rotation.act(SIMD3<Float>(0,0,-80))
        let up=rotation.act(SIMD3<Float>(0,1,0))
        if let outputFrame,outputFrame != frame {
            func convert(_ value:SIMD3<Float>)->SIMD3<Float> {
                let point=frame.point(u:Double(value.x)/frame.widthMeters+0.5,v:Double(value.z)/frame.depthMeters+0.5),uv=outputFrame.uv(point)
                return SIMD3(Float((uv.u-0.5)*outputFrame.widthMeters),value.y,Float((uv.v-0.5)*outputFrame.depthMeters))
            }
            eye=convert(eye);look=convert(look)
        }
        return .init(eye:eye,look:look,focus:finish.pose.focus,bank:finish.pose.bank*Float(weight),up:up)
    }
}
