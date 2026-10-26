import Foundation
import simd

/// A separate, metre-based camera rail. Route progress remains attached to the
/// original line, while flight can cut a bend or overshoot a tight turnaround.
struct WorldFlightCorridor {
    enum Style { case gliding,drone }
    let style:Style
    struct Sample {
        var point: GeoPoint
        var direction: SIMD2<Double>
        var routeDistance: Double
        var overview: Double
    }
    private struct Knot {
        var position: SIMD2<Double>;var route: Double;var flight: Double
        var tangent:SIMD2<Double> = .zero
        var speed:Double=336
        var overview:Double=0
    }
    private let origin: GeoPoint
    private let longitudeScale: Double
    private var knots: [Knot] = []
    var length: Double { knots.last?.flight ?? 0 }
    var routeLength: Double { knots.last?.route ?? 0 }

    init(path: WorldRouteTourPath, tolerance:Double=100,routeCentred:Bool=false,style:Style = .gliding) {
        self.style=style
        let drone=style == .drone
        let tolerance=drone ? 40 : max(5,min(500,tolerance))
        origin=path.points[0].coordinate
        longitudeScale=max(0.01,cos(origin.latitude * .pi/180))
        let origin=self.origin,scale=longitudeScale
        func local(_ p: GeoPoint)->SIMD2<Double> {
            SIMD2((p.longitude-origin.longitude)*111_195*scale,(origin.latitude-p.latitude)*111_195)
        }
        // Remove metre-scale digitising noise before building corner arcs.
        // Iterative subdivision avoids recursion on large imported tracks.
        let positions=path.points.map { local($0.coordinate) }
        var keep:Set<Int>=[0,positions.count-1],pending=[(0,positions.count-1)]
        if simd_distance(positions[0],positions.last!)<1,
           let peak=positions.indices.max(by:{simd_length_squared(positions[$0])<simd_length_squared(positions[$1])}),peak>0,peak<positions.count-1 {
            keep.insert(peak);pending=[(0,peak),(peak,positions.count-1)]
        }
        while let (a,b)=pending.popLast() {
            guard b>a+1 else { continue }
            let delta=positions[b]-positions[a],square=simd_length_squared(delta)
            // Fit the journey, not every footpath bend. A kink inside this
            // horizontal tube disappears completely from the camera rail.
            var error=tolerance*tolerance,index=a
            var furthestProjection=0.0,furthestIndex=a
            for i in (a+1)..<b {
                let t=square>0 ? min(1,max(0,simd_dot(positions[i]-positions[a],delta)/square)) : 0
                let value=simd_length_squared(positions[i]-(positions[a]+delta*t))
                if value>error { error=value;index=i }
                if square>1 {
                    let projection=simd_dot(positions[i]-positions[a],delta)/sqrt(square)
                    // Distance-only simplification loses an entire switchback
                    // when its legs overlap. Preserve substantial reversals.
                    if projection<furthestProjection-max(25,tolerance),furthestIndex>a { index=furthestIndex;break }
                    if projection>furthestProjection { furthestProjection=projection;furthestIndex=i }
                }
            }
            if index != a { keep.insert(index);pending.append((a,index));pending.append((index,b)) }
        }
        let indices=keep.sorted()
        var result:[Knot]=[],bends:[Double]=[]
        func append(_ p: SIMD2<Double>,_ route: Double) {
            let step=result.last.map { simd_distance($0.position,p) } ?? 0
            guard result.isEmpty || step>0.00001 else { return }
            result.append(Knot(position:p,route:route,flight:(result.last?.flight ?? 0)+step))
        }
        func line(_ p: SIMD2<Double>,_ route: Double) {
            guard let last=result.last else { append(p,route);return }
            let count=max(1,Int(ceil(simd_distance(last.position,p)/3)))
            for i in 1...count { let t=Double(i)/Double(count);append(last.position+(p-last.position)*t,last.route+(route-last.route)*t) }
        }
        func curve(_ a: SIMD2<Double>,_ b: SIMD2<Double>,_ c: SIMD2<Double>,_ d: SIMD2<Double>,_ start:Double,_ end:Double) {
            let count=max(16,Int(ceil((simd_distance(a,b)+simd_distance(b,c)+simd_distance(c,d))/2)))
            var samples:[SIMD2<Double>]=[a],arc=[0.0]
            for i in 1...count {
                let t=Double(i)/Double(count),u=1-t
                let p=a*(u*u*u)+b*(3*u*u*t)+c*(3*u*t*t)+d*(t*t*t)
                arc.append(arc.last!+simd_distance(samples.last!,p));samples.append(p)
            }
            for i in 1...count { append(samples[i],start+(end-start)*arc[i]/max(0.001,arc.last!)) }
        }
        append(positions[0],0)
        let end=positions.last!,farthest=positions.max(by:{simd_length_squared($0)<simd_length_squared($1)})!,reach=simd_length(farthest)
        let axis=reach>0 ? farthest/reach : SIMD2<Double>(0,-1)
        let peak=positions.firstIndex(of:farthest)!
        var oneReturn=true,extreme=0.0
        for i in positions.indices {
            let along=simd_dot(positions[i],axis)
            if i<=peak {
                if along<extreme-25 { oneReturn=false }
                extreme=max(extreme,along)
            } else {
                if i==peak+1 { extreme=reach }
                if along>extreme+25 { oneReturn=false }
                extreme=min(extreme,along)
            }
        }
        // Several overlapping hiking switchbacks in one narrow footprint are
        // one survey sweep, not a sequence of airplane turnarounds. Retain the
        // original ordered route separately; only its camera rail is condensed.
        let narrowBundle = !drone && tolerance>100 && reach>50 && positions.allSatisfy { abs($0.x*axis.y-$0.y*axis.x)<min(tolerance*0.6,reach*0.3) }
        let elongatedReturn=(oneReturn || narrowBundle) && simd_length(end)<min(30,reach*0.2) && reach>0.5 && positions.allSatisfy { abs($0.x*axis.y-$0.y*axis.x)<min(80,max(3,tolerance*0.75)) }
        if elongatedReturn && drone {
            // A direct outbound line, one local hairpin, then a direct exit.
            // No oval or sideways sweep along the full length of the route.
            let side=SIMD2(-axis.y,axis.x),r=min(180,reach*0.2),run=reach-r
            let peakRoute=path.distances[peak]
            line(axis*run-side*r,peakRoute*run/reach)
            let count=max(24,Int(ceil(.pi*r)))
            for i in 1...count {
                let angle=Double(i)/Double(count)*Double.pi,along=run+r*sin(angle)
                let p=axis*along-side*(r*cos(angle))
                let route=angle<=Double.pi/2 ? peakRoute*along/reach : peakRoute+(1-along/reach)*(path.length-peakRoute)
                append(p,route)
            }
            line(end,path.length)
        } else if elongatedReturn && (tolerance<100 || routeCentred) {
            // Follow both legs, with a small racetrack turnaround. An oval of
            // the entire journey starts sideways and desynchronizes progress.
            let side=SIMD2(-axis.y,axis.x),r=min(routeCentred ? 60 : tolerance,max(1,reach*0.2)),run=reach-r
            let entry=axis*run-side*r,exit=axis*run+side*r,peakRoute=path.distances[peak]
            curve(.zero,axis*(run/3),axis*(run*2/3)-side*r,entry,0,peakRoute*run/reach)
            let count=max(32,Int(ceil(.pi*r)))
            for i in 1...count {
                let angle=Double(i)/Double(count)*Double.pi,along=run+r*sin(angle)
                let p=axis*along-side*(r*cos(angle))
                let route=angle<=Double.pi/2 ? peakRoute*along/reach : peakRoute+(1-along/reach)*(path.length-peakRoute)
                append(p,route)
            }
            curve(exit,exit-axis*(run/3),end+axis*(run/3),end,peakRoute+(1-run/reach)*(path.length-peakRoute),path.length)
        } else if elongatedReturn {
            // A narrow out-and-back is one oval flight, rather than a left /
            // right teardrop forced to reverse at the same route coordinate.
            let side=SIMD2(-axis.y,axis.x)
            let width=tolerance>100 ? max(tolerance,min(600,sqrt(reach*0.5*150))) : min(tolerance,max(2,reach*0.35))
            let count=max(128,Int(ceil((reach*2+width*4)/3)))
            for i in 1...count {
                let t=Double(i)/Double(count),angle=t*2*Double.pi
                let p=end*t+axis*(reach*0.5*(1-cos(angle)))+side*(width*sin(angle))
                let along=0.5*(1-cos(angle)),peakRoute=path.distances[peak]
                append(p,oneReturn ? (t<=0.5 ? peakRoute*along : peakRoute+(1-along)*(path.length-peakRoute)) : path.length*t)
            }
        } else if indices.count>2 {
            for j in 1..<(indices.count-1) {
                let index=indices[j],corner=positions[index]
                let incoming=corner-positions[indices[j-1]],outgoing=positions[indices[j+1]]-corner
                let before=simd_length(incoming),after=simd_length(outgoing)
                guard before>0.01,after>0.01 else { continue }
                let a=incoming/before,b=outgoing/after,dot=simd_dot(a,b)
                if dot<0.94 { bends.append(path.distances[index]) }
                if drone && dot < -0.65 {
                    let axis=simd_normalize(a-b),cross=a.x*b.y-a.y*b.x
                    let side=SIMD2(-axis.y,axis.x)*(cross < -0.0001 ? -1.0 : 1.0)
                    let r=min(180,min(before,after)*0.4),center=corner-axis*r
                    let start=path.distances[index]-r*(path.distances[index]-path.distances[indices[j-1]])/before
                    let end=path.distances[index]+r*(path.distances[indices[j+1]]-path.distances[index])/after
                    line(center-side*r,start)
                    let count=max(24,Int(ceil(.pi*r)))
                    for i in 1...count {
                        let t=Double(i)/Double(count),angle=t*Double.pi
                        let p=center-side*(r*cos(angle))+axis*(r*sin(angle))
                        let route=t<=0.5 ? start+(path.distances[index]-start)*t*2 : path.distances[index]+(end-path.distances[index])*(t*2-1)
                        append(p,route)
                    }
                    continue
                }
                // Anticipate the angle across both neighbouring legs. Sharper
                // bends start earlier; adjoining bends share the fairing below.
                let anticipation=drone ? max(80,240*sqrt(max(0,(1-dot)/2))) : (tolerance < 100 ? tolerance*1.8 : (dot < -0.65 ? 320 : 240))
                let radius=min(anticipation,min(before,after)*0.44)
                let start=path.distances[index]-radius*(path.distances[index]-path.distances[indices[j-1]])/before
                let end=path.distances[index]+radius*(path.distances[indices[j+1]]-path.distances[index])/after
                let entry=corner-a*radius,exit=corner+b*radius
                line(entry,start)
                if dot < -0.65 {
                    // Carry on past the corner, then turn in a broad teardrop.
                    // Even an exact out-and-back gets a stable, nonzero tangent.
                    let axis=simd_normalize(a-b),cross=a.x*b.y-a.y*b.x
                    let side=SIMD2(-axis.y,axis.x)*(cross < -0.0001 ? -1.0 : 1.0)
                    let sweep=max(tolerance < 100 ? tolerance*2 : 150,radius)
                    let apex=corner+axis*sweep*0.45
                    curve(entry,entry+a*radius*0.5,apex-side*sweep*0.9,apex,start,(start+end)/2)
                    curve(apex,apex+side*sweep*0.9,exit-b*radius*0.5,exit,(start+end)/2,end)
                } else {
                    let handle=radius*0.66
                    curve(entry,entry+a*handle,exit-b*handle,exit,start,end)
                }
            }
        }
        if !elongatedReturn { line(positions.last!,path.length) }
        // Fit the position itself across each straight/arc join. Four symmetric
        // box filters give a broad, smooth kernel without adding independent
        // heading or bank lag. Linear endpoint extension retains forward speed.
        let raw=result,total=raw.last!.flight,count=max(drone ? 32 : 2,Int(ceil(total/2)))
        var uniform:[Knot]=[],cursor=0
        for i in 0...count {
            let distance=total*Double(i)/Double(count)
            while cursor+1<raw.count-1 && raw[cursor+1].flight<distance { cursor+=1 }
            let a=raw[cursor],b=raw[cursor+1],t=(distance-a.flight)/max(0.00001,b.flight-a.flight)
            uniform.append(Knot(position:a.position+(b.position-a.position)*t,route:a.route+(b.route-a.route)*t,flight:distance))
        }
        let smoothing=drone ? 60 : (tolerance>100 ? min(60,tolerance*0.2) : min(15,tolerance*0.5))
        let radius=max(1,Int(min(smoothing,total/30)/(total/Double(count))))
        var fitted=uniform.map(\.position)
        if drone {
            var attraction=fitted
            for _ in 0..<4 {
                var extended:[SIMD2<Double>]=[]
                let first=attraction[0],last=attraction.last!,start=attraction[1]-first,end=last-attraction[attraction.count-2]
                for i in -radius..<(attraction.count+radius) {
                    extended.append(i<0 ? first+start*Double(i) : i>=attraction.count ? last+end*Double(i-attraction.count+1) : attraction[i])
                }
                var prefix=[SIMD2<Double>.zero]
                for p in extended { prefix.append(prefix.last!+p) }
                attraction=attraction.indices.map { (prefix[$0+radius*2+1]-prefix[$0])/Double(radius*2+1) }
            }
            // Averaging positions can collapse a close return into a cusp:
            // its tangent nearly vanishes and the pace solver sees an almost
            // instantaneous reversal. Fair the course, then integrate unit
            // forward steps so the prepared rail cannot stall at that join.
            var headings:[Double]=[]
            for i in uniform.indices {
                let a=max(0,i-1),b=min(count,i+1),delta=uniform[b].position-uniform[a].position
                let angle=atan2(delta.y,delta.x)
                headings.append(headings.last.map { $0+atan2(sin(angle-$0),cos(angle-$0)) } ?? angle)
            }
            var span=min(110,total/8)
            for _ in 0..<8 {
                let r=max(1,Int(ceil(span/(total/Double(count))))),window=Double(r*2+1)
                var angles=headings
                for _ in 0..<4 {
                    var sums=[0.0]
                    for angle in angles { sums.append(sums.last!+angle) }
                    angles=angles.indices.map { i in
                        let a=max(0,i-r),b=min(count,i+r)
                        let pad=Double(max(0,r-i))*angles[0]+Double(max(0,i+r-count))*angles[count]
                        return (sums[b+1]-sums[a]+pad)/window
                    }
                }
                var flow=[uniform[0].position],guidance=[SIMD2<Double>.zero]
                for i in 1...count {
                    let angle=(angles[i-1]+angles[i])/2,step=uniform[i].flight-uniform[i-1].flight
                    let forward=SIMD2(cos(angle),sin(angle)),expected=flow.last!+forward*step
                    let error=attraction[i]-expected,distance=simd_length(error)
                    // A bounded, gradual route attraction prevents course
                    // integration accumulating drift along a long journey.
                    // It cannot cancel the forward step or recreate a cusp.
                    let correction=distance>0.000001 ? error*(0.3*tanh(distance/150)/distance) : .zero
                    guidance.append(correction)
                    flow.append(expected+correction*step)
                }
                // Fair the attraction as well as the course. Otherwise a
                // small reference bend can still make the bank twitch even
                // though forward speed never vanishes.
                for _ in 0..<4 {
                    var sums=[SIMD2<Double>.zero]
                    for value in guidance { sums.append(sums.last!+value) }
                    guidance=guidance.indices.map { i in
                        let a=max(0,i-radius),b=min(count,i+radius)
                        let pad=Double(max(0,radius-i))*guidance[0]+Double(max(0,i+radius-count))*guidance[count]
                        return (sums[b+1]-sums[a]+pad)/Double(radius*2+1)
                    }
                }
                flow=[uniform[0].position]
                for i in 1...count {
                    let angle=(angles[i-1]+angles[i])/2,step=uniform[i].flight-uniform[i-1].flight
                    flow.append(flow.last!+(SIMD2(cos(angle),sin(angle))+guidance[i])*step)
                }
                fitted=flow
                // The linear endpoint correction below must retain a forward
                // tangent even for short, closed or overlapping journeys.
                if simd_distance(flow.last!,uniform.last!.position)<total*0.4 || span<1 { break }
                span*=0.5
            }
        } else { for _ in 0..<4 {
            var extended:[SIMD2<Double>]=[]
            let first=fitted[0],last=fitted.last!,start=fitted[1]-first,end=last-fitted[fitted.count-2]
            for i in -radius..<(fitted.count+radius) {
                extended.append(i<0 ? first+start*Double(i) : i>=fitted.count ? last+end*Double(i-fitted.count+1) : fitted[i])
            }
            var prefix=[SIMD2<Double>.zero]
            for p in extended { prefix.append(prefix.last!+p) }
            fitted=fitted.indices.map { (prefix[$0+radius*2+1]-prefix[$0])/Double(radius*2+1) }
        } }
        let startCorrection=uniform[0].position-fitted[0],endCorrection=uniform.last!.position-fitted.last!
        for i in uniform.indices {
            let t=Double(i)/Double(count)
            uniform[i].position=fitted[i]+startCorrection*(1-t)+endCorrection*t
            uniform[i].flight=i==0 ? 0 : uniform[i-1].flight+simd_distance(uniform[i-1].position,uniform[i].position)
        }
        result=uniform
        // Precompute bend speeds and braking distances once. Runtime playback
        // only interpolates; even fast flight starts a turn without a hard brake.
        var firstBend=0
        for i in result.indices {
            let a=max(0,i-1),b=min(result.count-1,i+1)
            result[i].tangent=(result[b].position-result[a].position)/max(0.00001,result[b].flight-result[a].flight)
            while firstBend<bends.count && bends[firstBend]<result[i].route-220 { firstBend+=1 }
            var density=0.0,j=firstBend
            while j<bends.count && bends[j]<result[i].route+220 {
                let t=min(1,abs(bends[j]-result[i].route)/220)
                density+=1-t*t*(3-2*t);j+=1
            }
            let actual=local(path.sample(at:result[i].route).coordinate)
            let deviation=simd_distance(actual,result[i].position)
            // A larger route deviation calls for a gentler bank, without
            // inserting the ignored route turns back into the flight.
            let busy=max(min(1,max(0,(density-1)/1.1)),min(1,max(0,(deviation-15)/100)))
            result[i].overview=busy*busy*(3-2*busy)
        }
        // Use one smooth turn estimate for both banking and corner speed.
        // Piecewise segment headings used to jump every few metres; coupled
        // lateral sway then turned those jumps into visible position jolts.
        knots=result
        for i in result.indices {
            let curvature=abs(turnCurvature(flightDistance:result[i].flight))
            // A relative pace curve keeps the speed control effective at every
            // setting. No hidden absolute corner cap can pin playback speed.
            result[i].speed=drone ? 1 : (tolerance<100 ? 1-0.60*min(1,curvature*35) : 1-0.18*min(1,curvature*180))
        }
        knots=result
    }

    private func bracket(_ value:Double,flight:Bool)->(Int,Int,Double) {
        let limit=flight ? length : routeLength
        let value=value.isFinite ? min(limit,max(0,value)) : 0
        var a=0,b=knots.count-1
        while a+1<b { let m=(a+b)/2;if (flight ? knots[m].flight : knots[m].route)<=value { a=m } else { b=m } }
        let start=flight ? knots[a].flight : knots[a].route,end=flight ? knots[b].flight : knots[b].route
        return (a,b,(value-start)/max(0.000001,end-start))
    }
    func flightDistance(at routeDistance:Double)->Double {
        let (a,b,t)=bracket(routeDistance,flight:false)
        return knots[a].flight+(knots[b].flight-knots[a].flight)*t
    }
    func advance(from routeDistance:Double,metres:Double)->Double {
        sample(flightDistance:flightDistance(at:routeDistance)+max(0,metres)).routeDistance
    }
    func speedLimit(at routeDistance:Double,requested:Double)->Double {
        let (a,b,t)=bracket(routeDistance,flight:false)
        return requested*(knots[a].speed+(knots[b].speed-knots[a].speed)*t)
    }
    func sample(routeDistance:Double)->Sample { sample(flightDistance:flightDistance(at:routeDistance)) }
    func sample(flightDistance:Double)->Sample {
        let (a,b,t)=bracket(flightDistance,flight:true)
        let left=knots[a],right=knots[b],span=right.flight-left.flight
        let m0=left.tangent*span,m1=right.tangent*span,t2=t*t,t3=t2*t
        let p=left.position*(2*t3-3*t2+1)+m0*(t3-2*t2+t)+right.position*(-2*t3+3*t2)+m1*(t3-t2)
        let delta=left.position*(6*t2-6*t)+m0*(3*t2-4*t+1)+right.position*(-6*t2+6*t)+m1*(3*t2-2*t)
        let direction=simd_length_squared(delta)>0.000001 ? simd_normalize(delta) : SIMD2(0,-1)
        return Sample(point:GeoPoint(latitude:origin.latitude-p.y/111_195,longitude:origin.longitude+p.x/(111_195*longitudeScale)),
                      direction:direction,routeDistance:left.route+(right.route-left.route)*t,
                      overview:left.overview+(right.overview-left.overview)*t)
    }
    func turnCurvature(flightDistance:Double)->Double {
        let a=sample(flightDistance:flightDistance-35).direction,b=sample(flightDistance:flightDistance+35).direction
        let span=min(length,flightDistance+35)-max(0,flightDistance-35)
        return atan2(a.x*b.y-a.y*b.x,simd_dot(a,b))/max(1,span)
    }
}
