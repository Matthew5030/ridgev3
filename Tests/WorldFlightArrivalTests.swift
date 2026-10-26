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
            let path=WorldRouteTourPath(segments:[[point(0,0),point(0,-size),point(size/3,-size)]])!,rail=WorldFlightCorridor(path:path,style:.drone)
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map {_ in Float?(100)})
            let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:WorldRouteTour.flightClearance,cornerLift:WorldRouteTour.fpvCornerLift,routeFraming:true,movementAligned:true)
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

            // Real browsing poses include a vertical overview and a camera on
            // the other side of the route. Preparation must preserve them,
            // including the lens and actual up vector, without an initial cut.
            for vertical in [false,true] {
                let eye=start.pose.eye+SIMD3<Float>(240,600,300)
                let look=vertical ? eye+SIMD3<Float>(0,-80,0) : start.pose.eye
                let up=vertical ? SIMD3<Float>(0,0,-1) : SIMD3<Float>(0,1,0)
                let browsing=WorldRouteTourCamera.Pose(eye:eye,look:look,focus:start.pose.focus,up:up)
                let joining=WorldFlightArrival(path:path,flight:start,frame:frame,aspect:aspect,from:browsing,fieldOfView:43)
                let first=joining.sample(elapsed:0)
                try check(simd_distance(first.eye,eye)<0.001,"Preview begins at the exact browsing camera")
                try check(simd_dot(simd_normalize(first.look-first.eye),simd_normalize(look-eye))>0.99999,"Preview preserves the initial viewing direction")
                try check(joining.fieldOfView(elapsed:0)==43 && joining.fieldOfView(elapsed:joining.duration)==start.fieldOfView,"The lens blends from browsing into FPV")
                try check(joining.duration<=4.2,"The entrance has no fixed eight-second intro")
                camera.simdPosition=eye;WorldCameraOrientation.aim(camera,at:look,up:up)
                for time in stride(from:0.0,through:joining.duration,by:0.02) {
                    let pose=joining.sample(elapsed:time)
                    let previous=camera.simdWorldOrientation
                    camera.simdPosition=pose.eye;WorldCameraOrientation.aim(camera,at:pose.look,bank:pose.bank,up:pose.up)
                    try check(abs(simd_dot(previous.vector,camera.simdWorldOrientation.vector))>0.999,"The camera basis turns continuously from the original view")
                    try check(pose.eye.y>100 && pose.eye.x.isFinite,"The actual-view entrance stays above the flat terrain fixture")
                }
                let joined=joining.sample(elapsed:joining.duration),near=joining.sample(elapsed:joining.duration-0.01)
                try check(simd_distance(joined.eye,start.pose.eye)<0.02 && simd_distance((joined.eye-near.eye)/0.01,start.velocity)<0.3,"The browsing transition joins the exact prepared flight and velocity")
                let nextFrame=GeoBounds(minLatitude:52.9,minLongitude:-4.1,maxLatitude:53.3,maxLongitude:-3.7)
                let rebased=joining.sample(elapsed:joining.duration*0.5,in:nextFrame),original=joining.sample(elapsed:joining.duration*0.5)
                let a=frame.point(u:Double(original.eye.x)/frame.widthMeters+0.5,v:Double(original.eye.z)/frame.depthMeters+0.5)
                let b=nextFrame.point(u:Double(rebased.eye.x)/nextFrame.widthMeters+0.5,v:Double(rebased.eye.z)/nextFrame.depthMeters+0.5)
                try check(a.distance(to:b)<0.01,"Terrain frame replacement preserves the geographic entry camera")
            }
        } } }
        print("PASS \(checks) FPV entrance continuity and prepared-flight handoff checks")
    }
}
