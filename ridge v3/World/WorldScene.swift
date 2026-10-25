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
    var onEntryStarted: ((Date)->Void)? = nil
    var overheadViewport:GeoBounds? = nil
    var onSurfaceReady:(([GeoBounds])->Void)? = nil
    var onEntrySurfaceReady:((GeoBounds)->Void)? = nil
    var atlasRequest: UUID? = nil
    var tour: WorldRouteTour
    var tourConfiguration: WorldRouteTour.Configuration
    func makeUIView(context: Context) -> WorldSceneView {
        let view = WorldSceneView(); view.model = model; view.onTap = onTap; view.onAtlas = onAtlas; view.onEntryStarted=onEntryStarted;view.overheadViewport=overheadViewport;view.onSurfaceReady=onSurfaceReady;view.onEntrySurfaceReady=onEntrySurfaceReady; view.tour = tour
        view.refresh(route: route, segments: segments, waypoints: waypoints, command: command, atlasRequest:atlasRequest); return view
    }
    func updateUIView(_ view: WorldSceneView, context: Context) {
        view.model = model; view.onTap = onTap; view.onAtlas = onAtlas; view.onEntryStarted=onEntryStarted;view.overheadViewport=overheadViewport;view.onSurfaceReady=onSurfaceReady;view.onEntrySurfaceReady=onEntrySurfaceReady; view.tour = tour
        view.refresh(route: route, segments: segments, waypoints: waypoints, command: command, atlasRequest:atlasRequest)
    }
    static func dismantleUIView(_ view: WorldSceneView, coordinator: ()) { view.stopTour(restore:false); view.stopFlight(); view.cancelCameraNotification(); view.scene = nil; view.model = nil }
}

/// The native renderer is deliberately independent of downloads. Nodes are
/// replaced a tile at a time, and the camera survives every replacement.
final class WorldSceneView: SCNView,SCNSceneRendererDelegate {
    weak var model: WorldModel?
    weak var tour: WorldRouteTour?
    private var tourLink: CADisplayLink?
    private var tourSavedPose: TerrainCameraPose?
    private var tourDistance = 0.0
    private let cameraRig=WorldCameraRig()
    private var cinematicLook=WorldCinematicLook()
    private var tourBasePose: WorldRouteTourCamera.Pose?
    private var flightArrivalTime=0.0
    private var flightArrival:WorldFlightArrival?
    private var flightPlan:WorldFlightPlan?
    private var flightTerrain:WorldFlightTerrain?
    private var flightTime=0.0
    private var flightPlayback=WorldFlightPlayback()
    private var flightGlide=WorldFlightGlide()
    private var flightSample:WorldFlightPlan.Sample?
    private var flightSession:UUID?
    private var flightPreparation:Task<Void,Never>?
    private var flightPreparationID=UUID()
    private var preparingClearance:Double?
    private var preparingSpeed:Double?
    private var preparingMotion:Bool?
    private var flightPreparationFailed=false
    private var tourLookTime=0.0
    private var tourLastTime = 0.0
    private var tourLastReport = 0.0
    private var tourLastTerrainRequest = 0.0
    private var tourLastHeightReport = 0.0
    private var tourLastLabels = 0.0
    private var tourRenderScale: CGFloat?
    private var tourCoverageRevision = -1
    private var tourCoverageCells: [GeoBounds] = []
    private var tourSeekRevision = -1
    var onTap: ((GeoPoint) -> Void)?
    var onAtlas: ((GeoBounds) -> Void)?
    var onEntryStarted: ((Date)->Void)?
    var overheadViewport:GeoBounds?
    var onSurfaceReady:(([GeoBounds])->Void)?
    var onEntrySurfaceReady:((GeoBounds)->Void)?
    private var pendingEntrySurface:UUID?
    private var reportedEntrySurface:UUID?
    private var reportedSurface=false
    private var reportedCoverage:[GeoBounds]=[]
    private var pendingSurfaceCoverage:[GeoBounds]=[]
    private var source: WorldSource?
    private var overview: WorldOverview?
    private var nodes: [String: SCNNode] = [:]
    private var distantNode = SCNNode()
    private var seamNode = SCNNode()
    private var offlineBoundaryNode = SCNNode()
    private var offlineBoundaryEdges: [WorldOfflineCoverage.Edge] = []
    private var offlineBoundaryCenter: GeoPoint?
    private var distantID: UUID?
    private var contextCoverage: Set<String>?
    private var contextKeys: [String:String] = [:]
    private var retiringNodes: [String:(String,SCNNode)] = [:]
    private var contextMask: Task<Void,Never>?
    private var contextMaskPending = false
    private var contextMaskGeneration = 0
    private var tileIndex = WorldTileIndex(tiles:[])
    private var cameraNotification: DispatchWorkItem?
    private var labelNotification: DispatchWorkItem?
    private let placeLabels = WorldPlaceLabels()
    private var uploadNotification: DispatchWorkItem?
    private var lastTerrainUpload = 0.0
    private var uploadQueue: [String] = []
    private var queuedUploads = Set<String>()
    private var reconciledTileIDs = Set<String>()
    private var coarse: [String: SCNGeometry] = [:]
    private var applied: [String: WorldTileRequest] = [:]
    private var flightLink: CADisplayLink?
    private var flightStart = 0.0
    private var flightEntrySpan: Double?
    private var flightExitPose: WorldCameraTransition.Pose?
    private var lastAtlasRequest: UUID?
    private var revision = -1
    private struct DeferredRefresh {
        var route:[RoutePoint];var segments:[[RoutePoint]];var waypoints:[RouteWaypoint]
        var command:TerrainCameraCommand;var atlasRequest:UUID?
    }
    private var deferredRefresh:DeferredRefresh?
    private var cameraNode = SCNNode()
    private var target = SIMD3<Float>(0,0,0)
    private var distance: Float = 6000
    private var yaw: Float = 0
    private var pitch: Float = 0.85
    private var navigationGesture: WorldNavigationGesture!
    private var routeOverlays: [String: WorldRouteOverlay.Binding] = [:]
    private var routePoints: [RoutePoint] = []
    private var routeSegments: [[RoutePoint]] = []
    private var routeWaypoints: [RouteWaypoint] = []
    private var lastCommand: TerrainCameraCommand?

    init() {
        super.init(frame: .zero, options: nil)
        antialiasingMode = .multisampling4X; preferredFramesPerSecond = 60
        rendersContinuously = false; autoenablesDefaultLighting = false; backgroundColor = UIColor(red: 0.76, green: 0.86, blue: 0.91, alpha: 1)
        navigationGesture = WorldNavigationGesture(target:self,action:#selector(navigateWorld(_:)))
        navigationGesture.onContactChanged = { [weak self] touching in self?.navigationContactChanged(touching) }
        let tap = UITapGestureRecognizer(target:self,action:#selector(tap(_:)))
        tap.require(toFail:navigationGesture)
        addGestureRecognizer(navigationGesture);addGestureRecognizer(tap)
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = "Terrain map"; accessibilityHint = "Drag to move. Pinch to zoom. Drag two fingers left or right to turn, up or down to tilt. The horizon stays level."
    }
    required init?(coder: NSCoder) { nil }
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
    private var sceneUpdatesDeferred:Bool { !cameraRig.touring && (navigationGesture.isInteracting || flightEntrySpan != nil) }
    func refresh(route: [RoutePoint], segments: [[RoutePoint]], waypoints: [RouteWaypoint], command: TerrainCameraCommand, atlasRequest: UUID?) {
        if sceneUpdatesDeferred {
            deferredRefresh=DeferredRefresh(route:route,segments:segments,waypoints:waypoints,command:command,atlasRequest:atlasRequest)
            return
        }
        guard let model, let next = model.source, let overview = model.overview else { return }
        let sourceChanged = source?.revision != next.revision || source?.id != next.id
        if sourceChanged {
            let previousFrame=source?.frame
            let firstScene = source == nil || previousFrame != next.frame
            if let previousFrame,cameraRig.touring,previousFrame != next.frame {
                cameraRig.rebaseTour(from:previousFrame,to:next.frame,on:cameraNode)
                if let held=cameraRig.heldPose { tourBasePose = .init(eye:held.eye,look:held.look,focus:model.center) }
            }
            source = next; self.overview = overview
            if firstScene { buildScene(next, overview:overview) }
            else { reconcileTerrain(next,overview:overview); updateCamera(notify:false) }
        }
        if let distant = model.distantTerrain, distantID != distant.id {
            distantID = distant.id; contextCoverage=nil
            distantNode.categoryBitMask = 4 // Context cannot create route waypoints.
            if distantNode.parent == nil { scene?.rootNode.addChildNode(distantNode);seamNode.categoryBitMask=4;scene?.rootNode.addChildNode(seamNode) }
            if nodes.isEmpty {
                let geometry=distant.geometry(excluding:[])
                let material=SCNMaterial();material.lightingModel = .constant
                material.diffuse.contents=distant.image;material.diffuse.mipFilter = .linear
                material.diffuse.maxAnisotropy=4;material.isDoubleSided=true
                geometry.materials=[material];distantNode.geometry=geometry;contextCoverage=[]
            }
            scheduleContextMask()
        }
        if revision != model.revision {
            revision = model.revision
            let changedIDs = model.changedTileIDs.union(sourceChanged ? reconciledTileIDs : [])
            let changed = next.tiles.filter { changedIDs.contains($0.id) }.sorted { $0.mesh.bounds.center.distance(to:model.center) > $1.mesh.bounds.center.distance(to:model.center) }.map(\.id)
            model.changedTileIDs.removeAll(keepingCapacity:true)
            enqueueTerrain(changed)
        }
        if !cameraRig.touring { updateOfflineBoundary(force:sourceChanged) }
        if sourceChanged || route != routePoints || segments != routeSegments || waypoints != routeWaypoints { routeSegments = segments; routePoints = route; routeWaypoints = waypoints; updateRouteOverlay() }
        if let overheadViewport {
            delegate=self
            lastCommand=command;lastAtlasRequest=atlasRequest
            applyOverhead(overheadViewport);return
        }
        delegate=nil
        if reportedSurface || reportedEntrySurface != nil,let span=model.entrySpan {
            model.entrySpan=nil;beginEntry(span:span)
        }
        syncTour()
        if lastCommand != command {
            let initial = lastCommand == nil
            lastCommand = command
            if !initial {
            tour?.close(); stopTour(restore:true); interruptFlight()
            switch command.action {
            case .focus(let point): target = local(point); distance = min(distance, 2000); updateCamera()
            case .zoomIn: distance /= 1.5; updateCamera()
            case .zoomOut: distance *= 1.5; updateCamera()
            case .fitRoute:
                let points=routePoints.map(\.coordinate).filter(\.isValid)
                if let first=points.first {
                    let region=GeoBounds(minLatitude:points.map(\.latitude).min() ?? first.latitude,
                        minLongitude:points.map(\.longitude).min() ?? first.longitude,
                        maxLatitude:points.map(\.latitude).max() ?? first.latitude,
                        maxLongitude:points.map(\.longitude).max() ?? first.longitude)
                    target=local(region.center);yaw=0;pitch=1.1
                    let span=max(300,max(region.depthMeters,region.widthMeters/Double(max(0.3,bounds.width/max(1,bounds.height)))))
                    distance=Float(min(11000,span*0.7/tan(43 * .pi/360)/sin(Double(pitch))))
                    updateCamera()
                }
            case .north: yaw=0; updateCamera()
            case .restore(let pose):
                target=local(pose.target);target.y=Float(pose.targetElevationMeters)
                distance=Float(pose.distanceMeters);yaw=pose.yaw;pitch=pose.pitch;updateCamera()
            case .overhead: pitch = 1.49; yaw = 0; updateCamera()
            case .home: target = local(next.bounds.center); distance = 6000; pitch = 0.85; yaw = 0; updateCamera()
            default: break
            }
            }
        }
        if atlasRequest != lastAtlasRequest { lastAtlasRequest=atlasRequest; if atlasRequest != nil { beginExit() } }
        if let point = model.requestFocus { tour?.close(); stopTour(restore:true); interruptFlight(); DispatchQueue.main.async { model.requestFocus = nil }; target = local(point); distance = 1500; updateCamera() }
    }
    private func material(_ image: CGImage?, tileID: String) -> SCNMaterial {
        let m=WorldPreview.material(image)
        m.diffuse.maxAnisotropy=cameraRig.touring ? 4 : 16
        routeOverlays[tileID]?.apply(to:m,pixelScale:Float(contentScaleFactor))
        return m
    }
    private func buildScene(_ source: WorldSource, overview: WorldOverview) {
        pendingEntrySurface=nil;reportedEntrySurface=nil;reportedSurface=false;reportedCoverage=[];pendingSurfaceCoverage=[]
        let scene = SCNScene(); scene.background.contents = backgroundColor
        scene.fogColor = backgroundColor; scene.fogDensityExponent = 1
        cancelCameraNotification()
        distantID=nil; distantNode.removeFromParentNode();seamNode.removeFromParentNode();distantNode=SCNNode();seamNode=SCNNode();retiringNodes=[:]; contextKeys=[:]
        offlineBoundaryNode=SCNNode();offlineBoundaryNode.categoryBitMask=8;offlineBoundaryNode.castsShadow=false
        scene.rootNode.addChildNode(offlineBoundaryNode);offlineBoundaryCenter=nil;offlineBoundaryEdges=[]
        self.scene = scene; nodes = [:]; coarse = [:]; applied = [:]; tileIndex = WorldTileIndex(tiles:[]); routeOverlays = [:]
        if cameraRig.touring {
            cameraNode.removeFromParentNode();cameraRig.restoreTour(on:cameraNode)
        } else {
            cameraNode = SCNNode(); cameraNode.camera = SCNCamera(); cameraNode.camera?.fieldOfView = 43
            cameraNode.camera?.zNear = 2; cameraNode.camera?.zFar = 60000; cameraNode.camera?.wantsHDR = false;cameraNode.camera?.projectionDirection = .vertical
        }
        scene.rootNode.addChildNode(cameraNode); pointOfView = cameraNode
        WorldPreview.installLighting(in:scene)
        reconcileTerrain(source,overview:overview)
        target = local(model?.center ?? source.bounds.center); distance = Float(model?.distance ?? 6000)
        if let pose = model?.cameraPose, source.bounds.contains(pose.target) {
            target = local(pose.target); target.y = Float(pose.targetElevationMeters)
            distance = Float(pose.distanceMeters); yaw = pose.yaw; pitch = pose.pitch
        }
        if cameraRig.touring {
            model?.entrySpan=nil;cameraRig.restoreTour(on:cameraNode)
        } else if let span=model?.entrySpan {
            model?.entrySpan=nil;beginEntry(span:span)
        } else { updateCamera() }
    }
    private func reconcileTerrain(_ source: WorldSource, overview: WorldOverview) {
        guard scene != nil else { return }
        reconciledTileIDs.removeAll(keepingCapacity:true)
        tileIndex = WorldTileIndex(tiles:source.tiles)
        let previousContextKeys=contextKeys
        contextKeys = Dictionary(uniqueKeysWithValues:source.tiles.compactMap { tile in WorldDistantTerrain.key(for:tile.mesh.bounds).map { (tile.id,$0) } })
        let keep = Set(source.tiles.map(\.id))
        uploadQueue.removeAll { !keep.contains($0) }; queuedUploads.formIntersection(keep)
        for id in Array(coarse.keys) where !keep.contains(id) {
            if let node=nodes.removeValue(forKey:id) {
                if distantNode.geometry != nil,let key=previousContextKeys[id] { retiringNodes[id]=(key,node) }
                else { node.removeFromParentNode() }
            }
            coarse.removeValue(forKey:id); applied.removeValue(forKey:id); routeOverlays.removeValue(forKey:id)
        }
        for tile in source.tiles {
            guard let g = model?.backdrop?.geometries[tile.id] else { continue }
            if coarse[tile.id] !== g { coarse[tile.id] = g; applied.removeValue(forKey:tile.id); reconciledTileIDs.insert(tile.id) }
        }
        let focus = model?.center ?? source.bounds.center
        let places = source.places.filter { $0.kind == "peak" }.sorted {
            $0.coordinate.distance(to:focus) < $1.coordinate.distance(to:focus)
        }.prefix(60)
        scheduleContextMask()
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
        guard !sceneUpdatesDeferred else { return }
        guard let model, let scene else { return }
        let began = CACurrentMediaTime()
        if cameraRig.touring,!uploadQueue.isEmpty {
            let wait=1.0/15-(began-lastTerrainUpload)
            if wait>0 {
                let next=DispatchWorkItem { [weak self] in self?.uploadTerrain() }
                uploadNotification=next;DispatchQueue.main.asyncAfter(deadline:.now()+wait,execute:next)
                return
            }
        }
        lastTerrainUpload=began
        var count = 0, coverageChanged = false
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        while let id = uploadQueue.popLast() {
            queuedUploads.remove(id)
            guard let fallback = coarse[id], let prepared = model.preparedTile(id) else { continue }
            if applied[id] != prepared.request || nodes[id] == nil {
                let geometry = prepared.geometry ?? fallback
                geometry.materials = [material(prepared.image,tileID:id)]
                let node: SCNNode
                if let old = nodes[id] { node = old }
                else {
                    coverageChanged=true
                    if let retained=retiringNodes.removeValue(forKey:id) { node=retained.1 }
                    else { node=SCNNode();node.isHidden=distantNode.geometry != nil && contextKeys[id] != nil }
                    node.categoryBitMask=1;node.name=id;nodes[id]=node
                    if node.parent == nil { scene.rootNode.addChildNode(node) }
                }
                node.geometry = geometry; applied[id] = prepared.request
                if prepared.geometry != nil { fallback.materials = [] }
            }
            count += 1
            // Keep GPU resource creation out of most flight frames. A single
            // smaller page replaces the existing fallback without a burst.
            if count >= (cameraRig.touring ? 1 : 24) || CACurrentMediaTime()-began >= 0.004 { break }
        }
        SCNTransaction.commit(); setNeedsDisplay()
        if tourSavedPose != nil && tour?.isPlaying != true { applyTourCamera() }
        if coverageChanged { scheduleContextMask() }
        if !uploadQueue.isEmpty {
            let next = DispatchWorkItem { [weak self] in self?.uploadTerrain() }
            uploadNotification = next
            DispatchQueue.main.asyncAfter(deadline:.now()+(cameraRig.touring ? 1.0/15 : 1.0/60),execute:next)
        }
    }
    private func scheduleContextMask() {
        contextMaskPending = true
        guard contextMask == nil, model?.distantTerrain != nil else { return }
        let maskGeneration=contextMaskGeneration
        contextMask = Task { [weak self] in
            guard let self else { return }
            defer {
                if maskGeneration==contextMaskGeneration {
                    contextMask=nil
                    if contextMaskPending && !Task.isCancelled { scheduleContextMask() }
                }
            }
            while contextMaskPending && !Task.isCancelled {
                if sceneUpdatesDeferred {
                    try? await Task.sleep(nanoseconds:100_000_000);continue
                }
                contextMaskPending=false
                guard let distant=model?.distantTerrain else { return }
                let covered=Set(nodes.keys.compactMap { contextKeys[$0] })
                if contextCoverage==covered && distantNode.geometry != nil { continue }
                let boundaries=nodes.compactMap { id,node -> WorldDistantTerrain.Boundary? in
                    guard let key=contextKeys[id],let geometry=node.geometry,(0..<4).contains(where:{ !covered.contains(WorldDistantTerrain.neighbor(key,edge:$0)) }) else { return nil }
                    return .init(key:key,geometry:geometry)
                }
                let preparation=Task.detached(priority:.utility) { (distant.geometry(excluding:covered),distant.seams(boundaries,covered:covered)) }
                let (geometry,seams)=await preparation.value
                guard !Task.isCancelled, distantID==distant.id else { return }
                if sceneUpdatesDeferred { contextMaskPending=true;continue }
                let current=Set(nodes.keys.compactMap { contextKeys[$0] })
                if current != covered { contextMaskPending=true }
                let material=SCNMaterial();material.lightingModel = .constant
                material.diffuse.contents=distant.image;material.diffuse.mipFilter = .linear
                material.diffuse.maxAnisotropy=4; material.isDoubleSided=true
                SCNTransaction.begin();SCNTransaction.animationDuration=0
                geometry.materials=[material];distantNode.geometry=geometry;seams?.materials=[material];seamNode.geometry=seams;contextCoverage=covered
                for (id,node) in nodes { if let key=contextKeys[id] { node.isHidden = !covered.contains(key) } }
                for (id,old) in Array(retiringNodes) where !covered.contains(old.0) { old.1.removeFromParentNode();retiringNodes.removeValue(forKey:id) }
                SCNTransaction.commit();setNeedsDisplay()
                try? await Task.sleep(nanoseconds:100_000_000)
            }
        }
    }
    private func updateOfflineBoundary(force: Bool = false) {
        guard let model, let source else { return }
        let focus=coordinate(target)
        if !sceneUpdatesDeferred && (force || offlineBoundaryEdges != model.offlineEdges || offlineBoundaryCenter == nil || offlineBoundaryCenter!.distance(to:focus)>250) {
            offlineBoundaryEdges=model.offlineEdges;offlineBoundaryCenter=focus
            offlineBoundaryNode.geometry=WorldOfflineBoundary.geometry(edges:offlineBoundaryEdges,focus:focus,frame:source.frame,elevation:height)
        }
        let visibility=max(0,min(1,(12000-distance)/4000))
        offlineBoundaryNode.geometry?.firstMaterial?.setValue(NSValue(scnVector4:SCNVector4(target.x,target.z,visibility,0)),forKey:"ridgeBoundaryFocus")
    }
    nonisolated func renderer(_ renderer:any SCNSceneRenderer,didRenderScene scene:SCNScene,atTime time:TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self,self.overheadViewport != nil,let source=self.source else { return }
            // The continuous bundled mesh can hand off immediately. Fine tile
            // coverage still controls the sharper top-down atlas replacement.
            if let distant=self.model?.distantTerrain,self.distantID==distant.id,
               self.distantNode.geometry != nil,self.reportedEntrySurface != distant.id {
                if self.pendingEntrySurface==distant.id {
                    self.reportedEntrySurface=distant.id
                    self.onEntrySurfaceReady?(distant.bounds)
                } else { self.pendingEntrySurface=distant.id;self.setNeedsDisplay() }
            }
            // Only visible, textured local terrain counts. The low-resolution
            // distant horizon cannot certify a close-map handoff.
            let coverage=source.tiles.compactMap { tile -> GeoBounds? in
                guard let request=self.applied[tile.id],request.pixels>=WorldMapSurface.minimumPixels,
                      let node=self.nodes[tile.id],!node.isHidden,node.parent != nil else { return nil }
                return tile.mesh.bounds
            }
            guard coverage != self.reportedCoverage else { return }
            // Certify a stable rendered frame, rather than nodes uploaded after
            // the render callback was queued on the main thread.
            if coverage != self.pendingSurfaceCoverage {
                self.pendingSurfaceCoverage=coverage;self.setNeedsDisplay();return
            }
            self.reportedCoverage=coverage;self.reportedSurface = !coverage.isEmpty
            self.onSurfaceReady?(coverage)
            if self.reportedEntrySurface == nil,let viewport=self.overheadViewport,WorldMapSurface.covers(viewport,tiles:coverage) {
                self.onEntrySurfaceReady?(viewport)
            }
        }
    }
    private func applyOverhead(_ viewport:GeoBounds) {
        guard source != nil else { return }
        cameraNotification?.cancel();cameraNotification=nil
        let pose=WorldCameraTransition.entry(span:viewport.depthMeters,progress:0)
        target=local(viewport.center);distance=Float(pose.distance);yaw=0;pitch=Float(pose.pitch)
        cameraNode.camera?.fieldOfView=CGFloat(pose.fieldOfView);cameraNode.camera?.zFar=max(500000,pose.distance+60000)
        let atmosphere=WorldAtmosphere.range(cameraDistance:pose.distance)
        scene?.fogStartDistance=atmosphere.start;scene?.fogEndDistance=atmosphere.end
        let eye=target+distance*SIMD3<Float>(0,sin(pitch),cos(pitch))
        cameraRig.orbit(on:cameraNode,eye:eye,look:target)
        placeLabels.scale(camera:cameraNode,viewport:bounds.size);scheduleLabels();setNeedsDisplay()
    }
    override func layoutSubviews() { super.layoutSubviews(); placeLabels.scale(camera:cameraNode,viewport:bounds.size); scheduleLabels() }
    private func updateCamera(notify: Bool = true) {
        guard !cameraRig.touring,let source else { return }
        if let overheadViewport { applyOverhead(overheadViewport);return }
        // The camera is independent of residency. Moving toward missing data
        // requests it; it never snaps back to a storage rectangle.
        distance = min(flightLink == nil ? 26000 : 300000,max(170,distance))
        cameraNode.camera?.zFar=max(60000,Double(distance)*2)
        let atmosphere = WorldAtmosphere.range(cameraDistance:Double(distance))
        scene?.fogStartDistance = atmosphere.start; scene?.fogEndDistance = atmosphere.end
        var eye = target + distance * SIMD3(sin(yaw)*cos(pitch),sin(pitch),cos(yaw)*cos(pitch))
        let point = coordinate(eye)
        if source.bounds.contains(point) { eye.y = max(eye.y,height(point)+25) }
        cameraRig.orbit(on:cameraNode,eye:eye,look:target)
        placeLabels.scale(camera:cameraNode,viewport:bounds.size)
        scheduleLabels()
        updateOfflineBoundary()
        guard notify else { return }
        model?.cameraPose = TerrainCameraPose(target: coordinate(target), targetElevationMeters: Double(target.y), yaw: yaw, pitch: pitch, distanceMeters: Double(distance))
        // Finger movement owns the frame budget. Expand the terrain window and
        // refine its working set after release, keeping the current map visible.
        guard !navigationGesture.isInteracting else { return }
        // Coalesce navigation work while keeping the actual camera at gesture
        // rate. A single queued update always consumes the latest pose.
        guard cameraNotification == nil else { return }
        let notification = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cameraNotification = nil
            guard !self.cameraRig.touring,!self.navigationGesture.isInteracting,self.scene != nil, let pose = self.model?.cameraPose else { return }
            self.model?.update(center:pose.target,distance:pose.distanceMeters)
            if self.distance > 12000 && self.flightLink == nil && self.tourSavedPose == nil && !self.navigationGesture.isInteracting { self.beginExit() }
        }
        cameraNotification = notification
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:notification)
    }
    func cancelCameraNotification() {
        deferredRefresh=nil
        contextMaskGeneration+=1;contextMask?.cancel(); contextMask=nil; contextMaskPending=false
        cameraNotification?.cancel(); cameraNotification = nil
        labelNotification?.cancel(); labelNotification = nil
        uploadNotification?.cancel(); uploadNotification = nil
        uploadQueue = []; queuedUploads = []
    }
    func stopFlight() {
        flightLink?.invalidate();flightLink=nil;flightEntrySpan=nil;flightExitPose=nil
        if !cameraRig.touring { rendersContinuously=false }
        DispatchQueue.main.async { [weak self] in self?.resumeSceneUpdates() }
    }
    private func resumeSceneUpdates() {
        guard scene != nil,!sceneUpdatesDeferred else { return }
        if let value=deferredRefresh {
            deferredRefresh=nil
            refresh(route:value.route,segments:value.segments,waypoints:value.waypoints,command:value.command,atlasRequest:value.atlasRequest)
        }
        uploadTerrain();scheduleLabels();scheduleContextMask()
    }
    private func interruptFlight() {
        guard flightLink != nil else { return }
        let field=cameraNode.camera?.fieldOfView ?? 43
        distance *= Float(tan(field * .pi/360)/tan(43 * .pi/360))
        stopFlight();cameraNode.camera?.fieldOfView=43
        updateCamera(notify:false)
    }
    private func beginEntry(span: Double) {
        guard !cameraRig.touring else { return }
        stopFlight()
        if UIAccessibility.isReduceMotionEnabled {
            let pose=WorldCameraTransition.entry(span:span,progress:1)
            distance=Float(pose.distance);pitch=Float(pose.pitch);yaw=0;updateCamera();return
        }
        flightEntrySpan=span;startFlight()
        model?.update(center:coordinate(target),distance:WorldCameraTransition.entry(span:span,progress:1).distance)
    }
    private func beginExit() {
        tour?.close(); stopTour(restore:true)
        guard flightExitPose == nil else { return }
        interruptFlight()
        let pose=WorldCameraTransition.Pose(distance:Double(distance),pitch:Double(pitch),yaw:Double(yaw),fieldOfView:Double(cameraNode.camera?.fieldOfView ?? 43))
        if UIAccessibility.isReduceMotionEnabled {
            onAtlas?(WorldCameraTransition.viewport(center:coordinate(target),span:max(WorldCameraTransition.exitSpan,pose.span),aspect:Double(bounds.width/max(1,bounds.height))));return
        }
        flightExitPose=pose;startFlight()
    }
    private func startFlight() {
        flightStart=CACurrentMediaTime();cameraNode.camera?.zFar=500000
        if flightEntrySpan != nil {
            let startedAt=Date()
            DispatchQueue.main.async { [weak self] in
                guard let self,self.flightEntrySpan != nil else { return }
                self.onEntryStarted?(startedAt)
            }
        }
        let link=CADisplayLink(target:self,selector:#selector(advanceFlight));link.preferredFramesPerSecond=60
        flightLink=link;rendersContinuously=true;link.add(to:.main,forMode:.common)
        applyFlight(progress:0)
    }
    @objc private func advanceFlight() {
        guard !cameraRig.touring else { stopFlight();return }
        let duration=flightEntrySpan != nil ? WorldCameraTransition.entryDuration : WorldCameraTransition.exitDuration
        let progress=min(1,(CACurrentMediaTime()-flightStart)/duration)
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
        guard !cameraRig.touring else { return }
        let pose:WorldCameraTransition.Pose
        if let span=flightEntrySpan { pose=WorldCameraTransition.entry(span:span,progress:progress) }
        else if let start=flightExitPose { pose=WorldCameraTransition.exit(from:start,progress:progress) }
        else { return }
        distance=Float(pose.distance);pitch=Float(pose.pitch);yaw=Float(pose.yaw);cameraNode.camera?.fieldOfView=CGFloat(pose.fieldOfView)
        updateCamera(notify:false)
    }
    private func syncTour() {
        guard let tour,tour.isPresented,let path=tour.path else { stopTour(restore:true);return }
        let changed=tourSavedPose == nil || tourSeekRevision != tour.seekRevision
        if tourSavedPose == nil {
            interruptFlight()
            cameraNotification?.cancel();cameraNotification=nil
            tourSavedPose=TerrainCameraPose(target:coordinate(target),targetElevationMeters:Double(target.y),yaw:yaw,pitch:pitch,distanceMeters:Double(distance))
            cameraRig.beginTour(on:cameraNode)
            tourCoverageRevision = -1
            tourRenderScale=contentScaleFactor
            contentScaleFactor=min(2,contentScaleFactor)
            antialiasingMode = .multisampling2X
            offlineBoundaryNode.isHidden=true
            tourLastHeightReport=0;tourLastLabels=0
            tourSeekRevision = -1;tourLastTerrainRequest=0;tourLookTime=0
        }
        if tourSeekRevision != tour.seekRevision {
            tourSeekRevision=tour.seekRevision;tourDistance=tour.progress*path.length
            if flightPlan?.hasSpeedTransition == true { flightPlan=nil }
            flightArrival=nil;flightArrivalTime=0;flightPlayback.reset(speed:tour.metersPerSecond);cinematicLook.reset();flightGlide.reset();flightSample=nil;flightTime=flightPlan?.time(at:tourDistance) ?? 0
        }
        if !tour.isPlaying { cinematicLook.reset() }
        model?.setClosePreviewDetail(true)
        prepareFlightPlan()
        // Hold the real browsing pose while preparing. A speculative approach
        // used to move the camera before the final path/height was available.
        // Terrain/UI notifications can arrive between display frames. Keep a
        // single camera sample per playback frame instead of interleaving them.
        if changed || tourLink == nil { applyTourCamera() }
        ensureTourFrames()
    }
    private func prepareFlightPlan() {
        guard let tour,let path=tour.path,let corridor=tour.corridor,let source,let model else { return }
        if flightSession != tour.sessionID {
            flightPreparation?.cancel();flightPreparation=nil;preparingClearance=nil;preparingSpeed=nil;preparingMotion=nil
            flightArrival=nil;flightArrivalTime=0;flightPlan=nil;flightTerrain=nil;flightGlide.reset();flightSample=nil;flightSession=tour.sessionID
            flightPreparationFailed=false
        }
        let clearance=min(1000,max(5,tour.clearance))
        let speed=WorldRouteTour.preparedSpeed,motion=UIAccessibility.isReduceMotionEnabled,cornerLift=WorldRouteTour.fpvCornerLift
        if flightPlan?.cruiseSpeed==speed,flightPlan?.reduceMotion==motion,flightPlan?.clearance==clearance { return }
        if flightPreparation != nil,preparingSpeed==speed,preparingMotion==motion,preparingClearance==clearance { return }
        if flightPreparationFailed,!tour.isPlaying { return }
        flightPreparationFailed=false
        flightPreparation?.cancel()
        let token=UUID(),session=tour.sessionID,frame=source.frame,cached=flightTerrain
        flightPreparationID=token;preparingClearance=clearance;preparingSpeed=speed;preparingMotion=motion
        tour.isPreparing=true;tour.message="Preparing flight plan…"
        flightPreparation=Task { [weak self] in
            do {
                let terrain:WorldFlightTerrain
                if let cached { terrain=cached } else {
                    let points=WorldFlightTerrain.clearancePoints(corridor:corridor)
                    let (lanes,places)=try await model.prepareFlightElevations(points)
                    let stations=WorldFlightTerrain.distances(length:corridor.length)
                    let heights=stations.indices.map { lanes[$0*5+2] }
                    let clearanceHeights=stations.indices.map { i in lanes[(i*5)..<(i*5+5)].compactMap { $0 }.max() }
                    terrain=WorldFlightTerrain(path:path,corridor:corridor,heights:heights,places:places,clearanceHeights:clearanceHeights)
                }
                try Task.checkCancellation()
                let build=Task.detached(priority:.userInitiated) {
                    try WorldFlightPlan(path:path,corridor:corridor,terrain:terrain,frame:frame,cruiseSpeed:speed,reduceMotion:motion,clearance:clearance,cornerLift:cornerLift)
                }
                let plan=try await withTaskCancellationHandler(operation:{try await build.value},onCancel:{build.cancel()})
                guard let self,self.flightPreparationID==token,self.tour?.sessionID==session,self.tour?.isPresented==true,!Task.isCancelled else { return }
                self.flightTerrain=terrain;self.flightArrival=nil;self.flightPlan=plan;self.flightTime=plan.time(at:self.tourDistance)
                self.flightGlide.reset();self.flightSample=nil
                self.flightPreparation=nil;self.preparingClearance=nil;self.preparingSpeed=nil;self.preparingMotion=nil
                self.tour?.isPreparing=false;self.tour?.message=nil
                self.applyTourCamera();self.ensureTourFrames()
            } catch {
                guard let self,self.flightPreparationID==token,!Task.isCancelled else { return }
                self.flightPreparation=nil;self.preparingClearance=nil;self.preparingSpeed=nil;self.preparingMotion=nil
                self.flightPreparationFailed=true
                self.tour?.isPreparing=false;self.tour?.finishEntry();self.tour?.pause()
                self.tour?.message="Couldn’t prepare this flight from saved terrain. Check the downloaded map and try Preview again."
            }
        }
    }
    private func ensureTourFrames() {
        guard flightPlan != nil,let tour,tour.isPresented,tour.isPlaying || (tour.isEntering && tour.isRevealing && tour.progress>=1) else {
            tourLink?.invalidate();tourLink=nil;rendersContinuously=false;return
        }
        guard tourLink == nil else { return }
        tourLastTime=0;tourLastReport=0
        let link=CADisplayLink(target:self,selector:#selector(advanceTour(_:)))
        link.preferredFramesPerSecond=60;tourLink=link;rendersContinuously=true;link.add(to:.main,forMode:.common)
    }
    func stopTour(restore: Bool) {
        model?.setClosePreviewDetail(false)
        flightPreparation?.cancel();flightPreparation=nil;flightPreparationID=UUID();preparingClearance=nil;preparingSpeed=nil;preparingMotion=nil
        flightArrival=nil;flightArrivalTime=0;flightPlan=nil;flightTerrain=nil;flightGlide.reset();flightSample=nil;flightSession=nil;flightPreparationFailed=false;tour?.isPreparing=false
        tourLink?.invalidate();tourLink=nil;cameraRig.endTour()
        guard let saved=tourSavedPose else { return }
        tourSavedPose=nil;tourBasePose=nil;cinematicLook.reset()
        rendersContinuously=false
        if let scale=tourRenderScale { contentScaleFactor=scale;tourRenderScale=nil }
        antialiasingMode = .multisampling4X;offlineBoundaryNode.isHidden=false
        cameraNode.camera?.fieldOfView=43;cameraNode.camera?.zNear=2
        if restore,source != nil {
            target=local(saved.target);target.y=Float(saved.targetElevationMeters)
            distance=Float(saved.distanceMeters);yaw=saved.yaw;pitch=saved.pitch;updateCamera()
        }
    }
    @objc private func advanceTour(_ link:CADisplayLink) {
        guard let tour,tour.isPresented,let path=tour.path else { syncTour();return }
        let now=link.targetTimestamp
        let elapsed=max(0,min(0.1,tourLastTime>0 ? now-tourLastTime : link.targetTimestamp-link.timestamp))
        tourLastTime=now
        if tour.isEntering && tour.isRevealing && (tour.isPlaying || tour.progress>=1),flightPlan != nil {
            // The entry and route clocks never wait for visual detail. The
            // prepared plan already contains the complete elevation snapshot.
            flightArrivalTime+=elapsed
            if abs(tour.entryElapsed-flightArrivalTime)>=1.0/30 { tour.reportEntry(elapsed:flightArrivalTime) }
        }
        cinematicLook.advance(seconds:elapsed)
        if tour.canAdvance {
            guard let plan=flightPlan else { return }
            let clockStep=flightPlayback.advance(seconds:elapsed,requested:tour.metersPerSecond,preparedSpeed:plan.cruiseSpeed)
            let nextTime=min(plan.duration,flightTime+clockStep),reference=plan.sample(time:nextTime)
            var glide=flightGlide
            // Integrate once per playback frame, in the stable plan frame.
            // Rendering notifications and streaming must never advance flight.
            let scale=elapsed>0 ? (nextTime-flightTime)/elapsed : 0
            let sample=glide.advance(reference:reference,yaw:cinematicLook.yaw,pitch:cinematicLook.pitch,
                speedScale:scale,seconds:elapsed,frame:plan.frame,reduceMotion:plan.reduceMotion)
            let next=sample.routeDistance,point=sample.pose.focus
            if !hasTourCoverage(point) || !hasTourCoverage(path.sample(at:next).coordinate) {
                tour.message="Preview paused at the edge of your downloaded map. Download this area to continue."
                tour.pause()
            } else {
                let previous=flightSample ?? plan.sample(time:flightTime)
                let measured=elapsed>0 ? Double(simd_distance(previous.pose.eye,sample.pose.eye))/elapsed : 0
                flightGlide=glide;flightSample=sample
                flightTime=nextTime;tourDistance=next
                if now-tourLastReport>=0.1 || next>=path.length {
                    tourLastReport=now;tour.reportSpeed(measured);tour.report(distance:next)
                }
            }
        }
        applyTourCamera(seconds:elapsed);ensureTourFrames()
    }
    private func tourContactChanged(_ touching: Bool) {
        guard cameraRig.touring,tour?.isPresented == true,tour?.isPlaying == true,tour?.isEntering == false else { return }
        if touching { cinematicLook.begin() } else { cinematicLook.end() }
        ensureTourFrames()
    }
    private func navigateTour(_ gesture: WorldNavigationGesture) {
        guard tour?.isPlaying == true,tour?.isEntering == false,gesture.state == .began || gesture.state == .changed else { return }
        if !cinematicLook.touching { cinematicLook.begin() }
        switch gesture.step {
        case let .pan(a,b),let .zoom(a,b,_,_): cinematicLook.drag(dx:b.x-a.x,dy:b.y-a.y)
        case let .angle(dx,dy): cinematicLook.drag(dx:dx,dy:dy)
        case .none,.rebase: break
        }
        if tour?.isPlaying != true { applyTourCamera() }
        ensureTourFrames()
    }
    private func hasTourCoverage(_ point:GeoPoint)->Bool {
        guard let model else { return false }
        if tourCoverageRevision != model.offlineCoverageRevision {
            tourCoverageRevision=model.offlineCoverageRevision;tourCoverageCells.removeAll(keepingCapacity:true)
        }
        if tourCoverageCells.contains(where:{ $0.contains(point) }) { return true }
        guard let cell=model.offlineBounds.first(where:{ $0.contains(point) }) else { return false }
        // Reuse nearby exact saved cells, keeping coverage checks off the full
        // download catalogue on almost every display frame.
        if tourCoverageCells.count>=8 { tourCoverageCells.removeFirst() }
        tourCoverageCells.append(cell);return true
    }
    private func streamTourTerrain(plan:WorldFlightPlan,now:Double) {
        guard now-tourLastTerrainRequest>=0.4,let tour else { return }
        tourLastTerrainRequest=now
        // Look a second ahead, rather than discovering each page only when
        // the eye crosses its edge. Coarse terrain remains visible meanwhile.
        let moving=flightSample ?? plan.sample(time:flightTime)
        let ahead=moving.pose.eye+moving.velocity
        let lead=plan.frame.point(u:Double(ahead.x)/plan.frame.widthMeters+0.5,v:Double(ahead.z)/plan.frame.depthMeters+0.5)
        let session=tour.sessionID
        DispatchQueue.main.async { [weak self] in
            guard let self,self.tour?.sessionID==session,self.tour?.isPresented==true,
                  self.model?.hasCoverage(lead)==true else { return }
            self.model?.update(center:lead,distance:1000)
        }
    }
    private func applyTourCamera(seconds:Double? = nil) {
        guard cameraRig.touring,let tour,let plan=flightPlan,let source else { return }
        let moving=flightSample ?? plan.sample(time:flightTime)
        let prepared=WorldFlightPlan.converted(moving,from:plan.frame,to:source.frame),point=prepared.pose.focus
        if !hasTourCoverage(point) {
            let message="This part of the route needs a downloaded map. Choose a saved section to preview."
            if tour.message != message { tour.message=message };tour.finishEntry();tour.pause()
        } else {
            streamTourTerrain(plan:plan,now:CACurrentMediaTime())
            if tour.isEntering && !UIAccessibility.isReduceMotionEnabled {
                if flightArrival == nil,let path=tour.path {
                    var entry=plan.sample(time:flightTime);entry.velocity *= Float(flightPlayback.speed/plan.cruiseSpeed)
                    let held=cameraRig.heldPose
                    func convert(_ value:SIMD3<Float>)->SIMD3<Float> {
                        let point=source.frame.point(u:Double(value.x)/source.frame.widthMeters+0.5,v:Double(value.z)/source.frame.depthMeters+0.5),uv=plan.frame.uv(point)
                        return SIMD3(Float((uv.u-0.5)*plan.frame.widthMeters),value.y,Float((uv.v-0.5)*plan.frame.depthMeters))
                    }
                    let opening=held.map { WorldRouteTourCamera.Pose(eye:convert($0.eye),look:convert($0.look),focus:entry.pose.focus,up:$0.up) }
                    flightArrival=WorldFlightArrival(path:path,flight:entry,frame:plan.frame,aspect:Double(bounds.width/max(1,bounds.height)),
                        from:opening,fieldOfView:held?.fieldOfView ?? WorldRouteTour.fieldOfView)
                }
                let elapsed=flightArrivalTime
                tourBasePose=flightArrival?.sample(elapsed:elapsed,in:source.frame) ?? prepared.pose
                if let arrival=flightArrival,elapsed>=arrival.duration { tour.finishEntry();cinematicLook.reset();flightGlide.reset();flightSample=nil;tourBasePose=prepared.pose }
            } else {
                tourBasePose=prepared.pose
                if tour.isEntering && tour.isRevealing { tour.finishEntry() }
            }
            let now=CACurrentMediaTime()
            if now-tourLastHeightReport>=0.1 {
                tourLastHeightReport=now;tour.reportHeight(prepared.heightAboveGround)
            }
            // Only the initial cloud reveal needs a backdrop. Fine geometry
            // and texture readiness never gate the moving camera afterwards.
            if !tour.isTerrainReady,source.bounds.contains(point),
               distantNode.geometry != nil || tileIndex.tile(at:point).flatMap({ nodes[$0.id] }).map({ !$0.isHidden }) == true {
                tour.isTerrainReady=true
            }
        }
        guard let pose=tourBasePose else { return }
        let now=CACurrentMediaTime(),step=seconds ?? (tourLookTime>0 ? max(0,min(0.1,now-tourLookTime)) : 0)
        tourLookTime=now
        let direction=simd_normalize(pose.look-pose.eye)
        target=SIMD3(pose.eye.x,pose.eye.y-10,pose.eye.z);distance=1000
        cameraNode.camera?.zFar=tour.isEntering ? 500000 : 60000
        let atmosphere=WorldAtmosphere.range(cameraDistance:tour.isEntering ? Double(pose.eye.y) : 3000)
        scene?.fogStartDistance=atmosphere.start;scene?.fogEndDistance=atmosphere.end
        let bank=flightPlayback.roll(toward:pose.bank,seconds:step)
        let fieldOfView=tour.isEntering ? flightArrival?.fieldOfView(elapsed:flightArrivalTime) ?? WorldRouteTour.fieldOfView : WorldRouteTour.fieldOfView
        cameraRig.fly(on:cameraNode,pose:.init(eye:pose.eye,look:pose.eye+direction*80,fieldOfView:fieldOfView,bank:bank,up:pose.up))
        placeLabels.scale(camera:cameraNode,viewport:bounds.size)
        if now-tourLastLabels>=0.25 {
            tourLastLabels=now;placeLabels.select(in:self,focus:target)
        }
        setNeedsDisplay()
    }
    private func scheduleLabels() {
        setNeedsDisplay()
        guard !cameraRig.touring,!sceneUpdatesDeferred else { return }
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
    private func navigationContactChanged(_ touching:Bool) {
        tourContactChanged(touching)
        guard !cameraRig.touring else { return }
        if touching {
            cameraNotification?.cancel();cameraNotification=nil
            labelNotification?.cancel();labelNotification=nil
            uploadNotification?.cancel();uploadNotification=nil
        } else {
            // Cancellation callbacks precede the recognizer clearing contacts.
            DispatchQueue.main.async { [weak self] in
                guard let self,self.scene != nil,!self.navigationGesture.isInteracting else { return }
                self.resumeSceneUpdates()
            }
        }
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
    @objc private func navigateWorld(_ gesture: WorldNavigationGesture) {
        if cameraRig.touring,tour?.isPresented == true { navigateTour(gesture);return }
        guard gesture.state == .began || gesture.state == .changed else {
            if tourSavedPose == nil { updateCamera() };return
        }
        if gesture.state == .began { tour?.close(); stopTour(restore:true); interruptFlight() }
        switch gesture.step {
        case .none: return
        case .rebase:
            rebaseDragPlane()
            return
        case let .pan(previous,current):
            if let a=groundPoint(previous),let b=groundPoint(current) { target += a-b }
            else {
                // Near the sky, finger rays may never meet the ground. Apply
                // the same drag around the screen centre instead of freezing.
                let middle=CGPoint(x:bounds.midX,y:bounds.midY)
                let shifted=CGPoint(x:middle.x+current.x-previous.x,y:middle.y+current.y-previous.y)
                if let a=groundPoint(middle),let b=groundPoint(shifted) { target += a-b }
            }
        case let .angle(dx,dy):
            yaw -= Float(dx)*0.005
            pitch=min(1.49,max(0.30,pitch-Float(dy)*0.004))
        case let .zoom(previous,current,scale,rotation):
            let anchor=groundPoint(previous)
            distance /= Float(scale)
            yaw += Float(rotation)
            updateCamera(notify:false)
            if let anchor,let after=groundPoint(current) { target += anchor-after }
        }
        updateCamera()
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        if tour?.isPresented == true { tour?.pause(); return }
        if let hit = hitTest(gesture.location(in:self),options:[.categoryBitMask:1,.searchMode:SCNHitTestSearchMode.closest.rawValue]).first {
            onTap?(coordinate(SIMD3(hit.worldCoordinates.x,hit.worldCoordinates.y,hit.worldCoordinates.z)))
        } else if let hit=hitTest(gesture.location(in:self),options:[.categoryBitMask:4,.searchMode:SCNHitTestSearchMode.closest.rawValue]).first {
            let point=coordinate(SIMD3(hit.worldCoordinates.x,hit.worldCoordinates.y,hit.worldCoordinates.z))
            if model?.hasCoverage(point) == true { model?.browse(point) }
            else { model?.offerDownload(at:point) }
        }
    }
}
