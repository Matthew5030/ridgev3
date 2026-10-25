import Foundation
import simd

@main struct WorldFlightMotionTests {
    @MainActor static func main() throws {
        var checks=0
        func check(_ value:Bool,_ message:String) throws { checks+=1;if !value { throw NSError(domain:message,code:1) } }
        func point(_ x:Double,_ z:Double)->RoutePoint {
            .init(coordinate:.init(latitude:53-z/111195,longitude:-4+x/(111195*cos(53 * .pi/180))),elevation:100)
        }
        let frame=GeoBounds(minLatitude:52.99,minLongitude:-4.02,maxLatitude:53.03,maxLongitude:-3.98)
        let fixtures:[(String,[RoutePoint])]=[
            ("turn",[point(0,0),point(0,-700),point(600,-700)]),
            ("return",[point(0,0),point(0,-350),point(0,0)]),
            ("multiple switchbacks",[point(0,0),point(0,-350),point(20,-40),point(40,-320),point(10,0)]),
            ("small closed return",[point(0,0),point(0,-35),point(0,0)])]
        for (name,points) in fixtures {
            let path=WorldRouteTourPath(segments:[points])!,rail=WorldFlightCorridor(path:path)
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map {_ in Float?(100)})
            try check(rail.length>1,"\(name): a closed route cannot collapse into an empty rail")
            for speed in [25.0,60] {
                let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:speed,reduceMotion:false,clearance:10)
                var previousRoute=0.0,maxBankStep:Float=0,lastBank=plan.sample(time:0).pose.bank,minSpeed=Double.infinity
                for t in stride(from:0.02,to:plan.duration-0.02,by:1.0/60) {
                    let sample=plan.sample(time:t),direction=simd_normalize(sample.pose.look-sample.pose.eye)
                    let velocity=simd_normalize(sample.velocity)
                    let movement=plan.sample(time:t+0.01).pose.eye-plan.sample(time:t-0.01).pose.eye
                    try check(simd_dot(direction,velocity)>0.99999,"\(name): camera heading exactly follows its velocity")
                    try check(simd_dot(direction,simd_normalize(movement))>0.9999,"\(name): camera cannot slide sideways across its visible direction")
                    try check(sample.routeDistance>=previousRoute,"\(name): switchback traversal keeps route order")
                    try check(abs(sample.heightAboveGround-10)<0.01,"\(name): no hidden height boost on turns")
                    minSpeed=min(minSpeed,sample.speed);previousRoute=sample.routeDistance
                    if abs(sample.pose.bank-lastBank)>maxBankStep { maxBankStep=abs(sample.pose.bank-lastBank) };lastBank=sample.pose.bank
                }
                try check(minSpeed>speed*0.7,"\(name): broad turns keep forward momentum (\(minSpeed))")
                // A tiny return cannot support a high-speed cinematic turn, but
                // normal-size bends still need continuous banking at 60 fps.
                try check(maxBankStep<0.02,"\(name): bank has no per-frame jolts (\(maxBankStep))")
                print("\(name) at \(speed*3.6) km/h: min speed \(minSpeed*3.6), max bank step \(maxBankStep)")
            }
            if name=="multiple switchbacks" {
                var reversals=0,lastSign=0.0
                for distance in stride(from:2.0,to:rail.length-2,by:2) {
                    let sign=rail.sample(flightDistance:distance).direction.y
                    if abs(sign)>0.5 { if lastSign*sign<0 { reversals+=1 };lastSign=sign }
                }
                try check(reversals>=3,"Distinct overlapping switchbacks cannot be mistaken for a single out-and-back oval (\(reversals))")
            }
        }
        let longReturn=WorldRouteTourPath(segments:[[point(0,0),point(0,-10000),point(0,0)]])!
        let longRail=WorldFlightCorridor(path:longReturn)
        for distance in stride(from:0.0,through:longRail.length,by:20) {
            let point=longRail.sample(flightDistance:distance).point
            let lateral=abs((point.longitude+4)*111195*cos(53 * .pi/180))
            try check(lateral<110,"A long out-and-back stays within the flight corridor instead of making a kilometre-wide oval")
        }
        let path=WorldRouteTourPath(segments:[[point(0,0),point(0,-2000)]])!,rail=WorldFlightCorridor(path:path)
        let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map {_ in Float?(100)})
        for height in [5.0,20,80,150] {
            let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:height)
            try check(abs(plan.sample(time:plan.duration/2).heightAboveGround-height)<0.01,"Flat terrain uses the selected \(height) m clearance")
        }
        let changing=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:10,speedChangeAt:500,initialSpeed:25,initialAltitude:180)
        try check(abs(changing.sample(time:changing.time(at:500)).pose.eye.y-180)<0.02,"Changing height starts at the current altitude without teleporting")
        try check(abs(changing.sample(time:changing.time(at:900)).heightAboveGround-10)<0.02,"Height change reaches the selected clearance")
        print("PASS \(checks) forward flight, switchback order, coordinated heading and adjustable height checks")
    }
}
