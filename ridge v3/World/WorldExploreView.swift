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
    @FocusState private var searchFocused: Bool
    @State private var atlasRequest: UUID?
    @State private var mapSize=CGSize(width:768,height:1024)
    @State private var focus = AtlasFocus(point: GeoPoint(latitude: 54.2, longitude: -3.4), scale: 7400, bounds: GeoBounds(minLatitude:49.8,minLongitude:-8.3,maxLatitude:59.4,maxLongitude:2.0))
    @State private var selection: GeoBounds?
    @State private var dragging = false
    @State private var export: GPXDocument?
    @State private var exporting = false
    @State private var showWaypoints = false
    private enum DownloadMode:String { case custom,regions }
    @State private var downloadMode:DownloadMode?
    @State private var regionMaps:[WorldRegionMapOverlay]=[]
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
    var body: some View {
        ZStack(alignment: .top) {
            if world.in3D {
                WorldScene(model: world, route: store.activeRoute?.points ?? [], segments: store.activeRoute?.segments.map(\.points) ?? [], waypoints: store.activeRoute?.waypoints ?? [], command: store.camera,
                    onTap: tapped, onAtlas: leaveWorld, atlasRequest:atlasRequest).ignoresSafeArea(edges: .bottom)
            } else {
                OfflineAtlasView(atlas: store.atlas, entries: [], savedEntries: [], focus: focus, selecting: world.drawingDownload && !world.isSavingOffline,
                    selectedBounds: $selection, draggingSelection: $dragging, admittedBounds: nil, selectionAllowed: world.downloadError == nil,
                    requiredBounds: nil, route: [], routeSegments: [], onViewport: viewportChanged, onWorldTap: visit, worldOfflineBounds:world.offlineDisplayBounds, worldOfflineEdges:world.offlineEdges, worldDownloadEdges:dragging ? [] : world.downloadPlan?.edges ?? [],
                    worldDownloadTiles:dragging ? [] : world.downloadPlan?.bounds ?? [],
                    worldCompletedTiles:world.completedDownloadTiles,worldActiveTiles:world.activeDownloadTiles,
                    worldDownloading:world.isSavingOffline,onSelectionFinished: { bounds in
                        world.offerDownload(at:bounds.center,selection:bounds)
                    },worldRegions:downloadMode == .regions ? regionMaps : [],selectedWorldRegion:world.downloadRegion?.id,
                    onRegionTap:downloadMode == .regions ? selectRegion : nil)
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
                    Button(action:beginDownload) { Label("Download",systemImage:"arrow.down.circle").font(.subheadline.weight(.medium)).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) }
                        .disabled(world.catalog == nil)
                    control("slider.horizontal.3", "Settings") { store.showSettings = true }
                }
                if !world.in3D,downloadMode != nil || world.downloadCenter != nil { downloadModeBar }
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
                    } else if world.downloadCenter == nil && downloadMode == nil {
                        VStack(alignment:.leading,spacing:10) {
                            Text("Explore the mountains").font(.headline)
                            Text("Choose a place and download its map. Then explore in 3D without a connection.").font(.subheadline)
                            Text(mapMode == "cloud" ? "Cloud · Snowdon pilot coverage" : "Local network")
                                .font(.caption.weight(.semibold)).foregroundStyle(RidgeTheme.muted)
                            if mapMode == "local", let host = world.libraryRoot?.host {
                                Text(host).font(.caption).foregroundStyle(RidgeTheme.muted)
                            }
                            if let catalog = world.catalog {
                                Text("\(catalog.sources.count.formatted()) map areas available")
                                    .font(.caption).foregroundStyle(RidgeTheme.muted)
                            }
                            if world.offlineBounds.isEmpty {
                                Text("No areas saved offline").font(.caption).foregroundStyle(RidgeTheme.muted)
                            } else {
                                HStack(spacing:8) {
                                    RoundedRectangle(cornerRadius:2).fill(RidgeTheme.offlineBoundary.opacity(0.12))
                                        .overlay(RoundedRectangle(cornerRadius:2).strokeBorder(RidgeTheme.offlineBoundary,lineWidth:2))
                                        .frame(width:22,height:14).accessibilityHidden(true)
                                    Text("Saved offline").font(.caption.weight(.medium))
                                }.accessibilityLabel("Amber outlines show maps saved offline")
                            }
                            if world.isLoading && world.catalog == nil { ProgressView("Connecting to maps") }
                        }.padding(16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                        Spacer()
                    }
                }
                if showsDownloadBoundary { downloadBoundaryCard }
                Spacer()
                if world.downloadCenter != nil { downloadSelectionCard }
                if downloadMode == .regions,let pack=world.downloadRegion {
                    ScrollView {
                        WorldRegionDownloadCard(world:world,pack:pack) {
                            endDownloadSelection()
                            focus=AtlasFocus(point:pack.bounds.center,scale:1,bounds:pack.bounds,animated:true,exactViewport:true)
                        }
                    }.scrollBounceBehavior(.basedOnSize).frame(maxWidth:500,maxHeight:min(340,mapSize.height*0.43))
                        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                } else if let pack=world.downloadRegion,world.isSavingOffline || world.regionComplete || world.downloadError != nil {
                    Button(action:beginDownload) {
                        Label(world.regionComplete ? "\(pack.name) saved" : "\(pack.name) download",systemImage:"arrow.down.circle")
                            .font(.subheadline).padding(14).background(RidgeTheme.paper,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain)
                }
                if let phase=world.downloadPhase { preparationCard(phase) }
                if let message = world.message {
                    HStack { Text(message).font(.caption);Spacer();Button("Retry") { if world.catalog == nil { Task { await world.configure(mode: mapMode, local: localMapServer); if let bounds = visibleBounds { viewportChanged(bounds) } } } else { world.retry() } } }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if downloadMode == nil, world.downloadCenter == nil, !showsDownloadBoundary, let message = world.coverageMessage { Text(message).font(.caption).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) }
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
        .task(id:world.catalog?.revision) {
            do {
                let packs=try WorldRegionPack.load(),catalog=world.catalog
                let overlays=await Task.detached(priority:.userInitiated) { packs.map { WorldRegionMapOverlay(pack:$0,catalog:catalog) } }.value
                guard !Task.isCancelled else { return }
                regionMaps=overlays;regionMapError=nil
                if downloadMode == .regions,world.downloadRegion == nil { focusAllRegions() }
            } catch { regionMapError=error.localizedDescription }
        }
        .onChange(of:world.downloadCenter) { _, point in
            if point != nil && world.in3D { atlasRequest=UUID() } else { previewDownload() }
        }
        .onChange(of:world.downloadRadius) { _, _ in previewDownload() }
        .onChange(of:world.in3D) { _, value in if !value { previewDownload() } }
        .onChange(of:world.downloadedDestination) { _, point in
            if let point { downloadMode=nil;world.downloadedDestination=nil;visit(point) }
        }
        .onChange(of:world.streaming) { _, streaming in
            if !streaming,!world.in3D,let bounds=visibleBounds { viewportChanged(bounds) }
        }
        .onChange(of: world.source?.revision) { _, _ in
            if let terrain = world.routeTerrain { store.worldTerrain = terrain; store.activeTerrain = terrain; store.isWorldBrowsing = true }
            if let bounds = visibleBounds, !world.in3D { viewportChanged(bounds) }
        }
        .onAppear { if downloadMode == nil { world.resume() }; store.isWorldBrowsing=true; if let terrain=world.routeTerrain { store.activeTerrain=terrain }; if let point=store.worldRouteFocus {visit(point);store.worldRouteFocus=nil} }
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
                } else if downloadMode == nil { world.resume() }
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
    private var showsDownloadBoundary: Bool {
        world.in3D && world.downloadCenter == nil && (world.nearOfflineBoundary || !world.insideOfflineArea)
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
                if available { chooseDownload() } else { atlasRequest=UUID() }
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
            Spacer();Button("Cancel") { world.pauseDownload() }
        }.padding(16).frame(maxWidth:500).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
    }
    private var downloadSelectionCard: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(world.isSavingOffline ? (world.downloadPlan?.bytes == 0 ? "Opening saved map" : "Downloading new tiles") : "Download this area").font(.headline)
                Spacer()
                Button(world.isSavingOffline ? "Cancel download" : "Cancel") { selection=nil;world.cancelDownload() }
            }
            if !world.isSavingOffline {
                Picker("Select an area",selection:Binding(get:{world.drawingDownload},set:{ enabled in
                    selection=nil;world.setDrawingDownload(enabled)
                })) {
                    Text("Around a place").tag(false);Text("Draw area").tag(true)
                }.pickerStyle(.segmented)
                if world.drawingDownload {
                    Text("Drag a rectangle, or tap two opposite corners. Drag the corners to resize. Two fingers move the map.").font(.caption).foregroundStyle(RidgeTheme.muted)
                    if let selection { Text(String(format:"%.1f × %.1f km",selection.widthMeters/1000,selection.depthMeters/1000)).font(.caption.monospacedDigit()) }
                } else {
                Text("Tap the map to move the area. Size is the distance across.").font(.caption).foregroundStyle(RidgeTheme.muted)
                Picker("Area size",selection:Binding(get:{Int(world.downloadRadius)},set:{ radius in
                    if let point=world.downloadCenter { world.offerDownload(at:point,radius:Double(radius)) }
                })) {
                    Text("8 km").tag(4000);Text("16 km").tag(8000);Text("24 km").tag(12000)
                }.pickerStyle(.segmented)
                }
            }
            if world.checkingDownload { ProgressView("Checking download size…") }
            else if let plan=world.downloadPlan {
                if world.isSavingOffline {
                    if world.isConnectingDownload { ProgressView("Connecting to map server…") }
                    else if plan.bytes == 0 { ProgressView("Opening saved map…") }
                    else {
                        ProgressView(value:Double(world.downloadedBytes),total:Double(plan.bytes))
                        Text("\(RidgeTheme.bytes(world.downloadedBytes)) of \(RidgeTheme.bytes(plan.bytes))").font(.caption.monospacedDigit())
                    }
                    HStack(spacing:8) {
                        Image(systemName:"square.grid.3x3.fill").foregroundStyle(RidgeTheme.forest)
                        Text("\(world.completedDownloadTiles.count) of \(plan.bounds.count) tiles ready").monospacedDigit()
                    }.font(.subheadline).accessibilityLabel("\(world.completedDownloadTiles.count) of \(plan.bounds.count) tiles ready")
                    Text("Amber tiles are loading. Green ticks mean ready. 3D opens when the whole area is saved.").font(.caption).foregroundStyle(RidgeTheme.muted)
                } else {
                    Text(plan.bytes == 0 ? "This area is already on your device" : "\(RidgeTheme.bytes(plan.bytes)) of new data").font(.subheadline.weight(.medium))
                    Text("\(plan.readyBounds.count) tiles already on device · \(plan.bounds.count-plan.readyBounds.count) to download").font(.caption).foregroundStyle(RidgeTheme.muted)
                    Button(world.downloadError != nil ? "Resume download" : plan.bytes == 0 ? "Open in 3D" : "Download and open in 3D") { world.downloadAndOpen() }
                        .buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(dragging)
                }
            }
            if let error=world.downloadError {
                Text(error).font(.caption)
                if world.downloadPlan == nil { Button("Retry") { if let point=world.downloadCenter { world.offerDownload(at:point,selection:world.downloadSelection) } } }
            }
        }.padding(16).frame(maxWidth:500).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
    }
    private var downloadModeBar:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:12) {
                Picker("Download mode",selection:Binding(get:{downloadMode ?? .custom},set:setDownloadMode)) {
                    Text("Custom").tag(DownloadMode.custom)
                    Text("Regions").tag(DownloadMode.regions)
                }.pickerStyle(.segmented).disabled(world.isSavingOffline)
                Button("Done",action:endDownloadSelection).disabled(world.isSavingOffline)
            }
            HStack {
                Text(downloadMode == .regions ? "Tap a region to download. Zoom in for more names." : "Choose around a place, or draw an area.")
                    .font(.caption).foregroundStyle(RidgeTheme.muted)
                Spacer(minLength:4)
                if downloadMode == .regions { Button("All regions") { if !world.isSavingOffline { world.cancelDownload() };focusAllRegions() }.font(.caption.weight(.semibold)) }
            }
            if let regionMapError,downloadMode == .regions { Text(regionMapError).font(.caption) }
        }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
    }
    private func beginDownload() {
        searchFocused=false;query=""
        downloadMode=world.downloadCenter != nil ? .custom : .regions
        world.cancelRegionLoad()
        if world.in3D { atlasRequest=UUID() }
        else if downloadMode == .regions { focusAllRegions() }
    }
    private func setDownloadMode(_ mode:DownloadMode) {
        guard !world.isSavingOffline else { return }
        if mode == .custom { chooseDownload() }
        else {
            selection=nil;world.cancelDownload();world.cancelRegionLoad();downloadMode = .regions
            focusAllRegions()
        }
    }
    private func endDownloadSelection() {
        guard !world.isSavingOffline else { return }
        downloadMode=nil;selection=nil;world.cancelDownload()
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
        query="";searchFocused=false
        if world.downloadRegion?.id != pack.id { world.offerRegionDownload(pack) }
        let bounds=pack.bounds
        let span=max(bounds.depthMeters,bounds.widthMeters/Double(max(0.3,mapSize.width/max(1,mapSize.height))))*1.8
        // Leave room below the selected landscape for the inline download panel.
        let center=GeoPoint(latitude:bounds.center.latitude-span/111_000*0.12,longitude:bounds.center.longitude)
        let viewport=WorldCameraTransition.viewport(center:center,span:span,aspect:Double(mapSize.width/max(1,mapSize.height)))
        focus=AtlasFocus(point:center,scale:1,bounds:viewport,animated:true,exactViewport:true)
    }
    private func chooseDownload() {
        guard !world.isSavingOffline else { return }
        downloadMode = .custom
        searchFocused=false
        let point=world.in3D ? world.center : visibleBounds?.center ?? focus.point
        if world.in3D { atlasRequest=UUID() }
        selection=nil;world.cancelDownload();world.offerDownload(at:point)
    }
    private func previewDownload() {
        guard !world.in3D,!world.drawingDownload,let point=world.downloadCenter else { return }
        let bounds=WorldCameraTransition.viewport(center:point,span:world.downloadRadius*2.7,aspect:Double(mapSize.width/max(1,mapSize.height)))
        focus=AtlasFocus(point:point,scale:1,bounds:bounds,animated:true,exactViewport:true)
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
        query = "";searchFocused=false
        if downloadMode == .regions {
            if let region=WorldRegionMapOverlay.at(point,in:regionMaps) { selectRegion(region.pack) }
            return
        }
        if downloadMode == .custom,world.downloadCenter == nil { world.offerDownload(at:point);return }
        if world.downloadCenter != nil { if !world.drawingDownload { world.offerDownload(at:point) };return }
        if world.in3D {
            world.visit(point)
            return
        }
        let bounds = WorldCameraTransition.viewport(center:point,span:3500,aspect:Double(mapSize.width/max(1,mapSize.height)))
        focus = AtlasFocus(point:point,scale:1,bounds:bounds,animated:true,exactViewport:true)
        viewportChanged(bounds)
    }
    private func viewportChanged(_ bounds:GeoBounds) {
        visibleBounds = bounds
        guard !world.in3D,downloadMode == nil,world.downloadCenter == nil else { return }
        guard bounds.depthMeters < 7000 else { world.cancelRegionLoad(); world.coverageMessage = nil; return }
        guard world.browse(bounds.center), !world.streaming, let source = world.source, source.bounds.contains(bounds.center) else { return }
        world.center = bounds.center; world.cameraPose = nil; world.entrySpan = bounds.depthMeters
        world.distance = max(1800,bounds.depthMeters); atlasRequest = nil; world.in3D = true
        store.isWorldBrowsing = true; store.activeTerrain = world.routeTerrain
    }
    private func leaveWorld(_ bounds:GeoBounds) {
        focus=AtlasFocus(point:bounds.center,scale:1,bounds:bounds,exactViewport:true)
        world.suspend();atlasRequest=nil;world.in3D=false
        if downloadMode == .regions { focusAllRegions() }
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
