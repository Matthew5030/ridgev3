import SwiftUI
import UniformTypeIdentifiers

struct WorldExploreView: View {
    @Bindable var store: AppStore
    @Bindable var world: WorldModel
    @AppStorage("ridge.mapSourceMode") private var mapMode = "cloud"
    @AppStorage("ridge.localMapServer") private var localMapServer = ""
    @State private var visibleBounds: GeoBounds?
    private var connectionID: String { mapMode + "|" + (mapMode == "local" ? localMapServer : "") }
    @Environment(\.scenePhase) private var phase
    @State private var query = ""
    @State private var atlasRequest: UUID?
    @State private var mapSize=CGSize(width:768,height:1024)
    @State private var focus = AtlasFocus(point: GeoPoint(latitude: 54.2, longitude: -3.4), scale: 7400, bounds: GeoBounds(minLatitude:49.8,minLongitude:-8.3,maxLatitude:59.4,maxLongitude:2.0))
    @State private var selection: GeoBounds?
    @State private var dragging = false
    @State private var export: GPXDocument?
    @State private var exporting = false
    @State private var showWaypoints = false
    @State private var editWaypoint: RouteWaypoint?
    @State private var renaming = false
    @State private var routeName = ""
    private var candidates: [MapPlace] {
        let places = (world.source?.places ?? []) + (store.atlas?.places ?? [])
        var names = Set<String>()
        let term = "snowdon".hasPrefix(query.lowercased()) && !query.isEmpty ? "Yr Wyddfa" : query
        return places.filter { $0.name.localizedCaseInsensitiveContains(term) && names.insert($0.name).inserted }.prefix(8).map { $0 }
    }
    var body: some View {
        ZStack(alignment: .top) {
            if world.in3D {
                WorldScene(model: world, route: store.activeRoute?.points ?? [], segments: store.activeRoute?.segments.map(\.points) ?? [], waypoints: store.activeRoute?.waypoints ?? [], command: store.camera,
                    onTap: tapped, onAtlas: leaveWorld, atlasRequest:atlasRequest).ignoresSafeArea(edges: .bottom)
            } else {
                OfflineAtlasView(atlas: store.atlas, entries: [], savedEntries: [], focus: focus, selecting: false,
                    selectedBounds: $selection, draggingSelection: $dragging, admittedBounds: nil, selectionAllowed: false,
                    requiredBounds: nil, route: [], routeSegments: [], onViewport: viewportChanged, worldCoverage: world.source?.bounds, worldPreview:world.preview, onWorldTap: visit)
                    .ignoresSafeArea(edges: .bottom)
            }
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    if world.in3D { control("map", "Show UK map") { atlasRequest=UUID() } }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(RidgeTheme.muted)
                        TextField("Find a place", text: $query).autocorrectionDisabled()
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") } }
                    }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                    control("slider.horizontal.3", "Settings") { store.showSettings = true }
                }
                if !query.isEmpty {
                    VStack(alignment:.leading,spacing:0) {
                        ForEach(candidates) { place in Button { visit(place.coordinate) } label: {
                            HStack { Text(place.name);Spacer();Image(systemName:"arrow.up.right") }.padding(12)
                        }.buttonStyle(.plain) }
                    }.background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                }
                HStack(alignment:.top) {
                    if world.in3D {
                        VStack(alignment:.leading,spacing:4) {
                            Text("Terrain").font(.subheadline.weight(.semibold))
                            if world.loadingRegionID != nil { ProgressView("Loading nearby terrain").font(.caption) }
                            if world.pending > 0 { Label("Adding detail",systemImage:"arrow.down.circle").font(.caption).foregroundStyle(RidgeTheme.muted) }
                        }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                        Spacer()
                        VStack(spacing:8) {
                            control("plus", "Zoom in") { store.camera = TerrainCameraCommand(action:.zoomIn) }
                            control("minus", "Zoom out") { store.camera = TerrainCameraCommand(action:.zoomOut) }
                            control("square.3.layers.3d.top.filled", "Look straight down") { store.camera = TerrainCameraCommand(action:.overhead) }
                            Menu {
                                Button("Keep this area offline",systemImage:"arrow.down.circle") { world.keepOffline() }
                                Button("Import GPX",systemImage:"square.and.arrow.down") { store.showGPXImporter = true }
                                Button("Saved areas",systemImage:"folder") { store.tab = .areas }
                            } label: { Image(systemName:"ellipsis").frame(width:42,height:42).background(.regularMaterial,in:Circle()) }
                        }
                    } else {
                        VStack(alignment:.leading,spacing:10) {
                            Text("Explore the mountains").font(.headline)
                            Text("Zoom in to see the terrain.").font(.subheadline)
                            Text(mapMode == "cloud" ? "Cloud · Snowdon pilot coverage" : "Local network")
                                .font(.caption).foregroundStyle(RidgeTheme.muted)
                            if world.isLoading { ProgressView(world.catalog == nil ? "Connecting to maps" : "Loading terrain") }
                        }.padding(16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                        Spacer()
                    }
                }
                Spacer()
                if let message = world.message {
                    HStack { Text(message).font(.caption);Spacer();Button("Retry") { if world.catalog == nil { Task { await world.configure(mode: mapMode, local: localMapServer); if let bounds = visibleBounds { viewportChanged(bounds) } } } else { world.retry() } } }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if let message = world.coverageMessage { Text(message).font(.caption).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) }
                if let message = world.offlineMessage {
                    HStack { Text(message).font(.caption);Spacer();Button("OK") { world.offlineMessage=nil } }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if let notice = store.notice { Text(notice).font(.subheadline).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) }
                if world.in3D { routeBar }
                Text("© OpenStreetMap contributors · Welsh Government OGL v3 · Natural Earth · Mapzen")
                    .font(.system(size:9)).foregroundStyle(RidgeTheme.muted).padding(3).background(.regularMaterial,in:Capsule())
            }.padding(16)
        }
        .onGeometryChange(for:CGSize.self) { $0.size } action: { mapSize=$0 }
        .animation(.easeInOut(duration:0.25),value:world.in3D)
        .foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
        .task(id:connectionID) {
            store.worldTerrain = nil
            await world.configure(mode: mapMode, local: localMapServer)
            if let bounds = visibleBounds { viewportChanged(bounds) }
        }
        .onChange(of: world.source?.id) { _, _ in
            if let terrain = world.routeTerrain { store.worldTerrain = terrain; store.activeTerrain = terrain; store.isWorldBrowsing = true }
            if let bounds = visibleBounds, !world.in3D { viewportChanged(bounds) }
        }
        .onAppear { world.resume(); store.isWorldBrowsing=true; if let terrain=world.routeTerrain { store.activeTerrain=terrain }; if let point=store.worldRouteFocus {visit(point);store.worldRouteFocus=nil} }
        .onDisappear { world.suspend() }
        .onChange(of:phase) { _, value in
            // System permission sheets briefly make the app inactive. They must
            // not cancel the connection whose permission is being requested.
            if value == .background { world.suspend() }
            else if value == .active {
                if world.catalog == nil && !world.isLoading {
                    Task {
                        await world.configure(mode: mapMode, local: localMapServer)
                        if let bounds = visibleBounds { viewportChanged(bounds) }
                    }
                } else { world.resume() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in world.memoryWarning() }
        .onChange(of:store.worldRouteFocus) { _, point in if let point { visit(point);store.worldRouteFocus=nil } }
        .sheet(isPresented:$showWaypoints) { WaypointsSheet(store:store).presentationDetents([.medium,.large]) }
        .fileExporter(isPresented:$exporting,document:export,contentType:.ridgeGPX,defaultFilename:store.activeRoute?.name ?? "Route") { result in if case .failure(let e)=result { store.errorMessage=e.localizedDescription } }
        .confirmationDialog("Waypoint",isPresented:Binding(get:{editWaypoint != nil},set:{if !$0 {editWaypoint=nil}})) {
            if let waypoint=editWaypoint {
                Button("Move waypoint") { store.movingWaypoint=store.activeRoute?.waypoints.firstIndex(where:{$0.id==waypoint.id});editWaypoint=nil }
                Button("Delete waypoint",role:.destructive) { store.deleteWaypoint(waypoint.id);editWaypoint=nil }
            }
        }
        .alert("Route name",isPresented:$renaming) {
            TextField("Name",text:$routeName)
            Button("Save") { if let route=store.activeRoute {store.renameRoute(route,to:routeName)} }
            Button("Cancel",role:.cancel) {}
        }
    }
    private var routeBar: some View {
        VStack(spacing:10) {
            if let route=store.activeRoute {
                HStack {
                    Button { routeName=route.name;renaming=true } label: { Text(route.name).font(.headline).lineLimit(1) }
                    Spacer()
                    if store.isRouting { ProgressView() }
                    Menu {
                        Button("Waypoints") { showWaypoints=true }
                        Button("Reverse route") { store.reverseRoute() }
                        Button("Close loop") { store.closeLoop() }
                        Button("Export GPX") { do {export=try GPXDocument(route:route);exporting=true} catch {store.errorMessage=error.localizedDescription} }
                        Button("Start another route") {store.startRoute()}
                    } label: { Image(systemName:"ellipsis.circle").font(.title3) }
                }
                if !route.points.isEmpty {
                    let stats=RouteEngine.statistics(for:route)
                    Text(String(format:"%.1f km · %d waypoints",stats.distanceMeters/1000,route.waypoints.count)).font(.subheadline).foregroundStyle(RidgeTheme.muted)
                }
            }
            HStack(spacing:14) {
                if store.editing {
                    Text("Tap a path to add a waypoint").font(.subheadline).foregroundStyle(RidgeTheme.muted)
                    Spacer()
                    Button {store.undo()} label:{Image(systemName:"arrow.uturn.backward")}.disabled(store.undoStack.isEmpty)
                    Button {store.redo()} label:{Image(systemName:"arrow.uturn.forward")}.disabled(store.redoStack.isEmpty)
                    Button("Done") {store.finishRoute()}.fontWeight(.semibold)
                } else {
                    Button(store.activeRoute == nil ? "Plan a route" : "Edit route",systemImage:"point.topleft.down.to.point.bottomright.curvepath") {
                        if store.activeRoute == nil {store.startRoute()} else {store.editing=true}
                    }.buttonStyle(.borderedProminent).foregroundStyle(.white)
                    Spacer()
                    Button("Keep offline",systemImage:"arrow.down.circle") {world.keepOffline()}.disabled(world.saving)
                }
            }.disabled(store.isRouting)
        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
    }
    private func control(_ symbol:String,_ label:String,action:@escaping()->Void)->some View {
        Button(action:action) {Image(systemName:symbol).frame(width:42,height:42).background(.regularMaterial,in:Circle())}.accessibilityLabel(label)
    }
    private func visit(_ point:GeoPoint) {
        query = ""
        if world.in3D {
            if world.hasCoverage(point) { world.requestFocus = point; world.browse(point) }
            else { world.browse(point) }
            return
        }
        let bounds = WorldCameraTransition.viewport(center:point,span:3500,aspect:Double(mapSize.width/max(1,mapSize.height)))
        focus = AtlasFocus(point:point,scale:1,bounds:bounds,animated:true,exactViewport:true)
        viewportChanged(bounds)
    }
    private func viewportChanged(_ bounds:GeoBounds) {
        visibleBounds = bounds
        guard !world.in3D else { return }
        guard bounds.depthMeters < 7000 else { world.cancelRegionLoad(); world.coverageMessage = nil; return }
        guard world.browse(bounds.center), let source = world.source, source.bounds.contains(bounds.center) else { return }
        world.center = bounds.center; world.cameraPose = nil; world.entrySpan = bounds.depthMeters
        world.distance = max(1800,bounds.depthMeters); atlasRequest = nil; world.in3D = true
        store.isWorldBrowsing = true; store.activeTerrain = world.routeTerrain
    }
    private func leaveWorld(_ bounds:GeoBounds) {
        focus=AtlasFocus(point:bounds.center,scale:1,bounds:bounds,exactViewport:true)
        world.suspend();atlasRequest=nil;world.in3D=false
    }
    private func tapped(_ point:GeoPoint) {
        if store.editing,store.movingWaypoint==nil,let waypoint=store.activeRoute?.waypoints.min(by:{$0.point.coordinate.distance(to:point)<$1.point.coordinate.distance(to:point)}),waypoint.point.coordinate.distance(to:point)<max(8,world.distance*0.007) {
            editWaypoint=waypoint;return
        }
        guard world.source?.bounds.contains(point) == true else { world.browse(point); return }
        if store.editing, let last = store.activeRoute?.waypoints.last?.point.coordinate,
           world.source?.bounds.contains(last) != true {
            store.toast("Paths across this map boundary aren’t joined yet. Your route hasn’t changed.")
            return
        }
        store.tapTerrain(point)
    }
}
