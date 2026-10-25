import Foundation
import simd

/// Hold one scenic subject for a complete eased shot. Selection uses distance,
/// forward visibility and terrain sight lines, rather than switching every frame.
struct WorldCinematicDirector {
    struct Focus {
        var point: GeoPoint
        var elevation: Float
        var weight: Float
        var id: String
    }
    private struct Shot { var place: MapPlace;var began: Double }
    private var shot: Shot?
    private var nextSelection=0.0
    private var lastSubject: String?
    mutating func reset() { self=Self() }

    mutating func focus(path: WorldRouteTourPath,distance: Double,time: Double,places: [MapPlace],frame: GeoBounds,
                        corridor:WorldFlightCorridor? = nil,elevation: (GeoPoint)->Float)->Focus? {
        let rail=corridor?.sample(routeDistance:distance)
        let point=rail?.point ?? path.sample(at:distance).coordinate
        let chord=path.heading(at:distance,lookAhead:70)
        func local(_ point: GeoPoint)->SIMD3<Float> { WorldRouteTourCamera.local(point,frame:frame,elevation:elevation) }
        let eye=local(point)+SIMD3(0,10,0),a=local(chord.from.coordinate),b=local(chord.to.coordinate)
        let horizontal=rail.map { SIMD3<Float>(Float($0.direction.x),0,Float($0.direction.y)) } ?? SIMD3<Float>(b.x-a.x,0,b.z-a.z)
        guard simd_length_squared(horizontal)>0.0001 else { return nil }
        let forward=simd_normalize(horizontal)
        func candidate(_ place: MapPlace)->(point: SIMD3<Float>,alignment: Float,range: Float) {
            var destination=local(place.coordinate)
            if let height=place.elevation,height.isFinite { destination.y=max(destination.y,Float(height)) }
            destination.y+=6
            let delta=destination-eye,flat=SIMD3<Float>(delta.x,0,delta.z),range=simd_length(flat)
            return (destination,range>0 ? simd_dot(forward,flat/range) : -1,range)
        }
        func visible(_ destination: SIMD3<Float>)->Bool {
            for fraction: Float in [0.15,0.3,0.45,0.6,0.75,0.9] {
                let ray=simd_mix(eye,destination,SIMD3(repeating:fraction))
                let point=frame.point(u:Double(ray.x)/frame.widthMeters+0.5,v:Double(ray.z)/frame.depthMeters+0.5)
                if elevation(point)>ray.y-1 { return false }
            }
            return true
        }
        if let current=shot,time-current.began>=8 { lastSubject=current.place.id;shot=nil;nextSelection=time+3 }
        if shot == nil,time>=nextSelection {
            let ranked=places.filter { ["peak","viewpoint","lake","landmark"].contains($0.kind) && $0.coordinate.isValid }.compactMap { place -> (MapPlace,Float)? in
                let value=candidate(place)
                guard value.range>120,value.range<2400,value.alignment>0.28,place.id != lastSubject else { return nil }
                let prominence=max(0,min(1,(value.point.y-eye.y)/350))
                return (place,(value.alignment+prominence*0.35)/(value.range+400))
            }.sorted { $0.1 == $1.1 ? $0.0.id<$1.0.id : $0.1>$1.1 }
            if let next=ranked.prefix(5).first(where:{ visible(candidate($0.0).point) }) { shot=Shot(place:next.0,began:time) }
            else { nextSelection=time+2 }
        }
        guard let shot else { return nil }
        let age=max(0,time-shot.began),value=candidate(shot.place)
        let enter=smooth(age/2),leave=smooth((8-age)/2.5)
        let ahead=smooth(Double((value.alignment-0.05)/0.4))
        let weight=Float(enter*leave*ahead)*0.42
        guard weight>0 else { return nil }
        return Focus(point:shot.place.coordinate,elevation:value.point.y,weight:weight,id:shot.place.id)
    }
    private func smooth(_ value: Double)->Double { let t=min(1,max(0,value));return t*t*(3-2*t) }
}
