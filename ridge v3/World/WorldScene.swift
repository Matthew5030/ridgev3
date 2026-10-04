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
    @AppStorage(TerrainGestureStyle.defaultsKey) private var gestureStyle = TerrainGestureStyle.moveWithOneFinger
    func makeUIView(context: Context) -> WorldSceneView {
        let view = WorldSceneView(); view.model = model; view.onTap = onTap; view.onAtlas = onAtlas
        view.gestureStyle = gestureStyle; view.refresh(route: route, segments: segments, waypoints: waypoints, command: command); return view
    }
    func updateUIView(_ view: WorldSceneView, context: Context) {
        view.model = model; view.onTap = onTap; view.onAtlas = onAtlas; view.gestureStyle = gestureStyle
        view.refresh(route: route, segments: segments, waypoints: waypoints, command: command)
    }
    static func dismantleUIView(_ view: WorldSceneView, coordinator: ()) { view.scene = nil; view.model = nil }
}

/// The native renderer is deliberately independent of downloads. Nodes are
/// replaced a tile at a time, and the camera survives every replacement.
final class WorldSceneView: SCNView, UIGestureRecognizerDelegate {
    weak var model: WorldModel?
    var onTap: ((GeoPoint) -> Void)?
    var onAtlas: ((GeoPoint) -> Void)?
    var gestureStyle = TerrainGestureStyle.moveWithOneFinger { didSet { configureTouches() } }
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
    private var pitch: Float = 1.3
    private var manualTilt = false
    private var moveGesture: UIPanGestureRecognizer!
    private var orbitGesture: UIPanGestureRecognizer!
    private var routeNode = SCNNode()
    private var routePoints: [RoutePoint] = []
    private var routeSegments: [[RoutePoint]] = []
    private var routeWaypoints: [RouteWaypoint] = []
    private var lastCommand: TerrainCameraCommand?
    private var labels: [(MapPlace, UILabel)] = []
    private var labelUpdate: DispatchWorkItem?

    init() {
        super.init(frame: .zero, options: nil)
        antialiasingMode = .multisampling4X; preferredFramesPerSecond = 60
        rendersContinuously = false; autoenablesDefaultLighting = false; backgroundColor = UIColor(red: 0.76, green: 0.86, blue: 0.91, alpha: 1)
        moveGesture = UIPanGestureRecognizer(target: self, action: #selector(panWorld(_:)))
        orbitGesture = UIPanGestureRecognizer(target: self, action: #selector(orbit(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        for g in [moveGesture!,orbitGesture!,pinch,tap] { g.delegate = self; addGestureRecognizer(g) }
        configureTouches(); accessibilityLabel = "Terrain map"; accessibilityHint = "Drag to move, pinch to zoom. Two fingers rotate and tilt."
    }
    required init?(coder: NSCoder) { nil }
    private func configureTouches() {
        moveGesture?.minimumNumberOfTouches = gestureStyle.moveTouches; moveGesture?.maximumNumberOfTouches = gestureStyle.moveTouches
        orbitGesture?.minimumNumberOfTouches = gestureStyle.rotateTouches; orbitGesture?.maximumNumberOfTouches = gestureStyle.rotateTouches
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
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
            SCNTransaction.commit(); drawRoute(); scheduleLabels()
        }
        if route != routePoints || segments != routeSegments || waypoints != routeWaypoints { routeSegments = segments; routePoints = route; routeWaypoints = waypoints; drawRoute() }
        if lastCommand != command {
            let initial = lastCommand == nil
            lastCommand = command
            switch command.action {
            case .focus(let point): target = local(point); distance = min(distance, 2000); updateCamera()
            case .zoomIn: distance /= 1.5; updateCamera()
            case .zoomOut: distance *= 1.5; updateCamera()
            case .overhead: manualTilt = true; pitch = pitch > 1.2 ? 0.55 : 1.49; updateCamera()
            case .home where initial: break
            case .home: target = local(next.bounds.center); distance = 10500; manualTilt = false; updateCamera()
            default: break
            }
        }
        if let point = model.requestFocus { DispatchQueue.main.async { model.requestFocus = nil }; target = local(point); distance = 1500; manualTilt = false; updateCamera() }
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
        target = local(model?.center ?? source.bounds.center); distance = Float(model?.distance ?? 6000); updateCamera()
    }
    override func layoutSubviews() { super.layoutSubviews(); updateLabels() }
    private func updateCamera() {
        guard let source else { return }
        target.x = min(Float(source.bounds.widthMeters * 0.49), max(-Float(source.bounds.widthMeters * 0.49), target.x))
        target.z = min(Float(source.bounds.depthMeters * 0.49), max(-Float(source.bounds.depthMeters * 0.49), target.z))
        target.y = height(coordinate(target)) + 12
        distance = min(26000,max(170,distance))
        if !manualTilt { pitch = min(1.49,max(0.45,0.42 + (distance-500)/8500)) }
        var eye = target + distance * SIMD3(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))
        let point = coordinate(eye)
        if source.bounds.contains(point) { eye.y = max(eye.y,height(point)+25) }
        cameraNode.simdPosition = eye; cameraNode.look(at: SCNVector3(target))
        scheduleLabels(); drawRoute()
        let center = coordinate(target), range = Double(distance)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scene != nil else { return }
            self.model?.update(center: center, distance: range)
            if range > 22000 { self.onAtlas?(center) }
        }
    }
    private func scheduleLabels() {
        labelUpdate?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.updateLabels() }
        labelUpdate = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: task)
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
    @objc private func panWorld(_ gesture: UIPanGestureRecognizer) {
        let d = gesture.translation(in:self); gesture.setTranslation(.zero,in:self)
        let scale = distance * 0.0009
        target += SIMD3(-Float(d.x)*cos(yaw)+Float(d.y)*sin(yaw),0,Float(d.x)*sin(yaw)+Float(d.y)*cos(yaw)) * scale
        updateCamera()
    }
    @objc private func orbit(_ gesture: UIPanGestureRecognizer) {
        let d=gesture.translation(in:self);gesture.setTranslation(.zero,in:self);manualTilt=true
        yaw -= Float(d.x)*0.006; pitch=min(1.50,max(0.24,pitch+Float(d.y)*0.005));updateCamera()
    }
    @objc private func zoom(_ gesture: UIPinchGestureRecognizer) { distance /= Float(gesture.scale);gesture.scale=1;updateCamera() }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        if let hit = hitTest(gesture.location(in:self),options:[.categoryBitMask:1,.searchMode:SCNHitTestSearchMode.closest.rawValue]).first {
            onTap?(coordinate(SIMD3(hit.worldCoordinates.x,hit.worldCoordinates.y,hit.worldCoordinates.z)))
        }
    }
}
