import SwiftUI
import UniformTypeIdentifiers
import CoreLocation
import Observation

struct TerrainPlannerView: View {
    @Bindable var store: AppStore
    let terrain: LoadedTerrain
    @State private var editTarget: RouteEditTarget?
    @State private var showPlaces = false
    @State private var showDetails = false
    @State private var showNotes = false
    @State private var showHelp = false
    @State private var showSettings = false
    @State private var showAreaSelection = false
    private let gestureStyle = TerrainGestureStyle.moveWithOneFinger
    @State private var importGPX = false
    @State private var rename = false
    @State private var routeName = ""
    @State private var delete = false
    @State private var exportDocument: GPXDocument?
    @State private var exporting = false
    @State private var profileExpanded = true
    @State private var profileSamples: [RouteProfileSample] = []
    @State private var panelCollapsed = false
    @State private var panelHeight: CGFloat = 210
    @State private var location = RidgeLocation()
    private var imported: Bool { store.activeRoute?.segments.contains(where: { $0.mode == "imported" }) == true }
    private var statistics: RouteStatistics { store.activeRoute.map(RouteEngine.statistics) ?? .empty }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 900 || (geometry.size.width >= 640 && geometry.size.width > geometry.size.height)
            let sideWidth = panelCollapsed ? 172.0 : min(360, max(280, geometry.size.width * 0.34))
            ZStack {
                RidgeTheme.paper.ignoresSafeArea()
                // Keep the same Metal view alive through orientation changes;
                // only its unobscured viewport and surrounding controls change.
                TerrainView(terrain: terrain, route: store.activeRoute?.points ?? [], waypoints: store.activeRoute?.waypoints ?? [], editing: store.editing && !store.isRouting,
                            command: store.camera, selectedPoint: store.selectedPoint, routeSegments: store.activeRoute?.segments.map(\.points) ?? [],
                            extensionBounds: store.extensionManifest?.bounds, extensionGrid: store.extensionManifest?.grid,
                            onNavigationChange: store.updateNavigation, onRelease: { store.terrainViewReleased() },
                            onRouteEdit: store.editing && !imported && store.movingWaypoint == nil && store.insertingWaypoint == nil ? { editTarget = $0 } : nil) { store.tapTerrain($0) }
                    .padding(.top, wide ? 124 : 90)
                    .padding(.bottom, wide ? 38 : panelHeight)
                    .padding(.trailing, wide ? sideWidth + 20 : 0)
                if wide {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 8) {
                            topBar
                            cameraControls(horizontal: true).padding(.horizontal, 22)
                            if let notice = store.notice { noticeCard(notice).padding(.horizontal, 22) }
                            Spacer(minLength: 0)
                            if store.isRouting { routingIndicator.padding(.horizontal, 22) }
                            offlineBadge.padding(.horizontal, 22).padding(.bottom, 8)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        ScrollView {
                            bottomPanel(wide: true, extensionMaximumHeight: max(240, geometry.size.height - 24))
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(width: sideWidth)
                        .frame(maxHeight: panelCollapsed ? 72 : .infinity, alignment: .top)
                        .background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.cardRadius))
                        .clipShape(RoundedRectangle(cornerRadius: RidgeTheme.cardRadius))
                        .padding(.vertical, 8).padding(.trailing, 12)
                    }
                } else {
                    VStack(spacing: 0) {
                        topBar
                        HStack { offlineBadge; Spacer() }.padding(.horizontal, 22).padding(.top, 10)
                        HStack(alignment: .top) {
                            if let notice = store.notice { noticeCard(notice) }
                            Spacer(minLength: 0)
                            cameraControls()
                        }.padding(.horizontal, 22).padding(.top, 12)
                        Spacer(minLength: 0)
                        if store.isRouting { routingIndicator.padding(.bottom, 10) }
                        bottomPanel(extensionMaximumHeight: min(440, max(240, geometry.size.height * 0.54)))
                            .background(GeometryReader { proxy in Color.clear.preference(key: PlannerPanelHeight.self, value: proxy.size.height) })
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.sheet(isPresented: $showSettings) { SettingsView(store: store).presentationDragIndicator(.visible) }
        .fullScreenCover(isPresented: $showAreaSelection) { ExploreView(store: store, expanding: terrain.manifest, expansionFocus: store.areaExpansionFocus, onFinish: { showAreaSelection = false }).interactiveDismissDisabled(store.extensionInProgress) }
        .task(id: store.activeRoute?.modifiedAt) {
            let segments = store.activeRoute?.segments ?? []
            let samples = await Task.detached { RouteEngine.elevationProfile(segments) }.value
            if !Task.isCancelled { profileSamples = samples }
        }
        .onChange(of: store.editing) { _, editing in if editing { panelCollapsed = false } }
        .onChange(of: store.pendingExtension != nil) { _, _ in if store.pendingExtension != nil { panelCollapsed = false } }
        .onPreferenceChange(PlannerPanelHeight.self) { if $0 > 0 { panelHeight = $0 } }
            .foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest).preferredColorScheme(.light)
            .sheet(isPresented: $showPlaces) { PlacesSheet(terrain: terrain, store: store).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
            .sheet(isPresented: $showDetails) { WaypointsSheet(store: store).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
            .sheet(isPresented: $showNotes) { RouteNotesView(store: store).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
            .sheet(isPresented: $showHelp) { TerrainHelpView(terrain: terrain).presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
            .fileImporter(isPresented: $importGPX, allowedContentTypes: [.ridgeGPX, .xml], allowsMultipleSelection: false) { result in
                switch result { case .success(let urls): if let url = urls.first { store.importGPX(url) }; case .failure(let error): store.errorMessage = error.localizedDescription }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .ridgeGPX, defaultFilename: store.activeRoute?.name ?? "Ridge route") { result in
                if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
            }
            .alert("Name your route", isPresented: $rename) {
                TextField("Route name", text: $routeName)
                Button("Save") { if let route = store.activeRoute { store.renameRoute(route, to: routeName) } }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Ridge", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                if let retry = store.retryPreparation { Button("Retry") { store.errorMessage = nil; retry() } }
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .confirmationDialog("Edit route", isPresented: Binding(get: { editTarget != nil }, set: { if !$0 { editTarget = nil } }), titleVisibility: .visible) {
                if case .waypoint(let id) = editTarget {
                    Button("Move waypoint") {
                        store.movingWaypoint = store.activeRoute?.waypoints.firstIndex { $0.id == id }
                        store.insertingWaypoint = nil; editTarget = nil
                    }
                    Button("Delete waypoint", role: .destructive) { store.deleteWaypoint(id); editTarget = nil }
                }
                if case .segment(let index) = editTarget {
                    Button("Add a via point") { store.insertingWaypoint = index; store.movingWaypoint = nil; editTarget = nil }
                }
                Button("Cancel", role: .cancel) { editTarget = nil }
            }
            .confirmationDialog("Delete this route?", isPresented: $delete, titleVisibility: .visible) {
                Button("Delete route", role: .destructive) { if let route = store.activeRoute { store.deleteRoute(route) } }
            }
            .onChange(of: location.coordinate) { _, point in
                guard let point else { return }
                if terrain.manifest.bounds.contains(point) { store.selectedPoint = point; store.camera = TerrainCameraCommand(action: .focus(point)) }
                else { store.toast("Your position is outside this downloaded area.") }
            }
            .onChange(of: location.message) { _, message in if let message { store.toast(message) } }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            RoundControl(symbol: "arrow.left", label: "Back to your atlas") { store.closeTerrain() }.disabled(store.isRouting)
            VStack(alignment: .leading, spacing: 3) {
                Text(terrain.manifest.name).font(RidgeTheme.sectionTitle).lineLimit(1)
                Text(store.editing ? "Editing route" : "3D map").font(.caption).foregroundStyle(RidgeTheme.muted)
            }.padding(.vertical, 8).padding(.horizontal, 10).background(RidgeTheme.paper.opacity(0.88), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
            Spacer(minLength: 0)
            Menu {
                Button("Find a place", systemImage: "magnifyingglass") { showPlaces = true }
                Button("Expand area", systemImage: "rectangle.dashed") { showAreaSelection = true }
                Button("Add detail here", systemImage: "square.and.arrow.down") { store.requestExtensionAtViewpoint() }
                    .disabled(!store.viewingSurroundings)
                if store.routeNeedsDetail { Button("Add detail along route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { store.requestDetailAlongRoute() } }
                Button("Import GPX", systemImage: "square.and.arrow.down") { importGPX = true }
                Button("Map legend & gestures", systemImage: "info.circle") { showHelp = true }
                Button("Settings", systemImage: "slider.horizontal.3") { showSettings = true }
                if let route = store.activeRoute {
                    Divider()
                    Button("Rename route", systemImage: "pencil") { routeName = route.name; rename = true }
                    Button("Reverse direction", systemImage: "arrow.triangle.swap") { store.reverseRoute() }
                    Button("Route notes", systemImage: "note.text") { showNotes = true }
                    Button("Export GPX", systemImage: "square.and.arrow.up") { exportRoute() }
                    Button("Delete route", systemImage: "trash", role: .destructive) { delete = true }
                }
            } label: { Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold)).frame(width: 46, height: 46).background(RidgeTheme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius)) }.disabled(store.isRouting).accessibilityLabel("Terrain and route actions")
        }.padding(.horizontal, 22).padding(.top, 8)
    }
    @ViewBuilder private var offlineBadge: some View {
        let outside = store.viewingSurroundings || store.selectedPoint.map { !terrain.manifest.bounds.contains($0) } == true
        VStack(alignment: .leading, spacing: 8) {
            if outside {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.viewingSceneEdge ? "Edge of saved area" : "Outside detailed terrain")
                        .font(.system(size: 13, weight: .semibold))
                    Text(store.viewingSceneEdge ? "The map ends here. Expand area to check what terrain is available beyond it." : "This is a low-detail preview. Expand area to check available detail here.")
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(RidgeTheme.ink)
            }
            Button { showAreaSelection = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: outside ? "rectangle.dashed" : "checkmark.circle.fill")
                    if !outside { Text("Offline"); Rectangle().fill(RidgeTheme.forest.opacity(0.25)).frame(width: 1, height: 13) }
                    Text("Expand area").fontWeight(.semibold)
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 12)).foregroundStyle(RidgeTheme.forest)
                .padding(.horizontal, 13).frame(minHeight: 44)
                .background(outside ? RidgeTheme.forest.opacity(0.08) : RidgeTheme.panel.opacity(0.96), in: Capsule())
                .overlay { Capsule().strokeBorder(RidgeTheme.forest.opacity(0.12)) }
            }
            .disabled(store.isRouting || store.extensionInProgress)
            .accessibilityLabel(outside ? "Expand area" : "Detailed terrain, offline. Expand area")
            .accessibilityHint("Choose a larger area around this view. Check availability and size before saving; your route is kept.")
        }
        .padding(outside ? 12 : 0)
        .frame(maxWidth: outside ? 310 : nil, alignment: .leading)
        .background(outside ? RidgeTheme.panel.opacity(0.97) : Color.clear, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
    }

    private func noticeCard(_ notice: String) -> some View {
        Text(notice).font(.system(size: 13, weight: .medium)).lineSpacing(3).foregroundStyle(RidgeTheme.ink)
            .padding(14).background(RidgeTheme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius)).frame(maxWidth: 285, alignment: .leading)
    }

    private var routingIndicator: some View {
        HStack(spacing: 9) { ProgressView().tint(RidgeTheme.forest); Text("Calculating route…").font(.footnote.weight(.medium)) }
            .padding(12).background(RidgeTheme.panel, in: Capsule())
    }

    private func cameraControls(horizontal: Bool = false) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        return layout {
            RoundControl(symbol: "arrow.up", label: "Face north") { store.camera = TerrainCameraCommand(action: .north) }
            Menu {
                Button("Fit route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { store.camera = TerrainCameraCommand(action: .fitRoute) }
                    .disabled(store.activeRoute?.points.isEmpty != false)
                Button("Fit whole terrain", systemImage: "viewfinder") { store.camera = TerrainCameraCommand(action: .home) }
                Button("Zoom in", systemImage: "plus.magnifyingglass") { store.camera = TerrainCameraCommand(action: .zoomIn) }
                Button("Zoom out", systemImage: "minus.magnifyingglass") { store.camera = TerrainCameraCommand(action: .zoomOut) }
            } label: {
                Image(systemName: "viewfinder").font(.system(size: 17, weight: .medium))
                    .frame(width: 46, height: 46)
                    .background(RidgeTheme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: RidgeTheme.controlRadius).strokeBorder(RidgeTheme.ink.opacity(0.06)))
            }.accessibilityLabel("Fit or zoom terrain")
            RoundControl(symbol: "square.3.layers.3d.top.filled", label: "Look straight down within 3D") { store.camera = TerrainCameraCommand(action: .overhead) }
            RoundControl(symbol: "magnifyingglass", label: "Find a place in this area") { showPlaces = true }
            RoundControl(symbol: "location", label: "Show my position") { location.locate() }
        }
    }
    @ViewBuilder private func bottomPanel(wide: Bool = false, extensionMaximumHeight: CGFloat = 440) -> some View {
        if store.pendingExtension != nil {
            AreaExtensionCard(store: store, currentSpacing: terrain.level.spacing, maximumHeight: extensionMaximumHeight, compact: wide)
                .frame(maxWidth: 600)
                .padding(.horizontal, !wide && UIDevice.current.userInterfaceIdiom == .pad ? 28 : 0)
        } else {
            VStack(alignment: .leading, spacing: 14) {
            if !wide { Capsule().fill(RidgeTheme.line).frame(width: 30, height: 3).frame(maxWidth: .infinity).padding(.top, 2) }
            Button { panelCollapsed.toggle() } label: {
                HStack { Image(systemName: panelCollapsed ? "chevron.up" : "chevron.down"); Text(panelCollapsed ? "Show planner" : "Hide planner"); Spacer() }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 36)
            }.buttonStyle(.plain).accessibilityHint("Change how much terrain is visible")
            if !panelCollapsed {
            if let route = store.activeRoute {
                routeHeader(route)
                if store.routeNeedsDetail {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Overview terrain", systemImage: "mountain.2").font(.subheadline.weight(.semibold))
                        Text(route.points.count > 1 ? "Dashed sections use overview terrain. Sketch lines are manual connections; add detail to inspect them closely." : "This waypoint is on overview terrain. Add detail here to inspect the ground closely.")
                            .font(.caption).foregroundStyle(RidgeTheme.muted)
                        Button { store.requestDetailAlongRoute() } label: {
                            Label("Add detail along route", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered).tint(RidgeTheme.forest).disabled(store.isRouting || store.extensionInProgress)
                    }.padding(12).background(RidgeTheme.forest.opacity(0.06), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                }
                if route.points.count > 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        statMetric(RidgeTheme.distance(statistics.distanceMeters), unit: statistics.distanceMeters >= 1000 ? "km" : "m", title: "Distance")
                        Spacer()
                        statMetric(statistics.hasCompleteElevation ? "\(Int(statistics.ascentMeters.rounded()))" : "—", unit: "m ↑", title: "Ascent")
                        Spacer()
                        statMetric(statistics.hasCompleteElevation ? duration(statistics.estimatedMinutes) : "—", unit: "", title: "Time est.")
                    }
                    if profileExpanded {
                        ElevationProfileView(samples: profileSamples, onSelect: { store.selectedPoint = $0.coordinate },
                                             onFocus: { point in
                                                 let coverage = terrain.horizon?.layers.last?.metadata.bounds ?? terrain.manifest.bounds
                                                 if coverage.contains(point.coordinate) { store.camera = TerrainCameraCommand(action: .focus(point.coordinate)) }
                                                 else { store.requestExtension(at: point.coordinate) }
                                             })
                    }
                }
                if store.editing { editingControls(route) }
                else {
                    HStack(spacing: 10) {
                        if !imported {
                            Button { store.editing = true } label: { Label("Continue route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }.buttonStyle(RidgeButtonStyle())
                        } else {
                            Button { store.startRoute() } label: { Label("Plan a new route", systemImage: "plus") }.buttonStyle(RidgeButtonStyle())
                        }
                        Button { exportRoute() } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 19)).frame(width: 53, height: 53).background(RidgeTheme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius)) }.accessibilityLabel("Export route as GPX")
                    }.disabled(store.isRouting)
                }
            } else {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Route planning").font(RidgeTheme.sectionTitle)
                        Text("Add waypoints to plan a route across this area.").font(.system(size: 12)).foregroundStyle(RidgeTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                Button { store.startRoute() } label: { HStack { Image(systemName: "point.topleft.down.to.point.bottomright.curvepath"); Text("Plan a route"); Spacer(); Image(systemName: "arrow.right") }.padding(.horizontal, 18) }.buttonStyle(RidgeButtonStyle())
                HStack { Text(gestureStyle.shortGuide); Spacer(); Button("Guide") { showHelp = true }.fontWeight(.semibold) }.font(.caption).foregroundStyle(RidgeTheme.muted)
            }
            }
        }.padding(.horizontal, wide ? 18 : 22).padding(.top, 10).padding(.bottom, 18)
            .background(RidgeTheme.panel.opacity(0.98), in: UnevenRoundedRectangle(topLeadingRadius: RidgeTheme.cardRadius, topTrailingRadius: RidgeTheme.cardRadius))
            .overlay(alignment: .top) { UnevenRoundedRectangle(topLeadingRadius: RidgeTheme.cardRadius, topTrailingRadius: RidgeTheme.cardRadius).strokeBorder(RidgeTheme.ink.opacity(0.05)) }
            .frame(maxWidth: 600).padding(.horizontal, !wide && UIDevice.current.userInterfaceIdiom == .pad ? 28 : 0)
        }
    }
    private func routeHeader(_ route: RidgeRoute) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: store.editing ? "Editing route" : imported ? "Imported GPX track" : "Saved route")
                if store.isRouting { Text("Updating route…").font(.caption).foregroundStyle(RidgeTheme.muted) }
                else if store.routeSaved { Label(UIDevice.current.userInterfaceIdiom == .pad ? "Saved on this iPad" : "Saved on this device", systemImage: "checkmark.circle").font(.caption).foregroundStyle(RidgeTheme.muted) }
                Button { routeName = route.name; rename = true } label: { Text(route.name).font(RidgeTheme.sectionTitle).lineLimit(1) }.disabled(store.isRouting)
            }
            Spacer(minLength: 6)
            if route.points.count > 1 { Button { profileExpanded.toggle() } label: { Image(systemName: "chart.xyaxis.line").font(.system(size: 18)).frame(width: 38, height: 38).background(RidgeTheme.ink.opacity(0.04), in: Circle()) }.accessibilityLabel("Toggle elevation profile") }
        }
    }
    private func editingControls(_ route: RidgeRoute) -> some View {
        VStack(spacing: 12) {
            HStack {
                Menu {
                    ForEach(RoutePlanningMode.allCases) { mode in Button { store.planningMode = mode } label: { Label(mode.title, systemImage: mode == .paths ? "point.topleft.down.to.point.bottomright.curvepath" : "line.diagonal") } }
                } label: { HStack(spacing: 6) { Circle().fill(store.planningMode == .paths ? RidgeTheme.forest : RidgeTheme.orange).frame(width: 6, height: 6); Text(store.planningMode.title); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }.font(.system(size: 12, weight: .semibold)).padding(.vertical, 9).padding(.horizontal, 12).background(RidgeTheme.ink.opacity(0.04), in: Capsule()) }
                Spacer()
                Button { showDetails = true } label: { Text("\(route.waypoints.count) \(route.waypoints.count == 1 ? "point" : "points")").font(.system(size: 12, weight: .medium)); Image(systemName: "list.bullet").font(.system(size: 12)) }
            }
            if store.insertingWaypoint != nil {
                HStack { Text("Tap a position for your via point."); Spacer(); Button("Cancel") { store.insertingWaypoint = nil } }.font(.footnote).foregroundStyle(RidgeTheme.orange)
            } else if let moving = store.movingWaypoint {
                HStack { Text("Tap a new position for point \(moving + 1)."); Spacer(); Button("Cancel") { store.movingWaypoint = nil } }.font(.footnote).foregroundStyle(RidgeTheme.orange)
            } else if store.planningMode == .paths && store.viewingSurroundings {
                Text("Expand this area to follow mapped paths here.").font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            } else if store.planningMode == .paths && terrain.graph?.edges.isEmpty != false {
                Text("No walking paths in this selection. Expand the area or choose Direct line.").font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            } else if route.waypoints.count < 2 {
                Text(store.viewingSurroundings ? (route.waypoints.isEmpty ? "Tap the terrain to start a route sketch." : "Tap your next point to extend the sketch.") : (route.waypoints.isEmpty ? "Tap the terrain to place your start." : "Start placed. Tap your next point to trace the route.")).font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            } else if store.planningMode == .direct || route.segments.contains(where: { $0.mode == RoutePlanningMode.direct.rawValue }) {
                Text("Direct lines are manual connections; they do not establish a walkable path.").font(.system(size: 10)).foregroundStyle(RidgeTheme.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    routeHistoryControls(route)
                    Spacer(minLength: 0)
                    finishRouteButton()
                }
                VStack(spacing: 8) {
                    HStack(spacing: 9) { routeHistoryControls(route); Spacer(minLength: 0) }
                    finishRouteButton(fullWidth: true)
                }
            }
        }.disabled(store.isRouting)
    }
    @ViewBuilder private func routeHistoryControls(_ route: RidgeRoute) -> some View {
        Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 45) }.disabled(store.undoStack.isEmpty).accessibilityLabel("Undo last route change")
        Button { store.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 45) }.disabled(store.redoStack.isEmpty).accessibilityLabel("Redo route change")
        if route.waypoints.count > 1 { Button { store.closeLoop() } label: { Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90").frame(width: 44, height: 45) }.accessibilityLabel("Return to start") }
    }
    private func finishRouteButton(fullWidth: Bool = false) -> some View {
        Button { store.finishRoute() } label: {
            HStack { Image(systemName: "checkmark"); Text("Done").lineLimit(1) }
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 25)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 45)
                .foregroundStyle(RidgeTheme.panel).background(RidgeTheme.forest, in: Capsule())
        }
    }
    private func statMetric(_ value: String, unit: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) { Text(value).font(.system(size: 27, weight: .medium, design: .default)); Text(unit).font(.system(size: 11)).foregroundStyle(RidgeTheme.muted) }
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(RidgeTheme.muted)
        }
    }
    private func duration(_ minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded())), hours = total / 60
        return hours > 0 ? "\(hours)h \(total % 60)m" : "\(total)m"
    }
    private func exportRoute() {
        guard let route = store.activeRoute else { return }
        do { exportDocument = try GPXDocument(route: route); exporting = true }
        catch { store.errorMessage = error.localizedDescription }
    }
}

struct ElevationProfileView: View {
    let samples: [RouteProfileSample]
    var onSelect: (RoutePoint) -> Void
    var onFocus: (RoutePoint) -> Void
    @State private var selection: Int?
    private var selected: RouteProfileSample? { selection.flatMap { samples.indices.contains($0) ? samples[$0] : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let elevations = samples.compactMap { $0.point.elevation }
                let minimum = elevations.min() ?? 0, maximum = elevations.max() ?? 1
                let span = max(25, maximum - minimum), total = max(1, samples.last?.distance ?? 1)
                Canvas { context, size in
                    var path = Path(), hasPoint = false
                    for (index, sample) in samples.enumerated() {
                        let x = sample.distance / total * size.width
                        if index > 0 && (sample.unknownBefore || sample.point.elevation == nil) {
                            let previousX = samples[index - 1].distance / total * size.width
                            context.fill(Path(CGRect(x: previousX, y: 5, width: max(2, x - previousX), height: size.height - 20)), with: .color(RidgeTheme.orange.opacity(0.14)))
                        }
                        guard let elevation = sample.point.elevation else { hasPoint = false; continue }
                        let p = CGPoint(x: x, y: size.height - 14 - (elevation - minimum) / span * (size.height - 28))
                        if !hasPoint || sample.breakBefore || sample.unknownBefore { path.move(to: p); hasPoint = true } else { path.addLine(to: p) }
                    }
                    context.stroke(path, with: .color(RidgeTheme.forest), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    context.draw(Text("\(Int(maximum)) m").font(.caption2).foregroundStyle(RidgeTheme.muted), at: CGPoint(x: size.width, y: 0), anchor: .topTrailing)
                    context.draw(Text("0 km").font(.caption2).foregroundStyle(RidgeTheme.muted), at: CGPoint(x: 0, y: size.height), anchor: .bottomLeading)
                    context.draw(Text(String(format: "%.1f km", total / 1000)).font(.caption2).foregroundStyle(RidgeTheme.muted), at: CGPoint(x: size.width, y: size.height), anchor: .bottomTrailing)
                    if let selected {
                        let x = selected.distance / total * size.width
                        context.fill(Path(CGRect(x: x, y: 4, width: 1.5, height: size.height - 16)), with: .color(RidgeTheme.orange))
                    }
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let fraction = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                    guard let index = samples.indices.min(by: { abs(samples[$0].distance / total - fraction) < abs(samples[$1].distance / total - fraction) }) else { return }
                    select(index)
                })
                .accessibilityLabel("Elevation profile")
                .accessibilityValue(selected.map { String(format: "%.1f kilometres", $0.distance / 1000) } ?? "Adjust to inspect the route")
                .accessibilityAdjustableAction { direction in
                    let step = max(1, samples.count / 20)
                    select((selection ?? 0) + (direction == .increment ? step : -step))
                }
            }.frame(height: 96)
            if let selected {
                ViewThatFits(in: .horizontal) {
                    HStack { inspection(selected); Spacer(); focusButton(selected) }
                    VStack(alignment: .leading, spacing: 8) { inspection(selected); focusButton(selected) }
                }
            } else { Text("Slide along the profile to inspect your route.").font(.caption).foregroundStyle(RidgeTheme.muted) }
            if samples.contains(where: { $0.unknownBefore || $0.point.elevation == nil }) {
                Label("Shaded gaps need elevation detail", systemImage: "square.dashed").font(.caption).foregroundStyle(RidgeTheme.muted)
            }
        }.onChange(of: samples) { _, _ in selection = nil }
    }
    private func inspection(_ sample: RouteProfileSample) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%.2f km · ", sample.distance / 1000) + (sample.point.elevation.map { "\(Int($0)) m" } ?? "Elevation unknown")).font(.subheadline.monospacedDigit())
            Text(sample.gradientPercent.map { String(format: "Approx. grade %+.0f%%", $0) } ?? "Grade unavailable here").font(.caption).foregroundStyle(RidgeTheme.muted)
        }
    }
    private func focusButton(_ sample: RouteProfileSample) -> some View {
        Button("Show here", systemImage: "scope") { onFocus(sample.point) }.font(.subheadline).frame(minHeight: 44)
    }
    private func select(_ index: Int) {
        guard !samples.isEmpty else { return }
        let index = min(samples.count - 1, max(0, index))
        selection = index; onSelect(samples[index].point)
    }
}

struct PlacesSheet: View {
    let terrain: LoadedTerrain
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var places: [MapPlace] { terrain.manifest.places.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.sorted { ($0.kind == "peak" ? 0 : 1, $0.name) < ($1.kind == "peak" ? 0 : 1, $1.name) } }
    var body: some View {
        NavigationStack {
            List(places) { place in
                HStack(spacing: 12) {
                    Image(systemName: place.kind == "peak" ? "mountain.2" : "mappin").foregroundStyle(RidgeTheme.forest)
                    Button { store.camera = TerrainCameraCommand(action: .focus(place.coordinate)); store.selectedPoint = place.coordinate; dismiss() } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(place.name).foregroundStyle(RidgeTheme.ink); if let elevation = place.elevation { Text("\(Int(elevation)) m").font(.caption).foregroundStyle(RidgeTheme.muted) } }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    if store.editing { Button { store.tapTerrain(place.coordinate); dismiss() } label: { Image(systemName: "plus.circle.fill").foregroundStyle(RidgeTheme.forest).font(.title3) }.buttonStyle(.borderless).accessibilityLabel("Add \(place.name) to route") }
                }.padding(.vertical, 5).listRowBackground(RidgeTheme.panel)
            }.searchable(text: $query, prompt: "Search this area").navigationTitle("Places").navigationBarTitleDisplayMode(.inline).scrollContentBackground(.hidden).background(RidgeTheme.paper)
        }.tint(RidgeTheme.forest)
    }
}

struct WaypointsSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Select a point to move it, then tap its new position on the terrain.").font(.footnote).foregroundStyle(RidgeTheme.muted) }
                ForEach(Array((store.activeRoute?.waypoints ?? []).enumerated()), id: \.element.id) { index, waypoint in
                    Button {
                        store.insertingWaypoint = nil; store.movingWaypoint = index; store.camera = TerrainCameraCommand(action: .focus(waypoint.point.coordinate)); store.selectedPoint = waypoint.point.coordinate; dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            Text("\(index + 1)").font(.system(size: 12, weight: .bold, design: .default)).frame(width: 32, height: 32).background(RidgeTheme.selection, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(waypoint.name ?? (index == 0 ? "Start" : "Waypoint \(index + 1)"))
                                Text(String(format: "%.5f, %.5f", waypoint.point.coordinate.latitude, waypoint.point.coordinate.longitude)).font(.system(size: 10, design: .default)).foregroundStyle(RidgeTheme.muted)
                            }
                            Spacer(); Text(waypoint.point.elevation.map { "\(Int($0)) m" } ?? "—").font(.caption); Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }.foregroundStyle(RidgeTheme.ink)
                    }.disabled(store.isRouting).listRowBackground(RidgeTheme.panel)
                }
            }.scrollContentBackground(.hidden).background(RidgeTheme.paper).navigationTitle("Route points").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct RouteNotesView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    var body: some View {
        NavigationStack {
            TextEditor(text: $draft).padding(20).scrollContentBackground(.hidden).background(RidgeTheme.paper).navigationTitle("Route notes").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { store.updateNotes(draft); dismiss() }.disabled(store.isRouting) } }
        }.onAppear { draft = store.activeRoute?.notes ?? "" }.tint(RidgeTheme.forest)
    }
}

struct TerrainHelpView: View {
    private let gestureStyle = TerrainGestureStyle.moveWithOneFinger
    let terrain: LoadedTerrain
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Map help").font(RidgeTheme.pageTitle)
                helpRow("hand.draw", "Map controls", gestureStyle.guide)
                helpRow("point.topleft.down.to.point.bottomright.curvepath", "Planning a route", "Tap Plan a route, then place points on mapped paths. Follow paths uses the downloaded walking network. Direct line draws a manual connection.")
                helpRow("square.dashed", "Detailed and overview terrain", "Expand area is always available on the 3D map. Tap distant terrain or move beyond your detailed area to see the coverage explanation, then expand around that location. Availability and size are checked before saving. You can keep sketching beyond detailed coverage; overview lines are manual connections, not followed paths.")
                Divider()
                Text("Map legend").font(.headline)
                MapLegendView()
                Text("Walking times and elevation totals are estimates. A mapped path does not establish access permission or mountain difficulty.").font(.footnote).foregroundStyle(RidgeTheme.muted).lineSpacing(3)
                ForEach(terrain.manifest.sources, id: \.name) { source in VStack(alignment: .leading, spacing: 4) { Text(source.attribution); Text(source.license).foregroundStyle(RidgeTheme.muted) }.font(.system(size: 10)) }
            }.padding(28)
        }.background(RidgeTheme.panel).foregroundStyle(RidgeTheme.ink)
    }
    private func helpRow(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 15) { Image(systemName: symbol).font(.title3).frame(width: 30).foregroundStyle(RidgeTheme.forest); VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(text).font(.subheadline).foregroundStyle(RidgeTheme.muted).lineSpacing(3) } }
    }
}

@MainActor @Observable final class RidgeLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    var coordinate: GeoPoint?
    var message: String?
    private let manager = CLLocationManager()
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters }
    func locate() {
        message = nil
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: message = "Location access is off. Enable it for Ridge in Settings to show your position."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() } }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0, abs(location.timestamp.timeIntervalSinceNow) < 60 else { return }
        coordinate = GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { message = "Your position could not be found. You can keep planning offline." }
}

private struct PlannerPanelHeight: PreferenceKey { static let defaultValue: CGFloat = 210; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() } }
