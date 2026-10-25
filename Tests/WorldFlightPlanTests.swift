import Foundation
import SceneKit
import simd

@main struct WorldFlightPlanTests {
    @MainActor static func main() throws {
        var checks=0
        func check(_ value:Bool,_ message:String) throws { checks+=1;if !value { throw NSError(domain:message,code:1) } }
        let frame=GeoBounds(minLatitude:52.99,minLongitude:-4.02,maxLatitude:53.02,maxLongitude:-3.98)
        func point(_ x:Double,_ z:Double)->RoutePoint {
            RoutePoint(coordinate:GeoPoint(latitude:53-z/111195,longitude:-4+x/(111195*cos(53 * .pi/180))),elevation:100)
        }
        let fixtures:[(String,[RoutePoint])]=[
            ("isolated turnaround",[point(0,0),point(0,-300),point(0,0)]),
            ("dense switchbacks",[point(0,0),point(0,-160),point(80,-160),point(80,-240),point(0,-240),point(0,-320),point(80,-320),point(80,-500)])]
        for (name,points) in fixtures {
            let path=WorldRouteTourPath(segments:[points])!,corridor=WorldFlightCorridor(path:path)
            let heights=WorldFlightTerrain.distances(length:corridor.length).map { _ in Float?(100) }
            let terrain=WorldFlightTerrain(path:path,corridor:corridor,heights:heights)
            let began=Date(),plan=try WorldFlightPlan(path:path,corridor:corridor,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false)
            let prep=Date().timeIntervalSince(began)
            try check(plan.duration>5 && plan.count>50 && plan.count<=40002,"\(name): entire timeline is ready before playback with a bounded keyframe count")
            var last=plan.sample(time:0),maxBank:Float=0,maxHeight:Float=0,maxAngular:Float=0,maxAcceleration:Float=0,lastVelocity:SIMD3<Float>?
            let rig=WorldCameraRig(),camera=SCNNode();camera.camera=SCNCamera();rig.beginTour(on:camera)
            for tick in 1...Int(ceil(plan.duration*60)) {
                let now=min(plan.duration,Double(tick)/60),sample=plan.sample(time:now)
                let direction=simd_normalize(sample.pose.look-sample.pose.eye),previous=simd_normalize(last.pose.look-last.pose.eye)
                maxAngular=max(maxAngular,acos(min(1,max(-1,simd_dot(direction,previous)))))
                maxBank=max(maxBank,abs(sample.pose.bank));maxHeight=max(maxHeight,sample.pose.eye.y)
                let velocity=(sample.pose.eye-last.pose.eye)*60
                if let lastVelocity,tick<Int(plan.duration*60) { maxAcceleration=max(maxAcceleration,simd_distance(velocity,lastVelocity)*60) }
                lastVelocity=velocity
                try check(sample.routeDistance>=last.routeDistance && sample.pose.eye.y>=119.9,"\(name): baked playback keeps monotonic route progress and terrain clearance")
                try check(sample.pose.eye.x.isFinite && sample.pose.look.y.isFinite && abs(sample.pose.bank)<0.32,"\(name): interpolation stays finite and within the bank limit")
                rig.fly(on:camera,pose:.init(eye:sample.pose.eye,look:sample.pose.look,bank:sample.pose.bank))
                try check(simd_distance(camera.simdPosition,sample.pose.eye)<0.0001,"\(name): native camera follows the prepared pose exactly")
                if tick%20==0 {
                    let again=plan.sample(time:now)
                    try check(again.pose.eye==sample.pose.eye && again.pose.look==sample.pose.look && again.pose.bank==sample.pose.bank,"\(name): seek/replay samples are deterministic without terrain or camera calculations")
                    try check(abs(plan.time(at:sample.routeDistance)-now)<0.01,"\(name): scrubbing maps back to the same prepared instant")
                }
                last=sample
            }
            try check(abs(last.routeDistance-path.length)<0.01,"\(name): complete timeline reaches the finish")
            try check(maxAngular<0.035,"\(name): prepared heading has no per-frame jumps (\(maxAngular))")
            if name=="isolated turnaround" {
                try check(maxBank>0.015 && maxBank<0.32,"A sharp bend has a visible, bounded bird-like lean")
                try check(abs(maxHeight-120)<0.01,"A wide turn respects the selected ground clearance")
            } else { try check(abs(maxHeight-120)<0.01,"Repeated turns respect the selected ground clearance") }
            let slowed=try WorldFlightPlan(path:path,corridor:corridor,terrain:terrain,frame:frame,cruiseSpeed:7,reduceMotion:false)
            try check(slowed.duration>plan.duration,"Changing cruise speed prepares different timing from the same terrain snapshot")
            let still=try WorldFlightPlan(path:path,corridor:corridor,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:true)
            try check(abs(still.sample(time:still.duration/2).pose.bank)<0.0001,"Reduce Motion bakes a level horizon")
            let rebased=GeoBounds(minLatitude:52.98,minLongitude:-4.03,maxLatitude:53.03,maxLongitude:-3.97)
            let a=plan.sample(time:plan.duration/2),b=plan.sample(time:plan.duration/2,in:rebased)
            func geographic(_ p:SIMD3<Float>,_ bounds:GeoBounds)->GeoPoint { bounds.point(u:Double(p.x)/bounds.widthMeters+0.5,v:Double(p.z)/bounds.depthMeters+0.5) }
            try check(geographic(a.pose.eye,frame).distance(to:geographic(b.pose.eye,rebased))<0.02,"A new terrain frame cannot move the prepared geographic flight")
            print("\(name): prepared \(plan.count) keyframes in \(prep) s; duration \(plan.duration) s; peak bank \(maxBank*180 / .pi)°; height \(maxHeight-100) m; max frame turn \(maxAngular) rad; acceleration \(maxAcceleration) m/s²")
        }
        print("PASS \(checks) precomputed timeline, banking, overview and native playback checks")
    }
}
