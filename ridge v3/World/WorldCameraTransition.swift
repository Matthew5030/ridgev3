import Foundation

enum WorldCameraTransition {
    static let skyPitch = 1.567 // Near vertical, with an unambiguous north-up camera basis.
    struct Pose {
        var distance: Double
        var pitch: Double
        var yaw: Double
        var fieldOfView: Double
        var span: Double { 2*distance*tan(fieldOfView * .pi/360) }
    }
    static func entry(span: Double, progress: Double) -> Pose {
        let t=ease(progress),field=5+38*t,footprint=span*(1-0.18*t)
        return Pose(distance:footprint/(2*tan(field * .pi/360)),pitch:skyPitch+(0.85-skyPitch)*t,yaw:0,fieldOfView:field)
    }
    static func exit(from start: Pose, progress: Double) -> Pose {
        let t=ease(progress),field=start.fieldOfView+(5-start.fieldOfView)*t
        let span=start.span+(max(14000,start.span)-start.span)*t
        let heading=atan2(sin(start.yaw),cos(start.yaw))
        return Pose(distance:span/(2*tan(field * .pi/360)),pitch:start.pitch+(skyPitch-start.pitch)*t,yaw:heading*(1-t),fieldOfView:field)
    }
    static func viewport(center: GeoPoint, span: Double, aspect: Double) -> GeoBounds {
        let latitude=span/111_195,longitude=span*aspect/(111_195*max(0.01,cos(center.latitude * .pi/180)))
        return GeoBounds(minLatitude:center.latitude-latitude/2,minLongitude:center.longitude-longitude/2,maxLatitude:center.latitude+latitude/2,maxLongitude:center.longitude+longitude/2)
    }
    private static func ease(_ progress: Double) -> Double { let t=max(0,min(1,progress));return t*t*(3-2*t) }
}

/// Atmosphere depends on viewing distance, never on the state of tile loading.
/// Use the same curve during flight and ordinary gestures so entry cannot flash.
enum WorldAtmosphere {
    static func range(cameraDistance: Double) -> (start: Double, end: Double) {
        let start = max(20000,cameraDistance+16000)
        return (start,start+60000)
    }
}
