import Foundation

/// Decide once per gesture: a deliberate parallel vertical drag tilts; spreading
/// or twisting stays a map transform until both fingers are lifted.
enum WorldGestureIntent {
    case undecided, tilt, transform

    static func resolve(startA: CGPoint, startB: CGPoint, a: CGPoint, b: CGPoint) -> Self {
        let start = CGPoint(x: startB.x-startA.x, y: startB.y-startA.y)
        let current = CGPoint(x: b.x-a.x, y: b.y-a.y)
        let length = max(20, hypot(start.x, start.y))
        let scaleChange = abs(hypot(current.x,current.y)/length-1)
        let angle = atan2(current.y,current.x)-atan2(start.y,start.x)
        let rotation = abs(atan2(sin(angle),cos(angle)))
        let dx = (a.x+b.x-startA.x-startB.x)/2
        let dy = (a.y+b.y-startA.y-startB.y)/2
        if scaleChange > 0.035 || rotation > 0.055 { return .transform }
        if abs(dy) > 12 && abs(dy) > abs(dx)*1.8 { return .tilt }
        if hypot(dx,dy) > 14 { return .transform }
        return .undecided
    }
}
