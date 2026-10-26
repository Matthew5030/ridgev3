import Foundation
import simd

/// A separate, metre-based camera rail. Route progress remains attached to the
/// original line, while preplanned turns remain anchored to that journey.
struct WorldFlightCorridor {
    static let droneBankLimit=82 * Double.pi/180
    static let droneAngularLimit=3.0
    static let droneRollLimit=3.0
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
        if drone {
            knots=Self.anchoredDroneRail(positions:positions,distances:path.distances,indices:indices)
            return
        }
        // Retain the older gliding recipe for its separate regression fixtures.
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
        if elongatedReturn && (tolerance<100 || routeCentred) {
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
                // Anticipate the angle across both neighbouring legs. Sharper
                // bends start earlier; adjoining bends share the fairing below.
                let anticipation=tolerance < 100 ? tolerance*1.8 : (dot < -0.65 ? 320 : 240)
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
        let raw=result,total=raw.last!.flight,count=max(2,Int(ceil(total/2)))
        var uniform:[Knot]=[],cursor=0
        for i in 0...count {
            let distance=total*Double(i)/Double(count)
            while cursor+1<raw.count-1 && raw[cursor+1].flight<distance { cursor+=1 }
            let a=raw[cursor],b=raw[cursor+1],t=(distance-a.flight)/max(0.00001,b.flight-a.flight)
            uniform.append(Knot(position:a.position+(b.position-a.position)*t,route:a.route+(b.route-a.route)*t,flight:distance))
        }
        let smoothing=tolerance>100 ? min(60,tolerance*0.2) : min(15,tolerance*0.5)
        let radius=max(1,Int(min(smoothing,total/30)/(total/Double(count))))
        var fitted=uniform.map(\.position)
        for _ in 0..<4 {
            var extended:[SIMD2<Double>]=[]
            let first=fitted[0],last=fitted.last!,start=fitted[1]-first,end=last-fitted[fitted.count-2]
            for i in -radius..<(fitted.count+radius) {
                extended.append(i<0 ? first+start*Double(i) : i>=fitted.count ? last+end*Double(i-fitted.count+1) : fitted[i])
            }
            var prefix=[SIMD2<Double>.zero]
            for p in extended { prefix.append(prefix.last!+p) }
            fitted=fitted.indices.map { (prefix[$0+radius*2+1]-prefix[$0])/Double(radius*2+1) }
        }
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
            result[i].speed=tolerance<100 ? 1-0.60*min(1,curvature*35) : 1-0.18*min(1,curvature*180)
        }
        knots=result
    }

    /// Route-anchored, curvature-continuous turns joined by bounded Bezier
    /// transfers. No heading integration, attraction spring or endpoint pull.
    private static func anchoredDroneRail(positions original:[SIMD2<Double>],distances:[Double],indices:[Int])->[Knot] {
        typealias Point=SIMD2<Double>
        struct Turn {
            var points:[Point];var directions:[Point]
            var entryRoute:Double;var cornerRoute:Double;var exitRoute:Double
            var demand:Double
            var entry:Point { points[0] };var exit:Point { points.last! }
            var incoming:Point { directions[0] };var outgoing:Point { directions.last! }
        }
        let minimumLeg=min(300,distances.last!*0.04)
        // Additional candidate gates lie on the simplified route, so their
        // positions cannot reintroduce the GPS noise already discarded above.
        var positions=original
        for j in 1..<indices.count {
            let a=indices[j-1],b=indices[j],span=max(0.000001,distances[b]-distances[a])
            for i in a...b { positions[i]=original[a]+(original[b]-original[a])*((distances[i]-distances[a])/span) }
        }
        var mandatory=Set<Int>()
        if indices.count>2 { for j in 1..<(indices.count-1) {
            let a=original[indices[j]]-original[indices[j-1]],b=original[indices[j+1]]-original[indices[j]]
            if min(simd_length(a),simd_length(b))>max(80,minimumLeg*0.5),simd_dot(simd_normalize(a),simd_normalize(b))<cos(150 * .pi/180) {
                mandatory.insert(indices[j])
            }
        } }
        var pool=Set(indices),next=100.0
        for i in distances.indices where distances[i]>=next { pool.insert(i);next=distances[i]+100 }
        let options=pool.sorted()
        var scores=Array(repeating:Double.infinity,count:options.count),links=Array(repeating:0,count:options.count)
        scores[0]=0
        // Choose anchors across the complete journey. Greedy deletion can
        // strand two corners almost on top of one another after a long loop.
        // Every accepted shortcut stays in the tube and retains big reversals.
        for j in 1..<options.count {
            let end=options[j]
            for i in stride(from:j-1,through:0,by:-1) {
                let start=options[i],gap=distances[end]-distances[start]
                if gap>2500 && i<j-1 { break }
                guard scores[i].isFinite else { continue }
                if mandatory.contains(where:{ $0>start && $0<end }) { continue }
                let a=positions[start],delta=positions[end]-a,length=simd_length(delta)
                guard length>0.000001 else { continue }
                var valid=true,furthest=0.0
                for k in start...end {
                    let projection=simd_dot(original[k]-a,delta)/length
                    let t=min(1,max(0,projection/length))
                    if simd_distance(original[k],a+delta*t)>160 || projection<furthest-160 { valid=false;break }
                    furthest=max(furthest,projection)
                }
                guard valid else { continue }
                let score=scores[i]+1+pow(minimumLeg/length,4)+max(0,gap/length-1)*0.5
                if score<scores[j] { scores[j]=score;links[j]=i }
            }
        }
        var anchors:[Int]=[],cursor=options.count-1
        while cursor>0 { anchors.append(options[cursor]);cursor=links[cursor] }
        anchors.append(options[0]);anchors.reverse()
        func unitTurn(_ angle:Double)->([Point],[Point]) {
            let count=512
            var points=[Point.zero],directions=[Point(1,0)]
            for i in 1...count {
                let u=(Double(i)-0.5)/Double(count)
                let heading=angle*(u-sin(2 * .pi*u)/(2 * .pi))
                points.append(points.last!+Point(cos(heading),sin(heading))/Double(count))
                let t=Double(i)/Double(count),end=angle*(t-sin(2 * .pi*t)/(2 * .pi))
                directions.append(Point(cos(end),sin(end)))
            }
            return (points,directions)
        }
        func rotate(_ p:Point,_ forward:Point)->Point { forward*p.x+Point(-forward.y,forward.x)*p.y }
        func demand(_ curvature:Double,_ change:Double)->Double {
            let speed=600/3.6
            return max(abs(curvature)*speed/Self.droneAngularLimit,
                sqrt(abs(curvature)*speed*speed/(64*tan(Self.droneBankLimit))),
                cbrt(abs(change)*pow(speed,3)/(64*Self.droneRollLimit)))
        }
        var candidates:[[Turn]]=[]
        if anchors.count>2 { for j in 1..<(anchors.count-1) {
            let i=anchors[j],corner=positions[i]
            let left=corner-positions[anchors[j-1]],right=positions[anchors[j+1]]-corner
            let before=simd_length(left),after=simd_length(right),a=left/before,b=right/after
            let angle=acos(min(1,max(-1,simd_dot(a,b)))),cross=a.x*b.y-a.y*b.x
            guard angle>0.00001 else { continue }
            let turnaround=angle>150 * .pi/180
            let forward=turnaround ? simd_normalize(a-b) : a
            let angles=turnaround ? [Double.pi,-Double.pi] : [cross>=0 ? angle : -angle]
            var choices:[Turn]=[]
            for signed in angles { for allocation in [0.25,0.35,0.45] {
                let (unit,directions)=unitTurn(signed),middle=unit.count/2
                let preferred=turnaround ? 2 * Double.pi*80 : max(220,400*sqrt(abs(signed)),220*abs(signed))
                let length:Double,entry:Point,exit:Point,entrySetback:Double,exitSetback:Double
                if turnaround {
                    let inUnit=rotate(unit[middle],forward),outUnit=rotate(unit.last!-unit[middle],forward)
                    length=min(preferred,allocation*before/max(0.0001,simd_dot(inUnit,a)),allocation*after/max(0.0001,simd_dot(outUnit,b)))
                    entry=corner-inUnit*length;exit=corner+outUnit*length
                    entrySetback=simd_dot(corner-entry,a);exitSetback=simd_dot(exit-corner,b)
                } else {
                    let chord=simd_length(unit.last!),conversion=2*cos(angle/2)/chord
                    let setback=min(preferred/conversion,allocation*before,allocation*after)
                    length=setback*conversion;entry=corner-a*setback;exit=corner+b*setback
                    entrySetback=setback;exitSetback=setback
                }
                var points=unit.map { entry+rotate($0,forward)*length }
                points[points.count-1]=exit
                let start=distances[i]-entrySetback/before*(distances[i]-distances[anchors[j-1]])
                let end=distances[i]+exitSetback/after*(distances[anchors[j+1]]-distances[i])
                choices.append(Turn(points:points,directions:directions.map { rotate($0,forward) },entryRoute:start,cornerRoute:distances[i],exitRoute:end,
                    demand:demand(2*abs(signed)/length,2 * .pi*abs(signed)/(length*length))))
            } }
            candidates.append(choices)
        } }
        let start=positions[anchors[0]],finish=positions[anchors.last!]
        let initial=simd_normalize(positions[anchors[1]]-start),final=simd_normalize(finish-positions[anchors[anchors.count-2]])
        func bezier(_ controls:[Point],_ t:Double)->Point {
            var values=controls
            for n in stride(from:values.count-1,through:1,by:-1) { for i in 0..<n { values[i]=values[i]*(1-t)+values[i+1]*t } }
            return values[0]
        }
        func controls(_ from:Point,_ heading:Point,_ to:Point,_ endHeading:Point)->[Point] {
            let h=simd_distance(from,to)/7
            return [from,from+heading*h,from+heading*(h*2),from+heading*(h*3),to-endHeading*(h*3),to-endHeading*(h*2),to-endHeading*h,to]
        }
        func transferCost(_ a:Point,_ da:Point,_ b:Point,_ db:Point)->Double {
            let delta=b-a,length=max(0.000001,simd_length(delta)),direction=delta/length
            let p=simd_dot(direction,da),q=simd_dot(direction,db)
            guard p>0 && q>0 else { return 1e12 }
            let points=controls(a,da,b,db)
            let first=(1..<points.count).map { (points[$0]-points[$0-1])*7 }
            let second=(1..<first.count).map { (first[$0]-first[$0-1])*6 }
            let third=(1..<second.count).map { (second[$0]-second[$0-1])*5 }
            var worst=0.0
            for i in 0...32 {
                let t=Double(i)/32,v=bezier(first,t),acceleration=bezier(second,t),jerk=bezier(third,t)
                let squared=max(0.00000001,simd_length_squared(v)),cross=v.x*acceleration.y-v.y*acceleration.x
                let curvature=cross/pow(squared,1.5)
                let change=(v.x*jerk.y-v.y*jerk.x)/(squared*squared)-3*cross*simd_dot(v,acceleration)/pow(squared,3)
                worst=max(worst,demand(curvature,change))
            }
            return worst+(2-p-q)*0.000001
        }
        // Choose turnaround sides for the complete route, minimizing lateral
        // transfers between turns instead of flipping sides at each return.
        var costs:[[Double]]=[],parents:[[Int]]=[]
        for i in candidates.indices {
            var row:[Double]=[],links:[Int]=[]
            for turn in candidates[i] {
                if i==0 { row.append(max(turn.demand,transferCost(start,initial,turn.entry,turn.incoming)));links.append(0) }
                else {
                    var best=Double.infinity,parent=0
                    for k in candidates[i-1].indices {
                        let previous=candidates[i-1][k]
                        let value=max(costs[i-1][k],turn.demand,transferCost(previous.exit,previous.outgoing,turn.entry,turn.incoming))
                        if value<best { best=value;parent=k }
                    }
                    row.append(best);links.append(parent)
                }
            }
            costs.append(row);parents.append(links)
        }
        var selected=Array(repeating:0,count:candidates.count)
        if let last=candidates.indices.last {
            selected[last]=candidates[last].indices.min { x,y in
                let a=candidates[last][x],b=candidates[last][y]
                return max(costs[last][x],transferCost(a.exit,a.outgoing,finish,final))<max(costs[last][y],transferCost(b.exit,b.outgoing,finish,final))
            }!
            if last>0 { for i in stride(from:last,through:1,by:-1) { selected[i-1]=parents[i][selected[i]] } }
        }
        var result:[Knot]=[]
        func append(_ p:Point,_ route:Double,_ direction:Point) {
            let step=result.last.map { simd_distance($0.position,p) } ?? 0
            if !result.isEmpty && step<0.0000001 { return }
            result.append(Knot(position:p,route:route,flight:(result.last?.flight ?? 0)+step,tangent:direction,speed:1))
        }
        func transfer(_ from:Point,_ heading:Point,_ to:Point,_ endHeading:Point,_ startRoute:Double,_ endRoute:Double) {
            let length=simd_distance(from,to)
            guard length>0.0000001 else { return }
            let controls=controls(from,heading,to,endHeading)
            let derivatives=(1..<controls.count).map { (controls[$0]-controls[$0-1])*7 }
            let count=max(32,Int(ceil(length/1.5)))
            var points=[from],directions=[heading],arc=[0.0]
            for i in 1...count {
                let t=Double(i)/Double(count),p=bezier(controls,t),v=bezier(derivatives,t)
                arc.append(arc.last!+simd_distance(points.last!,p));points.append(p);directions.append(simd_normalize(v))
            }
            for i in 1...count { append(points[i],startRoute+(endRoute-startRoute)*arc[i]/max(0.000000001,arc.last!),directions[i]) }
        }
        append(start,0,initial)
        var previous=start,heading=initial,route=0.0
        for i in candidates.indices {
            let turn=candidates[i][selected[i]]
            transfer(previous,heading,turn.entry,turn.incoming,route,turn.entryRoute)
            let middle=turn.points.count/2
            for j in 1..<turn.points.count {
                let progress=j<=middle ? turn.entryRoute+(turn.cornerRoute-turn.entryRoute)*Double(j)/Double(middle)
                    : turn.cornerRoute+(turn.exitRoute-turn.cornerRoute)*Double(j-middle)/Double(turn.points.count-1-middle)
                append(turn.points[j],progress,turn.directions[j])
            }
            previous=turn.exit;heading=turn.outgoing;route=turn.exitRoute
        }
        transfer(previous,heading,finish,final,route,distances.last!)
        return result
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
