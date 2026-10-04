import SwiftUI
import SceneKit
import simd

struct WorldScene: UIViewRepresentable {
    var model: WorldModel
    var route: [RoutePoint]
    var segments: [[RoutePoint]]
    var waypoints: [RouteWaypoint]
    var command: TerrainCameraCommand
    var onTap: (GeoPoint) -> Void
    var onAtlas: (GeoPoint) -> Void
    func makeUIView(context: Context) -> WorldSceneView {
        let view = WorldSceneView(); view.model = model; view.onTap = onTap; view.onAtlas = onAtlas
        view.refresh(route: route, segments: segments, waypoints: waypoints, command: command); return view
    }
    func updateUIView(_ view: WorldSceneView, context: Context) {
        view.model = model; view.onTap = onTap; view.onAtlas = onAtlas
        view.refresh(route: route, segments: segments, waypoints: waypoints, command: command)
    }
    static func dismantleUIView(_ view: WorldSceneView, coordinator: ()) { view.scene = nil; view.model = nil }
}

/// The native renderer is deliberately independent of downloads. Nodes are
/// replaced a tile at a time, and the camera survives every replacement.
final class WorldSceneView: SCNView, UIGestureRecognizerDelegate, SCNSceneRendererDelegate {
    weak var model: WorldModel?
    var onTap: ((GeoPoint) -> Void)?
    var onAtlas: ((GeoPoint) -> Void)?
    private var source: WorldSource?
    private var overview: WorldOverview?
    private var nodes: [String: SCNNode] = [:]
    private var tileIDs: [Int: String] = [:]
    private var coarse: [String: SCNGeometry] = [:]
    private var applied: [String: WorldTileRequest] = [:]
    private var revision = -1
    private var cameraNode = SCNNode()
    private var target = SIMD3<Float>(0,0,0)
    private var distance: Float = 6000
    private var yaw: Float = 0
    private var pitch: Float = 0.85
    private var moveGesture: UIPanGestureRecognizer!
    private var transformGesture: WorldTwoFingerGesture!
    private var routeUpdate: DispatchWorkItem?
    private var routeNode = SCNNode()
    private var routePoints: [RoutePoint] = []
    private var routeSegments: [[RoutePoint]] = []
    private var routeWaypoints: [RouteWaypoint] = []
    private var lastCommand: TerrainCameraCommand?
    private var labels: [(MapPlace, UILabel)] = []

    init() {
        super.init(frame: .zero, options: nil)
        delegate = self
        antialiasingMode = .multisampling4X; preferredFramesPerSecond = 60
        rendersContinuously = false; autoenablesDefaultLighting = false; backgroundColor = UIColor(red: 0.76, green: 0.86, blue: 0.91, alpha: 1)
        moveGesture = UIPanGestureRecognizer(target: self, action: #selector(panWorld(_:)))
        moveGesture.minimumNumberOfTouches = 1; moveGesture.maximumNumberOfTouches = 1
        transformGesture = WorldTwoFingerGesture(target: self, action: #selector(transformMap(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        tap.require(toFail: moveGesture); tap.require(toFail: transformGesture)
        for g in [moveGesture!,transformGesture!,tap] { g.delegate = self; addGestureRecognizer(g) }
        isMultipleTouchEnabled = true
        accessibilityLabel = "Terrain map"; accessibilityHint = "Drag to move. Pinch to zoom. Drag two fingers left or right to turn, up or down to tilt. The horizon stays level."
    }
    required init?(coder: NSCoder) { nil }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The one-finger pan cancels as the second finger arrives. The transform
        // recognizer must be allowed to take over that same touch sequence.
        (gestureRecognizer === moveGesture && other === transformGesture) || (gestureRecognizer === transformGesture && other === moveGesture)
    }
    private func local(_ point: GeoPoint) -> SIMD3<Float> {
        guard let source else { return .zero }
        let uv = source.bounds.uv(point)
        return SIMD3(Float((uv.u - 0.5) * source.bounds.widthMeters), height(point), Float((uv.v - 0.5) * source.bounds.depthMeters))
    }
    private func coordinate(_ p: SIMD3<Float>) -> GeoPoint {
        source!.bounds.point(u: Double(p.x) / source!.bounds.widthMeters + 0.5, v: Double(p.z) / source!.bounds.depthMeters + 0.5)
    }
    private func height(_ point: GeoPoint) -> Float {
        guard let source, let overview else { return 0 }
        let uv = source.bounds.uv(point), col = min(source.columns - 1, max(0, Int(uv.u * Double(source.columns)))), row = min(source.rows - 1, max(0, Int(uv.v * Double(source.rows))))
        if let id = tileIDs[row * source.columns + col], let h = model?.tiles[id]?.mesh?.elevation(at: point) { return Float(h) }
        return overview.elevation(point, bounds: source.bounds)
    }
    func refresh(route: [RoutePoint], segments: [[RoutePoint]], waypoints: [RouteWaypoint], command: TerrainCameraCommand) {
        guard let model, let next = model.source, let overview = model.overview else { return }
        if source?.revision != next.revision || source?.id != next.id {
            source = next; self.overview = overview; buildScene(next, overview: overview)
        }
        if revision != model.revision {
            revision = model.revision
            SCNTransaction.begin(); SCNTransaction.animationDuration = 0
            for tile in next.tiles {
                if let prepared = model.tiles[tile.id] {
                    guard applied[tile.id] != prepared.request else { continue }
                    let geometry = prepared.geometry ?? coarse[tile.id]!
                    geometry.materials = [material(prepared.image)]
                    nodes[tile.id]?.geometry = geometry; applied[tile.id] = prepared.request
                } else if applied.removeValue(forKey: tile.id) != nil {
                    coarse[tile.id]?.materials = [material(nil)]; nodes[tile.id]?.geometry = coarse[tile.id]
                }
            }
            SCNTransaction.commit(); scheduleRoute(); scheduleLabels()
        }
        if route != routePoints || segments != routeSegments || waypoints != routeWaypoints { routeSegments = segments; routePoints = route; routeWaypoints = waypoints; drawRoute() }
        if lastCommand != command {
            let initial = lastCommand == nil
            lastCommand = command
            switch command.action {
            case .focus(let point): target = local(point); distance = min(distance, 2000); updateCamera()
            case .zoomIn: distance /= 1.5; updateCamera(); scheduleRoute()
            case .zoomOut: distance *= 1.5; updateCamera(); scheduleRoute()
            case .overhead: pitch = 1.49; yaw = 0; updateCamera()
            case .home where initial: break
            case .home: target = local(next.bounds.center); distance = 6000; pitch = 0.85; yaw = 0; updateCamera()
            default: break
            }
        }
        if let point = model.requestFocus { DispatchQueue.main.async { model.requestFocus = nil }; target = local(point); distance = 1500; updateCamera() }
    }
    private func material(_ image: CGImage?) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = image ?? UIColor(red: 0.87,green: 0.89,blue: 0.79,alpha: 1) as Any
        m.diffuse.minificationFilter = .linear; m.diffuse.magnificationFilter = .linear; m.diffuse.mipFilter = .linear; m.diffuse.maxAnisotropy = 16
        if let image { let size = Float(image.width); var t = SCNMatrix4Identity; t.m11=(size-8)/size;t.m22=(size-8)/size;t.m41=4/size;t.m42=4/size;m.diffuse.contentsTransform=t }
        m.lightingModel = .lambert; m.isDoubleSided = true; return m
    }
    private func buildScene(_ source: WorldSource, overview: WorldOverview) {
        let scene = SCNScene(); scene.background.contents = backgroundColor
        scene.fogColor = backgroundColor; scene.fogStartDistance = 9000; scene.fogEndDistance = 26000
        self.scene = scene; nodes = [:]; coarse = [:]; applied = [:]; tileIDs = [:]
        cameraNode = SCNNode(); cameraNode.camera = SCNCamera(); cameraNode.camera?.fieldOfView = 43
        cameraNode.camera?.zNear = 2; cameraNode.camera?.zFar = 60000; cameraNode.camera?.wantsHDR = false
        scene.rootNode.addChildNode(cameraNode); pointOfView = cameraNode
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 400; scene.rootNode.addChildNode(ambient)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 600
        sun.eulerAngles = SCNVector3(-0.8,-0.7,0); scene.rootNode.addChildNode(sun)
        for tile in source.tiles {
            tileIDs[tile.row * source.columns + tile.column] = tile.id
            let g = WorldGeometry.coarse(tile: tile, source: source, overview: overview)
            g.materials = [material(nil)]; coarse[tile.id] = g
            let node = SCNNode(geometry: g); node.categoryBitMask = 1; node.name = tile.id
            nodes[tile.id] = node; scene.rootNode.addChildNode(node)
        }
        routeNode = SCNNode(); routeNode.categoryBitMask = 2; scene.rootNode.addChildNode(routeNode)
        for (_, label) in labels { label.removeFromSuperview() }; labels = []
        for place in source.places.filter({ $0.kind == "peak" }).prefix(80) {
            let label = UILabel(); label.text = place.name; label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = UIColor(white: 0.16, alpha: 1); label.backgroundColor = UIColor(white: 1,alpha: 0.78)
            label.layer.cornerRadius = 4; label.clipsToBounds = true; label.isUserInteractionEnabled = false
            label.sizeToFit(); label.bounds.size.width += 12; label.bounds.size.height += 6; addSubview(label); labels.append((place,label))
        }
        target = local(model?.center ?? source.bounds.center); distance = Float(model?.distance ?? 6000)
        if let pose = model?.cameraPose, source.bounds.contains(pose.target) {
            target = local(pose.target); target.y = Float(pose.targetElevationMeters)
            distance = Float(pose.distanceMeters); yaw = pose.yaw; pitch = pose.pitch
        }
        updateCamera()
    }
    override func layoutSubviews() { super.layoutSubviews(); updateLabels() }
    private func updateCamera(notify: Bool = true) {
        guard let source else { return }
        target.x = min(Float(source.bounds.widthMeters * 0.49), max(-Float(source.bounds.widthMeters * 0.49), target.x))
        target.z = min(Float(source.bounds.depthMeters * 0.49), max(-Float(source.bounds.depthMeters * 0.49), target.z))
        distance = min(26000,max(170,distance))
        var eye = target + distance * SIMD3(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))
        let point = coordinate(eye)
        if source.bounds.contains(point) { eye.y = max(eye.y,height(point)+25) }
        cameraNode.simdPosition = eye; WorldCameraOrientation.aim(cameraNode, at: target)
        scheduleLabels()
        guard notify else { return }
        model?.cameraPose = TerrainCameraPose(target: coordinate(target), targetElevationMeters: Double(target.y), yaw: yaw, pitch: pitch, distanceMeters: Double(distance))
        let center = coordinate(target), range = Double(distance)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scene != nil else { return }
            self.model?.update(center: center, distance: range)
            if range > 22000 { self.onAtlas?(center) }
        }
    }
    private func scheduleLabels() { setNeedsDisplay() }
    nonisolated func renderer(_ renderer: any SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        // Project only after SceneKit has adopted the new camera transform.
        DispatchQueue.main.async { [weak self] in self?.updateLabels() }
    }
    private func updateLabels() {
        guard scene != nil, let source else { return }
        var occupied: [CGRect] = []
        for (place,label) in labels.sorted(by: { $0.0.coordinate.distance(to: coordinate(target)) < $1.0.coordinate.distance(to: coordinate(target)) }) {
            var p = local(place.coordinate); p.y += 15
            let screen = projectPoint(SCNVector3(p)); let frame = CGRect(x: CGFloat(screen.x)-label.bounds.width/2,y: CGFloat(screen.y)-label.bounds.height-5,width:label.bounds.width,height:label.bounds.height)
            let visible = screen.z > 0 && screen.z < 1 && bounds.insetBy(dx: 12,dy: 12).contains(frame) && !occupied.contains(where: { $0.intersects(frame.insetBy(dx:-8,dy:-6)) }) && occupied.count < 12
            label.isHidden = !visible; label.frame = frame; if visible { occupied.append(frame) }
        }
    }
    private func drawRoute() {
        guard let source, !routePoints.isEmpty else { routeNode.geometry = nil; routeNode.childNodes.forEach { $0.removeFromParentNode() }; return }
        let halfWidth = max(1.2,distance*0.0012)
        var vertices: [SCNVector3] = []; var indices: [Int32] = []
        for path in (routeSegments.isEmpty ? [routePoints] : routeSegments) {
        for (a,b) in zip(path,path.dropFirst()) {
            let length = a.coordinate.distance(to:b.coordinate); let count = min(2000,max(1,Int(ceil(length/5))))
            for i in 0..<count {
                func point(_ t: Double) -> GeoPoint { GeoPoint(latitude:a.coordinate.latitude+(b.coordinate.latitude-a.coordinate.latitude)*t,longitude:a.coordinate.longitude+(b.coordinate.longitude-a.coordinate.longitude)*t) }
                let p = local(point(Double(i)/Double(count))), q = local(point(Double(i+1)/Double(count)))
                let d = SIMD2(q.x-p.x,q.z-p.z); if simd_length(d)<0.001 { continue }
                let n = SIMD2(-d.y,d.x)/simd_length(d)*halfWidth
                let start = Int32(vertices.count)
                for v in [p+SIMD3(n.x,0,n.y),p-SIMD3(n.x,0,n.y),q+SIMD3(n.x,0,n.y),q-SIMD3(n.x,0,n.y)] {
                    var v = v; v.y = height(coordinate(v))+2; vertices.append(SCNVector3(v))
                }
                indices += [start,start+1,start+2,start+1,start+3,start+2]
            }
        }
        }
        let geometry = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        let ink = SCNMaterial(); ink.diffuse.contents = UIColor(red:0.85,green:0.23,blue:0.12,alpha:1); ink.lightingModel = .constant; ink.isDoubleSided = true; ink.writesToDepthBuffer = false
        geometry.materials = [ink]; routeNode.geometry = geometry; routeNode.renderingOrder = 5
        routeNode.childNodes.forEach { $0.removeFromParentNode() }
        for waypoint in routeWaypoints {
            let marker = SCNNode(geometry:SCNSphere(radius:CGFloat(halfWidth*2.5))); marker.geometry?.materials = [ink]
            var p = local(waypoint.point.coordinate); p.y += halfWidth*3+2; marker.simdPosition = p; marker.categoryBitMask = 2; routeNode.addChildNode(marker)
        }
    }
    private func scheduleRoute() {
        routeUpdate?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.drawRoute() }
        routeUpdate = task; DispatchQueue.main.asyncAfter(deadline: .now()+0.12, execute:task)
    }
    /// Intersect the camera ray with the current drag plane. Using projection
    /// rather than a fixed metres-per-pixel multiplier keeps ground under a finger.
    private func groundPoint(_ screen: CGPoint) -> SIMD3<Float>? {
        let a = unprojectPoint(SCNVector3(Float(screen.x),Float(screen.y),0))
        let b = unprojectPoint(SCNVector3(Float(screen.x),Float(screen.y),1))
        let origin=SIMD3<Float>(a.x,a.y,a.z), direction=SIMD3<Float>(b.x-a.x,b.y-a.y,b.z-a.z)
        guard abs(direction.y)>0.0001 else { return nil }
        let t=(target.y-origin.y)/direction.y
        guard t>0 else { return nil }
        let point=origin+direction*t
        return simd_distance(point,target)<distance*5 ? point : nil
    }
    private func rebaseDragPlane() {
        // Move the orbit centre onto the visible ground without moving the eye
        // or changing its sight line. A valley can then be zoomed into even when
        // the previous drag started on a much higher summit.
        guard let hit=hitTest(CGPoint(x:bounds.midX,y:bounds.midY),options:[.categoryBitMask:1,.searchMode:SCNHitTestSearchMode.closest.rawValue]).first else { return }
        let p=hit.worldCoordinates, ground=SIMD3<Float>(p.x,p.y,p.z)
        let offset=cameraNode.simdPosition-ground, length=simd_length(offset)
        guard length>1 else { return }
        target=ground; distance=length
        pitch=asin(max(-1,min(1,offset.y/length))); yaw=atan2(offset.x,offset.z)
    }
    @objc private func panWorld(_ gesture: UIPanGestureRecognizer) {
        guard gesture.numberOfTouches == 1, gesture.state == .began || gesture.state == .changed else { return }
        if gesture.state == .began { rebaseDragPlane() }
        let d=gesture.translation(in:self), current=gesture.location(in:self)
        gesture.setTranslation(.zero,in:self)
        let previous=CGPoint(x:current.x-d.x,y:current.y-d.y)
        if let a=groundPoint(previous),let b=groundPoint(current) { target += a-b; updateCamera() }
    }
    @objc private func transformMap(_ gesture: WorldTwoFingerGesture) {
        guard gesture.state == .began || gesture.state == .changed else {
            moveGesture.isEnabled = true; scheduleRoute(); return
        }
        if gesture.state == .began { moveGesture.isEnabled = false; rebaseDragPlane() }
        defer { gesture.consume() }
        if gesture.intent == .angle {
            let dx=gesture.centroid.x-gesture.previousCentroid.x
            let dy=gesture.centroid.y-gesture.previousCentroid.y
            yaw -= Float(dx)*0.005
            pitch=min(1.49,max(0.30,pitch-Float(dy)*0.004))
        } else {
            let anchor=groundPoint(gesture.previousCentroid)
            distance /= Float(gesture.scaleDelta)
            updateCamera(notify:false)
            if let anchor,let after=groundPoint(gesture.centroid) { target += anchor-after }
        }
        updateCamera()
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        if let hit = hitTest(gesture.location(in:self),options:[.categoryBitMask:1,.searchMode:SCNHitTestSearchMode.closest.rawValue]).first {
            onTap?(coordinate(SIMD3(hit.worldCoordinates.x,hit.worldCoordinates.y,hit.worldCoordinates.z)))
        }
    }
}
