import Foundation
import SceneKit
import simd

@main struct WorldCinematicCameraTests {
    @MainActor static func main() throws {
        var checks=0
        func check(_ value:Bool,_ message:String) throws {
            checks+=1
            if !value { throw NSError(domain:message,code:1) }
        }
        func front(_ camera:SCNNode)->SIMD3<Float> {
            let axis=camera.simdWorldTransform.columns.2
            return -SIMD3(axis.x,axis.y,axis.z)
        }
        // Exercise the real camera writer: source refreshes and temporary detail
        // gaps must not produce a single orbit/top-down frame during playback.
        let camera=SCNNode();camera.camera=SCNCamera()
        let rig=WorldCameraRig()
        try check(rig.orbit(on:camera,eye:SIMD3(0,1000,500),look:.zero),"Browsing starts with orbit ownership")
        rig.beginTour(on:camera)
        let pose=WorldCameraRig.Pose(eye:SIMD3(0,110,0),look:SIMD3(0,113,-80))
        rig.fly(on:camera,pose:pose)
        let direction=front(camera)
        for frame in 0..<1000 {
            try check(!rig.orbit(on:camera,eye:SIMD3(0,Float(300+frame),0),look:.zero),"Terrain refresh cannot acquire the tour camera")
            if frame%7==0 { rig.restoreTour(on:camera) } // Waiting for close-up detail.
            try check(simd_distance(camera.simdPosition,pose.eye)<0.0001 && simd_dot(front(camera),direction)>0.99999,"No loading frame flashes to an orbit or changes the held flight angle")
            try check(abs(Double(camera.camera!.fieldOfView)-58)<0.001,"Terrain refresh cannot reset the flight lens")
        }
        let replacement=SCNNode();replacement.camera=SCNCamera()
        rig.restoreTour(on:replacement)
        try check(simd_distance(replacement.simdPosition,pose.eye)<0.0001 && simd_dot(front(replacement),direction)>0.9999,"Rebuilt scenes retain the exact flight view")
        let oldFrame=GeoBounds(minLatitude:52.99,minLongitude:-4.01,maxLatitude:53.02,maxLongitude:-3.99)
        let nextFrame=GeoBounds(minLatitude:52.98,minLongitude:-4.03,maxLatitude:53.03,maxLongitude:-3.98)
        let geographic=oldFrame.point(u:Double(pose.eye.x)/oldFrame.widthMeters+0.5,v:Double(pose.eye.z)/oldFrame.depthMeters+0.5)
        rig.rebaseTour(from:oldFrame,to:nextFrame,on:replacement)
        let rebased=nextFrame.point(u:Double(replacement.simdPosition.x)/nextFrame.widthMeters+0.5,v:Double(replacement.simdPosition.z)/nextFrame.depthMeters+0.5)
        try check(geographic.distance(to:rebased)<0.02 && abs(replacement.simdPosition.y-pose.eye.y)<0.001,"Frame changes preserve geographic camera position and elevation")
        rig.endTour()
        try check(rig.orbit(on:camera,eye:SIMD3(10,800,20),look:.zero),"Closing returns camera ownership to browsing")

        // Touch look remains user-controlled under a stationary finger. Release
        // has a deliberate delay, then a continuous frame-rate-independent return.
        var look=WorldCinematicLook();look.begin();look.drag(dx:-140,dy:40)
        let heldYaw=look.yaw,heldPitch=look.pitch
        for _ in 0..<120 { look.advance(seconds:1.0/60) }
        try check(look.yaw==heldYaw && look.pitch==heldPitch,"Holding a finger prevents automatic recentering")
        let automatic=SIMD3<Float>(0,0,-1)
        try check(look.direction(from:automatic).x>0.4,"Dragging changes the visible flight heading")
        look.end();look.advance(seconds:0.5)
        try check(look.yaw==heldYaw,"Release briefly holds the chosen angle")
        look.advance(seconds:3)
        try check(abs(look.yaw)<abs(heldYaw)*0.4 && abs(look.yaw)>0.05,"Return is gradual rather than a snap")
        for _ in 0..<1200 { look.advance(seconds:1.0/60) }
        try check(simd_dot(look.direction(from:automatic),automatic)>0.99999 && !look.needsAnimation,"Return settles on the cinematic heading and stops its animation")
        var sixty=WorldCinematicLook(),thirty=WorldCinematicLook()
        sixty.begin();sixty.drag(dx:100,dy:80);sixty.end();thirty=sixty
        for _ in 0..<360 { sixty.advance(seconds:1.0/60) }
        for _ in 0..<180 { thirty.advance(seconds:1.0/30) }
        try check(abs(sixty.yaw-thirty.yaw)<0.0001 && abs(sixty.pitch-thirty.pitch)<0.0001,"Look return is independent of display refresh rate")
        look.begin();look.drag(dx:10000,dy:10000)
        let manual=look.direction(from:automatic)
        try check(manual.x.isFinite && manual.y.isFinite && manual.z.isFinite && abs(manual.y)<1,"Extreme drags remain finite without flipping the horizon")
        camera.simdPosition=pose.eye;WorldCameraOrientation.aim(camera,at:pose.eye+manual*80)
        try check(abs(camera.simdWorldTransform.columns.0.y)<0.00001,"Manual looking retains a level horizon")

        var heading=WorldCinematicHeading()
        _=heading.direction(toward:automatic,seconds:0)
        var previous=automatic
        for _ in 0..<180 {
            let next=heading.direction(toward:SIMD3(1,10,0),seconds:1.0/60)
            let angle=acos(min(1,max(-1,simd_dot(previous,next))))
            try check(angle<0.031 && next.y<=sin(0.501),"Automatic pans respect the 1.8 rad/s heading limit without an overhead view")
            previous=next
        }
        // Eight-second shots hold their subject when a source window adds new
        // metadata, and candidates behind a ridge are rejected by sight lines.
        func point(_ metres:Double,_ east:Double=0)->GeoPoint {
            GeoPoint(latitude:53+metres/111_195,longitude:-4+east/(111_195*cos(53 * .pi/180)))
        }
        let path=WorldRouteTourPath(segments:[(0...100).map { RoutePoint(coordinate:point(Double($0)*10),elevation:100) }])!
        let summit=MapPlace(id:"summit-a",name:"Ahead summit",coordinate:point(800,200),kind:"peak",elevation:300)
        let competitor=MapPlace(id:"summit-b",name:"Another summit",coordinate:point(600,-100),kind:"peak",elevation:400)
        var director=WorldCinematicDirector()
        _=director.focus(path:path,distance:100,time:0,places:[summit],frame:oldFrame,elevation:{ _ in 100 })
        let focus=director.focus(path:path,distance:100,time:3,places:[summit],frame:oldFrame,elevation:{ _ in 100 })
        try check(focus?.id==summit.id && (focus?.weight ?? 0)>0.35,"A visible summit ahead receives a gentle scenic shot")
        let held=director.focus(path:path,distance:110,time:4,places:[competitor,summit],frame:oldFrame,elevation:{ _ in 100 })
        try check(held?.id==summit.id,"A new candidate cannot steal an active scenic shot")
        try check(director.focus(path:path,distance:120,time:8.2,places:[summit,competitor],frame:oldFrame,elevation:{ _ in 100 }) == nil,"Shots return forward before choosing another subject")
        var blocked=WorldCinematicDirector()
        let ridge: (GeoPoint)->Float = { p in (53.002...53.004).contains(p.latitude) ? 800 : 100 }
        _=blocked.focus(path:path,distance:100,time:0,places:[summit],frame:oldFrame,elevation:ridge)
        try check(blocked.focus(path:path,distance:100,time:3,places:[summit],frame:oldFrame,elevation:ridge) == nil,"Terrain hiding a summit prevents a scenic shot")
        var behind=WorldCinematicDirector()
        let rear=MapPlace(id:"rear",name:"Behind",coordinate:point(0),kind:"peak",elevation:500)
        _=behind.focus(path:path,distance:300,time:0,places:[rear],frame:oldFrame,elevation:{ _ in 100 })
        try check(behind.focus(path:path,distance:300,time:3,places:[rear],frame:oldFrame,elevation:{ _ in 100 }) == nil,"A landmark behind the traveller cannot reverse the camera")

        // Playback continues while looking around, including loading refreshes.
        let tour=WorldRouteTour();tour.open(route:RidgeRoute(name:"Flight",regionID:"test",segments:[RouteSegment(points:path.points,mode:"direct")]))
        rig.beginTour(on:camera);look.reset();look.begin();look.drag(dx:-100,dy:0)
        for frame in 0..<120 {
            let metres=Double(frame)*2
            let base=WorldRouteTourCamera.pose(path:path,distance:metres,frame:oldFrame,focus:focus,elevation:{ _ in 100 })
            let view=look.direction(from:simd_normalize(base.look-base.eye))
            rig.fly(on:camera,pose:.init(eye:base.eye,look:base.eye+view*80))
            _=rig.orbit(on:camera,eye:SIMD3(0,3000,0),look:.zero)
            tour.report(distance:metres)
            try check(tour.isPlaying && simd_distance(camera.simdPosition,base.eye)<0.001,"Looking around preserves route progress and terrain-relative flight position")
        }
        try check(tour.progress>0.2,"The route advances while the user controls the viewing angle")
        print("PASS \(checks) cinematic ownership, free-look, return and scenery checks")
    }
}
