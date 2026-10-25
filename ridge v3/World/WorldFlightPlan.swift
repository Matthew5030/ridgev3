import Foundation
import simd

/// A small height-only snapshot of the saved terrain along the entire rail.
/// Preparation decodes one mesh at a time; playback never reads these meshes.
struct WorldFlightTerrain {
    let heights:[Float]
    let available:[Bool]
    private let clearanceHeights:[Float]
    let places:[MapPlace]
    private let origin:GeoPoint
    private let scale:Double
    private let points:[SIMD2<Double>]
    private var cells:[SIMD2<Int>:[Int]]=[:]
    static func distances(length:Double)->[Double] {
        let step=max(4,length/40000)
        var result=Array(stride(from:0.0,to:length,by:step));result.append(length);return result
    }
    /// Five lanes cover the steering corridor. They share a single cache-only
    /// terrain read; no geometry or height queries run during playback.
    static func clearancePoints(corridor:WorldFlightCorridor)->[GeoPoint] {
        distances(length:corridor.length).flatMap { distance -> [GeoPoint] in
            let rail=corridor.sample(flightDistance:distance)
            let right=SIMD2(-rail.direction.y,rail.direction.x)
            return [-1.0,-0.5,0,0.5,1].map { lane in
                let offset=right*(lane*WorldFlightGlide.lateralLimit)
                return GeoPoint(latitude:rail.point.latitude-offset.y/111195,
                                longitude:rail.point.longitude+offset.x/(111195*max(0.01,cos(rail.point.latitude * .pi/180))))
            }
        }
    }
    init(path:WorldRouteTourPath,corridor:WorldFlightCorridor,heights:[Float?],places:[MapPlace]=[],clearanceHeights:[Float?]? = nil) {
        let distances=Self.distances(length:corridor.length)
        let samples=distances.map { corridor.sample(flightDistance:$0) }
        origin=samples[0].point;scale=max(0.01,cos(origin.latitude * .pi/180))
        let origin=self.origin,scale=self.scale
        points=samples.map { SIMD2(($0.point.longitude-origin.longitude)*111195*scale,(origin.latitude-$0.point.latitude)*111195) }
        let preparedHeights=samples.indices.map { i in heights[i] ?? Float(path.sample(at:samples[i].routeDistance).elevation ?? 0) }
        self.heights=preparedHeights
        self.clearanceHeights=preparedHeights.indices.map { max(preparedHeights[$0],clearanceHeights?[$0] ?? preparedHeights[$0]) }
        available=heights.map { $0 != nil };self.places=places.sorted { $0.id<$1.id }
        for i in points.indices { cells[Self.cell(points[i]),default:[]].append(i) }
    }
    private static func cell(_ p:SIMD2<Double>)->SIMD2<Int> { SIMD2(Int(floor(p.x/24)),Int(floor(p.y/24))) }
    private func nearest(_ p:GeoPoint)->Int? {
        let point=SIMD2((p.longitude-origin.longitude)*111195*scale,(origin.latitude-p.latitude)*111195),key=Self.cell(point)
        var error=Double.infinity,best:Int?
        for y in -1...1 { for x in -1...1 {
            for i in cells[key &+ SIMD2(x,y)] ?? [] {
                let delta=simd_length_squared(point-points[i]);if delta<error { error=delta;best=i }
            }
        } }
        return best
    }
    func elevation(_ p:GeoPoint)->Float { nearest(p).map { heights[$0] } ?? 0 }
    func clearanceElevation(_ p:GeoPoint)->Float { nearest(p).map { clearanceHeights[$0] } ?? 0 }
}

/// Immutable camera choreography, prepared before playback. This includes the
/// complete height and speed timeline, with heading and bank derived from its
/// velocity and acceleration. At runtime
/// playback interpolates the rail; steering adds a continuous glide within its corridor.
struct WorldFlightPlan {
    struct Sample {
        var pose:WorldRouteTourCamera.Pose
        var routeDistance:Double
        var speed:Double
        var velocity:SIMD3<Float>
        var heightAboveGround:Double
        var cameraPoint:GeoPoint? = nil
    }
    /// Convert both eye and velocity together when streaming changes the scene
    /// origin. Steering state stays in the immutable plan frame.
    static func converted(_ sample:Sample,from frame:GeoBounds,to output:GeoBounds)->Sample {
        guard frame != output else { return sample }
        func point(_ value:SIMD3<Float>)->SIMD3<Float> {
            let geo=frame.point(u:Double(value.x)/frame.widthMeters+0.5,v:Double(value.z)/frame.depthMeters+0.5),uv=output.uv(geo)
            return SIMD3(Float((uv.u-0.5)*output.widthMeters),value.y,Float((uv.v-0.5)*output.depthMeters))
        }
        var result=sample
        result.pose.eye=point(sample.pose.eye);result.pose.look=point(sample.pose.look)
        result.velocity=point(sample.pose.eye+sample.velocity)-result.pose.eye
        return result
    }
    private struct Key {
        var time:Double;var route:Double;var eye:SIMD3<Double>;var ground:Double;var overview:Double
        var bank=0.0
        var velocity:SIMD3<Double> = .zero
        var acceleration:SIMD3<Double> = .zero
    }
    private struct Segment {
        var p:SIMD3<Double>;var c1:SIMD3<Double>;var c2:SIMD3<Double>;var c3:SIMD3<Double>;var inverseDuration:Double
        init(_ a:Key,_ b:Key) {
            let dt=max(0.00001,b.time-a.time)
            p=a.eye;c1=b.eye-a.eye-(a.acceleration*2+b.acceleration)*(dt*dt/6)
            c2=a.acceleration*(dt*dt/2);c3=(b.acceleration-a.acceleration)*(dt*dt/6)
            inverseDuration=1/dt
        }
        func sample(_ t:Double)->(position:SIMD3<Double>,velocity:SIMD3<Double>,acceleration:SIMD3<Double>) {
            (p+t*(c1+t*(c2+t*c3)),
             (c1+t*(c2*2+t*c3*3))*inverseDuration,
             (c2*2+t*c3*6)*inverseDuration*inverseDuration)
        }
    }
    let frame:GeoBounds
    let cruiseSpeed:Double
    let clearance:Double
    let reduceMotion:Bool
    let hasSpeedTransition:Bool
    private var keys:[Key]
    private var segments:[Segment]
    var duration:Double { keys.last?.time ?? 0 }
    var count:Int { keys.count }

    init(path:WorldRouteTourPath,corridor:WorldFlightCorridor,terrain:WorldFlightTerrain,frame:GeoBounds,cruiseSpeed:Double,reduceMotion:Bool,
         clearance:Double=20,cornerLift:Double=0,speedChangeAt:Double? = nil,initialSpeed:Double? = nil,initialAltitude:Float? = nil) throws {
        self.frame=frame;self.cruiseSpeed=cruiseSpeed;self.reduceMotion=reduceMotion;self.clearance=min(1000,max(5,clearance))
        hasSpeedTransition=initialSpeed != nil || initialAltitude != nil
        var result:[Key]=[],time=0.0,lastTravel=0.0,lastSpeed=0.0
        var minimumHeights:[Double]=[]
        let desiredSpacing=max(corridor.length/40000,min(3,max(0.5,cruiseSpeed*0.12)))
        let intervals=max(2,Int(ceil(corridor.length/desiredSpacing))),spacing=corridor.length/Double(intervals)
        let stations=(0...intervals).map { Double($0)*spacing }
        for (i,travel) in stations.enumerated() {
            if i%128==0 { try Task.checkCancellation() }
            let rail=corridor.sample(flightDistance:travel)
            var speed=max(0.1,corridor.speedLimit(at:rail.routeDistance,requested:cruiseSpeed))
            if let change=speedChangeAt,let old=initialSpeed {
                let span=max(40,(old+cruiseSpeed)*1.1),t=min(1,max(0,(travel-corridor.flightDistance(at:change))/span))
                speed=max(0.1,old+(speed-old)*t*t*(3-2*t))
            }
            if i>0 { time+=(travel-lastTravel)*2/(speed+lastSpeed) }
            let point=rail.point
            let ground=terrain.elevation(rail.point)
            let uv=frame.uv(point)
            let eye=SIMD3((uv.u-0.5)*frame.widthMeters,Double(ground),(uv.v-0.5)*frame.depthMeters)
            minimumHeights.append(Double(terrain.clearanceElevation(rail.point))+self.clearance+max(0,cornerLift)*rail.overview)
            result.append(Key(time:time,route:rail.routeDistance,eye:eye,ground:Double(ground),overview:rail.overview))
            lastTravel=travel;lastSpeed=speed
        }
        // Anticipate hills with a broad upper parabolic envelope. Its 1.4 km
        // vertical radius bridges short hollows without lifting the whole route
        // to the highest summit. This distance transform is linear in key count.
        let count=minimumHeights.count,penalty=spacing*spacing/(2*1400)
        var support=Array(repeating:0,count:count),boundary=Array(repeating:Double.infinity,count:count+1),k=0
        boundary[0] = -.infinity
        for q in 1..<count {
            var split=0.0
            while true {
                let j=support[k]
                split=(minimumHeights[j]-minimumHeights[q]+penalty*(Double(q*q)-Double(j*j)))/(2*penalty*Double(q-j))
                if split>boundary[k] || k==0 { break };k-=1
            }
            k+=1;support[k]=q;boundary[k]=split;boundary[k+1] = .infinity
        }
        var heights=minimumHeights;k=0
        for i in heights.indices {
            while boundary[k+1]<Double(i) { k+=1 }
            let delta=Double(i-support[k]);heights[i]=minimumHeights[support[k]]-penalty*delta*delta
        }
        // Symmetric filtering removes the envelope's support changes. Double
        // precision matters: rounding heights to Float before solving the motion
        // spline amplifies tiny height errors into acceleration and pitch noise.
        // Four bounded box convolutions form a C2 smoothing kernel. Finite
        // support avoids the long filter tails that can lift distant valleys.
        let radius=max(1,Int(ceil(120/spacing))),window=Double(radius*2+1)
        for _ in 0..<4 {
            try Task.checkCancellation()
            var sums=Array(repeating:0.0,count:count+1)
            for i in heights.indices { sums[i+1]=sums[i]+heights[i] }
            heights=heights.indices.map { i in
                let a=max(0,i-radius),b=min(count-1,i+radius)
                let padding=Double(max(0,radius-i))*heights[0]+Double(max(0,i+radius-count+1))*heights[count-1]
                return (sums[b+1]-sums[a]+padding)/window
            }
        }
        // Filtering can shave a summit's clearance. Restore only that deficit
        // with a conservative C2 spline, not local max bumps with sharp joins.
        // Every control contributing to a band includes that band's maximum;
        // positive spline weights guarantee the correction clears its samples.
        let deficits=zip(minimumHeights,heights).map { max(0,$0-$1) }
        let bandWidth=max(200,spacing),bandCount=max(1,Int(ceil(corridor.length/bandWidth)))
        var peaks=Array(repeating:0.0,count:bandCount)
        for i in stations.indices {
            let band=min(bandCount-1,Int(stations[i]/bandWidth))
            peaks[band]=max(peaks[band],deficits[i])
        }
        func control(_ index:Int)->Double {
            (-2...1).map { peaks[min(bandCount-1,max(0,index+$0))] }.max()!
        }
        for i in result.indices {
            let x=stations[i]/bandWidth,band=Int(floor(x)),t=x-Double(band),u=1-t
            let correction=(control(band-1)*u*u*u
                + control(band)*(3*t*t*t-6*t*t+4)
                + control(band+1)*(-3*t*t*t+3*t*t+3*t+1)
                + control(band+2)*t*t*t)/6
            result[i].eye.y=heights[i]+correction
        }
        if let change=speedChangeAt,let initialAltitude {
            let travel=corridor.flightDistance(at:change)
            let index=min(result.count-2,max(0,Int(travel/spacing)))
            let t=min(1,max(0,(travel-stations[index])/max(0.0001,stations[index+1]-stations[index])))
            let current=result[index].eye.y+(result[index+1].eye.y-result[index].eye.y)*t,offset=Double(initialAltitude)-current
            let span=max(100,cruiseSpeed*4)
            for i in result.indices {
                let t=min(1,max(0,(stations[i]-travel)/span)),weight=1-t*t*(3-2*t)
                result[i].eye.y=max(Double(result[i].ground)+5,result[i].eye.y+offset*weight)
            }
        }
        if cornerLift>0 {
            // Retiming belongs to the prepared camera path, not the original
            // rail. Smoothing shortens corners; using its old distance clock
            // would otherwise add a slowdown through those corners.
            var elapsed=0.0
            result[0].time=0
            for i in 1..<result.count {
                let a=corridor.speedLimit(at:result[i-1].route,requested:cruiseSpeed)
                let b=corridor.speedLimit(at:result[i].route,requested:cruiseSpeed)
                elapsed += max(0.00001,simd_distance(result[i-1].eye,result[i].eye)*2/max(0.2,a+b))
                result[i].time=elapsed
            }
        }
        // Solve one C2 cubic trajectory through the timed positions. Estimating
        // derivatives separately and then fitting a higher-order interpolant
        // introduced false curvature and alternating banks between close keys.
        // Endpoint curvature comes from the adjacent chords, avoiding a forced
        // zero-bank knot followed immediately by a full bank.
        Self.solveMotion(&result)
        let n=result.count
        // Roll anticipates the same trajectory over a short time window.
        // Smooth roll only: heading stays exactly tangent to forward motion.
        var banks=result.map { key -> Double in
            let v=SIMD2(key.velocity.x,key.velocity.z),a=SIMD2(key.acceleration.x,key.acceleration.z),square=simd_length_squared(v)
            let curvature=square>0.0001 ? (v.x*a.y-v.y*a.x)/pow(square,1.5) : 0
            return reduceMotion ? 0 : Double(WorldFlightTurn.bank(curvature:curvature,speed:sqrt(square),overview:key.overview))
        }
        for i in 1..<n { let w=1-exp(-(result[i].time-result[i-1].time)/0.5);banks[i]=banks[i-1]+(banks[i]-banks[i-1])*w }
        for i in stride(from:n-2,through:0,by:-1) { let w=1-exp(-(result[i+1].time-result[i].time)/0.5);banks[i]=banks[i+1]+(banks[i]-banks[i+1])*w }
        for i in result.indices { result[i].bank=banks[i] }
        keys=result;segments=(0..<(result.count-1)).map { Segment(result[$0],result[$0+1]) }
    }
    private static func solveMotion(_ result:inout [Key]) {
        let n=result.count
        var upper=Array(repeating:0.0,count:n),rhs=Array(repeating:SIMD3<Double>.zero,count:n)
        func endpointAcceleration(_ a:Int,_ b:Int,_ c:Int)->SIMD3<Double> {
            let h0=result[b].time-result[a].time,h1=result[c].time-result[b].time
            return ((result[c].eye-result[b].eye)/h1-(result[b].eye-result[a].eye)/h0)*(2/(h0+h1))
        }
        result[0].acceleration=endpointAcceleration(0,1,2)
        result[n-1].acceleration=endpointAcceleration(n-3,n-2,n-1)
        rhs[0]=result[0].acceleration
        for i in 1..<(n-1) {
            let a=result[i].time-result[i-1].time,b=result[i+1].time-result[i].time
            let diagonal=2*(a+b)-a*upper[i-1]
            let target=((result[i+1].eye-result[i].eye)/b-(result[i].eye-result[i-1].eye)/a)*6
            upper[i]=b/diagonal;rhs[i]=(target-rhs[i-1]*a)/diagonal
        }
        for i in stride(from:n-2,through:1,by:-1) { result[i].acceleration=rhs[i]-result[i+1].acceleration*upper[i] }
        for i in 0..<(n-1) {
            let dt=result[i+1].time-result[i].time
            result[i].velocity=(result[i+1].eye-result[i].eye)/dt-(result[i].acceleration*2+result[i+1].acceleration)*(dt/6)
        }
        let dt=result[n-1].time-result[n-2].time
        result[n-1].velocity=(result[n-1].eye-result[n-2].eye)/dt+(result[n-2].acceleration+result[n-1].acceleration*2)*(dt/6)
    }
    private func bracket(_ value:Double,byTime:Bool)->(Int,Int,Float) {
        let value=min(byTime ? duration : keys.last!.route,max(0,value.isFinite ? value : 0))
        var a=0,b=keys.count-1
        while a+1<b { let m=(a+b)/2;if (byTime ? keys[m].time : keys[m].route)<=value { a=m } else { b=m } }
        let x=byTime ? keys[a].time : keys[a].route,y=byTime ? keys[b].time : keys[b].route
        return (a,b,Float((value-x)/max(0.000001,y-x)))
    }
    func time(at routeDistance:Double)->Double {
        let (a,b,t)=bracket(routeDistance,byTime:false);return keys[a].time+(keys[b].time-keys[a].time)*Double(t)
    }
    func sample(time:Double,in outputFrame:GeoBounds? = nil)->Sample {
        let (a,b,t)=bracket(time,byTime:true),left=keys[a],right=keys[b],motion=segments[a].sample(Double(t))
        var eye=SIMD3<Float>(motion.position),velocity=SIMD3<Float>(motion.velocity)
        let bank=Float(left.bank+(right.bank-left.bank)*Double(t))
        let cameraPoint=frame.point(u:Double(eye.x)/frame.widthMeters+0.5,v:Double(eye.z)/frame.depthMeters+0.5)
        let routeDistance=left.route+(right.route-left.route)*Double(t)
        let focus=cameraPoint
        if let outputFrame,outputFrame != frame {
            func convert(_ p:SIMD3<Float>)->SIMD3<Float> {
                let geo=frame.point(u:Double(p.x)/frame.widthMeters+0.5,v:Double(p.z)/frame.depthMeters+0.5),uv=outputFrame.uv(geo)
                return SIMD3(Float((uv.u-0.5)*outputFrame.widthMeters),p.y,Float((uv.v-0.5)*outputFrame.depthMeters))
            }
            let next=convert(eye+velocity);eye=convert(eye);velocity=next-eye
        }
        let direction=simd_length_squared(velocity)>0.00001 ? simd_normalize(velocity) : SIMD3<Float>(0,0,-1)
        let ground=left.ground+(right.ground-left.ground)*Double(t)
        return Sample(pose:.init(eye:eye,look:eye+direction*80,focus:focus,bank:bank),routeDistance:routeDistance,
                      speed:Double(simd_length(velocity)),velocity:velocity,heightAboveGround:Double(eye.y)-ground,cameraPoint:cameraPoint)
    }
}
