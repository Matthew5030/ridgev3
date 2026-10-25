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
        func make(_ points:[RoutePoint],hilly:Bool=false,quiet:Bool=false) throws -> WorldFlightPlan {
            let path=WorldRouteTourPath(segments:[points])!,rail=WorldFlightCorridor(path:path,tolerance:160,routeCentred:true)
            let distances=WorldFlightTerrain.distances(length:rail.length)
            let heights:[Float?]=distances.map { distance in
                if hilly { return Float(300+300*sin(distance * Double.pi/6000)) }
                return Float(100)
            }
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:heights)
            return try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:quiet,
                clearance:10,cornerLift:12,routeFraming:true,movementAligned:true)
        }
        for (name,points) in fixtures {
            let began=Date(),plan=try make(points,hilly:name=="hilly bends"),preparation=Date().timeIntervalSince(began)
            var glide=WorldFlightGlide(),previous=plan.sample(time:0),lastBank=previous.pose.bank,lastYaw=0.0,lastRate=0.0
            var maxBank=0.0,maxRollRate=0.0,maxYawRate=0.0,maxLateral=0.0,minSpeed=Double.infinity,maxSpeed=0.0,maxAcceleration=0.0,maxSlip=0.0,variation=0.0
            var correctTurns=0,turns=0
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
                check(abs(tan(Double(sample.pose.bank))*9.81+lateral)<0.0001,"\(name): bank and actual centripetal acceleration agree")
                let before=plan.sample(time:time-0.002*scale),after=plan.sample(time:time+0.002*scale)
                let measuredAcceleration=SIMD3<Double>(after.velocity-before.velocity)*(scale/0.004)
                check(simd_distance(measuredAcceleration,a)<0.03,"\(name): bank uses acceleration measured from travel, with actual playback units")
                let angle=yaw(sample.velocity),change=atan2(sin(angle-lastYaw),cos(angle-lastYaw))/dt
                lastYaw=angle;maxYawRate=max(maxYawRate,abs(change));variation+=abs(change-lastRate);lastRate=change
                maxRollRate=max(maxRollRate,Double(abs(sample.pose.bank-lastBank))/dt);lastBank=sample.pose.bank
                maxBank=max(maxBank,abs(Double(sample.pose.bank)));maxLateral=max(maxLateral,abs(lateral))
                minSpeed=min(minSpeed,sample.speed);maxSpeed=max(maxSpeed,sample.speed)
                if tick>1 { maxAcceleration=max(maxAcceleration,Double(abs(simd_length(sample.velocity)-simd_length(previous.velocity)))/dt) }
                check(sample.routeDistance>=previous.routeDistance,"\(name): ordered route progress is retained")
                check(sample.heightAboveGround>9.7,"\(name): timing changes retain prepared terrain clearance")
                if abs(change)>0.02 {
                    turns+=1;if Double(sample.pose.bank)*change<0 { correctTurns+=1 }
                }
                rig.fly(on:camera,pose:.init(eye:sample.pose.eye,look:sample.pose.look,fieldOfView:sample.fieldOfView,bank:sample.pose.bank))
                let column=camera.simdWorldTransform.columns.2,front = -SIMD3(column.x,column.y,column.z)
                check(simd_dot(front,velocity)>0.99999,"\(name): rendered camera faces the movement, including while banked")
                let upColumn=camera.simdWorldTransform.columns.1,up=SIMD3(upColumn.x,upColumn.y,upColumn.z)
                let right=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),-front)),levelUp=simd_cross(-front,right)
                let renderedBank=atan2(-simd_dot(up,right),simd_dot(up,levelUp))
                check(abs(renderedBank-sample.pose.bank)<0.0001,"\(name): rendered bank agrees with the trajectory's turn force")
                if tick%71==0 {
                    let again=plan.sample(time:time)
                    check(again.pose.eye==reference.pose.eye && again.pose.bank==reference.pose.bank && again.pose.look==reference.pose.look,"\(name): scrub/replay uses deterministic prepared motion")
                    check(abs(plan.time(at:reference.routeDistance)-time)<0.01,"\(name): route scrub retains the new physical timing")
                }
                previous=sample
            }
            check(maxBank<24 * Double.pi/180 && maxLateral<4.0,"\(name): turn pace supports a comfortable physical bank")
            check(maxRollRate<0.225,"\(name): roll rate is bounded by the prepared movement, without a lagging camera filter")
            check(maxYawRate<0.225,"\(name): no fast swivel through tight turns")
            check(maxAcceleration<4.3,"\(name): speed changes anticipate bends without hard braking")
            check(minSpeed>0.5,"\(name): turn keeps moving forward")
            check(turns==0 || Double(correctTurns)/Double(turns)>0.99,"\(name): bank consistently agrees with the actual turn")
            if name=="straight" { check(abs(minSpeed-600/3.6)<0.01 && abs(maxSpeed-minSpeed)<0.01,"Straight flight keeps the selected 600 km/h cruise") }
            if name=="small corrections" { check(maxBank<0.01 && variation<0.1,"Discarded path noise cannot flap the camera") }
            if name=="tight return" { check(minSpeed<25 && maxSpeed>minSpeed*2,"A tight turn slows rather than applying fake bank at cruise pace") }
            print("\(name): prepare \(preparation)s; wall duration \(plan.duration/scale)s; speed \(minSpeed*3.6)…\(maxSpeed*3.6)km/h; bank \(maxBank*180 / .pi)°; roll rate \(maxRollRate); yaw rate \(maxYawRate); acceleration \(maxAcceleration); slip \(maxSlip)")
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
            check(maxRate<0.25 && maxBank<30 * Double.pi/180,"\(name): steering through prepared bends retains continuous bounded banking")
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
        print("\(checks) coordinated flight checks, \(failures.count) failures")
        if !failures.isEmpty { throw NSError(domain:failures.sorted().joined(separator:"; "),code:1) }
        print("PASS coordinated trajectory, actual bank physics, no sideslip, anticipatory pace, steering and Reduce Motion")
    }
}
