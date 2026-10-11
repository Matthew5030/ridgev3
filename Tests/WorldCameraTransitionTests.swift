import Foundation
@main struct WorldCameraTransitionTests {
    static func main() {
        var checks=0
        func check(_ pass:Bool) { precondition(pass);checks+=1 }
        for span in [2000.0,3500,6900] {
            var previous=Double.infinity
            for i in 0...100 {
                let p=WorldCameraTransition.entry(span:span,progress:Double(i)/100)
                check(p.distance.isFinite && p.distance>170 && p.distance<300000)
                check(p.span<=previous+0.00001);previous=p.span
                check(p.pitch>=0.85-1e-9 && p.pitch<=WorldCameraTransition.skyPitch)
            }
            let start=WorldCameraTransition.entry(span:span,progress:0),end=WorldCameraTransition.entry(span:span,progress:1)
            check(abs(start.span-span)<0.00001);check(end.fieldOfView==43)
            for yaw in [-6.0,-2,0,2,6] {
                let pose=WorldCameraTransition.Pose(distance:end.distance,pitch:0.5,yaw:yaw,fieldOfView:43)
                let first=WorldCameraTransition.exit(from:pose,progress:0),last=WorldCameraTransition.exit(from:pose,progress:1)
                check(abs(first.distance-pose.distance)<0.00001 && first.pitch==pose.pitch)
                check(abs(sin(first.yaw)-sin(yaw))<1e-8)
                check(abs(last.span-14000)<0.00001 && last.yaw==0)
                for aspect in [0.46,0.75,1.33,2.0] {
                    let bounds=WorldCameraTransition.viewport(center:GeoPoint(latitude:53.0763,longitude:-4.0546),span:last.span,aspect:aspect)
                    check(bounds.isValid && abs(bounds.depthMeters-last.span)<1)
                    check(abs(bounds.widthMeters/bounds.depthMeters-aspect)<0.001)
                }
            }
        }
        // Focused ground and its nearby route remain outside the haze at every
        // stage of the sky/terrain transition, including its final frame.
        for span in [2000.0,3500,6900] {
            for i in 0...100 {
                let pose = WorldCameraTransition.entry(span:span,progress:Double(i)/100)
                let fog = WorldAtmosphere.range(cameraDistance:pose.distance)
                check(fog.start > pose.distance+10000)
                check(fog.end-fog.start >= 50000)
                if i < 100 {
                    let next = WorldCameraTransition.entry(span:span,progress:Double(i+1)/100)
                    let nextFog = WorldAtmosphere.range(cameraDistance:next.distance)
                    check(abs(nextFog.start-fog.start) <= abs(next.distance-pose.distance)+0.001)
                }
            }
        }
        for distance in [170.0,2000,6000,12000,26000,300000] {
            let fog = WorldAtmosphere.range(cameraDistance:distance)
            check(fog.start >= 20000 && fog.start > distance && fog.end > fog.start)
        }
        print("PASS \(checks) camera transition checks")
    }
}
