import Foundation
import SceneKit
import simd

@main struct WorldFlightPhysicsTests {
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        var checks=0,failures=Set<String>()
        func check(_ value:Bool,_ message:String) { checks+=1;if !value { failures.insert(message) } }
        func point(_ x:Double,_ z:Double)->RoutePoint {
            .init(coordinate:.init(latitude:53-z/111195,longitude:-4+x/(111195*cos(53 * .pi/180))),elevation:100)
        }
        let frame=GeoBounds(minLatitude:52.9,minLongitude:-4.1,maxLatitude:53.1,maxLongitude:-3.9)
        let ripple=stride(from:0.0,through:4000.0,by:8).map { point(12*sin($0/24)+4*sin($0/9),-$0) }
        let circle=(0...160).map { i in let a=Double(i)*2 * .pi/160;return point(600*sin(a),600*cos(a)) }
        let fixtures:[(String,[RoutePoint])]=[
            ("straight",[point(0,0),point(0,-12000)]),
            ("small corrections",ripple),
            ("bend",[point(0,0),point(0,-1600),point(1800,-1600)]),
            ("tight return",[point(0,0),point(0,-1200),point(0,0)]),
            ("short return",[point(0,0),point(0,-35),point(0,0)]),
            ("nearby bends",[point(0,0),point(0,-1500),point(200,-1500),point(200,-1800),point(500,-1800),point(500,-3500)]),
            ("overlapping returns",[point(0,0),point(0,-350),point(20,-40),point(40,-320),point(10,0)]),
            ("heading wrap",circle),
            ("hilly bends",stride(from:0.0,through:6000.0,by:20).map { point(400*sin($0/500),-$0) })]
        let scale=(600/3.6)/25.0,dt=1.0/60
        func make(_ points:[RoutePoint],hilly:Bool=false,quiet:Bool=false,limits:WorldFlightTurn.Limits?=nil) throws -> WorldFlightPlan {
            let path=WorldRouteTourPath(segments:[points])!,rail=WorldFlightCorridor(path:path,style:.drone)
            let distances=WorldFlightTerrain.distances(length:rail.length)
            let heights:[Float?]=distances.map { distance in
                if hilly { return Float(300+300*sin(distance * Double.pi/6000)) }
                return Float(100)
            }
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:heights)
            return try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:quiet,
                clearance:10,cornerLift:12,routeFraming:true,movementAligned:true,turnLimits:limits)
        }
        for (name,points) in fixtures {
            let began=Date(),plan=try make(points,hilly:name=="hilly bends"),preparation=Date().timeIntervalSince(began)
            var glide=WorldFlightGlide(),previous=plan.sample(time:0),lastBank=previous.pose.bank,lastYaw=0.0,lastRate=0.0
            var maxBank=0.0,maxRollRate=0.0,maxYawRate=0.0,maxLateral=0.0,minSpeed=Double.infinity,maxSpeed=0.0,maxAcceleration=0.0,maxSlip=0.0,variation=0.0,maxDerivativeError=0.0
            var correctTurns=0,turns=0,maxPitchRate=0.0
            var lastPitch=atan2(Double(previous.velocity.y),Double(simd_length(SIMD2(previous.velocity.x,previous.velocity.z))))
            var turnStart=Double.infinity,turnFinish=Double.infinity
            var turnMinimum=Double.infinity,turnMaximum=0.0
            let initialDirection=simd_normalize(SIMD2(previous.velocity.x,previous.velocity.z))
            let camera=SCNNode();camera.camera=SCNCamera();let rig=WorldCameraRig();rig.beginTour(on:camera)
            func yaw(_ v:SIMD3<Float>)->Double { atan2(Double(v.x),-Double(v.z)) }
            lastYaw=yaw(previous.velocity)
            for tick in 1..<Int(plan.duration/(dt*scale)) {
                let time=Double(tick)*dt*scale,reference=plan.sample(time:time)
                let sample=glide.advance(reference:reference,yaw:0,pitch:0,speedScale:scale,seconds:dt,frame:frame,reduceMotion:false,clearance:10)
                let view=simd_normalize(sample.pose.look-sample.pose.eye),velocity=simd_normalize(sample.velocity)
                let slip=Double(simd_length(simd_cross(view,velocity)));maxSlip=max(maxSlip,slip)
                check(simd_dot(view,velocity)>0.99999,"\(name): full 3D view follows actual velocity, without sideslip")
                let difference=plan.sample(time:time+0.001*scale).pose.eye-plan.sample(time:time-0.001*scale).pose.eye
                check(simd_dot(view,simd_normalize(difference))>0.9999,"\(name): visible heading follows measured displacement")
                let v=SIMD3<Double>(sample.velocity),a=SIMD3<Double>(sample.acceleration),horizontal=hypot(v.x,v.z)
                let lateral=(v.x*a.z-v.z*a.x)/max(0.00001,horizontal)
                check(abs(tan(Double(sample.pose.bank))*sample.bankResponseAcceleration+lateral)<0.001,"\(name): cinematic bank agrees with the actual turn and shared response scale")
                let before=plan.sample(time:time-0.001*scale),after=plan.sample(time:time+0.001*scale)
                let measuredAcceleration=SIMD3<Double>(after.velocity-before.velocity)*(scale/0.002)
                // Compare the velocity integral over the finite stencil. C2
                // motion has continuous acceleration but may change jerk at a
                // knot, so a central difference need not equal its midpoint.
                var meanAcceleration=SIMD3<Double>.zero
                for part in 0...8 {
                    let offset = -0.001+Double(part)*0.00025
                    let weight=(part==0 || part==8) ? 0.5 : 1.0
                    meanAcceleration+=SIMD3<Double>(plan.sample(time:time+offset*scale).acceleration)*weight
                }
                meanAcceleration*=scale*scale/8
                let derivativeError=simd_distance(measuredAcceleration,meanAcceleration)
                maxDerivativeError=max(maxDerivativeError,derivativeError)
                check(derivativeError<0.03,"\(name): bank uses acceleration measured from travel, with actual playback units")
                let angle=yaw(sample.velocity),change=atan2(sin(angle-lastYaw),cos(angle-lastYaw))/dt
                let pitch=atan2(v.y,horizontal)
                maxPitchRate=max(maxPitchRate,abs(pitch-lastPitch)/dt);lastPitch=pitch
                let deflection=Double(acos(min(1,max(-1,simd_dot(initialDirection,simd_normalize(SIMD2(sample.velocity.x,sample.velocity.z)))))))
                if deflection>Double.pi/12 { turnStart=min(turnStart,time/scale) }
                let finishAngle=(name=="tight return" ? 11.0 : 5.0)*Double.pi/12
                if deflection>finishAngle { turnFinish=min(turnFinish,time/scale) }
                let plateauStart=(name=="tight return" ? 4.0 : 2.0)*Double.pi/12
                let plateauEnd=(name=="tight return" ? 8.0 : 4.0)*Double.pi/12
                if deflection>plateauStart && deflection<plateauEnd {
                    turnMinimum=min(turnMinimum,sample.speed);turnMaximum=max(turnMaximum,sample.speed)
                }
                lastYaw=angle;maxYawRate=max(maxYawRate,abs(change));variation+=abs(change-lastRate);lastRate=change
                maxRollRate=max(maxRollRate,Double(abs(sample.pose.bank-lastBank))/dt);lastBank=sample.pose.bank
                maxBank=max(maxBank,abs(Double(sample.pose.bank)));maxLateral=max(maxLateral,abs(lateral))
                minSpeed=min(minSpeed,sample.speed);maxSpeed=max(maxSpeed,sample.speed)
                if tick>1 { maxAcceleration=max(maxAcceleration,Double(abs(simd_length(sample.velocity)-simd_length(previous.velocity)))/dt) }
                check(sample.routeDistance>=previous.routeDistance,"\(name): ordered route progress is retained")
                check(sample.heightAboveGround>9.7,"\(name): timing changes retain prepared terrain clearance")
                check(sample.fieldOfView==78,"\(name): drone uses a fixed immersive lens without automatic pullback")
                if name != "hilly bends" { check(abs(sample.heightAboveGround-10)<0.1,"\(name): flat-ground drone flight has no artificial corner climb") }
                if abs(change)>0.02 {
                    turns+=1;if Double(sample.pose.bank)*change<0 { correctTurns+=1 }
                }
                if abs(sample.pose.bank)>0.55 {
                    check(abs(change)>0.20,"\(name): a pronounced bank produces an immediate, substantial change of travel direction")
                }
                rig.fly(on:camera,pose:.init(eye:sample.pose.eye,look:sample.pose.look,fieldOfView:sample.fieldOfView,bank:sample.pose.bank))
                let column=camera.simdWorldTransform.columns.2,front = -SIMD3(column.x,column.y,column.z)
                check(simd_dot(front,velocity)>0.99999,"\(name): rendered camera faces the movement, including while banked")
                let upColumn=camera.simdWorldTransform.columns.1,up=SIMD3(upColumn.x,upColumn.y,upColumn.z)
                let right=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),-front)),levelUp=simd_cross(-front,right)
                let renderedBank=atan2(-simd_dot(up,right),simd_dot(up,levelUp))
                check(abs(renderedBank-sample.pose.bank)<0.0001,"\(name): rendered bank agrees with the trajectory's prepared turn cue")
                if tick%71==0 {
                    let again=plan.sample(time:time)
                    check(again.pose.eye==reference.pose.eye && again.pose.bank==reference.pose.bank && again.pose.look==reference.pose.look,"\(name): scrub/replay uses deterministic prepared motion")
                    check(abs(plan.time(at:reference.routeDistance)-time)<0.01,"\(name): route scrub retains the new physical timing")
                }
                previous=sample
            }
            check(maxBank<66 * Double.pi/180 && maxLateral<133,"\(name): tighter turns use bounded cinematic banks within the manoeuvre envelope")
            check(maxRollRate<2.05,"\(name): roll rate is bounded by the prepared movement, without a lagging camera filter")
            check(maxYawRate<1.99,"\(name): tighter turns retain bounded continuous heading")
            check(maxAcceleration<64,"\(name): acceleration and braking stay inside the faster pace envelope")
            check(maxPitchRate<0.73,"\(name): terrain pitch remains calmer than the fast banked turns")
            check(minSpeed>0.5,"\(name): turn keeps moving forward")
            check(turns==0 || Double(correctTurns)/Double(turns)>0.99,"\(name): bank consistently agrees with the actual turn")
            if name=="straight" { check(abs(minSpeed-600/3.6)<0.01 && abs(maxSpeed-minSpeed)<0.01,"Straight flight keeps the selected 600 km/h cruise") }
            if name=="small corrections" { check(maxBank<0.01 && variation<0.1,"Discarded path noise cannot flap the camera") }
            if name=="tight return" || name=="bend" || name=="hilly bends" {
                let gentle=try make(points,hilly:name=="hilly bends",limits:.gentle)
                check(plan.duration<gentle.duration*0.4,"\(name): cinematic flight does not stretch the journey into slow motion")
                if name != "hilly bends" { check(maxBank>35 * Double.pi/180,"\(name): a sharp turn is achieved with a deeper bank") }
            }
            if name=="tight return" {
                check(minSpeed>30 && maxYawRate>1.2,"A local drone hairpin carries forward momentum through a decisive direction reversal")
                check(turnFinish-turnStart<2.6,"A drone hairpin turns locally rather than making a long aircraft sweep")
            }
            if name=="bend" {
                let approach=plan.sample(time:plan.time(at:1000)),exit=plan.sample(time:plan.time(at:2200))
                check(min(approach.speed,exit.speed)*scale>150,"The drone carries cruise into the approach and accelerates promptly out of the turn")
                check(maxSpeed*3.6>599,"A local turn constraint cannot reduce the cruise speed of a clear straight")
                check(turnFinish-turnStart<1.5,"The central part of a right-angle turn is a quick drone manoeuvre")
            }
            if name=="bend" || name=="tight return" {
                check(turnMinimum.isFinite && turnMaximum/turnMinimum<1.02,"\(name): hold one pace through the turn without a mid-corner surge")
                print("\(name): turn pace \(turnMinimum*3.6)…\(turnMaximum*3.6)km/h")
            }
            print("\(name): prepare \(preparation)s; wall duration \(plan.duration/scale)s; speed \(minSpeed*3.6)…\(maxSpeed*3.6)km/h; bank \(maxBank*180 / .pi)°; roll rate \(maxRollRate); yaw rate \(maxYawRate); acceleration \(maxAcceleration); slip \(maxSlip); derivative error \(maxDerivativeError); pitch rate \(maxPitchRate); turn window \(turnFinish-turnStart)s")
        }
        let straight=try make([point(0,0),point(0,-12000)])
        func steer(_ hz:Double)->WorldFlightPlan.Sample {
            var glide=WorldFlightGlide(),last=straight.sample(time:0),middle=last,maxRoll=0.0,lastBank:Float=0
            for tick in 1...Int(22*hz) {
                let seconds=Double(tick)/hz,reference=straight.sample(time:seconds*scale)
                let yaw:Float=seconds>=1 && seconds<7 ? 0.8 : 0,pitch:Float=seconds>=3 && seconds<8 ? 0.4 : 0
                let sample=glide.advance(reference:reference,yaw:yaw,pitch:pitch,speedScale:scale,seconds:1/hz,frame:frame,reduceMotion:false,clearance:10)
                let heading=simd_normalize(sample.pose.look-sample.pose.eye)
                check(simd_dot(heading,simd_normalize(sample.velocity))>0.99999,"Steering changes both travel and heading together")
                let movement=(sample.pose.eye-last.pose.eye)*Float(hz)
                if tick>1 { check(simd_dot(heading,simd_normalize(movement))>0.99998,"Touch steering does not pan separately from actual displacement") }
                check(simd_length(SIMD2(sample.pose.eye.x-reference.pose.eye.x,sample.pose.eye.z-reference.pose.eye.z))<12.01,"Steering remains within the sampled terrain corridor")
                maxRoll=max(maxRoll,Double(abs(sample.pose.bank-lastBank))*hz);lastBank=sample.pose.bank
                if tick==Int(5*hz) { middle=sample }
                last=sample
            }
            check(maxRoll<0.23,"Steering banks continuously, without acceleration steps")
            glide.reset()
            let reset=glide.advance(reference:straight.sample(time:0),yaw:0,pitch:0,speedScale:scale,seconds:0,frame:frame,reduceMotion:false)
            check(reset.pose.eye==straight.sample(time:0).pose.eye && reset.pose.bank==0,"Restart removes steering position, velocity and acceleration history")
            return middle
        }
        let a=steer(30),b=steer(60),c=steer(120)
        check(simd_distance(a.pose.eye,b.pose.eye)<0.1 && simd_distance(b.pose.eye,c.pose.eye)<0.1,"Manual glide is consistent across display rates")
        for name in ["tight return","hilly bends"] {
            let fixture=fixtures.first { $0.0==name }!,plan=try make(fixture.1,hilly:name=="hilly bends")
            var glide=WorldFlightGlide(),lastBank:Float=0,maxRate=0.0,maxBank=0.0
            for tick in 1..<Int(plan.duration/(dt*scale)) {
                let time=Double(tick)*dt*scale,reference=plan.sample(time:time)
                let command:Float=time<plan.duration*0.2 ? 0 : time<plan.duration*0.6 ? 0.8 : -0.5
                let sample=glide.advance(reference:reference,yaw:command,pitch:0.3,speedScale:scale,seconds:dt,frame:frame,reduceMotion:false,clearance:10)
                check(simd_dot(simd_normalize(sample.pose.look-sample.pose.eye),simd_normalize(sample.velocity))>0.99999,"\(name): looking around cannot introduce sideslip in a banked turn")
                if tick>1 { maxRate=max(maxRate,Double(abs(sample.pose.bank-lastBank))/dt) };lastBank=sample.pose.bank
                maxBank=max(maxBank,Double(abs(sample.pose.bank)))
            }
            check(maxRate<2.2 && maxBank<68 * Double.pi/180,"\(name): steering through prepared bends retains continuous bounded banking")
            print("\(name) with steering: peak bank \(maxBank*180 / .pi)°; roll rate \(maxRate)")
        }
        let quiet=try make(fixtures[3].1,quiet:true)
        for time in stride(from:0.0,to:quiet.duration,by:0.5) {
            let sample=quiet.sample(time:time)
            check(sample.pose.bank==0 && simd_dot(simd_normalize(sample.pose.look-sample.pose.eye),simd_normalize(sample.velocity))>0.99999,"Reduce Motion retains forward movement with a level horizon")
        }
        let sample=straight.sample(time:straight.duration*0.4),output=GeoBounds(minLatitude:52.98,minLongitude:-4.03,maxLatitude:53.04,maxLongitude:-3.97)
        let converted=WorldFlightPlan.converted(sample,from:frame,to:output)
        check(converted.movementAligned && simd_dot(simd_normalize(converted.pose.look-converted.pose.eye),simd_normalize(converted.velocity))>0.99999,"Scene rebasing cannot separate travel from viewing direction")
        let bendPath=WorldRouteTourPath(segments:[fixtures[2].1])!
        let droneRail=WorldFlightCorridor(path:bendPath,style:.drone),oldRail=WorldFlightCorridor(path:bendPath,tolerance:160,routeCentred:true)
        let corner=bendPath.sample(at:1600).coordinate
        let droneGap=droneRail.sample(routeDistance:1600).point.distance(to:corner),oldGap=oldRail.sample(routeDistance:1600).point.distance(to:corner)
        check(droneGap<40 && droneGap<oldGap*0.6,"The drone geometry takes a compact corner instead of the old broad arc")
        let returnPath=WorldRouteTourPath(segments:[fixtures[3].1])!,returnRail=WorldFlightCorridor(path:returnPath,style:.drone)
        let direction=returnRail.sample(flightDistance:returnRail.length*0.1).direction
        for fraction in [0.2,0.3,0.35] {
            check(simd_dot(direction,returnRail.sample(flightDistance:returnRail.length*fraction).direction)>0.999999,"Outbound leg is a direct line without a long sideways racetrack sweep")
        }
        print("Corner separation: drone \(droneGap)m, previous gliding rail \(oldGap)m")
        check(droneGap<22,"The new tighter corner passes closer than the previous drone recipe")
        let tiny=try make([point(0,0),point(0,-0.6),point(0,0)])
        var previousDistance=0.0
        for i in 0...200 {
            let sample=tiny.sample(time:tiny.duration*Double(i)/200)
            check(sample.routeDistance>=previousDistance && sample.routeDistance>=0,"A tiny closed route cannot acquire negative or reversed progress")
            check(sample.velocity.x.isFinite && simd_length(sample.velocity)>0.00001,"A tiny drone hairpin retains a finite forward trajectory")
            previousDistance=sample.routeDistance
        }
        var delayed=WorldFlightPlayback(),regular=WorldFlightPlayback()
        delayed.reset(speed:10);regular.reset(speed:10)
        var now=100.0,elapsed=0.0,travel=0.0
        for _ in 0..<20 { for dt in [1.0/60,0.22,1.0/30,0.16] {
            let next=now+dt,frame=WorldFlightPlayback.frameSeconds(now:next,previous:now,displayInterval:1/60)
            travel+=delayed.advance(seconds:frame,requested:600/3.6,preparedSpeed:25)
            elapsed+=dt;now=next
        } }
        let expected=regular.advance(seconds:elapsed,requested:600/3.6,preparedSpeed:25)
        check(abs(travel-expected)<0.000001,"Slow rendering frames cannot discard elapsed flight time or lower the actual pace")
        check(abs(WorldFlightPlayback.frameSeconds(now:200,previous:100,displayInterval:1/60)-1/60)<0.000001,"A long suspension restarts from a fresh display interval without skipping the route")
        func heldGlide(_ cadence:[Double])->WorldFlightPlan.Sample {
            var glide=WorldFlightGlide(),time=0.0,index=0,sample=straight.sample(time:0)
            while time<5 {
                let dt=min(cadence[index%cadence.count],5-time);time+=dt;index+=1
                sample=glide.advance(reference:straight.sample(time:time*scale),yaw:0.6,pitch:0.2,speedScale:scale,seconds:dt,frame:frame,reduceMotion:false,clearance:10)
            }
            return sample
        }
        let normal=heldGlide([1/60]),stalled=heldGlide([1/60,0.22,1/30,0.16])
        check(simd_distance(normal.pose.eye,stalled.pose.eye)<0.01,"Steering also consumes full slow-frame time without lagging behind the flight clock")
        print("\(checks) coordinated flight checks, \(failures.count) failures")
        if !failures.isEmpty { throw NSError(domain:failures.sorted().joined(separator:"; "),code:1) }
        print("PASS coordinated trajectory, turn-coherent cinematic bank, no sideslip, anticipatory pace, steering and Reduce Motion")
    }
}
