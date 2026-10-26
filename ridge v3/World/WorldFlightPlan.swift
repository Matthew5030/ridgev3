import Foundation
import simd

/// A small height-only snapshot of the saved terrain along the entire rail.
/// Preparation decodes one mesh at a time; playback never reads these meshes.
struct WorldFlightTerrain {
    let heights:[Float]
    let available:[Bool]
    private let clearanceHeights:[Float]
    private let subjects:[RoutePoint]
    private let subjectDistances:[Double]
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
        let limit=corridor.style == .drone ? WorldFlightGlide.coordinatedLateralLimit : WorldFlightGlide.lateralLimit
        return distances(length:corridor.length).flatMap { distance -> [GeoPoint] in
            let rail=corridor.sample(flightDistance:distance)
            let right=SIMD2(-rail.direction.y,rail.direction.x)
            return [-1.0,-0.5,0,0.5,1].map { lane in
                let offset=right*(lane*limit)
                return GeoPoint(latitude:rail.point.latitude-offset.y/111195,
                                longitude:rail.point.longitude+offset.x/(111195*max(0.01,cos(rail.point.latitude * .pi/180))))
            }
        }
    }
    /// Project the forward flight rail onto the walking path geometrically.
    /// Ordered walking distance can reverse through a skipped switchback while
    /// the camera still travels forward; it must not drag the gaze backwards.
    static func focusPoints(path:WorldRouteTourPath,corridor:WorldFlightCorridor)->[RoutePoint] {
        let origin=path.points[0].coordinate,scale=max(0.01,cos(origin.latitude * .pi/180))
        func local(_ point:GeoPoint)->SIMD2<Double> {
            SIMD2((point.longitude-origin.longitude)*111195*scale,(origin.latitude-point.latitude)*111195)
        }
        func cell(_ p:SIMD2<Double>)->SIMD2<Int> { SIMD2(Int(floor(p.x/160)),Int(floor(p.y/160))) }
        let step=max(8,path.length/40000)
        var distances=Array(stride(from:0.0,to:path.length,by:step));distances.append(path.length)
        let samples=distances.map { path.sample(at:$0) },positions=samples.map { local($0.coordinate) }
        var cells:[SIMD2<Int>:[Int]]=[:]
        for i in positions.indices { cells[cell(positions[i]),default:[]].append(i) }
        let last=path.points.last!
        // A tiny kink in the last walking segment must not swivel the gaze
        // into a new heading as the smooth camera rail finishes straight.
        let direction=corridor.sample(flightDistance:corridor.length).direction
        return Self.distances(length:corridor.length).map { travel in
            let ahead=travel+140
            if ahead>corridor.length {
                let delta=direction*(ahead-corridor.length)
                return RoutePoint(coordinate:.init(latitude:last.coordinate.latitude-delta.y/111195,
                    longitude:last.coordinate.longitude+delta.x/(111195*scale)),elevation:last.elevation)
            }
            let point=local(corridor.sample(flightDistance:ahead).point),key=cell(point)
            var best=Double.infinity,index=0
            for y in -2...2 { for x in -2...2 {
                for i in cells[key &+ SIMD2(x,y)] ?? [] {
                    let error=simd_length_squared(point-positions[i]);if error<best { best=error;index=i }
                }
            } }
            if !best.isFinite {
                for i in positions.indices {
                    let error=simd_length_squared(point-positions[i]);if error<best { best=error;index=i }
                }
            }
            var distance=distances[index]
            for a in max(0,index-1)...min(positions.count-2,index) {
                let delta=positions[a+1]-positions[a],square=simd_length_squared(delta)
                let t=square>0 ? min(1,max(0,simd_dot(point-positions[a],delta)/square)) : 0
                let error=simd_length_squared(point-positions[a]-delta*t)
                if error<best { best=error;distance=distances[a]+(distances[a+1]-distances[a])*t }
            }
            return path.sample(at:distance)
        }
    }
    init(path:WorldRouteTourPath,corridor:WorldFlightCorridor,heights:[Float?],places:[MapPlace]=[],clearanceHeights:[Float?]? = nil,focusPoints:[RoutePoint]? = nil,focusHeights:[Float?]? = nil) {
        let distances=Self.distances(length:corridor.length)
        subjectDistances=distances
        let focus=focusPoints ?? Self.focusPoints(path:path,corridor:corridor)
        let samples=distances.map { corridor.sample(flightDistance:$0) }
        origin=samples[0].point;scale=max(0.01,cos(origin.latitude * .pi/180))
        let origin=self.origin,scale=self.scale
        points=samples.map { SIMD2(($0.point.longitude-origin.longitude)*111195*scale,(origin.latitude-$0.point.latitude)*111195) }
        let preparedHeights=samples.indices.map { i in heights[i] ?? Float(path.sample(at:samples[i].routeDistance).elevation ?? 0) }
        self.heights=preparedHeights
        subjects=focus.indices.map { i in
            let height=focusHeights?[i] ?? nil
            let elevation=focusHeights == nil ? (focus[i].elevation ?? Double(preparedHeights[i])) : Double(height ?? preparedHeights[i])
            return RoutePoint(coordinate:focus[i].coordinate,elevation:elevation)
        }
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
    private func bracketTravel(_ travel:Double)->(Int,Int,Double) {
        let distance=min(subjectDistances.last!,max(0,travel.isFinite ? travel : 0))
        var a=0,b=subjectDistances.count-1
        while a+1<b { let m=(a+b)/2;if subjectDistances[m]<=distance { a=m } else { b=m } }
        return (a,b,(distance-subjectDistances[a])/max(0.000001,subjectDistances[b]-subjectDistances[a]))
    }
    /// The same position can be visited with a different heading and clearance
    /// corridor. Production must retain that occurrence, not choose a nearby
    /// sample from another leg at a crossing or close return.
    func elevation(at travel:Double)->Double {
        let (a,b,t)=bracketTravel(travel)
        return Double(heights[a])+(Double(heights[b])-Double(heights[a]))*t
    }
    func clearanceElevation(at travel:Double)->Double {
        let (a,b,t)=bracketTravel(travel)
        if t<=0.000000001 { return Double(clearanceHeights[a]) }
        if t>=0.999999999 { return Double(clearanceHeights[b]) }
        return Double(max(clearanceHeights[a],clearanceHeights[b]))
    }
    func subject(at travel:Double)->RoutePoint {
        var a=0,b=subjects.count-1
        while a+1<b { let m=(a+b)/2;if subjectDistances[m]<=travel { a=m } else { b=m } }
        let t=min(1,max(0,(travel-subjectDistances[a])/max(0.001,subjectDistances[b]-subjectDistances[a])))
        let x=subjects[a],y=subjects[b]
        let elevation:Double?=x.elevation.flatMap { left in y.elevation.map { left+($0-left)*t } }
        return .init(coordinate:.init(latitude:x.coordinate.latitude+(y.coordinate.latitude-x.coordinate.latitude)*t,
                                     longitude:x.coordinate.longitude+(y.coordinate.longitude-x.coordinate.longitude)*t),elevation:elevation)
    }

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
        var routeTarget:SIMD3<Float>? = nil
        var fieldOfView=WorldRouteTour.fieldOfView
        var acceleration=SIMD3<Float>.zero
        var movementAligned=false
        var bankResponseAcceleration=9.81
        var stabilizesRoll=false
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
        result.acceleration=point(sample.pose.eye+sample.acceleration)-result.pose.eye
        result.routeTarget=sample.routeTarget.map { point($0) }
        return result
    }
    private struct Key {
        var time:Double;var route:Double;var eye:SIMD3<Double>;var ground:Double;var overview:Double
        var bank=0.0
        var fieldOfView=WorldRouteTour.fieldOfView
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
        /// Integrate the prepared cubic in space. Five-point Gaussian
        /// quadrature is accurate over these short, densely sampled segments.
        func arcLength(to t:Double)->Double {
            let half=t*0.5
            func speed(_ x:Double)->Double {
                let u=half*(1+x)
                return simd_length(c1+u*(c2*2+u*c3*3))
            }
            return half*(0.5688888888888889*speed(0)
                + 0.4786286704993665*(speed(-0.5384693101056831)+speed(0.5384693101056831))
                + 0.2369268850561891*(speed(-0.9061798459386640)+speed(0.9061798459386640)))
        }
        func parameter(at length:Double,total:Double)->Double {
            var t=min(1,max(0,length/max(0.000000001,total)))
            for _ in 0..<4 {
                let derivative=simd_length(c1+t*(c2*2+t*c3*3))
                t=min(1,max(0,t-(arcLength(to:t)-length)/max(0.000000001,derivative)))
            }
            return t
        }
    }
    let frame:GeoBounds
    let cruiseSpeed:Double
    let clearance:Double
    let reduceMotion:Bool
    let hasSpeedTransition:Bool
    let routeFraming:Bool
    let adaptiveFraming:Bool
    let movementAligned:Bool
    let bankResponseAcceleration:Double
    let stabilizesRoll:Bool
    private var keys:[Key]
    private var segments:[Segment]
    private var lookSegments:[Segment]=[]
    private var arcLengths:[Double]=[]
    private var arcSpeed=0.0
    var duration:Double { keys.last?.time ?? 0 }
    var count:Int { keys.count }

    init(path:WorldRouteTourPath,corridor:WorldFlightCorridor,terrain:WorldFlightTerrain,frame:GeoBounds,cruiseSpeed:Double,reduceMotion:Bool,
         clearance:Double=20,cornerLift:Double=0,routeFraming:Bool=false,adaptiveFraming:Bool=true,coordinatedTurns:Bool=true,movementAligned requestedAlignment:Bool=false,turnLimits:WorldFlightTurn.Limits? = nil,speedChangeAt:Double? = nil,initialSpeed:Double? = nil,initialAltitude:Float? = nil) throws {
        let drone=corridor.style == .drone,movementAligned=requestedAlignment || corridor.style == .drone
        self.frame=frame;self.cruiseSpeed=cruiseSpeed;self.reduceMotion=reduceMotion;self.clearance=min(1000,max(5,clearance))
        hasSpeedTransition=initialSpeed != nil || initialAltitude != nil
        stabilizesRoll=drone && !reduceMotion && turnLimits == nil && initialSpeed == nil && initialAltitude == nil
        self.routeFraming=routeFraming && !drone;self.adaptiveFraming=adaptiveFraming && !drone
        self.movementAligned=movementAligned
        bankResponseAcceleration=movementAligned ? (turnLimits ?? (reduceMotion ? .gentle : .cinematic)).bankResponseAcceleration : 9.81
        var result:[Key]=[],time=0.0,lastTravel=0.0,lastSpeed=0.0
        var minimumHeights:[Double]=[]
        let desiredSpacing=max(corridor.length/40000,min(3,max(0.5,cruiseSpeed*0.12)))
        let intervals=max(drone ? 32 : 2,Int(ceil(corridor.length/desiredSpacing))),spacing=corridor.length/Double(intervals)
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
            let ground=drone ? terrain.elevation(at:travel) : Double(terrain.elevation(rail.point))
            let uv=frame.uv(point)
            let eye=SIMD3((uv.u-0.5)*frame.widthMeters,Double(ground),(uv.v-0.5)*frame.depthMeters)
            let floor=drone ? terrain.clearanceElevation(at:travel) : Double(terrain.clearanceElevation(rail.point))
            minimumHeights.append(floor+self.clearance+(drone ? 0 : max(0,cornerLift)*rail.overview))
            result.append(Key(time:time,route:rail.routeDistance,eye:eye,ground:Double(ground),overview:rail.overview))
            if drone { result[result.count-1].fieldOfView=reduceMotion ? WorldRouteTour.fieldOfView : 78 }
            lastTravel=travel;lastSpeed=speed
        }
        // The drone follows a closer terrain envelope; the older gliding
        // choreography keeps its broad hill anticipation. Both bridge small
        // hollows with one prepared, continuous height curve.
        let verticalRadius=drone ? 400.0 : 1400.0
        let count=minimumHeights.count,penalty=spacing*spacing/(2*verticalRadius)
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
        let radius=max(1,Int(ceil((drone ? 60 : 120)/spacing))),window=Double(radius*2+1)
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
        let bandWidth=max(drone ? 120 : 200,spacing),bandCount=max(1,Int(ceil(corridor.length/bandWidth)))
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
        if cornerLift>0 && !drone { Self.retime(&result,corridor:corridor,speed:cruiseSpeed) }
        // Solve one C2 cubic trajectory through the timed positions. Estimating
        // derivatives separately and then fitting a higher-order interpolant
        // introduced false curvature and alternating banks between close keys.
        // Endpoint curvature comes from the adjacent chords, avoiding a forced
        // zero-bank knot followed immediately by a full bank.
        Self.solveMotion(&result)
        // Composition is based on the original prepared motion, never feedback
        // from the widening camera. Dense bends become one held wide shot.
        var framingTargets:[SIMD3<Double>]=[]
        var terrainGrades:[Double]=[]
        var terrainInfluence:[Double]=[]
        var framingAmount=Array(repeating:0.0,count:result.count)
        if routeFraming && !drone {
            framingTargets=result.indices.map { i in
                let point=terrain.subject(at:stations[i]),uv=frame.uv(point.coordinate)
                var target=SIMD3((uv.u-0.5)*frame.widthMeters,point.elevation ?? result[i].ground,(uv.v-0.5)*frame.depthMeters)
                let v=SIMD2(result[i].velocity.x,result[i].velocity.z)
                let forward=simd_length_squared(v)>0.001 ? simd_normalize(v) : SIMD2<Double>(0,-1)
                let delta=SIMD2(target.x-result[i].eye.x,target.z-result[i].eye.z),shift=max(0,80-simd_dot(delta,forward))
                target.x+=forward.x*shift;target.z+=forward.y*shift;return target
            }
            // Hill clearance deliberately rises early. A nearby ground target
            // would therefore keep looking down even while climbing. Pitch
            // follows the broad terrain grade, independently of that lift.
            let ground=Self.smoothTargets(result.map { SIMD3<Double>(0,$0.ground,0) },
                spacing:spacing,span:80,extendEnds:true)
            let radius=max(1,Int(ceil(180/spacing)))
            terrainGrades=result.indices.map { i -> Double in
                let a=max(0,i-radius),b=min(result.count-1,i+radius)
                return (ground[b].y-ground[a].y)/max(0.001,stations[b]-stations[a])
            }
            // Hold the terrain framing through crests and flat shoulders.
            // Blending back to a ground stare whenever grade crosses zero
            // would introduce a large nod at the top/bottom of every hill.
            terrainInfluence=Self.heldProfile(terrainGrades.map { Self.ease((abs($0)-0.005)/0.025) },
                spacing:spacing,before:600,ahead:600,smoothing:100)
            if adaptiveFraming && !reduceMotion {
                let compositionTargets=Self.slopeFraming(result,targets:framingTargets,grades:terrainGrades,influence:terrainInfluence,spacing:spacing)
                let composition=Self.composition(result,targets:compositionTargets,spacing:spacing,
                    speedScale:WorldRouteTour.previewCruiseSpeed/3.6/cruiseSpeed)
                framingAmount=composition
                for i in result.indices {
                    result[i].eye.y+=composition[i]*28
                    result[i].fieldOfView=WorldRouteTour.fieldOfView+composition[i]*8
                }
                Self.retime(&result,corridor:corridor,speed:cruiseSpeed)
                Self.solveMotion(&result)
            }
        }
        if movementAligned {
            if drone && !reduceMotion && turnLimits == nil && !hasSpeedTransition {
                // Fly the complete spatial curve at one arc-length pace.
                // Corners shape the route, never a local throttle command.
                keys=result;segments=(0..<(result.count-1)).map { Segment(result[$0],result[$0+1]) }
                arcLengths=[0]
                for segment in segments { arcLengths.append(arcLengths.last!+segment.arcLength(to:1)) }
                let scale=WorldRouteTour.previewCruiseSpeed/3.6/cruiseSpeed
                // Very short routes use one slower pace for the entire shot,
                // so a metre-scale loop still has a watchable eight-second run.
                let maximum=min(cruiseSpeed*scale,arcLengths.last!/8)
                arcSpeed=Self.constantFlightPace(segments:segments,arcLengths:arcLengths,maximum:maximum,response:bankResponseAcceleration)/scale
                for i in keys.indices { keys[i].time=arcLengths[i]/max(0.000000001,arcSpeed) }
                return
            }
            // One trajectory supplies position, velocity, pitch and bank. Pace
            // must change to fit that trajectory, rather than faking a gentle
            // bank while crossing a hairpin at the straight-line cruise speed.
            try Self.retimeFlight(&result,cruiseSpeed:cruiseSpeed,limits:turnLimits ?? (reduceMotion ? .gentle : .cinematic))
            keys=result;segments=(0..<(result.count-1)).map { Segment(result[$0],result[$0+1]) }
            return
        }
        let n=result.count
        // Unframed flight banks from its trajectory. Route-framed flight below
        // coordinates its visible heading and roll from one prepared turn.
        var banks=result.map { key -> Double in
            let v=SIMD2(key.velocity.x,key.velocity.z),a=SIMD2(key.acceleration.x,key.acceleration.z),square=simd_length_squared(v)
            let curvature=square>0.0001 ? (v.x*a.y-v.y*a.x)/pow(square,1.5) : 0
            return reduceMotion ? 0 : Double(WorldFlightTurn.bank(curvature:curvature,speed:sqrt(square),overview:key.overview))
        }
        for i in 1..<n { let w=1-exp(-(result[i].time-result[i-1].time)/0.5);banks[i]=banks[i-1]+(banks[i]-banks[i-1])*w }
        for i in stride(from:n-2,through:0,by:-1) { let w=1-exp(-(result[i+1].time-result[i].time)/0.5);banks[i]=banks[i+1]+(banks[i]-banks[i+1])*w }
        for i in result.indices { result[i].bank=banks[i] }
        keys=result;segments=(0..<(result.count-1)).map { Segment(result[$0],result[$0+1]) }
        if routeFraming {
            // The route is the visual subject, including when the smooth rail
            // cuts a small bend. Prepare this focus curve once, alongside motion.
            // Extend the final leg so the finish cannot pull the camera vertically
            // down or flip it backwards as the eye reaches the last waypoint.
            let close=Self.smoothTargets(framingTargets,spacing:spacing,span:24)
            let wide=adaptiveFraming ? Self.smoothTargets(framingTargets,spacing:spacing,span:48) : close
            let groundTargets=result.indices.map { i in
                close[i]+(wide[i]-close[i])*(reduceMotion && adaptiveFraming ? 1 : framingAmount[i])
            }
            // Apply pitch after horizontal composition and from the final eye
            // height. Focus filtering and pullback cannot tip a climb down.
            var targets=Self.slopeFraming(result,targets:groundTargets,grades:terrainGrades,influence:terrainInfluence,spacing:spacing)
            if coordinatedTurns {
                targets=Self.turnFraming(result,targets:targets,stations:stations,spacing:spacing)
                if !reduceMotion {
                    let banks=Self.turnBanks(result,targets:targets,spacing:spacing,speedScale:WorldRouteTour.previewCruiseSpeed/3.6/cruiseSpeed)
                    for i in result.indices { result[i].bank=banks[i] }
                    keys=result
                }
            }
            var focus=result
            for i in focus.indices { focus[i].eye=targets[i] }
            Self.solveMotion(&focus)
            lookSegments=(0..<(focus.count-1)).map { Segment(focus[$0],focus[$0+1]) }
        }
    }
    /// Pick one cruise for the whole prepared shot. Geometry determines the
    /// direction and bank; no corner can issue a brake or acceleration command.
    private static func constantFlightPace(segments:[Segment],arcLengths:[Double],maximum:Double,response:Double)->Double {
        var stations:[(distance:Double,lateral:Double,angular:Double,pitch:Double)]=[]
        for i in segments.indices {
            for t in [0.0,0.5,1.0] {
                let m=segments[i].sample(t),squared=max(0.000000000001,simd_length_squared(m.velocity))
                let direction=m.velocity/sqrt(squared)
                let curvature=(m.acceleration-m.velocity*(simd_dot(m.velocity,m.acceleration)/squared))/squared
                let horizontal=max(0.000000001,hypot(direction.x,direction.z))
                stations.append((arcLengths[i]+segments[i].arcLength(to:t),
                    (direction.x*curvature.z-direction.z*curvature.x)/horizontal,
                    simd_length(simd_cross(direction,curvature)),abs(WorldFlightTurn.pitchRate(velocity:direction,acceleration:curvature))))
            }
        }
        func accepts(_ speed:Double)->Bool {
            var last:(distance:Double,bank:Double,bodyBank:Double)?
            for s in stations {
                let bank=WorldFlightTurn.cameraBank(lateral:s.lateral*speed*speed,responseAcceleration:response,stabilized:true)
                let bodyBank=atan(-s.lateral*speed*speed/response)
                // Horizon stabilization must not let the flight exceed its
                // original movement limits merely because the camera leans less.
                if abs(bodyBank)>WorldFlightCorridor.droneBankLimit || s.angular*speed>WorldFlightCorridor.droneAngularLimit || s.pitch*speed>0.6 { return false }
                if let previous=last,s.distance>previous.distance+0.0000001,
                   max(abs(bank-previous.bank),abs(bodyBank-previous.bodyBank))*speed/(s.distance-previous.distance)>WorldFlightCorridor.droneRollLimit { return false }
                last=(s.distance,bank,bodyBank)
            }
            return true
        }
        if accepts(maximum) { return maximum }
        var low=0.0,high=maximum
        for _ in 0..<18 { let mid=(low+high)/2;if accepts(mid) { low=mid } else { high=mid } }
        return max(0.000001,low)
    }
    /// Prepare a coordinated-turn speed envelope in actual playback seconds.
    /// v² κ is lateral acceleration; bank uses the chosen response scale. Curvature change
    /// also limits pace, so rolling into a bend takes time. Braking is planned
    /// backwards along the whole journey, never discovered by the live camera.
    private static func retimeFlight(_ keys:inout [Key],cruiseSpeed:Double,limits:WorldFlightTurn.Limits) throws {
        let n=keys.count,scale=WorldRouteTour.previewCruiseSpeed/3.6/cruiseSpeed
        var distance=Array(repeating:0.0,count:n)
        for i in 1..<n { distance[i]=distance[i-1]+simd_distance(keys[i].eye,keys[i-1].eye) }
        for i in keys.indices { keys[i].time=distance[i] }
        Self.solveMotion(&keys)
        let curvature=keys.map { key -> Double in
            let v=SIMD2(key.velocity.x,key.velocity.z),a=SIMD2(key.acceleration.x,key.acceleration.z)
            return (v.x*a.y-v.y*a.x)/max(0.0000001,pow(simd_length(v),3))
        }
        let cruise=WorldRouteTour.previewCruiseSpeed/3.6
        let fullCurvature=keys.map { key in
            simd_length(simd_cross(key.velocity,key.acceleration))/max(0.0000001,pow(simd_length(key.velocity),3))
        }
        let pitchCurvature=keys.map { abs(WorldFlightTurn.pitchRate(velocity:$0.velocity,acceleration:$0.acceleration)) }
        var caps=keys.indices.map { i -> Double in
            let k=abs(curvature[i])
            let lateral=sqrt(limits.lateralAcceleration/max(0.0000001,k)),angular=limits.yawRate/max(0.0000001,fullCurvature[i])
            let pitch=limits.pitchRate/max(0.0000001,pitchCurvature[i])
            return pow(min(cruise,lateral,angular,pitch),2)
        }
        // One pace through a manoeuvre. Independent curvature-change caps at
        // entry and exit created a brake/accelerate/brake pulse inside a turn.
        // Include the filtered joins, and hold nearby bends as one section.
        func holdTurnPace(_ values:inout [Double]) {
            var turns:[ClosedRange<Int>]=[],start:Int?,last:Int?
            for i in keys.indices where values[i]<cruise*cruise*0.98 {
                if let previous=last,distance[i]-distance[previous]>200,let a=start {
                    turns.append(a...previous);start=i
                } else if start == nil { start=i }
                last=i
            }
            if let a=start,let b=last { turns.append(a...b) }
            var spans:[ClosedRange<Int>]=[]
            for turn in turns {
                var a=turn.lowerBound,b=turn.upperBound
                while a>0 && distance[turn.lowerBound]-distance[a]<12 { a-=1 }
                while b<n-1 && distance[b]-distance[turn.upperBound]<12 { b+=1 }
                if let previous=spans.last,a<=previous.upperBound+1 { spans[spans.count-1]=previous.lowerBound...b }
                else { spans.append(a...b) }
            }
            for span in spans {
                let speed=span.map { values[$0] }.min()!
                for i in span { values[i]=speed }
            }
        }
        let spacing=distance.last!/Double(n-1)
        let radius=max(1,Int(ceil(limits.smoothingDistance/max(0.001,spacing))))
        func envelope(_ ceilings:[Double])->[Double] {
            var values=ceilings
            // Anticipate the manoeuvre without dragging its low corner speed
            // through kilometres of otherwise clear route.
            let slope=2*limits.acceleration
            for i in 1..<n { values[i]=min(values[i],values[i-1]+slope*(distance[i]-distance[i-1])) }
            for i in stride(from:n-2,through:0,by:-1) { values[i]=min(values[i],values[i+1]+slope*(distance[i+1]-distance[i])) }
            // A minimum over the complete filter support, then positive box
            // filters, stays below every original cap while easing its joins.
            let reach=radius*4
            var queue=Array(repeating:0,count:n),head=0,tail=0,added=0
            let input=values
            for i in values.indices {
                while added<=min(n-1,i+reach) {
                    while tail>head && input[queue[tail-1]]>=input[added] { tail-=1 }
                    queue[tail]=added;tail+=1;added+=1
                }
                while head<tail && queue[head]<i-reach { head+=1 }
                values[i]=input[queue[head]]
            }
            for _ in 0..<4 {
                var prefix=Array(repeating:0.0,count:n+1)
                for i in values.indices { prefix[i+1]=prefix[i]+values[i] }
                values=values.indices.map { i in
                    let a=max(0,i-radius),b=min(n-1,i+radius)
                    let pad=Double(max(0,radius-i))*values[0]+Double(max(0,i+radius-n+1))*values[n-1]
                    return (prefix[b+1]-prefix[a]+pad)/Double(radius*2+1)
                }
            }
            return values
        }
        var residual=1.0
        for _ in 0..<20 {
            try Task.checkCancellation()
            var targets=caps
            holdTurnPace(&targets)
            let speeds=envelope(targets).map { sqrt(max(0.0001,$0)) }
            keys[0].time=0
            for i in 1..<n {
                keys[i].time=keys[i-1].time+2*(distance[i]-distance[i-1])/(speeds[i]+speeds[i-1])*scale
            }
            Self.solveMotion(&keys)
            var factors=Array(repeating:1.0,count:n),last:(bank:Double,time:Double)?,valid=true
            residual=1
            for i in 0..<(n-1) {
                let segment=Segment(keys[i],keys[i+1])
                for fraction in [0.0,0.5,1.0] {
                    let sample=segment.sample(fraction),v=sample.velocity*scale,a=sample.acceleration*scale*scale
                    let horizontal=SIMD2(v.x,v.z),acceleration=SIMD2(a.x,a.z),speed=simd_length(horizontal)
                    let cross=horizontal.x*acceleration.y-horizontal.y*acceleration.x
                    let lateral=cross/max(0.00001,speed)
                    let rate=simd_length(simd_cross(v,a))/max(0.00001,simd_length_squared(v))
                    let bank=atan(-lateral/limits.bankResponseAcceleration),time=(keys[i].time+(keys[i+1].time-keys[i].time)*fraction)/scale
                    var factor=max(1,sqrt(abs(lateral)/(limits.lateralAcceleration*1.1)),abs(rate)/(limits.yawRate*1.1))
                    factor=max(factor,abs(WorldFlightTurn.pitchRate(velocity:v,acceleration:a))/limits.pitchRate)
                    if let previous=last,time>previous.time+0.000001 {
                        let rollRate=abs(bank-previous.bank)/(time-previous.time)
                        factor=max(factor,pow(rollRate/limits.rollRate,1.0/3))
                        residual=max(residual,rollRate/limits.rollRate)
                    }
                    if factor>1.001 { valid=false }
                    residual=max(residual,factor)
                    factors[i]=max(factors[i],factor);factors[i+1]=max(factors[i+1],factor)
                    last=(bank,time)
                }
            }
            if valid { residual=1;break }
            for i in caps.indices where factors[i]>1.001 { caps[i]/=pow(factors[i]*1.02,2) }
        }
        if residual>1.001 {
            // A pathological join still gets one continuous, slower timeline;
            // never silently fall back to clamping the visible bank alone.
            for i in keys.indices { keys[i].time*=residual*1.02 }
            Self.solveMotion(&keys)
        }
    }
    private static func unwrappedHeadings(_ keys:[Key],targets:[SIMD3<Double>])->[Double] {
        var result:[Double]=[]
        for i in keys.indices {
            let delta=targets[i]-keys[i].eye
            var angle=atan2(delta.x,-delta.z)
            if let previous=result.last { angle=previous+atan2(sin(angle-previous),cos(angle-previous)) }
            result.append(angle)
        }
        return result
    }
    /// Filter heading itself, rather than chasing nearby focus points through
    /// each bend. Pitch retains the accepted terrain framing. A forward cone
    /// stops a short return from becoming a turn of the head across the rail.
    private static func turnFraming(_ keys:[Key],targets:[SIMD3<Double>],stations:[Double],spacing:Double)->[SIMD3<Double>] {
        let angles=Self.unwrappedHeadings(keys,targets:targets)
        let smooth=Self.smoothTargets(angles.map { SIMD3<Double>(0,$0,0) },spacing:spacing,span:100)
        return keys.indices.map { i in
            let eye=keys[i].eye,delta=targets[i]-eye
            let originalRange=max(1,simd_length(SIMD2(delta.x,delta.z))),range=max(120,originalRange)
            let weight=Self.ease(min(stations[i],stations.last!-stations[i])/160)
            let heading=angles[i]+(smooth[i].y-angles[i])*weight
            let course=atan2(keys[i].velocity.x,-keys[i].velocity.z)
            let offset=atan2(sin(heading-course),cos(heading-course))
            let forwardHeading=course+0.9*tanh(offset/0.9)
            // Retain the accepted route composition in narrow turns. Smoothing
            // cannot replace a sideways swivel with a view that loses the path.
            let correction=atan2(sin(forwardHeading-angles[i]),cos(forwardHeading-angles[i]))
            let limit=12.0 * Double.pi/180
            let azimuth=angles[i]+limit*tanh(correction/limit)
            return eye+SIMD3(sin(azimuth)*range,delta.y*range/originalRange,-cos(azimuth)*range)
        }
    }
    /// One continuous roll cue for the visible turn, prepared in playback time.
    /// Look ahead by the runtime roll response so the bank begins before the
    /// heading swings. Small corrections do not repeatedly flap the horizon.
    private static func turnBanks(_ keys:[Key],targets:[SIMD3<Double>],spacing:Double,speedScale:Double)->[Double] {
        let headings=Self.unwrappedHeadings(keys,targets:targets),n=keys.count
        let radius=max(1,Int(ceil(35/spacing)))
        let banks=keys.indices.map { i -> SIMD3<Double> in
            let a=max(0,i-radius),b=min(n-1,i+radius)
            let rate=(headings[b]-headings[a])/max(0.001,keys[b].time-keys[a].time)*speedScale
            let limit=(24-6*keys[i].overview) * .pi/180
            let amount=Self.ease(abs(rate)/0.08)
            return SIMD3(0,-limit*tanh(rate/0.5)*amount,0)
        }
        let smooth=Self.smoothTargets(banks,spacing:spacing,span:60)
        let ahead=max(1,Int(ceil(0.45*simd_length(keys[0].velocity)*speedScale/spacing)))
        return keys.indices.map { smooth[min(n-1,$0+ahead)].y }
    }
    /// Keep the route's horizontal bearing while looking with the terrain:
    /// up on climbs, down on descents. Flat ground retains its accepted focus.
    /// A broad grade and smooth blend ignore small bumps. The original ground
    /// subject remains within the lower frame when clearance requires height.
    private static func ease(_ x:Double)->Double { let t=min(1,max(0,x));return t*t*t*(10+t*(-15+6*t)) }
    private static func slopeFraming(_ keys:[Key],targets:[SIMD3<Double>],grades:[Double],influence:[Double],spacing:Double)->[SIMD3<Double>] {
        let pitches=keys.indices.map { i -> SIMD3<Double> in
            let grade=min(0.8,max(-0.8,grades[i]))
            let eye=keys[i].eye
            let target=targets[i]
            let range=max(1,simd_length(SIMD2(target.x-eye.x,target.z-eye.z)))
            let groundPitch=atan2(target.y-eye.y,range)
            let pitch=atan(grade)
            let visible=groundPitch+(keys[i].fieldOfView/2-8) * .pi/180
            // Ease into the visibility bound instead of pitching sharply when
            // a high clearance arc brings the walking line near the frame edge.
            let softness=2 * Double.pi/180
            let limited=min(pitch,visible)-softness*log1p(exp(-abs(pitch-visible)/softness))
            return SIMD3(0,limited,0)
        }
        // Smooth the composed pitch as well as the terrain itself: a visibility
        // limit on a steep shoulder must not introduce a quick camera nod.
        let smooth=Self.smoothTargets(pitches,spacing:spacing,span:60,extendEnds:true)
        return keys.indices.map { i in
            let weight=influence[i]
            guard weight>0.000001 else { return targets[i] }
            let eye=keys[i].eye
            var target=targets[i]
            let range=max(1,simd_length(SIMD2(target.x-eye.x,target.z-eye.z)))
            let original=atan2(target.y-eye.y,range)
            target.y=eye.y+range*tan(original+(smooth[i].y-original)*weight)
            return target
        }
    }
    private static func smoothTargets(_ input:[SIMD3<Double>],spacing:Double,span:Double,extendEnds:Bool=false)->[SIMD3<Double>] {
        var targets=input
        let radius=max(1,Int(ceil(span/spacing))),window=Double(radius*2+1)
        for _ in 0..<4 {
            var prefix=[SIMD3<Double>.zero]
            for target in targets { prefix.append(prefix.last!+target) }
            targets=targets.indices.map { i in
                let a=max(0,i-radius),b=min(targets.count-1,i+radius)
                let left=Double(max(0,radius-i)),right=Double(max(0,i+radius-targets.count+1))
                var padding=targets[0]*left+targets.last!*right
                if extendEnds {
                    // Estimate endpoint grade over the filter's full span;
                    // a tiny bump at the first/last sample is not a hillside.
                    let band=min(radius,targets.count-1),step=Double(band)
                    padding-=(targets[band]-targets[0])*(left*(left+1)/(2*step))
                    padding+=(targets[targets.count-1]-targets[targets.count-1-band])*(right*(right+1)/(2*step))
                }
                return (prefix[b+1]-prefix[a]+padding)/window
            }
        }
        return targets
    }
    private static func retime(_ result:inout [Key],corridor:WorldFlightCorridor,speed:Double) {
        var elapsed=0.0;result[0].time=0
        for i in 1..<result.count {
            let a=corridor.speedLimit(at:result[i-1].route,requested:speed),b=corridor.speedLimit(at:result[i].route,requested:speed)
            elapsed+=max(0.00001,simd_distance(result[i-1].eye,result[i].eye)*2/max(0.2,a+b));result[i].time=elapsed
        }
    }
    /// Anticipate angular work at the chosen playback pace. A forward maximum
    /// starts widening before a turn, holds through nearby turns, and releases
    /// slowly. Four bounded convolutions make a smooth, immutable shot profile.
    private static func composition(_ keys:[Key],targets:[SIMD3<Double>],spacing:Double,speedScale:Double)->[Double] {
        let n=keys.count
        let views=keys.indices.map { simd_normalize(targets[$0]-keys[$0].eye) }
        let headings=keys.map { key -> SIMD2<Double> in
            let v=SIMD2(key.velocity.x,key.velocity.z)
            return simd_length_squared(v)>0.001 ? simd_normalize(v) : SIMD2<Double>(0,-1)
        }
        var viewArc=Array(repeating:0.0,count:n),turnArc=viewArc
        for i in 1..<n {
            viewArc[i]=viewArc[i-1]+acos(min(1,max(-1,simd_dot(views[i],views[i-1]))))
            turnArc[i]=turnArc[i-1]+acos(min(1,max(-1,simd_dot(headings[i],headings[i-1]))))
        }
        let band=max(1,Int(ceil(75/spacing)))
        var demand=Array(repeating:0.0,count:n)
        for i in keys.indices {
            let a=max(0,i-band),b=min(n-1,i+band),seconds=max(0.01,(keys[b].time-keys[a].time)/speedScale)
            let rate=max(viewArc[b]-viewArc[a],turnArc[b]-turnArc[a])/seconds
            let view=SIMD2(views[i].x,views[i].z)
            let bearing=simd_length_squared(view)>0.001 ? acos(min(1,max(-1,simd_dot(simd_normalize(view),headings[i])))) : 0
            demand[i]=min(1,max(0,max((rate-0.15)/0.75,(bearing-0.26)/0.75)))
        }
        return Self.heldProfile(demand,spacing:spacing,before:160,ahead:280,smoothing:80)
    }
    private static func heldProfile(_ demand:[Double],spacing:Double,before:Double,ahead:Double,smoothing:Double)->[Double] {
        let n=demand.count
        let before=max(1,Int(ceil(before/spacing))),ahead=max(1,Int(ceil(ahead/spacing)))
        var queue=Array(repeating:0,count:n),head=0,tail=0,added=0,profile=demand
        for i in demand.indices {
            let end=min(n-1,i+ahead)
            while added<=end {
                while tail>head && demand[queue[tail-1]]<=demand[added] { tail-=1 }
                queue[tail]=added;tail+=1;added+=1
            }
            while tail>head && queue[head]<i-before { head+=1 }
            profile[i]=demand[queue[head]]
        }
        let radius=max(1,Int(ceil(smoothing/spacing))),window=Double(radius*2+1)
        for _ in 0..<4 {
            var prefix=Array(repeating:0.0,count:n+1)
            for i in demand.indices { prefix[i+1]=prefix[i]+profile[i] }
            profile=demand.indices.map { i in
                let a=max(0,i-radius),b=min(n-1,i+radius)
                let pad=Double(max(0,radius-i))*profile[0]+Double(max(0,i+radius-n+1))*profile[n-1]
                return min(1,max(0,(prefix[b+1]-prefix[a]+pad)/window))
            }
        }
        return profile
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
    private func bracket(_ value:Double,byTime:Bool)->(Int,Int,Double) {
        let value=min(byTime ? duration : keys.last!.route,max(0,value.isFinite ? value : 0))
        var a=0,b=keys.count-1
        while a+1<b { let m=(a+b)/2;if (byTime ? keys[m].time : keys[m].route)<=value { a=m } else { b=m } }
        let x=byTime ? keys[a].time : keys[a].route,y=byTime ? keys[b].time : keys[b].route
        return (a,b,(value-x)/max(0.000001,y-x))
    }
    func time(at routeDistance:Double)->Double {
        let (a,b,t)=bracket(routeDistance,byTime:false)
        if !arcLengths.isEmpty { return keys[a].time+segments[a].arcLength(to:t)/arcSpeed }
        return keys[a].time+(keys[b].time-keys[a].time)*t
    }
    /// Opt-in device diagnostics: relative progress and motion only, with no
    /// coordinates. Called on the preparation worker, never in the frame loop.
    func diagnosticProfile(corridor:WorldFlightCorridor,terrain:WorldFlightTerrain)->Data? {
        let scale=WorldRouteTour.previewCruiseSpeed/3.6/cruiseSpeed,seconds=duration/scale
        let count=max(1,min(10000,Int(ceil(seconds/0.05))))
        var rows:[[String:Double]]=[]
        for i in 0...count {
            let time=seconds*Double(i)/Double(count),sample=sample(time:time*scale)
            let velocity=SIMD3<Double>(sample.velocity)*scale
            let acceleration=SIMD3<Double>(sample.acceleration)*scale*scale
            let travel=corridor.flightDistance(at:sample.routeDistance)
            let pitch=atan2(velocity.y,hypot(velocity.x,velocity.z))
            rows.append([
                "seconds":time,"routeDistanceM":sample.routeDistance,"speedKmh":sample.speed*scale*3.6,
                "altitudeM":Double(sample.pose.eye.y),"groundM":terrain.elevation(at:travel),
                "clearanceFloorM":terrain.clearanceElevation(at:travel)+clearance,"heightAGL":sample.heightAboveGround,
                "pitchDegrees":pitch*180 / .pi,"bankDegrees":Double(sample.pose.bank)*180 / .pi,
                "pitchRateDegreesS":WorldFlightTurn.pitchRate(velocity:velocity,acceleration:acceleration)*180 / .pi,
                "verticalVelocityMS":velocity.y,"verticalAccelerationMS2":acceleration.y])
        }
        let payload:[String:Any]=["format":1,"recordedAtUnix":Date().timeIntervalSince1970,"durationSeconds":seconds,"stabilizesRoll":stabilizesRoll,"samples":rows]
        return try? JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)
    }
    func sample(time:Double,in outputFrame:GeoBounds? = nil)->Sample {
        let (a,b,fraction)=bracket(time,byTime:true),left=keys[a],right=keys[b]
        let t:Double
        if !arcLengths.isEmpty {
            let length=arcLengths[b]-arcLengths[a]
            t=segments[a].parameter(at:length*fraction,total:length)
        } else { t=fraction }
        var motion=segments[a].sample(t)
        if !arcLengths.isEmpty {
            let squared=max(0.000000000001,simd_length_squared(motion.velocity)),ratio=arcSpeed/sqrt(squared)
            motion.acceleration=(motion.acceleration-motion.velocity*(simd_dot(motion.velocity,motion.acceleration)/squared))*ratio*ratio
            motion.velocity *= ratio
        }
        var eye=SIMD3<Float>(motion.position),velocity=SIMD3<Float>(motion.velocity),acceleration=SIMD3<Float>(motion.acceleration)
        let bank:Float
        if movementAligned {
            let scale=WorldRouteTour.previewCruiseSpeed/3.6/cruiseSpeed
            bank=reduceMotion ? 0 : WorldFlightTurn.coordinatedBank(velocity:motion.velocity*scale,acceleration:motion.acceleration*scale*scale,responseAcceleration:bankResponseAcceleration,stabilized:stabilizesRoll)
        } else { bank=Float(left.bank+(right.bank-left.bank)*Double(t)) }
        let cameraPoint=frame.point(u:Double(eye.x)/frame.widthMeters+0.5,v:Double(eye.z)/frame.depthMeters+0.5)
        let routeDistance=left.route+(right.route-left.route)*Double(t)
        let focus=cameraPoint
        if let outputFrame,outputFrame != frame {
            func convert(_ p:SIMD3<Float>)->SIMD3<Float> {
                let geo=frame.point(u:Double(p.x)/frame.widthMeters+0.5,v:Double(p.z)/frame.depthMeters+0.5),uv=outputFrame.uv(geo)
                return SIMD3(Float((uv.u-0.5)*outputFrame.widthMeters),p.y,Float((uv.v-0.5)*outputFrame.depthMeters))
            }
            let next=convert(eye+velocity),nextAcceleration=convert(eye+acceleration);eye=convert(eye);velocity=next-eye;acceleration=nextAcceleration-eye
        }
        let direction=simd_length_squared(velocity)>0.00001 ? simd_normalize(velocity) : SIMD3<Float>(0,0,-1)
        var routeTarget:SIMD3<Float>?=lookSegments.isEmpty ? nil : SIMD3<Float>(lookSegments[a].sample(Double(t)).position)
        if let outputFrame,outputFrame != frame,let target=routeTarget {
            let geo=frame.point(u:Double(target.x)/frame.widthMeters+0.5,v:Double(target.z)/frame.depthMeters+0.5),uv=outputFrame.uv(geo)
            routeTarget=SIMD3(Float((uv.u-0.5)*outputFrame.widthMeters),target.y,Float((uv.v-0.5)*outputFrame.depthMeters))
        }
        if var target=routeTarget {
            let v=SIMD2(velocity.x,velocity.z),forward=simd_length_squared(v)>0.001 ? simd_normalize(v) : SIMD2<Float>(0,-1)
            let delta=SIMD2(target.x-eye.x,target.z-eye.z),shift=max(0,60-simd_dot(delta,forward))
            target.x+=forward.x*shift;target.z+=forward.y*shift;routeTarget=target
        }
        let ground=left.ground+(right.ground-left.ground)*Double(t)
        return Sample(pose:.init(eye:eye,look:routeTarget ?? eye+direction*80,focus:focus,bank:bank),routeDistance:routeDistance,
                      speed:Double(simd_length(velocity)),velocity:velocity,heightAboveGround:Double(eye.y)-ground,cameraPoint:cameraPoint,routeTarget:routeTarget,fieldOfView:left.fieldOfView+(right.fieldOfView-left.fieldOfView)*Double(t),acceleration:acceleration,movementAligned:movementAligned,bankResponseAcceleration:bankResponseAcceleration,stabilizesRoll:stabilizesRoll)
    }
}
