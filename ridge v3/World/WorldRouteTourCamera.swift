import Foundation
import simd

/// One terrain-relative cinematic camera. Orbit and first-person modes never
/// participate in playback; the director supplies only a gentle scenic focus.
enum WorldRouteTourCamera {
    struct Pose {
        var eye: SIMD3<Float>
        var look: SIMD3<Float>
        var focus: GeoPoint
        var bank: Float = 0
        var up: SIMD3<Float> = SIMD3(0,1,0)
    }
    static func local(_ point: GeoPoint,frame: GeoBounds,elevation: (GeoPoint)->Float)->SIMD3<Float> {
        let uv=frame.uv(point)
        return SIMD3(Float((uv.u-0.5)*frame.widthMeters),elevation(point),Float((uv.v-0.5)*frame.depthMeters))
    }
    static func pose(path: WorldRouteTourPath,distance: Double,frame: GeoBounds,
                     corridor supplied: WorldFlightCorridor? = nil,focus: WorldCinematicDirector.Focus? = nil,
                     cinematicMotion: Bool = true,motionTime:Double? = nil,flightSpeed:Double=42,elevation: (GeoPoint)->Float)->Pose {
        let corridor=supplied ?? WorldFlightCorridor(path:path),travel=corridor.flightDistance(at:distance)
        let sample=corridor.sample(flightDistance:travel),overview=sample.overview
        let future=corridor.sample(flightDistance:travel+10+overview*25)
        let curvature=corridor.turnCurvature(flightDistance:travel)
        let ground=local(sample.point,frame:frame,elevation:elevation)
        let tangent=sample.direction+future.direction
        let heading=simd_length_squared(tangent)>0.00001 ? simd_normalize(tangent) : sample.direction
        let forward=SIMD3<Float>(Float(heading.x),0,Float(heading.y))
        let right=SIMD3<Float>(-forward.z,0,forward.x)
        let turnLoad=min(1,abs(curvature)*35)
        let drift=cinematicMotion ? Float(sin(motionTime.map { $0*0.22 } ?? travel/180)*1.2*(1-overview)*(1-turnLoad*0.8)) : 0
        var eye=ground+right*drift
        let eyePoint=frame.point(u:Double(eye.x)/frame.widthMeters+0.5,v:Double(eye.z)/frame.depthMeters+0.5)
        // A broad clearance envelope starts rising before a ridge and bridges
        // little hollows. It is spatially stable when route points are noisy.
        let clearance=Float(10+overview*40)
        eye.y=elevation(eyePoint)+clearance
        var before:Float=0,after:Float=0
        for offset in stride(from:-72.0,through:72.0,by:18) {
            let p=corridor.sample(flightDistance:travel+offset).point,h=elevation(p)
            eye.y=max(eye.y,h+clearance-Float(abs(offset))*0.12)
            if offset<0 { before+=h/4 } else if offset>0 { after+=h/4 }
        }
        let slope=max(-0.15,min(0.22,(after-before)/90))
        let tilt=slope*Float(1-overview*0.7)+0.0375-Float(overview)*0.22
        var direction=simd_normalize(forward*80+SIMD3(0,tilt*80,0))
        if cinematicMotion,let focus,focus.weight>0 {
            var destination=local(focus.point,frame:frame,elevation:elevation);destination.y=focus.elevation
            let delta=destination-eye
            if simd_length_squared(delta)>1 {
                let weight=min(0.42,focus.weight)*Float((1-overview)*(1-turnLoad*0.8))
                direction=simd_normalize(simd_mix(direction,simd_normalize(delta),SIMD3(repeating:weight)))
            }
        }
        // The automatic view stays near the horizon. Manual looking is applied
        // afterwards and can freely look above or below these bounds.
        let yaw=atan2(direction.x,-direction.z),pitch=max(-0.20,min(0.50,asin(direction.y)))
        direction=SIMD3(sin(yaw)*cos(pitch),sin(pitch),-cos(yaw)*cos(pitch))
        let anticipated=corridor.turnCurvature(flightDistance:min(corridor.length,travel+min(8,flightSpeed*0.35)))
        let bank=cinematicMotion ? WorldFlightTurn.bank(curvature:anticipated,speed:flightSpeed,overview:overview) : 0
        return Pose(eye:eye,look:eye+direction*80,focus:sample.point,bank:bank)
    }
}
