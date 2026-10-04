import UIKit
import UIKit.UIGestureRecognizerSubclass

final class WorldTwoFingerGesture: UIGestureRecognizer {
    private var fingers: [UITouch] = []
    private var starts: [CGPoint] = []
    private(set) var intent = WorldGestureIntent.undecided
    private(set) var centroid = CGPoint.zero
    private(set) var previousCentroid = CGPoint.zero
    private(set) var scaleDelta: CGFloat = 1
    private(set) var rotationDelta: CGFloat = 0
    private var previousSpan: CGFloat = 1
    private var previousAngle: CGFloat = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        fingers.append(contentsOf: touches)
        guard fingers.count <= 2 else { state = .cancelled; return }
        if fingers.count == 2 {
            starts = fingers.map { $0.location(in: view) }
            previousCentroid = CGPoint(x:(starts[0].x+starts[1].x)/2,y:(starts[0].y+starts[1].y)/2)
            previousSpan = max(20,hypot(starts[1].x-starts[0].x,starts[1].y-starts[0].y))
            previousAngle = atan2(starts[1].y-starts[0].y,starts[1].x-starts[0].x)
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard fingers.count == 2, starts.count == 2 else { return }
        let a=fingers[0].location(in:view), b=fingers[1].location(in:view)
        if intent == .undecided { intent = WorldGestureIntent.resolve(startA:starts[0],startB:starts[1],a:a,b:b) }
        guard intent != .undecided else { return }
        centroid = CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2)
        let span=max(20,hypot(b.x-a.x,b.y-a.y)), angle=atan2(b.y-a.y,b.x-a.x)
        scaleDelta = span/previousSpan
        rotationDelta = atan2(sin(angle-previousAngle),cos(angle-previousAngle))
        state = state == .possible ? .began : .changed
        // Values are consumed synchronously by the target action after this event.
        // The next event snapshots its own prior values in the scene handler.
    }
    func consume() {
        previousCentroid = centroid
        if fingers.count == 2 {
            let a=fingers[0].location(in:view), b=fingers[1].location(in:view)
            previousSpan=max(20,hypot(b.x-a.x,b.y-a.y)); previousAngle=atan2(b.y-a.y,b.x-a.x)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { state = state == .possible ? .failed : .ended }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() { super.reset(); fingers=[]; starts=[]; intent = .undecided; scaleDelta=1; rotationDelta=0 }
}
