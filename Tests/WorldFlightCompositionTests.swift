import Foundation
import SceneKit
import simd

@main struct WorldFlightCompositionTests {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        var checks=0
        func check(_ value:Bool,_ message:String) throws { checks+=1;if !value { throw NSError(domain:message,code:1) } }
        func point(_ x:Double,_ z:Double)->RoutePoint {
            .init(coordinate:.init(latitude:53-z/111195,longitude:-4+x/(111195*cos(53 * .pi/180))),elevation:100)
        }
        let frame=GeoBounds(minLatitude:52.9,minLongitude:-4.1,maxLatitude:53.1,maxLongitude:-3.9)
        let fixtures:[(String,[RoutePoint])]=[
            ("straight",[point(0,0),point(0,-4000)]),
            ("bend",[point(0,0),point(0,-1600),point(1800,-1600)]),
            ("return",[point(0,0),point(0,-1200),point(0,0)]),
            ("overlapping returns",[point(0,0),point(0,-350),point(20,-40),point(40,-320),point(10,0)]),
            ("nearby bends",[point(0,0),point(0,-1500),point(200,-1500),point(200,-1800),point(500,-1800),point(500,-3500)])]
        for (name,points) in fixtures {
            let path=WorldRouteTourPath(segments:[points])!,rail=WorldFlightCorridor(path:path,tolerance:160,routeCentred:true)
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map { _ in Float?(100) })
            func plan(adaptive:Bool,reduceMotion:Bool=false) throws -> WorldFlightPlan {
                try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:reduceMotion,
                    clearance:10,cornerLift:12,routeFraming:true,adaptiveFraming:adaptive)
            }
            let old=try plan(adaptive:false),new=try plan(adaptive:true),quiet=try plan(adaptive:true,reduceMotion:true)
            let scale=WorldRouteTour.previewCruiseSpeed/3.6/new.cruiseSpeed,dt=1.0/60
            func cameraMetrics(_ plan:WorldFlightPlan)->(turn:Double,variation:Double) {
                var previous=simd_normalize(plan.sample(time:0).pose.look-plan.sample(time:0).pose.eye)
                var previousVelocity=SIMD3<Float>.zero,maxTurn=0.0,variation=0.0
                for t in stride(from:dt*scale,to:plan.duration,by:dt*scale) {
                    let sample=plan.sample(time:t),direction=simd_normalize(sample.pose.look-sample.pose.eye)
                    maxTurn=max(maxTurn,Double(acos(min(1,max(-1,simd_dot(previous,direction))))))
                    // Perspective magnification determines how far a given
                    // angular movement travels across the image. This measures
                    // visual variation as the lens widens, alongside raw turns.
                    let magnification=Float(tan(sample.fieldOfView * .pi/360))
                    let velocity=(direction-previous)/(Float(dt)*magnification)
                    variation+=Double(simd_length(velocity-previousVelocity));previousVelocity=velocity;previous=direction
                }
                return (maxTurn,variation)
            }
            let a=cameraMetrics(old),b=cameraMetrics(new)
            var minFOV=Double.infinity,maxFOV=0.0,maxLift=0.0,maxLensRate=0.0,wideRuns=0,wasWide=false
            var previous=new.sample(time:0)
            let camera=SCNNode();camera.camera=SCNCamera();let rig=WorldCameraRig();rig.beginTour(on:camera)
            for t in stride(from:dt*scale,to:new.duration,by:dt*scale) {
                let sample=new.sample(time:t),base=old.sample(time:old.time(at:sample.routeDistance))
                minFOV=min(minFOV,sample.fieldOfView);maxFOV=max(maxFOV,sample.fieldOfView)
                maxLift=max(maxLift,Double(sample.pose.eye.y-base.pose.eye.y))
                maxLensRate=max(maxLensRate,abs(sample.fieldOfView-previous.fieldOfView)/dt)
                try check(sample.fieldOfView>=67.999 && sample.fieldOfView<=76.001,"\(name): bounded optical pullback")
                try check(sample.pose.eye.y>=base.pose.eye.y-0.02 && sample.pose.eye.y<=base.pose.eye.y+28.02,"\(name): physical pullback is positive and bounded")
                let expected=rail.speedLimit(at:sample.routeDistance,requested:new.cruiseSpeed)
                try check(abs(sample.speed-expected)<0.5,"\(name): pullback retains the prepared cruise/turn pace")
                try check(simd_dot(simd_normalize(sample.pose.look-sample.pose.eye),simd_normalize(sample.routeTarget!-sample.pose.eye))>0.99999,"\(name): pullback retains route-guided framing")
                rig.fly(on:camera,pose:.init(eye:sample.pose.eye,look:sample.pose.look,fieldOfView:sample.fieldOfView,bank:sample.pose.bank))
                try check(abs(Double(camera.camera!.fieldOfView)-sample.fieldOfView)<0.0001,"\(name): the real camera receives the prepared lens")
                if Int(t*60)%17==0 {
                    let again=new.sample(time:t)
                    try check(again.fieldOfView==sample.fieldOfView && again.pose.eye==sample.pose.eye,"\(name): zoom and position are deterministic during scrub/replay")
                    rig.restoreTour(on:camera)
                    try check(abs(Double(camera.camera!.fieldOfView)-sample.fieldOfView)<0.0001,"\(name): terrain refresh cannot reset the adaptive lens")
                }
                let wide=sample.fieldOfView>71
                if wide && !wasWide { wideRuns+=1 };wasWide=wide
                previous=sample
            }
            for t in stride(from:0.0,to:quiet.duration,by:0.2) {
                let sample=quiet.sample(time:t)
                try check(sample.fieldOfView==68 && sample.pose.bank==0,"\(name): Reduce Motion avoids automatic zoom and roll")
                try check(simd_distance(sample.pose.eye,old.sample(time:t).pose.eye)<0.01,"\(name): Reduce Motion omits the additional pullback motion")
            }
            print("\(name): frame turn \(a.turn) → \(b.turn) rad; screen movement variation \(a.variation) → \(b.variation); lens \(minFOV)…\(maxFOV)°; lift \(maxLift) m; lens rate \(maxLensRate)°/s; wide shots \(wideRuns)")
            try check(maxLensRate<9,"\(name): no rapid zoom corrections")
            if name=="straight" {
                try check(maxFOV==68 && maxLift<0.01,"Straight flight stays low without artificial zoom breathing")
            } else {
                try check(maxFOV>72 && maxLift>14,"\(name): large movements receive a wider, more distant view")
                try check(b.turn<a.turn,"\(name): the adaptive view reduces peak camera movement")
                try check(b.variation<a.variation,"\(name): the adaptive view reduces abrupt changes in screen movement")
            }
            if name=="bend" {
                let approach=new.sample(time:new.time(at:1250)),after=new.sample(time:new.time(at:path.length-50))
                try check(approach.fieldOfView>68.2,"The shot begins widening before the turn")
                try check(after.fieldOfView<68.2,"The view settles close again after a long clear straight")
            }
            if name=="nearby bends" { try check(wideRuns==1,"Nearby bends hold one wide shot instead of zooming in and out repeatedly") }
            let source=new.sample(time:new.duration/2)
            let output=GeoBounds(minLatitude:52.98,minLongitude:-4.03,maxLatitude:53.04,maxLongitude:-3.97)
            let converted=WorldFlightPlan.converted(source,from:frame,to:output)
            try check(converted.fieldOfView==source.fieldOfView,"Scene origin changes preserve the adaptive lens")
        }
        print("PASS \(checks) adaptive composition, calm framing, zoom continuity and low straight-flight checks")
    }
}
