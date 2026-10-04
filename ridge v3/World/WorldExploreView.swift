import SwiftUI
import UniformTypeIdentifiers

struct WorldExploreView: View {
    @Bindable var store: AppStore
    @Bindable var world: WorldModel
    @AppStorage("ridge.worldSourceURL") private var sourceAddress = ""
    @Environment(\.scenePhase) private var phase
    @State private var query = ""
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
        return places.filter { $0.name.localizedCaseInsensitiveContains(query) && names.insert($0.name).inserted }.prefix(8).map { $0 }
    }
    var body: some View {
        ZStack(alignment: .top) {
            if world.in3D {
                WorldScene(model: world, route: store.activeRoute?.points ?? [], segments: store.activeRoute?.segments.map(\.points) ?? [], waypoints: store.activeRoute?.waypoints ?? [], command: store.camera,
                    onTap: tapped, onAtlas: leaveWorld).ignoresSafeArea(edges: .bottom)
            } else {
                OfflineAtlasView(atlas: store.atlas, entries: [], savedEntries: [], focus: focus, selecting: false,
                    selectedBounds: $selection, draggingSelection: $dragging, admittedBounds: nil, selectionAllowed: false,
                    requiredBounds: nil, route: [], routeSegments: [], onViewport: viewportChanged, worldCoverage: world.source?.bounds, onWorldTap: visit)
                    .ignoresSafeArea(edges: .bottom)
            }
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    if world.in3D { control("map", "Show UK map") { leaveWorld(world.center) } }
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
                            Text(world.source?.name ?? "Terrain").font(.subheadline.weight(.semibold))
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
                            Text("Zoom into a place to explore in 3D.").font(.subheadline)
                            if let source = world.source {
                                Button("Explore \(source.name)") { visit(world.center) }.buttonStyle(.borderedProminent).foregroundStyle(.white)
                                Text("Snowdon test map included · more coverage to follow").font(.caption).foregroundStyle(RidgeTheme.muted)
                            } else if world.isLoading { ProgressView("Opening map") }
                        }.padding(16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                        Spacer()
                    }
                }
                Spacer()
                if let message = world.message {
                    HStack { Text(message).font(.caption);Spacer();Button("Retry") { if world.source == nil { Task { await world.open(address: sourceAddress) } } else { world.retry() } } }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if let message = world.offlineMessage {
                    HStack { Text(message).font(.caption);Spacer();Button("OK") { world.offlineMessage=nil } }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if let notice = store.notice { Text(notice).font(.subheadline).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) }
                if world.in3D { routeBar }
                Text("© OpenStreetMap contributors · Welsh Government OGL v3 · Natural Earth · Mapzen")
                    .font(.system(size:9)).foregroundStyle(RidgeTheme.muted).padding(3).background(.regularMaterial,in:Capsule())
            }.padding(16)
        }
        .animation(.easeInOut(duration:0.3),value:world.in3D)
        .foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
        .task(id:sourceAddress) {
            await world.open(address:sourceAddress)
            if let terrain=world.routeTerrain { store.worldTerrain=terrain; if store.activeTerrain==nil || store.isWorldBrowsing { store.activeTerrain=terrain;store.isWorldBrowsing=true } }
        }
        .onAppear { world.resume(); store.isWorldBrowsing=true; if let terrain=world.routeTerrain { store.activeTerrain=terrain }; if let point=store.worldRouteFocus {visit(point);store.worldRouteFocus=nil} }
        .onDisappear { world.suspend() }
        .onChange(of:phase) { _, value in if value == .active { world.resume() } else { world.suspend() } }
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
                    Picker("Route mode",selection:$store.planningMode) { Text("Follow paths").tag(RoutePlanningMode.paths);Text("Direct line").tag(RoutePlanningMode.direct) }.pickerStyle(.segmented)
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
        query=""
        guard let source=world.source,source.bounds.contains(point) else {
            focus=AtlasFocus(point:point,scale:150_000);world.message="Detailed coverage for this place hasn’t been published yet.";return
        }
        world.center=point;world.distance=1800;world.requestFocus=point;world.in3D=true
        store.isWorldBrowsing=true;store.activeTerrain=world.routeTerrain
    }
    private func viewportChanged(_ bounds:GeoBounds) {
        guard !world.in3D,let source=world.source,source.bounds.contains(bounds.center),bounds.depthMeters<12000 else{return}
        world.center=bounds.center;world.distance=max(1800,bounds.depthMeters*1.1);world.in3D=true
        store.isWorldBrowsing=true;store.activeTerrain=world.routeTerrain
    }
    private func leaveWorld(_ point:GeoPoint) {
        world.in3D=false;world.suspend();focus=AtlasFocus(point:point,scale:80_000)
    }
    private func tapped(_ point:GeoPoint) {
        if store.editing,store.movingWaypoint==nil,let waypoint=store.activeRoute?.waypoints.min(by:{$0.point.coordinate.distance(to:point)<$1.point.coordinate.distance(to:point)}),waypoint.point.coordinate.distance(to:point)<max(8,world.distance*0.007) {
            editWaypoint=waypoint;return
        }
        store.tapTerrain(point)
    }
}
