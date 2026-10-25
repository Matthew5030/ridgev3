import UIKit
import UIKit.UIGestureRecognizerSubclass

/// One recognizer owns the entire contact sequence, including 1→2→1 fingers.
/// Disabling separate recognizers mid-touch loses the remaining finger in UIKit.
final class WorldNavigationGesture: UIGestureRecognizer {
    var onContactChanged: ((Bool)->Void)?
    private var fingers: [UITouch:Int] = [:]
    private var nextID = 0
    private var motion = WorldGestureMotion()
    private(set) var step = WorldGestureMotion.Step.none
    var isInteracting: Bool { !fingers.isEmpty && (state == .began || state == .changed) }

    private func sample() {
        step=motion.update(fingers.map { .init(id:$0.value,point:$0.key.location(in:view)) })
        if state == .began || state == .changed { state = .changed }
        else if motion.recognized { state = .began }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if fingers.isEmpty {
            onContactChanged?(true)
            motion.rotateWithOneFinger = UserDefaults.standard.string(forKey:TerrainGestureStyle.defaultsKey) == TerrainGestureStyle.rotateWithOneFinger.rawValue
        }
        for touch in touches { fingers[touch]=nextID;nextID+=1 }
        sample()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { sample() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { fingers.removeValue(forKey:touch) }
        if fingers.isEmpty { onContactChanged?(false);step = .none;state = state == .possible ? .failed : .ended }
        else { sample() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onContactChanged?(false);fingers=[:];step = .none;state = state == .possible ? .failed : .cancelled
    }
    override func reset() {
        if !fingers.isEmpty { onContactChanged?(false) }
        super.reset();fingers=[:];nextID=0;motion=WorldGestureMotion();step = .none
    }
}
