import Foundation

/// Treat coordinated travel as angle adjustment, tolerating uneven finger
/// arrival. Pinches and twists need deliberate relative movement.
enum WorldGestureIntent {
    case undecided, angle, transform

    static func resolve(startA: CGPoint, startB: CGPoint, a: CGPoint, b: CGPoint) -> Self {
        let start = CGPoint(x:startB.x-startA.x,y:startB.y-startA.y)
        let current = CGPoint(x:b.x-a.x,y:b.y-a.y)
        let length = max(20,hypot(start.x,start.y))
        let spanChange = abs(hypot(current.x,current.y)-length)
        let angle = atan2(current.y,current.x)-atan2(start.y,start.x)
        let rotation = abs(atan2(sin(angle),cos(angle)))
        let da=CGPoint(x:a.x-startA.x,y:a.y-startA.y),db=CGPoint(x:b.x-startB.x,y:b.y-startB.y)
        let la=hypot(da.x,da.y),lb=hypot(db.x,db.y)
        let bothMoved=la>3 && lb>3
        let parallel=bothMoved && da.x*db.x+da.y*db.y>0.7*la*lb
        let travel=hypot((da.x+db.x)/2,(da.y+db.y)/2)
        let twistTravel=rotation*length/2
        // A leading finger creates apparent rotation, especially with a narrow
        // grip. Coherent dragging gets priority over small spacing changes.
        if parallel && travel>4 && spanChange<=max(12,length*0.06) && twistTravel<10 { return .angle }
        if spanChange>max(12,length*0.06) && (bothMoved || spanChange>max(24,length*0.12)) { return .transform }
        if rotation>0.075 && twistTravel>10 && (bothMoved || twistTravel>20) { return .transform }
        return .undecided
    }
}

/// Pure touch-sequence state shared by UIKit and the regression tests. Finger
/// identity/count changes always establish a fresh baseline, never a delta.
struct WorldGestureMotion {
    struct Finger: Equatable {
        let id: Int
        var point: CGPoint
    }
    enum Step: Equatable {
        case none, rebase
        case pan(CGPoint,CGPoint)
        case zoom(CGPoint,CGPoint,Double,Double)
        case angle(Double,Double)
    }
    private var previous: [Finger] = []
    private var start: [Finger] = []
    private var moving = false
    private(set) var intent = WorldGestureIntent.undecided
    var rotateWithOneFinger = false

    private func angleStep(_ delta: CGPoint) -> Step {
        // Suppress small cross-axis jitter, but let direction change naturally
        // during the same drag instead of locking it at first recognition.
        let dx=abs(delta.x) < abs(delta.y)*0.4 ? 0 : delta.x
        let dy=abs(delta.y) < abs(delta.x)*0.4 ? 0 : delta.y
        return .angle(dx,dy)
    }
    private static func midpoint(_ p: [Finger]) -> CGPoint {
        CGPoint(x:(p[0].point.x+p[1].point.x)/2,y:(p[0].point.y+p[1].point.y)/2)
    }
    private static func span(_ p: [Finger]) -> Double {
        max(20,hypot(p[0].point.x-p[1].point.x,p[0].point.y-p[1].point.y))
    }
    mutating func update(_ fingers: [Finger]) -> Step {
        let p=fingers.sorted { $0.id<$1.id }
        defer { previous=p }
        guard p.map(\.id)==previous.map(\.id) else {
            start=p;moving=false;intent = .undecided
            return .rebase
        }
        guard (1...2).contains(p.count) else { return .none }
        if p.count==1 {
            if !moving {
                guard hypot(p[0].point.x-start[0].point.x,p[0].point.y-start[0].point.y)>3 else { return .none }
                moving=true
                // Consume the recognition threshold instead of jumping by it.
                return .rebase
            }
            if rotateWithOneFinger {
                return angleStep(CGPoint(x:p[0].point.x-previous[0].point.x,y:p[0].point.y-previous[0].point.y))
            }
            return .pan(previous[0].point,p[0].point)
        }
        if intent == .undecided {
            intent=WorldGestureIntent.resolve(startA:start[0].point,startB:start[1].point,a:p[0].point,b:p[1].point)
            guard intent != .undecided else { return .none }
            start=p;moving=true
            return .rebase
        }
        if intent == .angle {
            // A pinch can start after the fingers initially travel together.
            // Rebase at that point rather than replaying the accumulated scale.
            let startAngle=atan2(start[1].point.y-start[0].point.y,start[1].point.x-start[0].point.x)
            let nowAngle=atan2(p[1].point.y-p[0].point.y,p[1].point.x-p[0].point.x)
            let twist=abs(atan2(sin(nowAngle-startAngle),cos(nowAngle-startAngle)))
            let length=Self.span(start)
            if abs(Self.span(p)-length)>max(16,length*0.12) || (twist>0.12 && twist*length/2>12) {
                intent = .transform;start=p;return .rebase
            }
            let a=Self.midpoint(previous),b=Self.midpoint(p)
            if rotateWithOneFinger { return .pan(a,b) }
            return angleStep(CGPoint(x:b.x-a.x,y:b.y-a.y))
        }
        // Zoom must not own the rest of the touch sequence. Once relative
        // movement settles, a clear coordinated drag can adjust the angle.
        // The larger travel threshold avoids hopping modes during a pinch.
        let next=WorldGestureIntent.resolve(startA:start[0].point,startB:start[1].point,a:p[0].point,b:p[1].point)
        if next == .angle {
            let a=Self.midpoint(start),b=Self.midpoint(p)
            if hypot(b.x-a.x,b.y-a.y)>8 {
                intent = .angle;start=p;return .rebase
            }
        } else if next == .transform { start=p }
        let before=atan2(previous[1].point.y-previous[0].point.y,previous[1].point.x-previous[0].point.x)
        let after=atan2(p[1].point.y-p[0].point.y,p[1].point.x-p[0].point.x)
        let rotation=atan2(sin(after-before),cos(after-before))
        return .zoom(Self.midpoint(previous),Self.midpoint(p),Self.span(p)/Self.span(previous),rotation)
    }
    var recognized: Bool { moving }
}
