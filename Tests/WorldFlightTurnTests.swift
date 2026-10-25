import Foundation
import SceneKit
import simd

@main struct WorldFlightTurnTests {
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
            ("straight",[point(0,0),point(0,-4000)]),
            ("small corrections",ripple),
            ("bend",[point(0,0),point(0,-1600),point(1800,-1600)]),
            ("return",[point(0,0),point(0,-1200),point(0,0)]),
            ("nearby bends",[point(0,0),point(0,-1500),point(200,-1500),point(200,-1800),point(500,-1800),point(500,-3500)]),
            ("overlapping returns",[point(0,0),point(0,-350),point(20,-40),point(40,-320),point(10,0)]),
            ("heading wrap",circle)]
        for (name,points) in fixtures {
            let path=WorldRouteTourPath(segments:[points])!,rail=WorldFlightCorridor(path:path,tolerance:160,routeCentred:true)
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map { _ in Float?(100) })
            func plan(_ coordinated:Bool,quiet:Bool=false) throws -> WorldFlightPlan {
                try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:quiet,
                    clearance:10,cornerLift:12,routeFraming:true,coordinatedTurns:coordinated)
            }
            let old=try plan(false),new=try plan(true),quiet=try plan(true,quiet:true)
            let scale=WorldRouteTour.previewCruiseSpeed/3.6/new.cruiseSpeed,dt=1.0/60
            func yaw(_ sample:WorldFlightPlan.Sample)->Double {
                let d=sample.pose.look-sample.pose.eye;return atan2(Double(d.x),-Double(d.z))
            }
            func angle(_ a:Double,_ b:Double)->Double { atan2(sin(a-b),cos(a-b)) }
            var oldYaw=yaw(old.sample(time:0)),newYaw=yaw(new.sample(time:0)),oldRate=0.0,newRate=0.0
            var oldVariation=0.0,newVariation=0.0,maxRate=0.0,maxOffset=0.0,maxBank:Float=0,lastBank:Float=0
            var turns=0,banked=0,aligned=0,firstRoll=Double.infinity,firstTurn=Double.infinity
            var glide=WorldFlightGlide(),playback=WorldFlightPlayback();playback.reset(speed:600/3.6)
            let camera=SCNNode();camera.camera=SCNCamera();let rig=WorldCameraRig();rig.beginTour(on:camera)
            for time in stride(from:dt*scale,to:new.duration,by:dt*scale) {
                let reference=new.sample(time:time),base=old.sample(time:time),seconds=time/scale
                let a=angle(yaw(base),oldYaw)/dt,b=angle(yaw(reference),newYaw)/dt
                oldVariation+=abs(a-oldRate);newVariation+=abs(b-newRate)
                oldRate=a;newRate=b;oldYaw=yaw(base);newYaw=yaw(reference);maxRate=max(maxRate,abs(b))
                maxOffset=max(maxOffset,abs(angle(yaw(reference),yaw(base))))
                let sample=glide.advance(reference:reference,yaw:0,pitch:0,speedScale:scale,seconds:dt,frame:frame,reduceMotion:false,clearance:10)
                check(abs(sample.pose.bank-reference.pose.bank)<0.00001,"\(name): runtime does not replace prepared roll with noisy physical curvature")
                let bank=playback.roll(toward:sample.pose.bank,seconds:dt)
                maxBank=max(maxBank,abs(bank))
                check(abs(bank-lastBank)<=Float(dt*0.2201),"\(name): actual roll retains its comfort rate limit")
                lastBank=bank
                if abs(bank)>0.035 { firstRoll=min(firstRoll,seconds) }
                if abs(b)>0.2 { firstTurn=min(firstTurn,seconds) }
                if abs(b)>0.2 && seconds>0.6 {
                    turns+=1
                    if abs(bank)>0.025 { banked+=1 }
                    if b * Double(bank)<0 { aligned+=1 }
                }
                check(simd_distance(reference.pose.eye,base.pose.eye)<0.001 && reference.fieldOfView==base.fieldOfView,"\(name): accepted flight rail, height and lens are preserved")
                let d=simd_normalize(reference.pose.look-reference.pose.eye),v=simd_normalize(reference.velocity)
                check(simd_dot(SIMD2(d.x,d.z),SIMD2(v.x,v.z))>0,"\(name): camera continues looking forward")
                rig.fly(on:camera,pose:.init(eye:sample.pose.eye,look:sample.pose.look,fieldOfView:sample.fieldOfView,bank:bank))
                let axis=camera.simdWorldTransform.columns.2,front = -SIMD3(axis.x,axis.y,axis.z)
                check(simd_dot(front,simd_normalize(sample.pose.look-sample.pose.eye))>0.99999,"\(name): real banked camera follows its prepared heading")
                let column=camera.simdWorldTransform.columns.1,up=SIMD3(column.x,column.y,column.z)
                let right=simd_normalize(simd_cross(SIMD3<Float>(0,1,0),-front)),levelUp=simd_cross(-front,right)
                let actualBank=atan2(-simd_dot(up,right),simd_dot(up,levelUp))
                check(abs(actualBank-bank)<0.0001,"\(name): the rendered camera actually holds the requested bank")
                if Int(time*60)%31==0 {
                    let again=new.sample(time:time)
                    check(again.pose.look==reference.pose.look && again.pose.bank==reference.pose.bank,"\(name): seeking is deterministic without hidden heading/roll state")
                }
            }
            for time in stride(from:0.0,to:quiet.duration,by:0.2) { check(quiet.sample(time:time).pose.bank==0,"\(name): Reduce Motion retains a level horizon") }
            let fraction=turns>0 ? Double(banked)/Double(turns) : 1,sign=turns>0 ? Double(aligned)/Double(turns) : 1
            print("\(name): yaw variation \(oldVariation) → \(newVariation); peak rate \(maxRate) rad/s; peak change from old framing \(maxOffset*180 / .pi)°; bank \(maxBank*180 / .pi)°; banked turns \(fraction), correct lean \(sign); roll/turn onset \(firstRoll)/\(firstTurn) s")
            check(maxOffset<12.01 * Double.pi/180,"\(name): calmer heading remains near the accepted route framing")
            check(maxBank<=Float(24.01 * Double.pi/180),"\(name): bank stays bounded")
            if name=="small corrections" {
                check(newVariation<oldVariation*0.65,"Small lateral corrections are substantially reduced")
                check(maxBank<0.035,"Small corrections cannot flap the horizon")
            }
            if name != "straight" && name != "small corrections" {
                check(turns>30 && fraction>0.9 && sign>0.9,"\(name): visible turns are continuously banked in the correct direction")
            }
            if name=="bend" || name=="return" {
                check(firstRoll<firstTurn,"\(name): the bank leads the main heading change")
            }
        }
        let path=WorldRouteTourPath(segments:[[point(0,0),point(0,-4000)]])!,rail=WorldFlightCorridor(path:path,tolerance:160,routeCentred:true)
        let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map { _ in Float?(100) })
        let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:10,routeFraming:true)
        func steered(_ hz:Double)->WorldFlightPlan.Sample {
            var glide=WorldFlightGlide(),middle=plan.sample(time:0)
            for tick in 1...Int(hz*10) {
                let seconds=Double(tick)/hz,reference=plan.sample(time:seconds*(600/3.6)/25)
                let command:Float=seconds>=1 && seconds<4 ? 0.6 : 0
                let sample=glide.advance(reference:reference,yaw:command,pitch:0,speedScale:(600/3.6)/25,seconds:1/hz,frame:frame,reduceMotion:false,clearance:10)
                check(abs(sample.pose.bank-reference.pose.bank)<=Float(6.01 * Double.pi/180),"Touch steering adds only a small bounded roll correction")
                if tick==Int(hz*3) { middle=sample }
            }
            glide.reset()
            let reset=glide.advance(reference:plan.sample(time:0),yaw:0,pitch:0,speedScale:1,seconds:0,frame:frame,reduceMotion:false)
            check(reset.pose.bank==plan.sample(time:0).pose.bank,"Seek/reset removes manual roll history")
            return middle
        }
        let a=steered(30),b=steered(60)
        check(simd_distance(a.pose.eye,b.pose.eye)<0.4 && abs(a.pose.bank-b.pose.bank)<0.01,"Manual steering remains consistent at 30 and 60 Hz")
        print("\(checks) continuous-turn and real-camera checks, \(failures.count) failures")
        if !failures.isEmpty { throw NSError(domain:failures.sorted().joined(separator:"; "),code:1) }
        print("PASS continuous heading, coordinated roll, anticipation, terrain/framing retention and Reduce Motion")
    }
}
