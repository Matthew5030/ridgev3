import Foundation
import simd

@main struct WorldFlightBestFitTests {
    @MainActor static func main() throws {
        var checks=0
        func check(_ value:Bool,_ message:String) throws { checks+=1;if !value { throw NSError(domain:message,code:1) } }
        func point(_ x:Double,_ z:Double)->RoutePoint {
            .init(coordinate:.init(latitude:53-z/111195,longitude:-4+x/(111195*cos(53 * .pi/180))),elevation:100)
        }
        let frame=GeoBounds(minLatitude:52.99,minLongitude:-4.02,maxLatitude:53.03,maxLongitude:-3.98)
        let kink=WorldRouteTourPath(segments:[[point(0,0),point(0,-300),point(75,-370),point(0,-440),point(0,-1000)]])!
        let rail=WorldFlightCorridor(path:kink)
        try check(abs(rail.length-1000)<0.02,"A 75 m route kink is flown straight over, not rounded into another camera turn")
        let elevations=WorldFlightTerrain.distances(length:rail.length).map { _ in Float?(100) }
        let terrain=WorldFlightTerrain(path:kink,corridor:rail,heights:elevations)
        let normal=try WorldFlightPlan(path:kink,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false)
        let fast=try WorldFlightPlan(path:kink,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:50,reduceMotion:false)
        try check(abs(normal.duration/fast.duration-2)<0.0001,"Doubling speed halves flight duration even where the underlying route has a kink")
        var minSpeed=Double.infinity,maxBank:Float=0,maxTurn:Float=0,last:SIMD3<Float>?
        for t in stride(from:0.1,through:normal.duration-0.1,by:0.1) {
            let sample=normal.sample(time:t),previous=normal.sample(time:t-0.01)
            let measured=Double(simd_distance(sample.pose.eye,previous.pose.eye))/0.01
            minSpeed=min(minSpeed,measured)
            maxBank=max(maxBank,abs(sample.pose.bank))
            let direction=simd_normalize(sample.pose.look-sample.pose.eye)
            if let last { maxTurn=max(maxTurn,simd_length(direction-last)) };last=direction
            try check(measured>24.8 && measured<25.2,"Small route kinks cannot silently slow the flight below its selected speed")
        }
        try check(maxBank<0.0001 && maxTurn<0.0001,"An ignored kink produces no banking, weaving or head movement")
        let dense=WorldRouteTourPath(segments:[[point(0,0),point(0,-160),point(80,-160),point(80,-240),point(0,-240),point(0,-320),point(80,-320),point(80,-500)]])!
        let denseRail=WorldFlightCorridor(path:dense)
        try check(denseRail.length<dense.length*0.8,"A cluster of switchbacks is crossed on one broad best-fit line")
        let denseGround=WorldFlightTerrain.distances(length:denseRail.length).map { _ in Float?(100) }
        let denseTerrain=WorldFlightTerrain(path:dense,corridor:denseRail,heights:denseGround)
        let densePlan=try WorldFlightPlan(path:dense,corridor:denseRail,terrain:denseTerrain,frame:frame,cruiseSpeed:25,reduceMotion:false)
        let denseFast=try WorldFlightPlan(path:dense,corridor:denseRail,terrain:denseTerrain,frame:frame,cruiseSpeed:50,reduceMotion:false)
        try check(abs(densePlan.duration/denseFast.duration-2)<0.0001,"The speed setting still scales correctly across dense route turns")
        try check(abs(densePlan.sample(time:densePlan.duration/2).pose.eye.y-120)<0.01,"Bypassed switchbacks respect the selected flight height")
        let straight=WorldRouteTourPath(segments:[[point(0,0),point(0,-2000)]])!,straightRail=WorldFlightCorridor(path:straight)
        let stations=WorldFlightTerrain.distances(length:straightRail.length)
        let noisyHeights=stations.map { Float?(100+6*Float(sin($0/2))) }
        let noisy=WorldFlightTerrain(path:straight,corridor:straightRail,heights:noisyHeights)
        let quiet=WorldFlightTerrain(path:straight,corridor:straightRail,heights:stations.map { _ in Float?(100) })
        let noisyPlan=try WorldFlightPlan(path:straight,corridor:straightRail,terrain:noisy,frame:frame,cruiseSpeed:25,reduceMotion:false)
        let quietPlan=try WorldFlightPlan(path:straight,corridor:straightRail,terrain:quiet,frame:frame,cruiseSpeed:25,reduceMotion:false)
        var low=Float.infinity,high = -Float.infinity,maxPitchDifference:Float=0
        for t in stride(from:0.0,through:noisyPlan.duration,by:0.1) {
            let a=noisyPlan.sample(time:t).pose,b=quietPlan.sample(time:t).pose
            low=min(low,a.eye.y);high=max(high,a.eye.y)
            let da=simd_normalize(a.look-a.eye),db=simd_normalize(b.look-b.eye)
            maxPitchDifference=max(maxPitchDifference,abs(da.y-db.y))
            try check(a.eye.y>125,"The broad height fit safely clears six-metre terrain ripples")
        }
        try check(high-low<0.5,"Terrain ripples cannot bob the camera height (range \(high-low) m)")
        try check(maxPitchDifference<0.003,"Terrain ripple pitch stays below 0.18 degrees (\(maxPitchDifference) rad)")
        let changing=try WorldFlightPlan(path:straight,corridor:straightRail,terrain:quiet,frame:frame,cruiseSpeed:50,reduceMotion:false,speedChangeAt:500,initialSpeed:25)
        try check(abs(changing.sample(time:changing.time(at:500)).speed-25)<0.1,"Changing cruise speed starts from the existing flight speed")
        try check(changing.sample(time:changing.time(at:900)).speed>49.9,"The prepared acceleration reaches the new selected speed")
        let returning=WorldRouteTourPath(segments:[[point(0,0),point(0,-300),point(0,0)]])!,returnRail=WorldFlightCorridor(path:returning)
        let returnTerrain=WorldFlightTerrain(path:returning,corridor:returnRail,heights:WorldFlightTerrain.distances(length:returnRail.length).map {_ in Float?(100)})
        let loop=try WorldFlightPlan(path:returning,corridor:returnRail,terrain:returnTerrain,frame:frame,cruiseSpeed:25,reduceMotion:false)
        let fastLoop=try WorldFlightPlan(path:returning,corridor:returnRail,terrain:returnTerrain,frame:frame,cruiseSpeed:50,reduceMotion:false)
        try check(abs(loop.duration/fastLoop.duration-2)<0.0001,"Doubling speed also halves a real turnaround, without an absolute corner cap")
        var sign:Float=0
        for t in stride(from:0.0,through:loop.duration,by:0.1) {
            let sample=loop.sample(time:t)
            if abs(sample.pose.bank)>0.001 {
                if sign==0 { sign=sample.pose.bank }
                try check(sample.pose.bank*sign>0,"An out-and-back holds one sweeping turn instead of banking left then right")
            }
        }
        let tour=WorldRouteTour();tour.open(route:RidgeRoute(name:"Speed display",regionID:"qa",segments:[.init(points:kink.points,mode:"direct")]))
        tour.isPreparing=false;tour.speed=90;tour.reportSpeed(25)
        try check(abs(tour.metersPerSecond-25)<0.0001 && tour.actualKilometersPerHour==90,"Both target and measured speed use real km/h")
        tour.isPreparing=true
        try check(tour.actualKilometersPerHour==90,"A background speed re-plan cannot hide continuing measured movement")
        tour.pause();try check(tour.actualKilometersPerHour==0,"Paused playback does not claim to be travelling")
        print("Ignored kink: \(rail.length) m straight flight; minimum measured speed \(minSpeed*3.6) km/h; max bank \(maxBank) rad")
        print("Terrain ripple test: height range \(high-low) m; pitch difference \(maxPitchDifference) rad")
        print("PASS \(checks) best-fit flight, terrain independence and real speed checks")
    }
}
