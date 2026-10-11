import Foundation

/// Decide from both fingers, rather than interpreting the first moving finger
/// as a tilt. Once chosen, the mode is stable until a clear pinch takes over.
enum WorldGestureIntent {
    case undecided, angle, transform

    static func resolve(startA: CGPoint, startB: CGPoint, a: CGPoint, b: CGPoint) -> Self {
        let start = CGPoint(x:startB.x-startA.x,y:startB.y-startA.y)
        let current = CGPoint(x:b.x-a.x,y:b.y-a.y)
        let length = max(20,hypot(start.x,start.y))
        let spanChange = abs(hypot(current.x,current.y)-length)
        let angle = atan2(current.y,current.x)-atan2(start.y,start.x)
        let rotation = abs(atan2(sin(angle),cos(angle)))
        if spanChange > max(6,length*0.035) || rotation > 0.055 { return .transform }
        let da=CGPoint(x:a.x-startA.x,y:a.y-startA.y),db=CGPoint(x:b.x-startB.x,y:b.y-startB.y)
        let la=hypot(da.x,da.y),lb=hypot(db.x,db.y)
        let parallel=la>4 && lb>4 && da.x*db.x+da.y*db.y>0.7*la*lb
        if parallel && hypot((da.x+db.x)/2,(da.y+db.y)/2)>8 { return .angle }
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
        case zoom(CGPoint,CGPoint,Double)
        case angle(Double,Double)
    }
    private var previous: [Finger] = []
    private var start: [Finger] = []
    private var moving = false
    private(set) var intent = WorldGestureIntent.undecided
    private var horizontal = false
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
            return .pan(previous[0].point,p[0].point)
        }
        if intent == .undecided {
            intent=WorldGestureIntent.resolve(startA:start[0].point,startB:start[1].point,a:p[0].point,b:p[1].point)
            guard intent != .undecided else { return .none }
            let origin=Self.midpoint(start),now=Self.midpoint(p)
            horizontal=abs(now.x-origin.x)>abs(now.y-origin.y)
            start=p;moving=true
            return .rebase
        }
        if intent == .angle {
            // A pinch can start after the fingers initially travel together.
            // Rebase at that point rather than replaying the accumulated scale.
            if abs(Self.span(p)/Self.span(start)-1)>0.10 && abs(Self.span(p)-Self.span(start))>12 {
                intent = .transform;return .rebase
            }
            let a=Self.midpoint(previous),b=Self.midpoint(p)
            return .angle(horizontal ? b.x-a.x : 0,horizontal ? 0 : b.y-a.y)
        }
        return .zoom(Self.midpoint(previous),Self.midpoint(p),Self.span(p)/Self.span(previous))
    }
    var recognized: Bool { moving }
}
