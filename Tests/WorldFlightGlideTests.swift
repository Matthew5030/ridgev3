import Foundation
import SceneKit
import simd

@main struct WorldFlightGlideTests {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        var checks=0
        func check(_ value:Bool,_ message:String) throws { checks+=1;if !value { throw NSError(domain:message,code:1) } }
        func point(_ x:Double,_ z:Double)->RoutePoint {
            .init(coordinate:.init(latitude:53-z/111195,longitude:-4+x/(111195*cos(53 * .pi/180))),elevation:100)
        }
        let frame=GeoBounds(minLatitude:52.9,minLongitude:-4.1,maxLatitude:53.1,maxLongitude:-3.9)
        let path=WorldRouteTourPath(segments:[[point(0,0),point(0,-5000)]])!,rail=WorldFlightCorridor(path:path,tolerance:160)
        let stations=WorldFlightTerrain.distances(length:rail.length)
        let flat=WorldFlightTerrain(path:path,corridor:rail,heights:stations.map { _ in Float?(100) })
        let straight=try WorldFlightPlan(path:path,corridor:rail,terrain:flat,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:15,cornerLift:90)
        let ripples:[Float?]=stations.map { distance in
            let broad=18.0*sin(distance/9.0),fine=7.0*sin(distance/2.7)
            return Float(300.0+broad+fine)
        }
        let ridge:[Float?]=stations.map { distance in
            let x=(distance-2500.0)/230.0
            let hill=300.0*exp(-x*x),ripple=5.0*sin(distance/7.0)
            return Float(100.0+hill+ripple)
        }
        let fixtures:[(String,[Float?])]=[("ripples",ripples),("ridge and valley",ridge)]
        for (name,heights) in fixtures {
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:heights)
            let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:15,cornerLift:90)
            var last=plan.sample(time:0),maxPitchRate=0.0,maxVerticalAcceleration=0.0,maxPitch=0.0
            let speedScale=(150.0/3.6)/plan.cruiseSpeed,dt=1.0/60
            for time in stride(from:dt*speedScale,to:plan.duration-dt*speedScale,by:dt*speedScale) {
                let sample=plan.sample(time:time),heading=simd_normalize(sample.pose.look-sample.pose.eye)
                let movement=sample.pose.eye-last.pose.eye
                try check(simd_dot(heading,simd_normalize(sample.velocity))>0.99999,"\(name): full 3D gaze follows velocity on hills")
                try check(simd_dot(heading,simd_normalize(movement))>0.9999,"\(name): climbs cannot slide across the view")
                try check(sample.heightAboveGround>=14.95,"\(name): broad spline conservatively clears sampled terrain")
                let pitch=atan2(Double(sample.velocity.y),Double(simd_length(SIMD2(sample.velocity.x,sample.velocity.z))))
                let oldPitch=atan2(Double(last.velocity.y),Double(simd_length(SIMD2(last.velocity.x,last.velocity.z))))
                maxPitchRate=max(maxPitchRate,abs(pitch-oldPitch)/dt)
                maxPitch=max(maxPitch,abs(pitch))
                maxVerticalAcceleration=max(maxVerticalAcceleration,Double(abs(sample.velocity.y-last.velocity.y))*speedScale/dt)
                last=sample
            }
            try check(maxPitchRate<0.10,"\(name): no rapid nodding over terrain (\(maxPitchRate) rad/s)")
            if name=="ripples" { try check(maxPitch<0.01,"Small ground ripples do not make repeated climbs and dips") }
            print("\(name): peak pitch \(maxPitch) rad, rate \(maxPitchRate) rad/s; vertical acceleration \(maxVerticalAcceleration) m/s²")
        }
        // The complete steering corridor is prepared, including higher terrain
        // to either side. Playback consumes these heights without live queries.
        let lanePoints=WorldFlightTerrain.clearancePoints(corridor:rail)
        try check(lanePoints.count==stations.count*5,"Bounded five-lane terrain preparation")
        for i in stations.indices {
            try check(lanePoints[i*5+2].distance(to:rail.sample(flightDistance:stations[i]).point)<0.01,"Centre lane is unchanged")
            try check(abs(lanePoints[i*5].distance(to:lanePoints[i*5+4])-WorldFlightGlide.lateralLimit*2)<0.2,"Clearance covers the entire steering width")
        }
        let sideHeights:[Float?]=stations.map { distance in
            let x=(distance-2500.0)/100.0
            return Float(100.0+80.0*exp(-x*x))
        }
        let sideHill=WorldFlightTerrain(path:path,corridor:rail,heights:stations.map { _ in Float?(100) },clearanceHeights:sideHeights)
        let safe=try WorldFlightPlan(path:path,corridor:rail,terrain:sideHill,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:15)
        try check(safe.sample(time:safe.time(at:2500)).pose.eye.y>=194.9,"A hill beside the centre line is cleared before steering")

        func flight(hz:Double,speed:Double) throws -> (WorldFlightPlan.Sample,WorldFlightPlan.Sample) {
            var glide=WorldFlightGlide(),look=WorldCinematicLook()
            var last=straight.sample(time:0),maxOffset=0.0,peakBank:Float=0,time=0.0
            var bankedRight=false,bankedBack=false,middle=last
            let dt=1/hz,scale=speed/25
            for tick in 1...Int(45*hz) {
                let seconds=Double(tick)*dt
                if tick==Int(hz) { look.begin();look.drag(dx:-150,dy:110) }
                if tick==Int(7*hz) { look.end() }
                look.advance(seconds:dt);time+=dt*scale
                let reference=straight.sample(time:time)
                let sample=glide.advance(reference:reference,yaw:look.yaw,pitch:look.pitch,speedScale:scale,seconds:dt,frame:frame,reduceMotion:false)
                let offset=sample.pose.eye-reference.pose.eye,heading=simd_normalize(sample.pose.look-sample.pose.eye),delta=sample.pose.eye-last.pose.eye
                try check(simd_dot(heading,simd_normalize(sample.velocity))>0.99999,"Steered gaze and travel share one velocity")
                try check(simd_dot(heading,simd_normalize(delta))>0.9995,"Steering turns forward instead of sliding sideways")
                try check(abs(offset.x)<=Float(WorldFlightGlide.lateralLimit)+0.01 && offset.y>=(-0.01) && offset.y<=12.01,"Steering stays inside its prepared clearance corridor")
                try check(sample.speed>=speed*0.95 && sample.speed<speed*1.4,"Steering keeps forward momentum")
                if seconds>2 && seconds<5 {
                    try check(sample.pose.eye.x>reference.pose.eye.x+(speed>20 ? 0.1 : 0.01),"Dragging right changes the actual flight path")
                    try check(sample.pose.look.y>sample.pose.eye.y,"Dragging upward makes the flight climb")
                }
                if seconds>1 && seconds<3 && sample.pose.bank < (speed>20 ? -0.003 : -0.0005) { bankedRight=true }
                if seconds>7 && sample.pose.bank > 0.003 { bankedBack=true }
                if seconds<7 { maxOffset=max(maxOffset,Double(simd_length(offset)));peakBank=max(peakBank,abs(sample.pose.bank)) }
                if tick==Int(4*hz) { middle=sample }
                last=sample
            }
            try check(maxOffset>(speed>20 ? 5 : 0.1) && peakBank>(speed>20 ? 0.003 : 0.0005),"Steering makes a visible coordinated bank and manoeuvre")
            try check(bankedRight,"Right steering banks into the turn")
            if speed>20 { try check(bankedBack,"Rejoining banks back towards the route") }
            let finish=straight.sample(time:time)
            let error=Double(simd_distance(last.pose.eye,finish.pose.eye))
            // At very slow cruise a spatial manoeuvre deliberately takes longer.
            if speed>20 { try check(error<0.5,"Release gradually rejoins the route without snapping (\(error) m)") }
            print("Steering at \(speed*3.6) km/h / \(hz) Hz: final route offset \(error) m")
            return (last,middle)
        }
        var input=WorldCinematicLook();input.begin();input.drag(dx:-10000,dy:10000)
        try check(input.yaw>0 && input.yaw<=0.9 && input.pitch<=0.6,"Long steering drags saturate without wrapping into the opposite turn")
        let saturated=input.yaw;input.drag(dx:10,dy:-10)
        try check(input.yaw<saturated,"A reverse drag immediately releases saturated steering")
        let a=try flight(hz:30,speed:150/3.6),b=try flight(hz:60,speed:150/3.6)
        try check(simd_distance(a.0.pose.eye,b.0.pose.eye)<0.03,"Steering/release is consistent at 30 and 60 Hz")
        try check(simd_distance(a.1.pose.eye,b.1.pose.eye)<0.4,"The active steering manoeuvre matches at 30 and 60 Hz")
        _=try flight(hz:60,speed:10/3.6)
        for points in [[point(0,0),point(0,-700),point(600,-700)],
                       [point(0,0),point(0,-500),point(20,-50),point(40,-450),point(0,0)]] {
            let curvedPath=WorldRouteTourPath(segments:[points])!,curvedRail=WorldFlightCorridor(path:curvedPath,tolerance:160)
            let terrain=WorldFlightTerrain(path:curvedPath,corridor:curvedRail,heights:WorldFlightTerrain.distances(length:curvedRail.length).map { _ in Float?(100) })
            let plan=try WorldFlightPlan(path:curvedPath,corridor:curvedRail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:15,cornerLift:90)
            var glide=WorldFlightGlide(),last=plan.sample(time:0)
            for time in stride(from:1.0/60,to:plan.duration,by:1.0/60) {
                let reference=plan.sample(time:time)
                let command:Float=time<plan.duration*0.3 ? 0.8 : time<plan.duration*0.6 ? -0.8 : 0
                let sample=glide.advance(reference:reference,yaw:command,pitch:0.2,speedScale:1,seconds:1/60,frame:frame,reduceMotion:false)
                let heading=simd_normalize(sample.pose.look-sample.pose.eye),movement=sample.pose.eye-last.pose.eye
                try check(simd_dot(heading,simd_normalize(movement))>0.9995,"Steering through turns retains forward gaze")
                try check(sample.speed>plan.cruiseSpeed*0.45,"Changing steering through switchbacks cannot stall the flight")
                try check(simd_length(SIMD2(sample.pose.eye.x-reference.pose.eye.x,sample.pose.eye.z-reference.pose.eye.z))<Float(WorldFlightGlide.lateralLimit)+0.01,"Curved flight stays in its corridor")
                last=sample
            }
        }
        // Fast cruise gets a shorter observation window to stay before the end.
        var glide=WorldFlightGlide(),last=straight.sample(time:0)
        for tick in 1...1200 {
            let speed=tick<300 ? 600.0/3.6 : tick<600 ? 10/3.6 : 150/3.6
            let reference=straight.sample(time:Double(tick)/60)
            let sample=glide.advance(reference:reference,yaw:tick<500 ? 3 : -3,pitch:tick<500 ? 1 : -1,speedScale:speed/25,seconds:1/60,frame:frame,reduceMotion:true)
            let offset=sample.pose.eye-reference.pose.eye
            try check(simd_length(SIMD2(offset.x,offset.z))<=Float(WorldFlightGlide.lateralLimit)+0.01 && offset.y>=(-10.01) && sample.heightAboveGround>=4.99,"Changing speed or steering direction cannot overshoot the corridor")
            try check(sample.pose.bank==0,"Reduce Motion keeps a level horizon while steering")
            last=sample
        }
        for clearance in [5.0,8,15,100] {
            var descending=WorldFlightGlide()
            let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:flat,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:clearance)
            var sample=plan.sample(time:0)
            for tick in 1...600 {
                let reference=plan.sample(time:Double(tick)/60)
                sample=descending.advance(reference:reference,yaw:0,pitch:-0.6,speedScale:1,seconds:1/60,frame:frame,reduceMotion:false,clearance:clearance)
                try check(sample.heightAboveGround>=4.99,"Downward steering retains the minimum prepared clearance")
            }
            if clearance>5 {
                try check(sample.pose.eye.y<plan.sample(time:10).pose.eye.y-0.1 && sample.pose.look.y<sample.pose.eye.y,"A downward drag descends along the viewing direction")
            }
        }
        let rebased=GeoBounds(minLatitude:52.98,minLongitude:-4.03,maxLatitude:53.03,maxLongitude:-3.97)
        let converted=WorldFlightPlan.converted(last,from:frame,to:rebased)
        func geographic(_ p:SIMD3<Float>,_ frame:GeoBounds)->GeoPoint { frame.point(u:Double(p.x)/frame.widthMeters+0.5,v:Double(p.z)/frame.depthMeters+0.5) }
        try check(geographic(last.pose.eye,frame).distance(to:geographic(converted.pose.eye,rebased))<0.02,"Streaming origin changes preserve the steered camera position")
        glide.reset()
        let reset=glide.advance(reference:straight.sample(time:0),yaw:0,pitch:0,speedScale:1,seconds:0,frame:frame,reduceMotion:false)
        try check(reset.pose.eye==straight.sample(time:0).pose.eye,"Seek/restart discards steering displacement")
        let mountain=WorldFlightTerrain(path:path,corridor:rail,heights:stations.map { _ in Float?(1000) },focusHeights:stations.map { _ in Float?(1000) })
        let mountainPlan=try WorldFlightPlan(path:path,corridor:rail,terrain:mountain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:10,routeFraming:true)
        let mountainSample=mountainPlan.sample(time:5)
        try check(abs(mountainSample.routeTarget!.y-1000)<0.01,"Route focus uses saved terrain height, including stale or absent route elevations")
        let mountainRebased=WorldFlightPlan.converted(mountainSample,from:frame,to:rebased)
        try check(geographic(mountainSample.routeTarget!,frame).distance(to:geographic(mountainRebased.routeTarget!,rebased))<0.02,"Scene rebasing preserves the route focus as well as the camera")
        // Exercise the production route-framing mode at the chosen 600 km/h.
        let tour=WorldRouteTour()
        try check(tour.speed==600 && abs(tour.metersPerSecond-600/3.6)<0.001,"Preview opens at the single chosen 600 km/h pace")
        for (name,points) in [
            ("straight",[point(0,0),point(0,-2000)]),
            ("bend",[point(0,0),point(0,-700),point(600,-700)]),
            ("kink",[point(0,0),point(0,-300),point(75,-370),point(0,-440),point(0,-1000)]),
            ("return",[point(0,0),point(0,-500),point(0,0)]),
            ("overlapping returns",[point(0,0),point(0,-350),point(20,-40),point(40,-320),point(10,0)]),
            ("switchbacks",[point(0,0),point(0,-160),point(80,-160),point(80,-240),point(0,-240),point(0,-500)])] {
            let path=WorldRouteTourPath(segments:[points])!,rail=WorldFlightCorridor(path:path,tolerance:160,routeCentred:true)
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map { _ in Float?(100) })
            let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,
                clearance:WorldRouteTour.flightClearance,cornerLift:WorldRouteTour.fpvCornerLift,routeFraming:true)
            let camera=SCNNode();camera.camera=SCNCamera();let rig=WorldCameraRig();rig.beginTour(on:camera)
            var previous=plan.sample(time:0),largestTurn:Float=0,largestAimError:Float=0
            let dt=1.0/60,scale=tour.metersPerSecond/25
            var glide=WorldFlightGlide()
            for time in stride(from:dt*scale,to:plan.duration,by:dt*scale) {
                let reference=plan.sample(time:time)
                let sample=glide.advance(reference:reference,yaw:time<plan.duration/2 ? 0.5 : 0,pitch:0,speedScale:scale,seconds:dt,frame:frame,reduceMotion:false,clearance:plan.clearance)
                let target=sample.routeTarget!,direction=simd_normalize(sample.pose.look-sample.pose.eye)
                largestTurn=max(largestTurn,acos(min(1,max(-1,simd_dot(direction,simd_normalize(previous.pose.look-previous.pose.eye))))))
                try check(sample.heightAboveGround>=9.95 && sample.heightAboveGround<=26.0,"\(name): lower flight avoids the old 90 m automatic corner lift (\(sample.heightAboveGround) m)")
                try check(simd_dot(direction,simd_normalize(target-sample.pose.eye))>0.99999,"\(name): steering retains the route focus")
                rig.fly(on:camera,pose:.init(eye:sample.pose.eye,look:sample.pose.look,bank:sample.pose.bank))
                let axis=camera.simdWorldTransform.columns.2,front = -SIMD3(axis.x,axis.y,axis.z)
                try check(simd_dot(front,simd_normalize(target-sample.pose.eye))>0.99999,"\(name): real camera centres the planned route focus while banking")
                let horizontal=simd_normalize(SIMD2(direction.x,direction.z)),travel=simd_normalize(SIMD2(sample.velocity.x,sample.velocity.z))
                largestAimError=max(largestAimError,acos(min(1,max(-1,simd_dot(horizontal,travel)))))
                try check(simd_dot(horizontal,travel)>0,"\(name): the guided view never looks backwards through a turn")
                previous=sample
            }
            print("Route framing \(name) at 600 km/h: maximum frame turn \(largestTurn) rad, maximum framing bearing \(largestAimError) rad")
            try check(largestTurn<0.06,"\(name): route framing cannot produce a sudden camera spin")
            let finish=plan.sample(time:plan.duration)
            try check(simd_dot(simd_normalize(finish.pose.look-finish.pose.eye),simd_normalize(finish.velocity))>0.95,"\(name): the finish keeps looking down the final leg")
        }
        print("PASS \(checks) terrain-envelope, forward-steering, release, bank and frame-continuity checks")
    }
}
