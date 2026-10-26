import SwiftUI

struct RouteLibraryView: View {
    @Bindable var store: AppStore
    @Bindable var world: WorldModel
    @State private var query = ""
    @State private var favouritesOnly = false
    @AppStorage("ridge.favouriteRoutes") private var favouriteData = Data()
    @AppStorage("ridge.routeLibrary.order") private var orderValue = RouteLibraryOrder.recent.rawValue
    @State private var distances: [UUID: Double] = [:]
    @State private var briefRoute: RidgeRoute?
    private var order: RouteLibraryOrder { RouteLibraryOrder(rawValue: orderValue) ?? .recent }
    private var routesRevision: String { store.routes.map { "\($0.id)|\($0.modifiedAt.timeIntervalSince1970)" }.joined(separator: ";") }
    private var favouriteIDs: Set<UUID> { Set((try? JSONDecoder().decode([UUID].self, from: favouriteData)) ?? []) }
    private var visibleRoutes: [RidgeRoute] {
        let filtered = store.routes.filter { route in
            (!favouritesOnly || favouriteIDs.contains(route.id)) &&
            (query.isEmpty || route.name.localizedCaseInsensitiveContains(query) || route.notes.localizedCaseInsensitiveContains(query))
        }
        let sorted = order.sorted(filtered, distances: distances)
        return order == .recent ? sorted.sorted { favouriteIDs.contains($0.id) && !favouriteIDs.contains($1.id) } : sorted
    }
    private func toggleFavourite(_ id: UUID) {
        var ids = favouriteIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        if let data = try? JSONEncoder().encode(Array(ids)) { favouriteData = data }
    }
    @State private var renameTarget: RidgeRoute?
    @State private var renameText = ""
    @State private var removal: RidgeRoute?
    @State private var exportDocument: GPXDocument?
    @State private var exportName = "Ridge route.gpx"
    @State private var showingExporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !store.routes.isEmpty {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(RidgeTheme.muted)
                        TextField("Search routes and notes", text: $query).autocorrectionDisabled()
                        if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                    }.padding(14).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                    HStack {
                        Text("\(visibleRoutes.count) \(visibleRoutes.count == 1 ? "route" : "routes")").font(.subheadline).foregroundStyle(RidgeTheme.muted)
                        Spacer()
                        Menu {
                            Picker("Sort routes", selection: $orderValue) {
                                ForEach(RouteLibraryOrder.allCases) { item in
                                    Text(item.title).tag(item.rawValue)
                                        .disabled((item == .shortest || item == .longest) && !store.routes.allSatisfy { distances[$0.id] != nil })
                                }
                            }
                        } label: { Label("Sort", systemImage: "arrow.up.arrow.down").frame(minHeight: 44) }
                            .accessibilityLabel("Sort routes").accessibilityValue(order.title)
                        Button { favouritesOnly.toggle() } label: {
                            Label("Favourites", systemImage: favouritesOnly ? "star.fill" : "star")
                                .font(.subheadline).padding(.horizontal, 12).frame(minHeight: 44)
                                .background(favouritesOnly ? RidgeTheme.selection : .clear, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                        }.buttonStyle(.plain).accessibilityAddTraits(favouritesOnly ? .isSelected : [])
                    }
                }
                if store.routes.isEmpty { emptyState }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
                        ForEach(visibleRoutes) { route in
                            let entry = store.containingEntry(for:route)
                            Button { store.openRoute(route,savedWorldBounds:world.offlineBounds) } label: {
                                LibraryRouteCard(route: route, entry: entry, packs: store.packs,
                                                 favourite: favouriteIDs.contains(route.id), savedWorldBounds:world.offlineBounds,
                                                 coverageRevision:world.offlineCoverageRevision,
                                                 worldMap:WorldRouteMapContext(catalog:world.catalog,root:world.libraryRoot,savedBounds:world.offlineBounds,coverageRevision:world.offlineCoverageRevision))
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Before you go", systemImage: "figure.walk") { briefRoute = route }
                                    Button("Open in 3D", systemImage: "mountain.2") { store.openRoute(route,savedWorldBounds:world.offlineBounds) }.disabled(store.isRouting)
                                    Button(favouriteIDs.contains(route.id) ? "Remove favourite" : "Add to favourites", systemImage: favouriteIDs.contains(route.id) ? "star.fill" : "star") { toggleFavourite(route.id) }
                                    Button("Export GPX", systemImage: "square.and.arrow.up") { export(route) }
                                    Button("Rename", systemImage: "pencil") { renameTarget = route; renameText = route.name }.disabled(store.isRouting)
                                    Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateRoute(route) }.disabled(store.isRouting)
                                    Button("Delete route", systemImage: "trash", role: .destructive) { removal = route }.disabled(store.isRouting)
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    Menu {
                                        Button("Before you go", systemImage: "figure.walk") { briefRoute = route }
                                        Button(favouriteIDs.contains(route.id) ? "Remove favourite" : "Add to favourites", systemImage: favouriteIDs.contains(route.id) ? "star.fill" : "star") { toggleFavourite(route.id) }
                                    Button("Export GPX", systemImage: "square.and.arrow.up") { export(route) }
                                        Button("Rename", systemImage: "pencil") { renameTarget = route; renameText = route.name }.disabled(store.isRouting)
                                        Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateRoute(route) }.disabled(store.isRouting)
                                        Button("Delete route", systemImage: "trash", role: .destructive) { removal = route }.disabled(store.isRouting)
                                    } label: {
                                        Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(RidgeTheme.muted).frame(width: 42, height: 42)
                                            .background(RidgeTheme.panel.opacity(0.95), in: Circle())
                                    }.accessibilityLabel("Options for \(route.name)").padding(12)
                                }
                        }
                    }
                    if visibleRoutes.isEmpty {
                        Text(favouritesOnly ? "No favourite routes match. Turn off the filter to see all routes." : "No routes match your search.").font(.subheadline).foregroundStyle(RidgeTheme.muted)
                    }
                    Text("Routes are saved automatically on this device.")
                        .font(.footnote).foregroundStyle(RidgeTheme.muted).lineSpacing(4).padding(.horizontal, 3)
                }
            }.padding(24).frame(maxWidth: 1280).frame(maxWidth: .infinity)
        }.background(RidgeTheme.paper).foregroundStyle(RidgeTheme.ink)
            .task(id: routesRevision) {
                let routes = store.routes
                let result = await Task.detached(priority: .utility) {
                    Dictionary(uniqueKeysWithValues: routes.map { ($0.id, RouteEngine.statistics(for: $0).distanceMeters) })
                }.value
                if !Task.isCancelled { distances = result }
            }
            .sheet(item: $briefRoute) { route in
                RouteBriefSheet(store: store, route: route, savedBounds: world.offlineBounds, coverageRevision: world.offlineCoverageRevision)
            }
            .alert("Rename route", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Route name", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Save") {
                    if let target = renameTarget { store.renameRoute(target, to: renameText) }
                    renameTarget = nil
                }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isRouting)
            }
            .confirmationDialog("Delete this route? Its saved line and notes will be removed from this device.", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                Button("Delete route", role: .destructive) { if let removal { store.deleteRoute(removal) }; removal = nil }.disabled(store.isRouting)
                Button("Cancel", role: .cancel) { removal = nil }
            }
            .fileExporter(isPresented: $showingExporter, document: exportDocument, contentType: .ridgeGPX, defaultFilename: exportName) { result in
                switch result {
                case .success: store.toast("GPX exported.")
                case .failure(let error): if (error as NSError).code != NSUserCancelledError { store.errorMessage = "GPX could not be exported: \(error.localizedDescription)" }
                }
            }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Routes").font(RidgeTheme.pageTitle)
            }
            Spacer()
            Button { store.showGPXImporter = true } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44).foregroundStyle(RidgeTheme.forest)
            }.accessibilityLabel("Import GPX").disabled(store.isRouting)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 32, weight: .regular)).foregroundStyle(RidgeTheme.muted).accessibilityHidden(true)
            VStack(spacing: 12) {
                Text("No saved routes")
                    .font(RidgeTheme.pageTitle).multilineTextAlignment(.center)
                Text("Open an area to plan a route, or import a GPX file.")
                    .font(.system(size: 14)).lineSpacing(4).foregroundStyle(RidgeTheme.muted).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button("Find an area") { store.tab = .explore }.buttonStyle(RidgeButtonStyle())
                Button { store.showGPXImporter = true } label: { Label("Import a GPX file", systemImage: "square.and.arrow.down") }
                    .buttonStyle(RidgeButtonStyle(secondary: true)).disabled(store.isRouting)
            }.padding(.top, 3)
        }.padding(26).frame(maxWidth: .infinity).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.cardRadius)).padding(.top, 8)
    }

    private func export(_ route: RidgeRoute) {
        do {
            exportDocument = try GPXDocument(route: route)
            let name = route.name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>" )).joined(separator: "-")
            exportName = String(name.prefix(120)) + ".gpx"
            showingExporter = true
        } catch { store.errorMessage = error.localizedDescription }
    }
}

private struct LibraryRouteCard: View {
    let route: RidgeRoute
    let entry: PackEntry?
    let packs: PackStore
    let favourite: Bool
    var savedWorldBounds:[GeoBounds]
    var coverageRevision:Int
    var worldMap:WorldRouteMapContext
    @AppStorage private var tripPlanData: Data
    @State private var worldCoverage:RouteOfflineCoverage?
    private var terrainReady:Bool { entry?.installed == true || worldCoverage?.isComplete == true }
    private var availabilityText:String {
        if terrainReady { return "Available offline" }
        if worldCoverage?.openingPoint != nil { return "Part of route available offline" }
        return worldCoverage == nil ? "Checking saved maps…" : "Map needed for 3D"
    }
    @State private var summary: RouteStatistics?

    init(route: RidgeRoute, entry: PackEntry?, packs: PackStore, favourite: Bool,
         savedWorldBounds: [GeoBounds], coverageRevision: Int, worldMap: WorldRouteMapContext) {
        self.route = route; self.entry = entry; self.packs = packs; self.favourite = favourite
        self.savedWorldBounds = savedWorldBounds; self.coverageRevision = coverageRevision; self.worldMap = worldMap
        _tripPlanData = AppStorage(wrappedValue: Data(), RouteTripPlan.storageKey(for: route.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryMapPreview(entry: entry, route: route, packs: packs,worldMap:worldMap)
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(entry?.manifest.name ?? (route.segments.contains { $0.mode == "imported" } ? "Imported GPX" : "Saved route")).font(.subheadline).foregroundStyle(RidgeTheme.muted)
                    Spacer(minLength: 4)
                    if favourite { Image(systemName: "star.fill").font(.caption).foregroundStyle(RidgeTheme.forest).accessibilityLabel("Favourite route") }
                }
                Text(route.name).font(RidgeTheme.sectionTitle).lineLimit(2, reservesSpace: true)
                HStack(spacing: 6) {
                    Image(systemName: route.segments.contains { $0.mode == "imported" } ? "arrow.down.doc" : "point.topleft.down.to.point.bottomright.curvepath")
                    Text(route.modifiedAt, format: .dateTime.day().month(.abbreviated).year())
                }.font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
            }
            if let summary {
                HStack(alignment: .firstTextBaseline) {
                    metric("Distance", value: RidgeTheme.distance(summary.distanceMeters), suffix: summary.distanceMeters >= 1000 ? "km" : "m")
                    Spacer(minLength: 8)
                    metric("Ascent est.", value: summary.hasElevation ? "\(Int(summary.ascentMeters.rounded()))" : "—", suffix: summary.hasElevation ? "m" : "")
                    Spacer(minLength: 8)
                    metric("Time est.", value: RouteTripPlan.duration((RouteTripPlan.decode(tripPlanData) ?? .init()).totalMinutes(for: summary)), suffix: "")
                }
            } else { ProgressView().tint(RidgeTheme.forest).frame(maxWidth: .infinity, minHeight: 66) }
            Rectangle().fill(RidgeTheme.line.opacity(0.7)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: terrainReady ? "checkmark.circle.fill" : "square.dashed")
                Text(availabilityText)
                Spacer(minLength: 3)
            }.padding(.trailing, 38).font(.system(size: 11, weight: .medium)).foregroundStyle(terrainReady ? RidgeTheme.forest : RidgeTheme.muted)
            }.padding(20)
        }.background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.cardRadius))
            .clipShape(RoundedRectangle(cornerRadius: RidgeTheme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: RidgeTheme.cardRadius).strokeBorder(RidgeTheme.forest.opacity(0.06)))
            .task(id:"\(route.id)|\(route.modifiedAt)|\(coverageRevision)") {
                let snapshot=route,bounds=savedWorldBounds
                let result=await Task.detached(priority:.utility) {
                    (RouteEngine.statistics(for:snapshot),RouteEngine.offlineCoverage(for:snapshot,in:bounds))
                }.value
                if !Task.isCancelled { summary=result.0;worldCoverage=result.1 }
            }
    }

    private func metric(_ title: String, value: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(RidgeTheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 20, weight: .medium, design: .default))
                Text(suffix).font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
            }
        }
    }

}
