import Foundation
import SceneKit
import simd

@main struct WorldRouteTourTests {
    @MainActor static func main() throws {
        var count=0
        func check(_ value:Bool,_ message:String) throws {
            count+=1
            if !value { throw NSError(domain:message,code:1) }
        }
        func point(_ meters:Double,_ elevation:Double? = 100) -> RoutePoint {
            RoutePoint(coordinate:GeoPoint(latitude:53+meters/111_195,longitude:-4),elevation:elevation)
        }
        let path=WorldRouteTourPath(segments:[[point(0),point(1),point(1),point(10),point(1000)]])!
        try check(path.points.count==4,"Duplicate points do not create zero-length interpolation")
        try check(abs(path.length-1000)<0.01,"Physical path length uses metres")
        for distance in stride(from:0.0,through:1000.0,by:5) {
            let sample=path.sample(at:distance)
            try check(abs(point(0).coordinate.distance(to:sample.coordinate)-distance)<0.01,"Uneven point spacing must not change traversal speed")
        }
        try check(path.sample(at:-100)==point(0),"Seeking before start clamps")
        try check(path.sample(at:2000)==point(1000),"Seeking after finish clamps")
        try check(path.sample(at:.nan)==point(0),"Nonfinite seeks remain safe")
        let endHeading=path.heading(at:path.length,lookAhead:12)
        try check(endHeading.to.coordinate.latitude>endHeading.from.coordinate.latitude,"The finish camera must keep looking forwards")
        try check(WorldRouteTourPath(segments:[]) == nil,"No route cannot play")
        try check(WorldRouteTourPath(segments:[[point(0),point(0)]]) == nil,"A single location cannot play")
        try check(WorldRouteTourPath(segments:[[point(0),point(10)],[point(100),point(200)]]) == nil,"GPX gaps cannot invent a connecting walk")
        try check(WorldRouteTourPath(segments:[[point(0),point(10)],[],[point(10),point(100)]]) != nil,"Shared segment endpoints form one continuous route")
        try check(WorldRouteTourPath(segments:[[point(0),RoutePoint(coordinate:.init(latitude:.nan,longitude:0),elevation:0)]]) == nil,"Invalid coordinates cannot produce a camera")
        let unknown=WorldRouteTourPath(segments:[[point(0,nil),point(10)]])!
        try check(unknown.sample(at:5).elevation == nil,"Missing elevations remain unknown")
        let climb=WorldRouteTourPath(segments:[[point(0,0),point(100,100)]])!
        try check(abs((climb.sample(at:50).elevation ?? -1)-50)<0.01,"Known heights interpolate by distance")
        let frame=GeoBounds(minLatitude:52.99,minLongitude:-4.01,maxLatitude:53.02,maxLongitude:-3.99)
        for distance in [0.0,1,500,path.length] {
            let pose=WorldRouteTourCamera.pose(path:path,distance:distance,frame:frame,elevation:{ _ in 340 })
            try check(abs(pose.eye.y-350)<0.001,"Cinematic flight stays ten metres above rendered ground")
            try check(pose.look.z<pose.eye.z,"Camera follows the route heading including at its finish")
            let camera=SCNNode();camera.simdPosition=pose.eye;WorldCameraOrientation.aim(camera,at:pose.look)
            try check(abs(camera.simdWorldTransform.columns.0.y)<0.0001,"Cinematic horizon remains level")
        }
        let short=WorldRouteTourPath(segments:[[point(0),point(2)]])!
        let shortPose=WorldRouteTourCamera.pose(path:short,distance:short.length,frame:frame,elevation:{ _ in 0 })
        try check(shortPose.look.z<shortPose.eye.z,"Very short routes still face forwards at their end")
        let raised=WorldRouteTourCamera.pose(path:path,distance:500,frame:frame,elevation:{ _ in 1000 })
        try check(abs(raised.eye.y-1010)<0.001,"Low flight clears raised terrain at the camera itself")
        let still=WorldRouteTourCamera.pose(path:path,distance:200,frame:frame,cinematicMotion:false,elevation:{ _ in 100 })
        try check(abs(still.eye.x)<0.001,"Reduce Motion removes lateral cinematic drift")
        let chart=[RouteProfileSample(distance:0,point:point(0,100),breakBefore:false,unknownBefore:false),
                   RouteProfileSample(distance:100,point:point(100,300),breakBefore:false,unknownBefore:false)]
        try check(abs((WorldRouteProfile.position(in:chart,at:25)?.elevation ?? 0)-150)<0.001,"Elevation marker interpolates along travelled distance")
        try check(abs((WorldRouteProfile.distance(nearest:point(35).coordinate,in:chart) ?? 0)-35)<0.01,"Planning selection stays in sync with the profile")
        var missing=chart;missing[1].point.elevation=nil
        try check(WorldRouteProfile.position(in:missing,at:50)?.elevation == nil,"Elevation scrubbing preserves unknown heights")
        var broken=chart;broken[1].breakBefore=true
        try check(WorldRouteProfile.position(in:broken,at:50) == nil,"Chart scrubbing never interpolates a track gap")
        try check(WorldRouteProfile.position(in:[],at:0) == nil,"An empty route has no profile marker")
        let tour=WorldRouteTour()
        let route=RidgeRoute(name:"Preview test",regionID:"test",segments:[RouteSegment(points:path.points,mode:"track")])
        try check(tour.open(route:route) && tour.isPresented && tour.isPlaying,"Preview opens playing")
        try check(tour.isEntering && !tour.canAdvance && !tour.isTerrainReady,"The entry animation holds the route clock while terrain prepares")
        tour.isTerrainReady=true
        try check(!tour.canAdvance,"Terrain readiness alone cannot run the journey behind the intro")
        tour.revealEntry()
        try check(tour.isRevealing && !tour.canAdvance,"The door shot and descent hold route progress until the glide begins")
        tour.finishEntry()
        try check(tour.canAdvance && !tour.isEntering,"Completing the reveal releases forward playback")
        try check(tour.clearance==15,"The FPV preview retains its low straight-line clearance")
        tour.speed=10
        try check(abs(tour.metersPerSecond-10.0/3.6)<0.001,"Cruise control is in real km/h")
        tour.speed=60
        try check(abs(tour.metersPerSecond-60.0/3.6)<0.001,"60 km/h converts to physical metres per second")
        tour.speed=240
        try check(abs(tour.metersPerSecond-240.0/3.6)<0.001,"240 km/h is a physical cruise speed")
        tour.speed=600
        try check(abs(tour.metersPerSecond-600.0/3.6)<0.001,"The fastest visible preset is actually 600 km/h")
        tour.speed=900
        try check(tour.metersPerSecond==600.0/3.6,"The control bounds clamp excessive input")
        tour.isTerrainReady=false
        try check(tour.canAdvance,"Once the intro finishes, missing visual detail never freezes the route clock")
        tour.pause()
        try check(!tour.isPlaying && tour.isPresented,"Pause retains the route preview")
        let revision=tour.seekRevision
        tour.seek(to:0.5)
        try check(tour.seekRevision>revision && tour.progress==0.5,"Scrubbing issues a new camera seek")
        tour.report(distance:path.length)
        try check(tour.progress==1 && !tour.isPlaying,"Playback stops at the finish")
        tour.togglePlayback()
        try check(tour.progress==0 && tour.isPlaying,"Replay restarts from the beginning")
        tour.seek(to:2)
        try check(tour.progress==1,"Slider seeks clamp to the end")
        tour.seek(to:.nan)
        try check(tour.progress==0,"Invalid slider values cannot poison playback")
        let first=RouteWaypoint(point:point(0),name:"Start")
        let middle=RouteWaypoint(point:point(100),name:"Turnaround")
        let last=RouteWaypoint(point:point(0),name:"Finish")
        let loop=RidgeRoute(name:"Loop",regionID:"test",waypoints:[first,middle,last],segments:[
            RouteSegment(points:[first.point,middle.point],mode:"direct"),
            RouteSegment(points:[middle.point,last.point],mode:"direct")])
        try check(tour.open(route:loop,startingAtWaypoint:middle.id) && abs(tour.progress-0.5)<0.0001 && tour.isPlaying,"Preview can start at an intermediate waypoint")
        try check(tour.open(route:loop,startingAtWaypoint:last.id) && tour.progress==1 && !tour.isPlaying,"A loop's finish uses its ordered occurrence rather than jumping to the start")
        try check(tour.open(route:loop,startingAtWaypoint:first.id) && tour.progress==0,"Start waypoint begins the route")
        try check(abs(path.distance(nearest:point(350).coordinate)-350)<0.01,"Sparse tracks can start between samples")
        let unaligned=RidgeRoute(name:"Track",regionID:"test",waypoints:[first,RouteWaypoint(point:point(350)),RouteWaypoint(point:point(1000))],segments:[RouteSegment(points:path.points,mode:"imported")])
        try check(tour.open(route:unaligned,startingAtWaypoint:unaligned.waypoints[1].id) && abs(tour.progress-0.35)<0.001,"Track waypoints use projected progress when no planned leg ordering is available")
        try check(tour.open(route:loop,startingAtWaypoint:UUID()) && tour.progress==0,"Stale waypoint identifiers safely preview from the start")
        tour.close()
        try check(!tour.isPlaying && !tour.isPresented && !tour.isEntering && !tour.canAdvance,"Closing stops playback and cancels the intro")
        print("PASS \(count) route tour checks")
    }
}
