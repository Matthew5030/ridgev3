import Foundation
import SceneKit
import simd

@main struct WorldFlightCorridorTests {
    @MainActor static func main() throws {
        var count=0
        func check(_ value:Bool,_ message:String) throws {
            count+=1
            if !value { throw NSError(domain:message,code:1) }
        }
        let longitudeScale=cos(53 * Double.pi/180)
        func point(_ x:Double,_ z:Double)->RoutePoint {
            RoutePoint(coordinate:GeoPoint(latitude:53-z/111_195,longitude:-4+x/(111_195*longitudeScale)),elevation:100)
        }
        func local(_ p:GeoPoint)->SIMD2<Double> { SIMD2((p.longitude+4)*111_195*longitudeScale,(53-p.latitude)*111_195) }
        let fixtures:[(String,[RoutePoint])]=[
            ("noisy straight",(0...300).map { point(sin(Double($0)*1.7)*4,-Double($0)*3) }),
            ("right angle",[point(0,0),point(0,-300),point(300,-300)]),
            ("exact reversal",[point(0,0),point(0,-300),point(0,0)]),
            ("hairpin",[point(0,0),point(0,-300),point(15,-300),point(15,0)]),
            ("S bends",[point(0,0),point(0,-150),point(180,-150),point(180,-350),point(0,-350),point(0,-550)]),
            ("two metre route",[point(0,0),point(0,-2)])]
        for (name,points) in fixtures {
            let path=WorldRouteTourPath(segments:[points])!,corridor=WorldFlightCorridor(path:path)
            try check(corridor.length.isFinite && corridor.length>0,"\(name): rail has finite positive length")
            try check(corridor.sample(routeDistance:0).point.distance(to:points[0].coordinate)<0.01,"\(name): rail starts at the route start")
            try check(corridor.sample(routeDistance:path.length).point.distance(to:points.last!.coordinate)<0.01,"\(name): rail finishes at the route finish")
            var previous=corridor.sample(flightDistance:0),largestTurn=0.0,maxOffset=0.0
            for distance in stride(from:1.0,through:corridor.length,by:1) {
                let next=corridor.sample(flightDistance:distance),p=local(next.point)
                let step=previous.point.distance(to:next.point)
                try check(step>0.7 && step<1.02,"\(name): arc-length traversal cannot stall or jump at a corner (\(step))")
                try check(next.routeDistance>=previous.routeDistance,"\(name): route progress remains monotonic through a swoop")
                let turn=abs(atan2(previous.direction.x*next.direction.y-previous.direction.y*next.direction.x,simd_dot(previous.direction,next.direction)))
                largestTurn=max(largestTurn,turn)
                var nearest=Double.infinity
                for i in 1..<points.count {
                    let a=local(points[i-1].coordinate),delta=local(points[i].coordinate)-a,square=simd_length_squared(delta)
                    let t=square>0 ? min(1,max(0,simd_dot(p-a,delta)/square)) : 0
                    nearest=min(nearest,simd_distance(p,a+delta*t))
                }
                maxOffset=max(maxOffset,nearest)
                previous=next
            }
            try check(maxOffset<200,"\(name): flight stays inside the broader camera corridor (\(maxOffset))")
            try check(largestTurn<0.18,"\(name): no instantaneous reversal or heading flicker (\(largestTurn))")
            if name=="exact reversal" {
                let extrema=stride(from:0.0,through:corridor.length,by:2).map { local(corridor.sample(flightDistance:$0).point) }
                try check(extrema.map(\.y).min()! < -280 && extrema.map { abs($0.x) }.max()!>20,"An out-and-back becomes one broad oval instead of reversing on the line")
            }
            if name=="noisy straight" { try check(largestTurn<0.005,"Digitising noise does not propagate into the flight heading") }
            var progress=0.0
            for _ in 0..<10 { progress=corridor.advance(from:progress,metres:0.5) }
            try check(abs(corridor.flightDistance(at:progress)-min(5,corridor.length))<0.0001,"\(name): traversal uses flight metres independently of route sample density")
            print("\(name): \(Int(corridor.length)) m rail; max turn \(largestTurn); max offset \(maxOffset) m")
        }
        let straight=WorldRouteTourPath(segments:[[point(0,0),point(0,-2000)]])!,rail=WorldFlightCorridor(path:straight)
        try check(abs(rail.speedLimit(at:200,requested:200)-200)<0.001,"Straight flight keeps the requested fast speed")
        let frame=GeoBounds(minLatitude:52.98,minLongitude:-4.02,maxLatitude:53.03,maxLongitude:-3.98)
        let terrain:(GeoPoint)->Float={ p in 100+Float(sin(local(p).y*1.5))*2 }
        var dynamics=WorldFlightDynamics(),previous:Float?,largestStep:Float=0
        for i in 0..<600 {
            let distance=Double(i)*0.7
            let pose=WorldRouteTourCamera.pose(path:straight,distance:distance,frame:frame,corridor:rail,elevation:terrain)
            let value=dynamics.update(height:pose.eye.y,floor:terrain(pose.focus)+6,bank:pose.bank,seconds:1.0/60)
            if let previous { largestStep=max(largestStep,abs(value.height-previous)) }
            previous=value.height
            try check(value.height>=terrain(pose.focus)+6,"Damped height preserves terrain clearance")
        }
        try check(largestStep<0.12,"Metre-scale terrain noise cannot make the camera bob every frame (\(largestStep))")
        var sixty=WorldFlightDynamics(),thirty=WorldFlightDynamics()
        _=sixty.update(height:100,floor:0,bank:0,seconds:0);_ = thirty.update(height:100,floor:0,bank:0,seconds:0)
        for _ in 0..<120 { _=sixty.update(height:120,floor:0,bank:0.1,seconds:1.0/60) }
        for _ in 0..<60 { _=thirty.update(height:120,floor:0,bank:0.1,seconds:1.0/30) }
        try check(abs(sixty.altitude!-thirty.altitude!)<0.001 && abs(sixty.bank-thirty.bank)<0.0001,"Height and bank damping are consistent at 30/60 Hz")
        let camera=SCNNode();camera.simdPosition=SIMD3(0,10,0)
        WorldCameraOrientation.aim(camera,at:SIMD3(0,10,-80),bank:0.12)
        try check(abs(camera.simdWorldTransform.columns.0.y-sin(0.12))<0.0001,"The native camera applies only the intended small bank")
        let turnPath=WorldRouteTourPath(segments:[fixtures[2].1])!,turnRail=WorldFlightCorridor(path:turnPath)
        var finePrevious=turnRail.sample(flightDistance:150).direction,largestFineTurn=0.0
        for distance in stride(from:150.05,through:turnRail.length-150,by:0.05) {
            let next=turnRail.sample(flightDistance:distance).direction
            largestFineTurn=max(largestFineTurn,abs(atan2(finePrevious.x*next.y-finePrevious.y*next.x,simd_dot(finePrevious,next))))
            finePrevious=next
        }
        try check(largestFineTurn<0.009,"Heading remains continuous across every rail table boundary, including sub-metre movement (\(largestFineTurn))")
        let slowBank=WorldFlightTurn.bank(curvature:0.02,speed:5,overview:0)
        let fastBank=WorldFlightTurn.bank(curvature:0.02,speed:15,overview:0)
        try check(slowBank<0 && fastBank<slowBank*2,"Turn banking grows with actual speed and leans into the bend")
        try check(abs(WorldFlightTurn.bank(curvature:-0.02,speed:15,overview:0)+fastBank)<0.0001,"Opposite turns bank in opposite directions")
        try check(abs(WorldFlightTurn.bank(curvature:1,speed:300,overview:0)-Float(-Double.pi/10))<0.0001,"Isolated bends never exceed 18 degrees of bank")
        try check(abs(WorldFlightTurn.bank(curvature:1,speed:300,overview:1))<0.210,"Overview flight limits bank to 12 degrees")
        let busy=WorldRouteTourPath(segments:[[point(0,0),point(0,-160),point(80,-160),point(80,-240),point(0,-240),point(0,-320),point(80,-320),point(80,-500)]])!
        let busyRail=WorldFlightCorridor(path:busy)
        let busyDistance=busy.length*0.5
        try check(busyRail.sample(routeDistance:busyDistance).overview>=0 && busyRail.length<busy.length*0.8,"Repeated switchbacks are bypassed on a shorter fitted rail")
        try check(turnRail.speedLimit(at:180,requested:336)>275,"Corner pacing scales with requested speed instead of hiding an absolute speed cap")
        var turnPace=WorldFlightPace(),heading=WorldCinematicHeading(),progress=0.0,lastDirection:SIMD3<Float>?
        var largestLag:Float=0,frames=0
        while progress<turnPath.length && frames<10000 {
            let speed=turnRail.speedLimit(at:progress,requested:84)
            progress=turnRail.advance(from:progress,metres:turnPace.metres(target:speed,seconds:1.0/60))
            let pose=WorldRouteTourCamera.pose(path:turnPath,distance:progress,frame:frame,corridor:turnRail,flightSpeed:turnPace.currentSpeed,elevation:{_ in 100})
            let desired=simd_normalize(pose.look-pose.eye),direction=heading.direction(toward:desired,seconds:1.0/60)
            if let previous=lastDirection {
                let turn=acos(min(1,max(-1,simd_dot(previous,direction))))
                try check(turn<0.031,"A complete fast turnaround has bounded native camera rotation at every frame")
            }
            largestLag=max(largestLag,acos(min(1,max(-1,simd_dot(desired,direction)))))
            lastDirection=direction;frames+=1
        }
        try check(progress>=turnPath.length,"The smoothed rail completes a full out-and-back without stalling")
        try check(largestLag<0.45,"Camera heading keeps up with the flight direction instead of lagging around a corner (\(largestLag))")
        print("Fast turnaround completed in \(Double(frames)/60) s; maximum camera lag \(largestLag*180 / .pi) degrees")
        let posed=WorldRouteTourCamera.pose(path:turnPath,distance:300,frame:frame,corridor:turnRail,cinematicMotion:false,elevation:{_ in 100})
        try check(posed.bank==0,"Reduce Motion disables banking as well as sway")
        var pace=WorldFlightPace()
        _=pace.metres(target:10,seconds:1.0/60)
        let metres=pace.metres(target:100,seconds:1.0/60)
        try check(metres<0.18,"Speed changes accelerate gradually rather than jumping")
        let long=WorldRouteTourPath(segments:[(0...20000).map { point(sin(Double($0))*2,-Double($0)*3) }])!
        let began=Date(),longRail=WorldFlightCorridor(path:long)
        try check(longRail.length>59000,"Large imported routes build without recursive subdivision")
        print("20,001-point / 60 km rail prepared in \(Date().timeIntervalSince(began)) s on this Mac")
        print("PASS \(count) smooth corridor, corner, pace, clearance and banking checks")
    }
}
