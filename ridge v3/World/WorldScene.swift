import SwiftUI
import SceneKit
import simd
import Metal

struct WorldScene: UIViewRepresentable {
    var model: WorldModel
    var route: [RoutePoint]
    var segments: [[RoutePoint]]
    var waypoints: [RouteWaypoint]
    var command: TerrainCameraCommand
    var onTap: (GeoPoint) -> Void
    var onAtlas: (GeoBounds) -> Void
    var atlasRequest: UUID? = nil
    func makeUIView(context: Context) -> WorldSceneView {
        let view = WorldSceneView(); view.model = model; view.onTap = onTap; view.onAtlas = onAtlas
        view.refresh(route: route, segments: segments, waypoints: waypoints, command: command, atlasRequest:atlasRequest); return view
    }
    func updateUIView(_ view: WorldSceneView, context: Context) {
        view.model = model; view.onTap = onTap; view.onAtlas = onAtlas
        view.refresh(route: route, segments: segments, waypoints: waypoints, command: command, atlasRequest:atlasRequest)
    }
    static func dismantleUIView(_ view: WorldSceneView, coordinator: ()) { view.stopFlight(); view.cancelCameraNotification(); view.scene = nil; view.model = nil }
}

/// The native renderer is deliberately independent of downloads. Nodes are
/// replaced a tile at a time, and the camera survives every replacement.
final class WorldSceneView: SCNView, UIGestureRecognizerDelegate {
    weak var model: WorldModel?
    var onTap: ((GeoPoint) -> Void)?
    var onAtlas: ((GeoBounds) -> Void)?
    private var source: WorldSource?
    private var overview: WorldOverview?
    private var nodes: [String: SCNNode] = [:]
    private var tileIndex = WorldTileIndex(tiles:[])
    private var cameraNotification: DispatchWorkItem?
    private var labelNotification: DispatchWorkItem?
    private let placeLabels = WorldPlaceLabels()
    private var uploadNotification: DispatchWorkItem?
    private var uploadQueue: [String] = []
    private var queuedUploads = Set<String>()
    private var coarse: [String: SCNGeometry] = [:]
    private var applied: [String: WorldTileRequest] = [:]
    private var flightLink: CADisplayLink?
    private var flightStart = 0.0
    private var flightEntrySpan: Double?
    private var flightExitPose: WorldCameraTransition.Pose?
    private var lastAtlasRequest: UUID?
    private var revision = -1
    private var cameraNode = SCNNode()
    private var target = SIMD3<Float>(0,0,0)
    private var distance: Float = 6000
    private var yaw: Float = 0
    private var pitch: Float = 0.85
    private var moveGesture: UIPanGestureRecognizer!
    private var transformGesture: WorldTwoFingerGesture!
    private var routeOverlays: [String: WorldRouteOverlay.Binding] = [:]
    private var routePoints: [RoutePoint] = []
    private var routeSegments: [[RoutePoint]] = []
    private var routeWaypoints: [RouteWaypoint] = []
    private var lastCommand: TerrainCameraCommand?

    init() {
        super.init(frame: .zero, options: nil)
        antialiasingMode = .multisampling4X; preferredFramesPerSecond = 60
        rendersContinuously = false; autoenablesDefaultLighting = false; backgroundColor = UIColor(red: 0.76, green: 0.86, blue: 0.91, alpha: 1)
        moveGesture = UIPanGestureRecognizer(target: self, action: #selector(panWorld(_:)))
        moveGesture.minimumNumberOfTouches = 1; moveGesture.maximumNumberOfTouches = 1
        transformGesture = WorldTwoFingerGesture(target: self, action: #selector(transformMap(_:)))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
        tap.require(toFail: moveGesture); tap.require(toFail: transformGesture)
        for g in [moveGesture!,transformGesture!,tap] { g.delegate = self; addGestureRecognizer(g) }
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
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
        let uv = source.frame.uv(point)
        return SIMD3(Float((uv.u - 0.5) * source.frame.widthMeters), height(point), Float((uv.v - 0.5) * source.frame.depthMeters))
    }
    private func coordinate(_ p: SIMD3<Float>) -> GeoPoint {
        source!.frame.point(u: Double(p.x) / source!.frame.widthMeters + 0.5, v: Double(p.z) / source!.frame.depthMeters + 0.5)
    }
    private func height(_ point: GeoPoint) -> Float {
        guard let source, let overview else { return 0 }
        if let tile = tileIndex.tile(at:point),
           let mesh = model?.tiles[tile.id]?.mesh ?? model?.backdrop?.meshes[tile.id],
           let h = mesh.elevation(at:point) { return Float(h) }
        return overview.elevation(point, bounds: source.bounds)
    }
    func refresh(route: [RoutePoint], segments: [[RoutePoint]], waypoints: [RouteWaypoint], command: TerrainCameraCommand, atlasRequest: UUID?) {
        guard let model, let next = model.source, let overview = model.overview else { return }
        let sourceChanged = source?.revision != next.revision || source?.id != next.id
        if sourceChanged {
            let firstScene = source == nil || source?.frame != next.frame
            source = next; self.overview = overview
            if firstScene { buildScene(next, overview:overview) }
            else { reconcileTerrain(next,overview:overview); updateCamera(notify:false) }
        }
        if revision != model.revision {
            revision = model.revision
            let changed = sourceChanged ? next.tiles.sorted { $0.mesh.bounds.center.distance(to:model.center) > $1.mesh.bounds.center.distance(to:model.center) }.map(\.id) : Array(model.changedTileIDs)
            model.changedTileIDs.removeAll(keepingCapacity:true)
            enqueueTerrain(changed)
        }
        if sourceChanged || route != routePoints || segments != routeSegments || waypoints != routeWaypoints { routeSegments = segments; routePoints = route; routeWaypoints = waypoints; updateRouteOverlay() }
        if lastCommand != command {
            let initial = lastCommand == nil
            lastCommand = command
            if !initial {
            interruptFlight()
            switch command.action {
            case .focus(let point): target = local(point); distance = min(distance, 2000); updateCamera()
            case .zoomIn: distance /= 1.5; updateCamera()
            case .zoomOut: distance *= 1.5; updateCamera()
            case .overhead: pitch = 1.49; yaw = 0; updateCamera()
            case .home: target = local(next.bounds.center); distance = 6000; pitch = 0.85; yaw = 0; updateCamera()
            default: break
            }
            }
        }
        if atlasRequest != lastAtlasRequest { lastAtlasRequest=atlasRequest; if atlasRequest != nil { beginExit() } }
        if let point = model.requestFocus { interruptFlight(); DispatchQueue.main.async { model.requestFocus = nil }; target = local(point); distance = 1500; updateCamera() }
    }
    private func material(_ image: CGImage?, tileID: String) -> SCNMaterial {
        let m = SCNMaterial(); m.diffuse.contents = image ?? UIColor(red: 0.87,green: 0.89,blue: 0.79,alpha: 1) as Any
        m.diffuse.minificationFilter = .linear; m.diffuse.magnificationFilter = .linear; m.diffuse.mipFilter = .linear; m.diffuse.maxAnisotropy = 16
        if let image { let size = Float(image.width); var t = SCNMatrix4Identity; t.m11=(size-8)/size;t.m22=(size-8)/size;t.m41=4/size;t.m42=4/size;m.diffuse.contentsTransform=t }
        m.lightingModel = .lambert; m.isDoubleSided = true
        routeOverlays[tileID]?.apply(to:m,pixelScale:Float(contentScaleFactor))
        return m
    }
    private func buildScene(_ source: WorldSource, overview: WorldOverview) {
        let scene = SCNScene(); scene.background.contents = backgroundColor
        scene.fogColor = backgroundColor; scene.fogDensityExponent = 1
        cancelCameraNotification()
        self.scene = scene; nodes = [:]; coarse = [:]; applied = [:]; tileIndex = WorldTileIndex(tiles:[]); routeOverlays = [:]
        cameraNode = SCNNode(); cameraNode.camera = SCNCamera(); cameraNode.camera?.fieldOfView = 43
        cameraNode.camera?.zNear = 2; cameraNode.camera?.zFar = 60000; cameraNode.camera?.wantsHDR = false
        scene.rootNode.addChildNode(cameraNode); pointOfView = cameraNode
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 400; scene.rootNode.addChildNode(ambient)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 600
        sun.eulerAngles = SCNVector3(-0.8,-0.7,0); scene.rootNode.addChildNode(sun)
        reconcileTerrain(source,overview:overview)
        target = local(model?.center ?? source.bounds.center); distance = Float(model?.distance ?? 6000)
        if let pose = model?.cameraPose, source.bounds.contains(pose.target) {
            target = local(pose.target); target.y = Float(pose.targetElevationMeters)
            distance = Float(pose.distanceMeters); yaw = pose.yaw; pitch = pose.pitch
        }
        if let span=model?.entrySpan {
            model?.entrySpan=nil
            beginEntry(span:span)
        } else { updateCamera() }
    }
    private func reconcileTerrain(_ source: WorldSource, overview: WorldOverview) {
        guard scene != nil else { return }
        tileIndex = WorldTileIndex(tiles:source.tiles)
        let keep = Set(source.tiles.map(\.id))
        uploadQueue.removeAll { !keep.contains($0) }; queuedUploads.formIntersection(keep)
        for id in Array(coarse.keys) where !keep.contains(id) {
            nodes.removeValue(forKey:id)?.removeFromParentNode()
            coarse.removeValue(forKey:id); applied.removeValue(forKey:id); routeOverlays.removeValue(forKey:id)
        }
        for tile in source.tiles {
            guard let g = model?.backdrop?.geometries[tile.id] else { continue }
            if coarse[tile.id] !== g { coarse[tile.id] = g; applied.removeValue(forKey:tile.id) }
        }
        let focus = model?.center ?? source.bounds.center
        let places = source.places.filter { $0.kind == "peak" }.sorted {
            $0.coordinate.distance(to:focus) < $1.coordinate.distance(to:focus)
        }.prefix(60)
        placeLabels.reconcile(places:Array(places),scene:scene!,position:local)
        scheduleLabels()
    }

    private func enqueueTerrain(_ ids: [String]) {
        for id in ids where queuedUploads.insert(id).inserted { uploadQueue.append(id) }
        guard uploadNotification == nil else { return }
        uploadTerrain()
    }
    private func uploadTerrain() {
        uploadNotification = nil
        guard let model, let scene else { return }
        let began = CACurrentMediaTime()
        var count = 0
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        while let id = uploadQueue.popLast() {
            queuedUploads.remove(id)
            guard let fallback = coarse[id], let prepared = model.preparedTile(id) else { continue }
            if applied[id] != prepared.request || nodes[id] == nil {
                let geometry = prepared.geometry ?? fallback
                geometry.materials = [material(prepared.image,tileID:id)]
                let node: SCNNode
                if let old = nodes[id] { node = old }
                else { node = SCNNode(); node.categoryBitMask = 1; node.name = id; nodes[id] = node; scene.rootNode.addChildNode(node) }
                node.geometry = geometry; applied[id] = prepared.request
                if prepared.geometry != nil { fallback.materials = [] }
            }
            count += 1
            if count >= 24 || CACurrentMediaTime()-began >= 0.004 { break }
        }
        SCNTransaction.commit(); setNeedsDisplay()
        if !uploadQueue.isEmpty {
            let next = DispatchWorkItem { [weak self] in self?.uploadTerrain() }
            uploadNotification = next
            DispatchQueue.main.asyncAfter(deadline:.now()+1.0/60,execute:next)
        }
    }
    override func layoutSubviews() { super.layoutSubviews(); placeLabels.scale(camera:cameraNode,viewport:bounds.size); scheduleLabels() }
    private func updateCamera(notify: Bool = true) {
        guard let source else { return }
        // The camera is independent of residency. Moving toward missing data
        // requests it; it never snaps back to a storage rectangle.
        distance = min(flightLink == nil ? 26000 : 300000,max(170,distance))
        cameraNode.camera?.zFar=max(60000,Double(distance)*2)
        let atmosphere = WorldAtmosphere.range(cameraDistance:Double(distance))
        scene?.fogStartDistance = atmosphere.start; scene?.fogEndDistance = atmosphere.end
        var eye = target + distance * SIMD3(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))
        let point = coordinate(eye)
        if source.bounds.contains(point) { eye.y = max(eye.y,height(point)+25) }
        cameraNode.simdPosition = eye; WorldCameraOrientation.aim(cameraNode, at: target)
        placeLabels.scale(camera:cameraNode,viewport:bounds.size)
        scheduleLabels()
        guard notify else { return }
        model?.cameraPose = TerrainCameraPose(target: coordinate(target), targetElevationMeters: Double(target.y), yaw: yaw, pitch: pitch, distanceMeters: Double(distance))
        // Coalesce navigation work while keeping the actual camera at gesture
        // rate. A single queued update always consumes the latest pose.
        guard cameraNotification == nil else { return }
        let notification = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cameraNotification = nil
            guard self.scene != nil, let pose = self.model?.cameraPose else { return }
            self.model?.update(center:pose.target,distance:pose.distanceMeters)
            if self.distance > 12000 && self.flightLink == nil { self.beginExit() }
        }
        cameraNotification = notification
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:notification)
    }
    func cancelCameraNotification() {
        cameraNotification?.cancel(); cameraNotification = nil
        labelNotification?.cancel(); labelNotification = nil
        uploadNotification?.cancel(); uploadNotification = nil
        uploadQueue = []; queuedUploads = []
    }
    func stopFlight() {
        flightLink?.invalidate();flightLink=nil;flightEntrySpan=nil;flightExitPose=nil
    }
    private func interruptFlight() {
        guard flightLink != nil else { return }
        let field=cameraNode.camera?.fieldOfView ?? 43
        distance *= Float(tan(field * .pi/360)/tan(43 * .pi/360))
        stopFlight();cameraNode.camera?.fieldOfView=43
        updateCamera(notify:false)
    }
    private func beginEntry(span: Double) {
        stopFlight()
        if UIAccessibility.isReduceMotionEnabled {
            let pose=WorldCameraTransition.entry(span:span,progress:1)
            distance=Float(pose.distance);pitch=Float(pose.pitch);yaw=0;updateCamera();return
        }
        flightEntrySpan=span;startFlight()
        model?.update(center:coordinate(target),distance:WorldCameraTransition.entry(span:span,progress:1).distance)
    }
    private func beginExit() {
        guard flightExitPose == nil else { return }
        interruptFlight()
        let pose=WorldCameraTransition.Pose(distance:Double(distance),pitch:Double(pitch),yaw:Double(yaw),fieldOfView:Double(cameraNode.camera?.fieldOfView ?? 43))
        if UIAccessibility.isReduceMotionEnabled {
            onAtlas?(WorldCameraTransition.viewport(center:coordinate(target),span:max(14000,pose.span),aspect:Double(bounds.width/max(1,bounds.height))));return
        }
        flightExitPose=pose;startFlight()
    }
    private func startFlight() {
        flightStart=CACurrentMediaTime();cameraNode.camera?.zFar=500000
        let link=CADisplayLink(target:self,selector:#selector(advanceFlight));flightLink=link;link.add(to:.main,forMode:.common)
        applyFlight(progress:0)
    }
    @objc private func advanceFlight() {
        let progress=min(1,(CACurrentMediaTime()-flightStart)/0.95)
        applyFlight(progress:progress)
        if progress>=1 {
            let leaving=flightExitPose != nil
            let span=2*Double(distance)*tan(Double(cameraNode.camera?.fieldOfView ?? 43) * .pi/360)
            let viewport=WorldCameraTransition.viewport(center:coordinate(target),span:span,aspect:Double(bounds.width/max(1,bounds.height)))
            stopFlight()
            if leaving { onAtlas?(viewport) } else { updateCamera() }
        }
    }
    private func applyFlight(progress: Double) {
        let pose:WorldCameraTransition.Pose
        if let span=flightEntrySpan { pose=WorldCameraTransition.entry(span:span,progress:progress) }
        else if let start=flightExitPose { pose=WorldCameraTransition.exit(from:start,progress:progress) }
        else { return }
        distance=Float(pose.distance);pitch=Float(pose.pitch);yaw=Float(pose.yaw);cameraNode.camera?.fieldOfView=CGFloat(pose.fieldOfView)
        updateCamera(notify:false)
    }
    private func scheduleLabels() {
        setNeedsDisplay()
        // Only placement/decluttering waits for the gesture to settle. The
        // labels themselves are rendered with the terrain on every frame.
        labelNotification?.cancel()
        let next = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.labelNotification = nil
            self.placeLabels.select(in:self,focus:self.target)
        }
        labelNotification = next
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:next)
    }
    private func updateRouteOverlay() {
        guard let source, let device = device ?? MTLCreateSystemDefaultDevice() else { return }
        if routePoints.isEmpty && routeSegments.isEmpty && routeWaypoints.isEmpty && routeOverlays.isEmpty { return }
        let paths = (routeSegments.isEmpty ? [routePoints] : routeSegments).map { $0.map(\.coordinate) }
        let tiles = WorldRouteOverlay.build(source:source,paths:paths,waypoints:routeWaypoints.map { $0.point.coordinate })
        routeOverlays = tiles.compactMapValues { WorldRouteOverlay.binding($0,device:device) }
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        for (id,node) in nodes {
            guard let material=node.geometry?.firstMaterial else { continue }
            if let overlay=routeOverlays[id] { overlay.apply(to:material,pixelScale:Float(contentScaleFactor)) }
            else {
                material.shaderModifiers=nil
                material.setValue(nil,forKey:"ridgeRouteRecords")
            }
        }
        SCNTransaction.commit()
        setNeedsDisplay()
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
        if gesture.state == .began { interruptFlight(); rebaseDragPlane() }
        let d=gesture.translation(in:self), current=gesture.location(in:self)
        gesture.setTranslation(.zero,in:self)
        let previous=CGPoint(x:current.x-d.x,y:current.y-d.y)
        if let a=groundPoint(previous),let b=groundPoint(current) { target += a-b; updateCamera() }
    }
    @objc private func transformMap(_ gesture: WorldTwoFingerGesture) {
        guard gesture.state == .began || gesture.state == .changed else {
            moveGesture.isEnabled = true; return
        }
        if gesture.state == .began { interruptFlight(); moveGesture.isEnabled = false; rebaseDragPlane() }
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
