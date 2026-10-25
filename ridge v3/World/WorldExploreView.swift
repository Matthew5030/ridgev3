import SwiftUI
import UniformTypeIdentifiers

struct WorldExploreView: View {
    @Bindable var store: AppStore
    @Bindable var world: WorldModel
    @AppStorage("ridge.mapSourceMode") private var mapMode = WorldLibrary.defaultMode
    @AppStorage("ridge.localMapServer") private var localMapServer = WorldLibrary.defaultLocalServer
    @State private var visibleBounds: GeoBounds?
    private var connectionID: String { mapMode + "|" + (mapMode == "local" ? localMapServer : "") }
    // Hardware verification of a cold 2D map without deleting a user's saves.
    private var verifyingPreinstalledAtlas:Bool { ProcessInfo.processInfo.arguments.contains("--verify-preinstalled-atlas") }
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var atlasRequest: UUID?
    @State private var mapSize=CGSize(width:768,height:1024)
    @State private var focus = AtlasFocus(point: GeoPoint(latitude: 54.2, longitude: -3.4), scale: 7400, bounds: GeoBounds(minLatitude:49.8,minLongitude:-8.3,maxLatitude:59.4,maxLongitude:2.0))
    @State private var export: GPXDocument?
    @State private var exporting = false
    @State private var showRoutePanel = false
    @State private var elevationSamples: [RouteProfileSample] = []
    @State private var containerSize=CGSize(width:768,height:1024)
    @State private var exploring = false
    @State private var atlasGestureActive = false
    @State private var terrainEntryID:UUID?
    @State private var terrainEntryTask:Task<Void,Never>?
    @State private var terrainEntryStartedAt:Date?
    @State private var overheadSurfaceReady=false
    @State private var overheadRenderedBounds:[GeoBounds]=[]
    @State private var terrainEntrySpan=WorldCameraTransition.minimumAtlasSpan
    @State private var routeBottomHeight:CGFloat=0
    @State private var didFitRegions = false
    @State private var explorePoint:GeoPoint?
    @State private var regionMaps:[WorldRegionMapOverlay]=[]
    @State private var parkMaps:[WorldRegionMapOverlay]=[]
    @State private var regionMapError:String?
    @State private var editWaypoint: RouteWaypoint?
    @State private var renaming = false
    @State private var routeName = ""
    @State private var tour = WorldRouteTour()
    @State private var showCameraHelp = false
    @AppStorage(TerrainGestureStyle.defaultsKey) private var gestureStyle = TerrainGestureStyle.moveWithOneFinger.rawValue
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
        mapContent
        .onGeometryChange(for:CGSize.self) { $0.size } action: { containerSize=$0 }
        .foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
        .overlay {
            if world.isRemovingDownloads {
                ZStack {
                    RidgeTheme.paper.opacity(0.15).ignoresSafeArea()
                    ProgressView("Removing maps…").padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                }
            }
        }
        .task(id:connectionID) {
            cancelTerrainEntry();exploring=false;didFitRegions=false
            if verifyingPreinstalledAtlas {
                didFitRegions=true;exploring=true
                let point=GeoPoint(latitude:53.0685,longitude:-4.0763)
                focus=AtlasFocus(point:point,scale:WorldCameraTransition.maximumAtlasScale(latitude:point.latitude,viewportHeight:Double(mapSize.height),minimumSpan:14000))
                return
            }
            let root=try? WorldLibrary.root(mode:mapMode,local:localMapServer)
            if world.catalog == nil || world.libraryRoot != root {
                store.worldTerrain=nil
                await world.configure(mode:mapMode,local:localMapServer)
            }
            // Read-only hardware regression check: open the actual region card
            // and inspect its remaining download without deleting saved maps.
            if let argument=ProcessInfo.processInfo.arguments.first(where:{ $0.hasPrefix("--inspect-region=") }),
               let library=try? WorldRegionPack.loadLibrary(),
               let pack=(library.areas+library.parks).first(where:{ $0.id==String(argument.dropFirst("--inspect-region=".count)) }) {
                didFitRegions=true;selectRegion(pack)
            }
            if !openPendingRoute(),let bounds = visibleBounds { viewportChanged(bounds) }
        }
        .task(id:"\(connectionID)|\(world.catalog?.revision ?? "")|\(world.offlineCoverageRevision)") {
            guard !verifyingPreinstalledAtlas else { return }
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
            } catch { regionMapError=error.localizedDescription }
        }
        .onChange(of:world.requestedDownloadPoint) { _,point in
            if let point { world.requestedDownloadPoint=nil;showRegion(at:point) }
        }
        .onChange(of:world.streaming) { _, streaming in
            if !streaming,!world.in3D,let bounds=visibleBounds { viewportChanged(bounds) }
        }
        .onChange(of:world.distantTerrain?.id) { _, _ in
            if !world.in3D,let bounds=visibleBounds { viewportChanged(bounds) }
        }
        .onChange(of: world.source?.revision) { _, _ in
            if let terrain = world.routeTerrain { store.worldTerrain = terrain; store.activeTerrain = terrain; store.isWorldBrowsing = true }
            else { store.worldTerrain=nil;if store.isWorldBrowsing { store.activeTerrain=nil } }
            if let bounds = visibleBounds, !world.in3D { viewportChanged(bounds) }
        }
        .onAppear { updateElevationProfile();if world.in3D { world.resume() }; store.isWorldBrowsing=true; if let terrain=world.routeTerrain { store.activeTerrain=terrain } }
        .onDisappear { cancelTerrainEntry();tour.close();world.suspend();UIApplication.shared.isIdleTimerDisabled=false }
        .onChange(of:world.isSavingOffline) { _, _ in updateIdleTimer() }
        .onChange(of:tour.isPlaying) { _, _ in updateIdleTimer() }
        .onChange(of:store.activeRoute) { _, _ in updateElevationProfile();if tour.isPresented { tour.close() } }
        .onChange(of:store.activeRoute?.id) { _, value in if value != nil { showRoutePanel=true } }
        .onChange(of:store.editing) { _, value in if value && store.movingWaypoint == nil && store.insertingWaypoint == nil { showRoutePanel=true } }
        .onChange(of:world.in3D) { _, value in if !value { tour.close() } }
        .onChange(of:phase) { _, value in
            guard !verifyingPreinstalledAtlas else { return }
            if value != .active { tour.pause() }
            // System permission sheets briefly make the app inactive. They must
            // not cancel the connection whose permission is being requested.
            if value == .background {
                cancelTerrainEntry()
                if world.downloadRegion != nil && (world.isSavingOffline || world.checkingDownload) { world.pauseRegionDownload() }
                world.suspend()
            }
            else if value == .active {
                world.restoreRegionDownloadOffer()
                if world.catalog == nil && !world.isLoading {
                    Task {
                        await world.configure(mode: mapMode, local: localMapServer,preservingSelection:true)
                        if let bounds = visibleBounds { viewportChanged(bounds) }
                    }
                } else if world.in3D { world.resume() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in world.memoryWarning() }
        .onChange(of:store.worldRouteFocus) { _, _ in openPendingRoute() }
        .fileExporter(isPresented:$exporting,document:export,contentType:.ridgeGPX,defaultFilename:store.activeRoute?.name ?? "Route") { result in if case .failure(let e)=result { store.errorMessage=e.localizedDescription } }
        .confirmationDialog("Waypoint",isPresented:Binding(get:{editWaypoint != nil},set:{if !$0 {editWaypoint=nil}})) {
            if let waypoint=editWaypoint {
                Button("Move waypoint") { store.editing=true;store.movingWaypoint=store.activeRoute?.waypoints.firstIndex(where:{$0.id==waypoint.id});editWaypoint=nil }
                Button("Delete waypoint",role:.destructive) { store.deleteWaypoint(waypoint.id);editWaypoint=nil }
            }
        }
        .alert("Route name",isPresented:$renaming) {
            TextField("Name",text:$routeName)
            Button("Save") { if let route=store.activeRoute {store.renameRoute(route,to:routeName)} }
            Button("Cancel",role:.cancel) {}
        }
    }
    private var dockedRoutePanel: Bool { containerSize.width>=760 }
    private var routePanelWidth:CGFloat { dockedRoutePanel ? min(360,max(310,containerSize.width*0.30)) : min(340,max(260,mapSize.width-56)) }
    private var routePanelVisible:Bool { world.in3D && store.activeRoute != nil && (dockedRoutePanel || showRoutePanel) && !tour.isEntering && (!world.in3D || terrainEntryID == nil) }
    private var overheadViewport:GeoBounds? {
        guard !world.in3D,let bounds=visibleBounds,bounds.depthMeters<WorldCameraTransition.overheadSpanLimit,
              world.canEnterTerrain(at:bounds.center) else { return nil }
        return bounds
    }
    private var overheadCanReveal:Bool {
        guard let bounds=overheadViewport else { return false }
        return overheadSurfaceReady && WorldMapSurface.covers(bounds,tiles:overheadRenderedBounds)
    }
    private var mapContent: some View {
        ZStack(alignment: .top) {
            if world.in3D || overheadViewport != nil {
                WorldScene(model: world, route: store.activeRoute?.points ?? [], segments: store.activeRoute?.segments.map(\.points) ?? [], waypoints: store.activeRoute?.waypoints ?? [], command: store.camera,
                    onTap: tapped, onAtlas: leaveWorld, onEntryStarted: { date in
                        if terrainEntryID != nil { terrainEntryStartedAt=date }
                    }, overheadViewport:overheadViewport,onSurfaceReady:{ bounds in overheadRenderedBounds=bounds;overheadSurfaceReady = !bounds.isEmpty },atlasRequest:atlasRequest, tour:tour, tourConfiguration:tour.configuration).ignoresSafeArea(edges: .bottom).allowsHitTesting(world.in3D).transition(.identity)
            }
            // Retain the actual atlas while SceneKit presents its matching
            // top-down first frame, then dissolve into the descending camera.
            if !world.in3D || terrainEntryID != nil {
                TimelineView(.animation(minimumInterval:1.0/60,paused:!world.in3D || reduceMotion)) { clock in
                OfflineAtlasView(atlas:store.atlas,entries:[],savedEntries:[],focus:focus,selecting:false,
                    selectedBounds:.constant(nil),draggingSelection:.constant(false),admittedBounds:nil,selectionAllowed:false,
                    requiredBounds:nil,route:[],routeSegments:[],onViewport:viewportChanged,onUserViewport:userViewportChanged,minimumViewportSpan:WorldCameraTransition.minimumAtlasSpan,terrainIsVisible:world.in3D ? overheadSurfaceReady : overheadCanReveal,onWorldTap:visit,
                    worldDownloadTiles:world.regionTileProgress.tiles,
                    worldCompletedTiles:world.regionTileProgress.completed,
                    worldActiveTiles:world.regionTileProgress.active,
                    worldDownloading:world.isSavingOffline,
                    worldSavedDownloadFills:world.regionTileProgress.savedFills,
                    worldRegions:regionMaps+parkMaps.filter { $0.id==world.downloadRegion?.id },selectedWorldRegion:world.downloadRegion?.id,onRegionTap:selectRegion)
                    .ignoresSafeArea(edges: .bottom)
                    .scaleEffect(overheadSurfaceReady ? 1 : atlasEntryScale(at:clock.date))
                    .opacity(world.in3D ? 0 : 1)
                    .animation(.easeInOut(duration:WorldCameraTransition.mapBlendDuration),value:world.in3D)
                    .allowsHitTesting(!world.in3D)
                }
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
                            Button { showCameraHelp.toggle() } label: { Label("Controls",systemImage:"hand.draw").font(.caption) }
                            if showCameraHelp {
                                Text((TerrainGestureStyle(rawValue:gestureStyle) ?? .moveWithOneFinger).shortGuide)
                                    .font(.caption).fixedSize(horizontal:false,vertical:true).frame(maxWidth:220)
                            }
                            if world.streaming { ProgressView("Preparing saved terrain").font(.caption) }
                            if world.pending > 0 { Label("Preparing detail",systemImage:"mountain.2").font(.caption).foregroundStyle(RidgeTheme.muted) }
                        }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                        Spacer()
                        VStack(spacing:8) {
                            control("plus", "Zoom in") { store.camera = TerrainCameraCommand(action:.zoomIn) }
                            control("minus", "Zoom out") { store.camera = TerrainCameraCommand(action:.zoomOut) }
                            control("location.north", "Face north") { store.camera = TerrainCameraCommand(action:.north) }
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
                                },retryConnection:retryConnection)
                        }
                    }.scrollBounceBehavior(.basedOnSize).frame(maxWidth:500,maxHeight:min(380,mapSize.height*0.46))
                        .background(.regularMaterial,in:RoundedRectangle(cornerRadius:12))
                }
                if !world.in3D,let phase=world.downloadPhase, (visibleBounds?.depthMeters ?? 0)<WorldCameraTransition.entrySpanLimit { preparationCard(phase) }
                if let message = world.message {
                    HStack { Text(message).font(.caption);Spacer();Button("Retry") { if world.catalog == nil { retryConnection() } else { world.retry() } } }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if world.downloadRegion == nil, !showsDownloadBoundary, let message = world.coverageMessage { Text(message).font(.caption).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) }
                if let message = world.offlineMessage {
                    HStack { Text(message).font(.caption);Spacer();Button("OK") { world.offlineMessage=nil } }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10))
                }
                if let notice = store.notice { Text(notice).font(.subheadline).padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:10)) }
                if world.in3D && store.activeRoute != nil && !dockedRoutePanel && !showRoutePanel { compactRouteLauncher }
                Text("© OpenStreetMap contributors · Welsh Government OGL v3 · Natural Earth · Mapzen · Copernicus Sentinel 2025")
                    .font(.system(size:9)).foregroundStyle(RidgeTheme.muted).padding(3).background(.regularMaterial,in:Capsule())
            }.padding(16).padding(.leading,routePanelVisible && dockedRoutePanel ? routePanelWidth+8 : 0).padding(.bottom,world.in3D ? routeBottomHeight : 0).opacity(tour.isEntering || (world.in3D && terrainEntryID != nil) ? 0 : 1).allowsHitTesting(!tour.isEntering && (!world.in3D || terrainEntryID == nil))
        }
        .onGeometryChange(for:CGSize.self) { $0.size } action: { mapSize=$0 }
        .onChange(of:overheadViewport == nil && !world.in3D) { _,absent in if absent { overheadSurfaceReady=false;overheadRenderedBounds=[] } }
        .overlay(alignment:.topLeading) {
            if routePanelVisible {
                routePanel
                    .frame(width:routePanelWidth,
                           height:max(200,mapSize.height-routeBottomHeight-92))
                    .clipShape(RoundedRectangle(cornerRadius:14))
                    .shadow(color:.black.opacity(0.16),radius:12,y:4)
                    .padding(.leading,8).padding(.top,76)
            }
        }
        .overlay(alignment:.bottom) {
            if world.in3D,!tour.isEntering,terrainEntryID == nil {
                routeBottomBar
                    .onGeometryChange(for:CGFloat.self) { $0.size.height } action: { routeBottomHeight=$0 }
            }
        }
        .overlay {
            if world.in3D && tour.isPresented && tour.isEntering {
                WorldFlightEntryView(tour:tour).transition(.opacity)
            }
        }
        .overlay(alignment:.bottom) {
            if terrainEntryID != nil,!world.in3D {
                HStack(spacing:10) {
                    ProgressView().controlSize(.small)
                    Text("Opening saved terrain…").font(.caption)
                    Button("Stay on map") { exploring=false;cancelTerrainEntry() }.font(.caption.weight(.semibold))
                }.padding(12).background(.regularMaterial,in:Capsule()).padding(.bottom,68)
            }
        }
    }
    private func atlasEntryScale(at date:Date)->CGFloat {
        guard world.in3D,let start=terrainEntryStartedAt,!reduceMotion else { return 1 }
        let progress=max(0,date.timeIntervalSince(start))/WorldCameraTransition.entryDuration
        return CGFloat(WorldCameraTransition.entryOverlayScale(span:terrainEntrySpan,progress:progress))
    }
    @ViewBuilder private var routeBottomBar:some View {
        if let route=store.activeRoute {
            VStack(spacing:0) {
                Divider()
                if elevationSamples.count>1 {
                    WorldRouteElevationStrip(samples:elevationSamples,
                        selectedDistance:store.selectedPoint.flatMap { WorldRouteProfile.distance(nearest:$0,in:elevationSamples) },tour:tour,onScrub:scrubRoute)
                    Divider()
                }
                WorldRouteToolbar(route:route,editing:store.editing,busy:store.isRouting,pathsReady:world.routeTerrain != nil,
                    canUndo:!store.undoStack.isEmpty,canRedo:!store.redoStack.isEmpty,
                    selectedWaypoint:route.waypoints.first { $0.point.coordinate == store.selectedPoint }?.id,onAction:routePanelAction)
            }.background(.regularMaterial)
        } else {
            WorldRoutePlanPrompt(pathsReady:world.routeTerrain != nil,busy:store.isRouting,
                plan:{ routePanelAction(.start) },library:{ routePanelAction(.library) })
                .frame(maxWidth:480).padding(12)
        }
    }
    private var showsDownloadBoundary: Bool {
        world.in3D && !tour.isPresented && (world.nearOfflineBoundary || !world.insideOfflineArea)
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
            statusKey("Unavailable terrain",color:Color(red:0.70,green:0.19,blue:0.16),symbol:"exclamationmark.triangle.fill")
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
    /// A saved route's destination must survive tab recreation and asynchronous
    /// catalogue/coverage loading. Region-overlay artwork is not a prerequisite.
    @discardableResult private func openPendingRoute()->Bool {
        guard let point=store.worldRouteFocus,world.catalog != nil,world.libraryRoot == (try? WorldLibrary.root(mode:mapMode,local:localMapServer)),world.hasCoverage(point),!world.isSavingOffline else { return false }
        store.worldRouteFocus=nil;openPlace(point);return true
    }
    private func openPlace(_ point:GeoPoint) {
        guard !world.isSavingOffline else { return }
        query="";searchFocused=false
        guard world.hasCoverage(point) else { showRegion(at:point);return }
        if world.in3D { world.visit(point);return }
        exploring=true;atlasGestureActive=false;world.cancelDownload()
        let bounds=WorldCameraTransition.viewport(center:point,span:WorldCameraTransition.minimumAtlasSpan,aspect:Double(mapSize.width/max(1,mapSize.height)))
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
        cancelTerrainEntry();exploring=false;atlasGestureActive=false;explorePoint=nil;world.cancelRegionLoad()
        query="";searchFocused=false
        if world.downloadRegion?.id != pack.id { world.offerRegionDownload(pack) }
        let bounds=pack.bounds
        let span=max(bounds.depthMeters,bounds.widthMeters/Double(max(0.3,mapSize.width/max(1,mapSize.height))))*1.8
        // Leave room below the selected landscape for the inline download panel.
        let center=GeoPoint(latitude:bounds.center.latitude-span/111_000*0.12,longitude:bounds.center.longitude)
        let viewport=WorldCameraTransition.viewport(center:center,span:span,aspect:Double(mapSize.width/max(1,mapSize.height)))
        focus=AtlasFocus(point:center,scale:1,bounds:viewport,animated:true,exactViewport:true)
    }
    private var routePanel: some View {
        let route=store.activeRoute
        let selected=route?.waypoints.first { $0.point.coordinate == store.selectedPoint }?.id
        let moving=store.movingWaypoint.flatMap { index in route?.waypoints.indices.contains(index) == true ? route?.waypoints[index].id : nil }
        let summary=route.map { value in
            let stats=RouteEngine.statistics(for:value)
            return String(format:"%.1f km · %d waypoints",stats.distanceMeters/1000,value.waypoints.count)
        } ?? ""
        return WorldRouteEditorPanel(route:route,editing:store.editing,busy:store.isRouting,pathsReady:world.routeTerrain != nil,
            canUndo:!store.undoStack.isEmpty,canRedo:!store.redoStack.isEmpty,selectedWaypoint:selected,movingWaypoint:moving,
            inserting:store.insertingWaypoint != nil,summary:summary,tour:tour,
            dismiss:dockedRoutePanel ? nil : { showRoutePanel=false },onAction:routePanelAction)
    }
    private var compactRouteLauncher: some View {
        HStack(spacing:12) {
            Button { showRoutePanel=true } label: {
                Label(tour.isPresented ? "Preview controls" : store.activeRoute == nil ? "Plan a route" : "Route · \(store.activeRoute?.waypoints.count ?? 0) points",systemImage:"sidebar.left")
                    .font(.subheadline.weight(.semibold)).frame(minHeight:44)
            }
            Spacer(minLength:0)
            if tour.isPresented {
                Button { tour.togglePlayback() } label: { Image(systemName:tour.isPlaying ? "pause.fill" : "play.fill").frame(width:44,height:44) }
                    .accessibilityLabel(tour.isPlaying ? "Pause preview" : "Play preview")
            } else if (store.activeRoute?.points.count ?? 0)>1 {
                Button("Preview",systemImage:"play.fill") { previewRoute() }.disabled(store.isRouting).frame(minHeight:44)
            }
        }.padding(.horizontal,14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
    }
    private func previewRoute(from waypoint: UUID? = nil) {
        guard !store.isRouting,let route=store.activeRoute else { return }
        guard tour.open(route:route,startingAtWaypoint:waypoint) else {
            store.toast("Preview needs a continuous route with at least two different points. Disconnected GPX tracks can’t be previewed as one walk.")
            return
        }
        world.cancelPendingCameraFocus()
        // Keep the editor session and history intact. Compact screens reveal
        // the camera while the sidebar remains one tap away.
        if !dockedRoutePanel { showRoutePanel=false }
    }
    private func routePanelAction(_ action: WorldRouteEditorPanel.Action) {
        if case .preview(let waypoint)=action { previewRoute(from:waypoint);return }
        tour.close()
        switch action {
        case .start: store.startRoute();showRoutePanel=true
        case .finish: store.finishRoute()
        case .edit: store.editing=true
        case .undo: store.undo()
        case .redo: store.redo()
        case .rename: routeName=store.activeRoute?.name ?? "";renaming=true
        case .export:
            if let route=store.activeRoute {
                do { export=try GPXDocument(route:route);exporting=true }
                catch { store.errorMessage=error.localizedDescription }
            }
        case .reverse: store.reverseRoute()
        case .fitRoute: store.camera=TerrainCameraCommand(action:.fitRoute)
        case .closeLoop:
            // closeLoop appends through the same path as a map tap.
            let wasEditing=store.editing;store.editing=true;store.closeLoop();store.editing=wasEditing
        case .library: store.tab = .routes
        case .cancelPlacement: store.movingWaypoint=nil;store.insertingWaypoint=nil
        case .select(let id), .move(let id), .insertAfter(let id), .delete(let id):
            guard let route=store.activeRoute,let index=route.waypoints.firstIndex(where:{ $0.id==id }) else { return }
            switch action {
            case .select:
                store.selectedPoint=route.waypoints[index].point.coordinate
                store.camera=TerrainCameraCommand(action:.focus(route.waypoints[index].point.coordinate))
            case .move:
                store.editing=true;store.insertingWaypoint=nil;store.movingWaypoint=index
                store.selectedPoint=route.waypoints[index].point.coordinate
                store.camera=TerrainCameraCommand(action:.focus(route.waypoints[index].point.coordinate))
                if !dockedRoutePanel { showRoutePanel=false }
            case .insertAfter:
                store.editing=true;store.movingWaypoint=nil;store.insertingWaypoint=index
                store.selectedPoint=route.waypoints[index].point.coordinate
                store.camera=TerrainCameraCommand(action:.focus(route.waypoints[index].point.coordinate))
                if !dockedRoutePanel { showRoutePanel=false }
            case .delete: store.editing=true;store.deleteWaypoint(id)
            default: break
            }
        case .preview: break
        }
    }
    private func updateElevationProfile() {
        guard let route=store.activeRoute else { elevationSamples=[];return }
        elevationSamples=RouteEngine.elevationProfile(route.segments.isEmpty ? [RouteSegment(points:route.points,mode:"direct")] : route.segments)
    }
    private func scrubRoute(_ fraction: Double) {
        if tour.isPresented { tour.seek(to:fraction);return }
        guard let length=elevationSamples.last?.distance,
              let position=WorldRouteProfile.position(in:elevationSamples,at:length*fraction) else { return }
        store.selectedPoint=position.coordinate
        store.camera=TerrainCameraCommand(action:.focus(position.coordinate))
    }
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled=tour.isPlaying || (world.isSavingOffline && world.downloadRegion != nil)
    }
    private func control(_ symbol:String,_ label:String,action:@escaping()->Void)->some View {
        Button(action:action) {Image(systemName:symbol).frame(width:44,height:44).background(.regularMaterial,in:Circle())}.accessibilityLabel(label)
    }
    private func visit(_ point:GeoPoint) {
        guard !world.isSavingOffline else { return }
        if world.in3D && world.hasCoverage(point) { openPlace(point) }
        else { showRegion(at:point) }
    }
    private func retryConnection() {
        guard !world.isLoading else { return }
        Task {
            await world.configure(mode:mapMode,local:localMapServer,preservingSelection:true)
            if let bounds=visibleBounds { viewportChanged(bounds) }
        }
    }
    private func userViewportChanged(_ bounds:GeoBounds, gestureEnded:Bool) {
        visibleBounds=bounds
        guard !world.in3D,!world.isSavingOffline else { return }
        exploring=true;atlasGestureActive = !gestureEnded
        if atlasGestureActive || bounds.depthMeters>=WorldCameraTransition.entrySpanLimit { cancelTerrainEntry() }
        // A selected region must not trap a pinch zoom behind its Explore button.
        // browse() still checks saved coverage before preparing any terrain.
        if bounds.depthMeters < WorldCameraTransition.preparationSpanLimit,world.downloadRegion != nil {
            world.cancelDownload();explorePoint=nil
        }
        viewportChanged(bounds)
    }
    private func viewportChanged(_ bounds:GeoBounds) {
        visibleBounds = bounds
        guard !verifyingPreinstalledAtlas else { return }
        guard !world.in3D,exploring,!world.isSavingOffline,world.downloadRegion == nil else { return }
        guard bounds.depthMeters < WorldCameraTransition.preparationSpanLimit else { world.cancelRegionLoad(); world.coverageMessage = nil; return }
        world.mapPreparationViewport=bounds
        if world.canEnterTerrain(at:bounds.center) {
            world.update(center:bounds.center,distance:WorldCameraTransition.entry(span:bounds.depthMeters,progress:1).distance,renderingSurface:true)
        }
        // Warm saved terrain while the atlas is still zooming. Keep the active
        // gesture on its original view; fly into the prepared scene on release.
        if bounds.depthMeters >= WorldCameraTransition.entrySpanLimit || atlasGestureActive {
            if world.hasCoverage(bounds.center) { world.browse(bounds.center) }
            return
        }
        guard world.hasCoverage(bounds.center) else { world.browse(bounds.center);return }
        world.browse(bounds.center)
        beginTerrainEntry()
    }
    private func cancelTerrainEntry() {
        terrainEntryTask?.cancel();terrainEntryTask=nil;terrainEntryID=nil;terrainEntryStartedAt=nil
    }
    private func beginTerrainEntry() {
        guard terrainEntryID == nil else { return }
        let id=UUID();terrainEntryID=id
        terrainEntryTask=Task { @MainActor in
            do {
                while !Task.isCancelled,terrainEntryID==id {
                    guard let bounds=visibleBounds,!world.in3D,exploring,!atlasGestureActive,
                          bounds.depthMeters<WorldCameraTransition.entrySpanLimit,world.hasCoverage(bounds.center),
                          world.downloadRegion == nil,!world.isSavingOffline else { cancelTerrainEntry();return }
                    if world.canEnterTerrain(at:bounds.center),overheadSurfaceReady,
                       WorldMapSurface.coversDownloaded(bounds,downloaded:world.offlineBounds,rendered:overheadRenderedBounds) {
                        terrainEntrySpan=bounds.depthMeters;terrainEntryStartedAt=nil
                        world.center=bounds.center;world.cameraPose=nil;world.entrySpan=bounds.depthMeters
                        world.distance=max(1800,bounds.depthMeters);atlasRequest=nil;world.in3D=true
                        store.isWorldBrowsing=true;store.activeTerrain=world.routeTerrain
                        // Keep the atlas alive for the full dissolve. Detailed
                        // tiles continue loading while the 3D camera descends.
                        try await Task.sleep(for:.seconds(WorldCameraTransition.mapBlendDuration))
                        guard terrainEntryID==id else { return }
                        terrainEntryTask=nil;terrainEntryID=nil;terrainEntryStartedAt=nil
                        return
                    }
                    if world.message != nil { cancelTerrainEntry();return }
                    try await Task.sleep(for:.milliseconds(60))
                }
            } catch { /* Cancellation keeps the current atlas or terrain view. */ }
        }
    }
    private func leaveWorld(_ bounds:GeoBounds) {
        cancelTerrainEntry()
        focus=AtlasFocus(point:bounds.center,scale:1,bounds:bounds,exactViewport:true)
        world.suspend();atlasRequest=nil;world.in3D=false
        exploring=false;atlasGestureActive=false
        if let pack=world.downloadRegion { let point=explorePoint;selectRegion(pack);explorePoint=point }
    }
    private func tapped(_ point:GeoPoint) {
        guard world.routeTerrain != nil else { return }
        if store.editing,store.movingWaypoint==nil,store.insertingWaypoint==nil,let waypoint=store.activeRoute?.waypoints.min(by:{$0.point.coordinate.distance(to:point)<$1.point.coordinate.distance(to:point)}),waypoint.point.coordinate.distance(to:point)<max(8,world.distance*0.007) {
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
