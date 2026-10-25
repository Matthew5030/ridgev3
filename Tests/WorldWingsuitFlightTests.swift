import Foundation
import simd

@main struct WorldWingsuitFlightTests {
    @MainActor static func main() throws {
        var checks=0
        func check(_ condition:Bool,_ message:String) throws { checks+=1;if !condition { throw NSError(domain:message,code:1) } }
        func point(_ x:Double,_ z:Double)->RoutePoint { .init(coordinate:.init(latitude:53-z/111195,longitude:-4+x/(111195*cos(53 * .pi/180))),elevation:100) }
        let frame=GeoBounds(minLatitude:52.98,minLongitude:-4.03,maxLatitude:53.03,maxLongitude:-3.97)
        let fixtures:[(String,[RoutePoint])]=[
            ("corner",[point(0,0),point(0,-350),point(400,-350)]),
            ("return",[point(0,0),point(0,-1000),point(0,0)]),
            ("overlapping-switchbacks",[point(0,0),point(0,-350),point(20,-40),point(40,-320),point(10,0)]),
            ("switchbacks",[point(0,0),point(0,-160),point(80,-160),point(80,-240),point(0,-240),point(0,-320),point(80,-320),point(80,-500)])]
        for (name,points) in fixtures {
            let tour=WorldRouteTour();tour.open(route:.init(name:name,regionID:"qa",segments:[.init(points:points,mode:"direct")]))
            let path=tour.path!,rail=tour.corridor!
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map {_ in Float?(100)})
            let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:WorldRouteTour.preparedSpeed,reduceMotion:false,clearance:tour.clearance,cornerLift:WorldRouteTour.fpvCornerLift)
            var maxError=0.0,bankSign:Float=0
            for time in stride(from:0.0,through:plan.duration,by:0.05) {
                let sample=plan.sample(time:time),route=path.sample(at:sample.routeDistance).coordinate
                if name=="overlapping-switchbacks",abs(sample.pose.bank)>0.002 {
                    if bankSign==0 { bankSign=sample.pose.bank }
                    try check(bankSign*sample.pose.bank>0,"Overlapping switchbacks form one sweep, without alternating turnaround loops")
                }
                let error=route.distance(to:sample.pose.focus);maxError=max(maxError,error)
                try check(error<800,"\(name): a broad flight remains in the route neighbourhood (\(error))")
                try check(sample.heightAboveGround>14.5 && sample.heightAboveGround<130,"FPV stays low on straights and makes a bounded anticipatory lift over busy turns")
                let v=SIMD2(sample.velocity.x,sample.velocity.z),gaze=SIMD2(sample.pose.look.x-sample.pose.eye.x,sample.pose.look.z-sample.pose.eye.z)
                try check(simd_dot(simd_normalize(v),simd_normalize(gaze))>0.99999,"FPV horizontal heading stays aligned to actual forward travel")
                try check(simd_length(v)>Float(plan.cruiseSpeed*0.7),"Switchbacks cannot stall or trap the FPV camera")
            }
            if name=="switchbacks" {
                let middle=plan.sample(time:plan.duration*0.5),heading=simd_normalize(SIMD2(middle.velocity.x,middle.velocity.z))
                try check(simd_dot(heading,SIMD2<Float>(0,-1))>0.98,"A cluster of 80 m switchbacks is crossed in one forward pass")
                try check(middle.heightAboveGround>35,"FPV gains height over the skipped switchback cluster")
            }
            var slow=WorldFlightPlayback(),fast=WorldFlightPlayback();slow.reset(speed:30/3.6);fast.reset(speed:240/3.6)
            var a=0.0,b=0.0
            for _ in 0..<120 { a+=slow.advance(seconds:1/60,requested:30/3.6,preparedSpeed:25);b+=fast.advance(seconds:1/60,requested:240/3.6,preparedSpeed:25) }
            try check(abs(b/a-8)<0.001,"The same prepared flight runs eight times faster at 240 than 30 km/h without rebuilding terrain")
            let origin=plan.sample(time:0).pose.eye,slowDistance=simd_distance(origin,plan.sample(time:a).pose.eye),fastDistance=simd_distance(origin,plan.sample(time:b).pose.eye)
            try check(fastDistance>slowDistance*5.5,"Changing cruise speed produces a large visible camera-distance change on the same flight")
            print("\(name): maximum route-marker separation \(maxError) m")
        }
        var changing=WorldFlightPlayback();changing.reset(speed:30/3.6)
        let first=changing.advance(seconds:1/60,requested:240/3.6,preparedSpeed:25)
        try check(first>30/3.6/60/25,"A speed change affects the very next display frame")
        for _ in 0..<180 { _=changing.advance(seconds:1/60,requested:240/3.6,preparedSpeed:25) }
        try check(changing.speed>66,"Acceleration reaches the selected cruise speed")
        var thirty=WorldFlightPlayback(),sixty=WorldFlightPlayback();thirty.reset(speed:10);sixty.reset(speed:10)
        var a=0.0,b=0.0
        for _ in 0..<90 { a+=thirty.advance(seconds:1/30,requested:60,preparedSpeed:25) }
        for _ in 0..<180 { b+=sixty.advance(seconds:1/60,requested:60,preparedSpeed:25) }
        try check(abs(a-b)<0.00001,"Playback acceleration is independent of display refresh rate")
        var quick=WorldFlightPlayback();quick.reset(speed:10/3.6)
        for _ in 0..<60 { _=quick.advance(seconds:1/60,requested:600/3.6,preparedSpeed:25) }
        try check(quick.speed>600/3.6*0.98,"The fastest speed takes effect within one second, without a replan")
        for _ in 0..<60 { _=quick.advance(seconds:1/60,requested:10/3.6,preparedSpeed:25) }
        try check(quick.speed<6,"Dragging back to slow cruise decelerates promptly")
        var irregular=WorldFlightPlayback(),regular=WorldFlightPlayback();irregular.reset(speed:15);regular.reset(speed:15)
        var irregularTime=0.0,regularTime=0.0
        for _ in 0..<40 {
            for dt in [1.0/60,1.0/30,1.0/20,1.0/40] { irregularTime+=irregular.advance(seconds:dt,requested:600/3.6,preparedSpeed:25) }
        }
        for _ in 0..<300 { regularTime+=regular.advance(seconds:1.0/60,requested:600/3.6,preparedSpeed:25) }
        try check(abs(irregularTime-regularTime)<0.00001,"Variable display cadence does not change distance or selected speed")
        var bank:Float=0
        for i in 0..<200 { let next=changing.roll(toward:i%20<10 ? 0.3 : -0.3,seconds:1/60);try check(abs(next-bank)<=0.22/60+0.00001,"Rapid switchbacks cannot flap the camera bank");bank=next }
        let path=WorldRouteTourPath(segments:[[point(0,0),point(0,-2400)]])!,rail=WorldFlightCorridor(path:path,tolerance:12)
        let stations=WorldFlightTerrain.distances(length:rail.length)
        let flatTerrain=WorldFlightTerrain(path:path,corridor:rail,heights:stations.map { _ in Float?(100) })
        let straight=try WorldFlightPlan(path:path,corridor:rail,terrain:flatTerrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:15,cornerLift:90)
        var crawl=WorldFlightPlayback(),sprint=WorldFlightPlayback();crawl.reset(speed:10/3.6);sprint.reset(speed:600/3.6)
        var crawlTime=0.0,sprintTime=0.0
        for _ in 0..<120 {
            crawlTime+=crawl.advance(seconds:1/60,requested:10/3.6,preparedSpeed:straight.cruiseSpeed)
            sprintTime+=sprint.advance(seconds:1/60,requested:600/3.6,preparedSpeed:straight.cruiseSpeed)
        }
        let start=straight.sample(time:0).pose.eye
        let slowTravel=simd_distance(start,straight.sample(time:crawlTime).pose.eye)
        let fastTravel=simd_distance(start,straight.sample(time:sprintTime).pose.eye)
        try check(abs(fastTravel/slowTravel-60)<0.01,"The complete 10–600 km/h control range changes visible camera travel by 60 times")
        let heights=stations.map { Float?(100+200*Float(exp(-pow(($0-1200)/200,2)))) }
        let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:heights)
        let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:15)
        try check(plan.sample(time:0).heightAboveGround<17 && plan.sample(time:plan.duration).heightAboveGround<17,"A summit cannot lift the entire valley above the fixed low glide")
        for time in stride(from:0.0,through:plan.duration,by:0.1) { try check(plan.sample(time:time).heightAboveGround>14.0,"Local hill anticipation preserves clearance") }
        print("PASS \(checks) FPV route tracking, low clearance and responsive speed checks")
    }
}
