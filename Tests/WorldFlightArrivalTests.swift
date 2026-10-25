import Foundation
import SceneKit
import simd

@main struct WorldFlightArrivalTests {
    @MainActor static func main() throws {
        var checks=0
        func check(_ condition:Bool,_ message:String) throws { checks+=1;if !condition { throw NSError(domain:message,code:1) } }
        func point(_ x:Double,_ z:Double)->RoutePoint { .init(coordinate:.init(latitude:53-z/111195,longitude:-4+x/(111195*cos(53 * .pi/180))),elevation:100) }
        let frame=GeoBounds(minLatitude:52.8,minLongitude:-4.2,maxLatitude:53.2,maxLongitude:-3.8)
        for size in [500.0,8000] { for aspect in [0.5,1.4] { for progress in [0.0,0.5] {
            let path=WorldRouteTourPath(segments:[[point(0,0),point(0,-size),point(size/3,-size)]])!,rail=WorldFlightCorridor(path:path,tolerance:160)
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map {_ in Float?(100)})
            let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:15,cornerLift:WorldRouteTour.fpvCornerLift)
            let start=plan.sample(time:plan.time(at:path.length*progress)),entry=WorldFlightArrival(path:path,flight:start,frame:frame,aspect:aspect)
            let direction=simd_normalize(entry.opening.look-entry.opening.eye)
            try check(direction.y < -0.05 && direction.y > -0.25,"FPV retains its shallow forward entrance")
            try check(abs(entry.opening.eye.y-start.pose.eye.y-110)<0.1,"FPV preserves its approach height")
            let camera=SCNNode();camera.simdPosition=entry.opening.eye
            WorldCameraOrientation.aim(camera,at:entry.opening.look,up:entry.opening.up)
            var previous=entry.sample(elapsed:entry.hold)
            for time in stride(from:entry.hold+0.02,through:entry.duration,by:0.02) {
                let pose=entry.sample(elapsed:time)
                try check(pose.eye.y>100 && pose.eye.x.isFinite && pose.look.y.isFinite,"The approach stays finite and above the saved flat terrain")
                let direction=simd_normalize(pose.look-pose.eye),last=simd_normalize(previous.look-previous.eye)
                try check(simd_dot(direction,last)>0.98,"The FPV entrance turns continuously")
                camera.simdPosition=pose.eye
                let oldRight=SIMD3(camera.simdWorldTransform.columns.0.x,camera.simdWorldTransform.columns.0.y,camera.simdWorldTransform.columns.0.z)
                WorldCameraOrientation.aim(camera,at:pose.look,bank:pose.bank,up:pose.up)
                let right=SIMD3(camera.simdWorldTransform.columns.0.x,camera.simdWorldTransform.columns.0.y,camera.simdWorldTransform.columns.0.z)
                try check(simd_dot(oldRight,right)>0.99,"The actual camera basis cannot flip during the entrance")
                previous=pose
            }
            let end=entry.sample(elapsed:entry.duration),before=entry.sample(elapsed:entry.duration-0.01)
            try check(simd_distance(end.eye,start.pose.eye)<0.02,"The entrance joins the exact prepared flight position")
            try check(simd_dot(simd_normalize(end.look-end.eye),simd_normalize(start.pose.look-start.pose.eye))>0.99999,"The entrance joins the stabilized FPV gaze")
            try check(simd_distance((end.eye-before.eye)/0.01,start.velocity)<0.3,"The entrance matches flight velocity without stopping")
        } } }
        print("PASS \(checks) FPV entrance continuity and prepared-flight handoff checks")
    }
}
