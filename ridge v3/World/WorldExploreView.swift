import SwiftUI
import UniformTypeIdentifiers

struct WorldExploreView: View {
    @Bindable var store: AppStore
    @Bindable var world: WorldModel
    @AppStorage("ridge.mapSourceMode") private var mapMode = WorldLibrary.defaultMode
    @AppStorage("ridge.localMapServer") private var localMapServer = WorldLibrary.defaultLocalServer
    @State private var visibleBounds: GeoBounds?
    private var connectionID: String { mapMode + "|" + (mapMode == "local" ? localMapServer : "") }
    @Environment(\.scenePhase) private var phase
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var atlasRequest: UUID?
    @State private var mapSize=CGSize(width:768,height:1024)
    @State private var focus = AtlasFocus(point: GeoPoint(latitude: 54.2, longitude: -3.4), scale: 7400, bounds: GeoBounds(minLatitude:49.8,minLongitude:-8.3,maxLatitude:59.4,maxLongitude:2.0))
    @State private var export: GPXDocument?
    @State private var exporting = false
    @State private var showWaypoints = false
    @State private var exploring = false
    @State private var didFitRegions = false
    @State private var explorePoint:GeoPoint?
    @State private var regionMaps:[WorldRegionMapOverlay]=[]
    @State private var parkMaps:[WorldRegionMapOverlay]=[]
    @State private var regionMapError:String?
    @State private var editWaypoint: RouteWaypoint?
    @State private var renaming = false
    @State private var routeName = ""
    private var candidates: [MapPlace] {
        let places = (world.source?.places ?? []) + (store.atlas?.places ?? [])
        var names = Set<String>()
        let term = "snowdon".hasPrefix(query.lowercased()) && !query.isEmpty ? "Yr Wyddfa" : query
        return places.filter { $0.name.localizedCaseInsensitiveContains(term) && names.insert($0.name).inserted }.prefix(8).map { $0 }
    }
    private var regionCandidates:[WorldRegionMapOverlay] {
        guard !world.in3D,!query.trimmingCharacters(in:.whitespaces).isEmpty else { return [] }
        let areas=parkMaps+regionMaps
        return Array(areas.filter { $0.pack.name.localizedCaseInsensitiveContains(query) }.prefix(3))
    }
    var body: some View {
        ZStack(alignment: .top) {
            if world.in3D {
                WorldScene(model: world, route: store.activeRoute?.points ?? [], segments: store.activeRoute?.segments.map(\.points) ?? [], waypoints: store.activeRoute?.waypoints ?? [], command: store.camera,
                    onTap: tapped, onAtlas: leaveWorld, atlasRequest:atlasRequest).ignoresSafeArea(edges: .bottom)
            } else {
                OfflineAtlasView(atlas:store.atlas,entries:[],savedEntries:[],focus:focus,selecting:false,
                    selectedBounds:.constant(nil),draggingSelection:.constant(false),admittedBounds:nil,selectionAllowed:false,
                    requiredBounds:nil,route:[],routeSegments:[],onViewport:viewportChanged,onUserViewport:userViewportChanged,onWorldTap:visit,
                    worldDownloadTiles:world.regionTileProgress.tiles,
                    worldCompletedTiles:world.regionTileProgress.completed,
                    worldActiveTiles:world.regionTileProgress.active,
                    worldDownloading:world.isSavingOffline,
                    worldSavedDownloadFills:world.regionTileProgress.savedFills,
                    worldRegions:regionMaps+parkMaps.filter { $0.id==world.downloadRegion?.id },selectedWorldRegion:world.downloadRegion?.id,onRegionTap:selectRegion)
                    .ignoresSafeArea(edges: .bottom)
            }
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    if world.in3D { control("map", "Show UK map") { atlasRequest=UUID() } }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(RidgeTheme.muted)
                        TextField("Find a place", text: $query).autocorrectionDisabled().focused($searchFocused)
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") } }
                    }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                    control("slider.horizontal.3", "Settings") { store.showSettings = true }
                }
                if !world.in3D { regionMapBar }
                if !query.isEmpty {
                    VStack(alignment:.leading,spacing:0) {
                        ForEach(regionCandidates) { area in Button { selectRegion(area.pack) } label: {
                            HStack {
                                Image(systemName:"map")
                                VStack(alignment:.leading,spacing:2) {
                                    Text(area.pack.name)
                                    Text(area.statusText).font(.caption).foregroundStyle(RidgeTheme.muted)
                                }
                                Spacer();Image(systemName:"arrow.up.right")
                            }.padding(12)
                        }.buttonStyle(.plain) }
                        ForEach(candidates.prefix(regionCandidates.isEmpty ? 8 : 4)) { place in Button { visit(place.coordinate) } label: {
                            HStack { Text(place.name);Spacer();Image(systemName:"arrow.up.right") }.padding(12)
                        }.buttonStyle(.plain) }
                    }.background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                }
                HStack(alignment:.top) {
                    if world.in3D {
                        VStack(alignment:.leading,spacing:4) {
                            Text("Terrain").font(.subheadline.weight(.semibold))
                            if world.streaming { ProgressView("Preparing saved terrain").font(.caption) }
                            if world.pending > 0 { Label("Preparing detail",systemImage:"mountain.2").font(.caption).foregroundStyle(RidgeTheme.muted) }
                        }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                        Spacer()
                        VStack(spacing:8) {
                            control("plus", "Zoom in") { store.camera = TerrainCameraCommand(action:.zoomIn) }
                            control("minus", "Zoom out") { store.camera = TerrainCameraCommand(action:.zoomOut) }
                            control("square.3.layers.3d.top.filled", "Look straight down") { store.camera = TerrainCameraCommand(action:.overhead) }
                            Menu {
                                Button("Import GPX",systemImage:"square.and.arrow.down") { store.showGPXImporter = true }
                                Button("Downloaded maps",systemImage:"map") { atlasRequest=UUID() }
                            } label: { Image(systemName:"ellipsis").frame(width:42,height:42).background(.regularMaterial,in:Circle()) }
                        }
                    }
                }
                if showsDownloadBoundary { downloadBoundaryCard }
                Spacer()
                if !world.in3D,let pack=world.downloadRegion {
                    ScrollView {
                        VStack(alignment:.trailing,spacing:0) {
                            Button { world.cancelDownload();explorePoint=nil } label: {
                                Image(systemName:"xmark").padding(12)
                            }.accessibilityLabel("Close region").disabled(world.isSavingOffline)
                            WorldRegionDownloadCard(world:world,pack:pack,
                                saved:(regionMaps+parkMaps).first { $0.id==pack.id },explore: { openRegion(pack) },
                                selectWholePark:parkMaps.first { $0.id==pack.parkID && $0.id != pack.id }.map { whole in
                                    { selectRegion(whole.pack) }
                                })
                        }
                    }.scrollBounceBehavior(.basedOnSize).frame(maxWidth:500,maxHeight:min(380,mapSize.height*0.46))
                        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                }
                if let phase=world.downloadPhase { preparationCard(phase) }
                if let message = world.message {
                    HStack { Text(message).font(.caption);Spacer();Button("Retry") { if world.catalog == nil { Task { await world.configure(mode: mapMode, local: localMapServer); if let bounds = visibleBounds { viewportChanged(bounds) } } } else { world.retry() } } }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if world.downloadRegion == nil, !showsDownloadBoundary, let message = world.coverageMessage { Text(message).font(.caption).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) }
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
            exploring=false;didFitRegions=false
            store.worldTerrain = nil
            await world.configure(mode: mapMode, local: localMapServer)
            if let bounds = visibleBounds { viewportChanged(bounds) }
        }
        .task(id:"\(connectionID)|\(world.catalog?.revision ?? "")|\(world.offlineCoverageRevision)") {
            do {
                let library=try WorldRegionPack.loadLibrary(),catalog=world.catalog,saved=world.offlineBounds
                let packs=library.areas.filter { $0.mapShapes?.isEmpty != true }
                let (overlays,parks)=await Task.detached(priority:.userInitiated) {
                    (WorldRegionMapOverlay.make(packs:packs,catalog:catalog,offline:saved),
                     WorldRegionMapOverlay.make(packs:library.parks,catalog:catalog,offline:saved))
                }.value
                guard !Task.isCancelled else { return }
                regionMaps=overlays;parkMaps=parks;regionMapError=nil
                if !didFitRegions,!world.in3D,!exploring { didFitRegions=true;focusAllRegions() }
                if world.catalog != nil,let point=store.worldRouteFocus { openPlace(point);store.worldRouteFocus=nil }
            } catch { regionMapError=error.localizedDescription }
        }
        .onChange(of:world.requestedDownloadPoint) { _,point in
            if let point { world.requestedDownloadPoint=nil;showRegion(at:point) }
        }
        .onChange(of:world.streaming) { _, streaming in
            if !streaming,!world.in3D,let bounds=visibleBounds { viewportChanged(bounds) }
        }
        .onChange(of: world.source?.revision) { _, _ in
            if let terrain = world.routeTerrain { store.worldTerrain = terrain; store.activeTerrain = terrain; store.isWorldBrowsing = true }
            if let bounds = visibleBounds, !world.in3D { viewportChanged(bounds) }
        }
        .onAppear { if world.in3D { world.resume() }; store.isWorldBrowsing=true; if let terrain=world.routeTerrain { store.activeTerrain=terrain } }
        .onDisappear { world.suspend();UIApplication.shared.isIdleTimerDisabled=false }
        .onChange(of:world.isSavingOffline) { _, saving in UIApplication.shared.isIdleTimerDisabled=saving && world.downloadRegion != nil }
        .onChange(of:phase) { _, value in
            // System permission sheets briefly make the app inactive. They must
            // not cancel the connection whose permission is being requested.
            if value == .background {
                if world.downloadRegion != nil && (world.isSavingOffline || world.checkingDownload) { world.pauseRegionDownload() }
                world.suspend()
            }
            else if value == .active {
                if world.catalog == nil && !world.isLoading {
                    Task {
                        await world.configure(mode: mapMode, local: localMapServer)
                        if let bounds = visibleBounds { viewportChanged(bounds) }
                    }
                } else if world.in3D { world.resume() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in world.memoryWarning() }
        .onChange(of:store.worldRouteFocus) { _, point in if let point,world.catalog != nil,!regionMaps.isEmpty { openPlace(point);store.worldRouteFocus=nil } }
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
    private var showsDownloadBoundary: Bool {
        world.in3D && (world.nearOfflineBoundary || !world.insideOfflineArea)
    }
    private var downloadBoundaryCard: some View {
        let inside=world.insideOfflineArea
        let available=world.catalog?.region(at:world.center) != nil
        return VStack(alignment:.leading,spacing:14) {
            HStack(alignment:.top,spacing:12) {
                Image(systemName:available ? "arrow.down.circle.fill" : "map")
                    .font(.system(size:30,weight:.medium)).foregroundStyle(RidgeTheme.offlineBoundary)
                    .accessibilityHidden(true)
                VStack(alignment:.leading,spacing:6) {
                    Text(!available ? "Detailed map unavailable" : inside ? "Approaching the edge" : "Map not downloaded")
                        .font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(!available ? "Detailed terrain isn’t available here yet. Choose another area on the map."
                         : inside ? "Your saved map ends nearby. Download more to keep exploring."
                         : "This is the overview. Download this area for detailed terrain and route planning.")
                        .font(.subheadline).fixedSize(horizontal:false,vertical:true)
                }
            }
            Button {
                showRegion(at:world.center)
            } label: {
                HStack {
                    Image(systemName:available ? "arrow.down.circle" : "map")
                    Text(!available ? "Choose another area" : inside ? "Download more" : "Download this area")
                    Spacer(minLength:8)
                    Image(systemName:"arrow.right")
                }.font(.headline).padding(.horizontal,16).frame(minHeight:48)
                    .frame(maxWidth:.infinity).foregroundStyle(.white)
                    .background(RidgeTheme.forest,in:RoundedRectangle(cornerRadius:10))
            }.buttonStyle(.plain).disabled(world.isSavingOffline)
        }
        .padding(18).frame(maxWidth:520,alignment:.leading)
        .background(RidgeTheme.paper,in:RoundedRectangle(cornerRadius:14))
        .overlay(RoundedRectangle(cornerRadius:14).strokeBorder(RidgeTheme.offlineBoundary,lineWidth:2))
        .shadow(color:.black.opacity(0.16),radius:12,y:4)
        .accessibilityElement(children:.contain)
    }
    private func preparationCard(_ phase: String) -> some View {
        HStack(spacing:12) {
            ProgressView();Text(phase).font(.subheadline)
            Spacer();Button("Cancel") { exploring=false;world.pauseDownload() }
        }.padding(16).frame(maxWidth:500).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
    }
    private var regionMapBar:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                statusKey("Downloaded",color:RidgeTheme.forest,symbol:"checkmark.circle.fill")
                statusKey("Part saved",color:RidgeTheme.offlineBoundary,symbol:"circle.lefthalf.filled")
                statusKey("Not saved",color:RidgeTheme.muted,symbol:"arrow.down.circle")
                Spacer(minLength:0)
                Button { if !world.isSavingOffline { world.cancelDownload() };exploring=false;world.cancelRegionLoad();focusAllRegions() } label: {
                    Image(systemName:"globe.europe.africa")
                }.accessibilityLabel("Show all regions")
            }
            if world.isLoading && world.catalog == nil { ProgressView("Connecting to maps").font(.caption) }
            else { Text("Zoom into saved terrain · tap a region to download").font(.caption).foregroundStyle(RidgeTheme.muted) }
            if let regionMapError { Text(regionMapError).font(.caption) }
        }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
    }
    private func statusKey(_ title:String,color:Color,symbol:String)->some View {
        Label(title,systemImage:symbol).font(.caption2.weight(.medium)).foregroundStyle(color)
    }
    private func showRegion(at point:GeoPoint) {
        exploring=false
        if let overlay=WorldRegionMapOverlay.at(point,in:regionMaps) { selectRegion(overlay.pack);explorePoint=point }
        if world.in3D { atlasRequest=UUID() }
    }
    private func openRegion(_ pack:WorldRegionPack) {
        let overlay=(regionMaps+parkMaps).first { $0.id==pack.id }
        let point=explorePoint.flatMap { world.hasCoverage($0) ? $0 : nil } ?? overlay?.savedPoint
            ?? world.offlineBounds.filter { tile in pack.cells.contains { $0.bounds.contains(tile.center) } }
                .min { $0.center.distance(to:pack.bounds.center)<$1.center.distance(to:pack.bounds.center) }?.center
        guard let point else { return }
        world.cancelDownload();openPlace(point)
    }
    private func openPlace(_ point:GeoPoint) {
        guard !world.isSavingOffline else { return }
        query="";searchFocused=false
        guard world.hasCoverage(point) else { showRegion(at:point);return }
        if world.in3D { world.visit(point);return }
        exploring=true;world.cancelDownload()
        let bounds=WorldCameraTransition.viewport(center:point,span:3500,aspect:Double(mapSize.width/max(1,mapSize.height)))
        focus=AtlasFocus(point:point,scale:1,bounds:bounds,animated:true,exactViewport:true)
        viewportChanged(bounds)
    }
    private func focusAllRegions() {
        guard !regionMaps.isEmpty else { return }
        let bounds=GeoBounds(minLatitude:regionMaps.map { $0.pack.bounds.minLatitude }.min()!-0.5,
                             minLongitude:regionMaps.map { $0.pack.bounds.minLongitude }.min()!-0.5,
                             maxLatitude:regionMaps.map { $0.pack.bounds.maxLatitude }.max()!+0.5,
                             maxLongitude:regionMaps.map { $0.pack.bounds.maxLongitude }.max()!+0.5)
        focus=AtlasFocus(point:bounds.center,scale:1,bounds:bounds,animated:true,exactViewport:true)
    }
    private func selectRegion(_ pack:WorldRegionPack) {
        guard !world.isSavingOffline else { return }
        exploring=false;explorePoint=nil;world.cancelRegionLoad()
        query="";searchFocused=false
        if world.downloadRegion?.id != pack.id { world.offerRegionDownload(pack) }
        let bounds=pack.bounds
        let span=max(bounds.depthMeters,bounds.widthMeters/Double(max(0.3,mapSize.width/max(1,mapSize.height))))*1.8
        // Leave room below the selected landscape for the inline download panel.
        let center=GeoPoint(latitude:bounds.center.latitude-span/111_000*0.12,longitude:bounds.center.longitude)
        let viewport=WorldCameraTransition.viewport(center:center,span:span,aspect:Double(mapSize.width/max(1,mapSize.height)))
        focus=AtlasFocus(point:center,scale:1,bounds:viewport,animated:true,exactViewport:true)
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
                    Label("Route saved",systemImage:"checkmark.circle").font(.caption).foregroundStyle(RidgeTheme.muted)
                }
            }.disabled(store.isRouting)
        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
    }
    private func control(_ symbol:String,_ label:String,action:@escaping()->Void)->some View {
        Button(action:action) {Image(systemName:symbol).frame(width:42,height:42).background(.regularMaterial,in:Circle())}.accessibilityLabel(label)
    }
    private func visit(_ point:GeoPoint) {
        guard !world.isSavingOffline else { return }
        if world.in3D && world.hasCoverage(point) { openPlace(point) }
        else { showRegion(at:point) }
    }
    private func userViewportChanged(_ bounds:GeoBounds) {
        visibleBounds=bounds
        guard !world.in3D,!world.isSavingOffline else { return }
        exploring=true
        // A selected region must not trap a pinch zoom behind its Explore button.
        // browse() still checks saved coverage before preparing any terrain.
        if bounds.depthMeters < WorldCameraTransition.entrySpanLimit,world.downloadRegion != nil {
            world.cancelDownload();explorePoint=nil
        }
        viewportChanged(bounds)
    }
    private func viewportChanged(_ bounds:GeoBounds) {
        visibleBounds = bounds
        guard !world.in3D,exploring,!world.isSavingOffline,world.downloadRegion == nil else { return }
        guard bounds.depthMeters < WorldCameraTransition.entrySpanLimit else { world.cancelRegionLoad(); world.coverageMessage = nil; return }
        guard world.browse(bounds.center), !world.streaming, let source = world.source, source.bounds.contains(bounds.center) else { return }
        world.center = bounds.center; world.cameraPose = nil; world.entrySpan = bounds.depthMeters
        world.distance = max(1800,bounds.depthMeters); atlasRequest = nil; world.in3D = true
        store.isWorldBrowsing = true; store.activeTerrain = world.routeTerrain
    }
    private func leaveWorld(_ bounds:GeoBounds) {
        focus=AtlasFocus(point:bounds.center,scale:1,bounds:bounds,exactViewport:true)
        world.suspend();atlasRequest=nil;world.in3D=false
        exploring=false
        if let pack=world.downloadRegion { let point=explorePoint;selectRegion(pack);explorePoint=point }
    }
    private func tapped(_ point:GeoPoint) {
        if store.editing,store.movingWaypoint==nil,let waypoint=store.activeRoute?.waypoints.min(by:{$0.point.coordinate.distance(to:point)<$1.point.coordinate.distance(to:point)}),waypoint.point.coordinate.distance(to:point)<max(8,world.distance*0.007) {
            editWaypoint=waypoint;return
        }
        guard world.source?.bounds.contains(point) == true else { world.browse(point); return }
        if store.editing, let last = store.activeRoute?.waypoints.last?.point.coordinate,
           world.source?.bounds.contains(last) != true {
            store.toast("Move back towards your last waypoint so its walking paths can stay loaded. Your route hasn’t changed.")
            return
        }
        store.tapTerrain(point)
    }
}
