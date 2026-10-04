import Foundation

@main struct WorldGestureTests {
    static func main() throws {
        var count=0
        func check(_ value:Bool,_ message:String) throws {
            count+=1
            if !value { throw NSError(domain:message,code:1) }
        }
        let a=CGPoint(x:100,y:100),b=CGPoint(x:300,y:100)
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:101,y:102),b:CGPoint(x:300,y:103)) == .undecided,"Touch jitter must not tilt")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:100,y:130),b:CGPoint(x:300,y:130)) == .tilt,"Parallel vertical motion tilts")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:80,y:125),b:CGPoint(x:320,y:125)) == .transform,"Off-centre pinch must not tilt")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:110,y:80),b:CGPoint(x:290,y:120)) == .transform,"Twist is classified as movement, never tilt")
        try check(WorldGestureIntent.resolve(startA:a,startB:b,a:CGPoint(x:130,y:104),b:CGPoint(x:330,y:104)) == .transform,"Horizontal two-finger translation must not orbit")
        // Both orientations and both zoom directions, with a moving midpoint.
        for direction in [-1.0,1.0] {
            for angle in stride(from:0.0,to:6.28,by:0.2) {
                let dx=cos(angle)*100,dy=sin(angle)*100
                let p=CGPoint(x:200-dx,y:200-dy),q=CGPoint(x:200+dx,y:200+dy)
                let factor=1+direction*0.15
                let u=CGPoint(x:204-dx*factor,y:230-dy*factor),v=CGPoint(x:204+dx*factor,y:230+dy*factor)
                try check(WorldGestureIntent.resolve(startA:p,startB:q,a:u,b:v) == .transform,"Rotated pinch must keep its camera pitch")
            }
        }
        print("PASS \(count) gesture intent checks")
    }
}
