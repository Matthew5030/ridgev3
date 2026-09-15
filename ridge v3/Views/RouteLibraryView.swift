import SwiftUI

struct RouteLibraryView: View {
    @Bindable var store: AppStore
    @State private var query = ""
    @State private var favouritesOnly = false
    @AppStorage("ridge.favouriteRoutes") private var favouriteData = Data()
    private var favouriteIDs: Set<UUID> { Set((try? JSONDecoder().decode([UUID].self, from: favouriteData)) ?? []) }
    private var visibleRoutes: [RidgeRoute] {
        store.routes.filter { route in
            (!favouritesOnly || favouriteIDs.contains(route.id)) &&
            (query.isEmpty || route.name.localizedCaseInsensitiveContains(query) || route.notes.localizedCaseInsensitiveContains(query))
        }.sorted { a, b in
            if favouriteIDs.contains(a.id) != favouriteIDs.contains(b.id) { return favouriteIDs.contains(a.id) }
            return a.modifiedAt > b.modifiedAt
        }
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
                    }.padding(14).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 14))
                    Toggle("Favourites only", isOn: $favouritesOnly).font(.subheadline).tint(RidgeTheme.forest)
                }
                if store.routes.isEmpty { emptyState }
                else {
                    HStack(spacing: 7) {
                        Circle().fill(RidgeTheme.forest).frame(width: 5, height: 5)
                        Text("\(store.routes.count) \(store.routes.count == 1 ? "ROUTE" : "ROUTES") · SAVED ON THIS DEVICE")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                    }.foregroundStyle(RidgeTheme.muted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
                        ForEach(visibleRoutes) { route in
                            let entry = store.entries.first { $0.id == route.regionID }
                            Button { store.openRoute(route) } label: {
                                LibraryRouteCard(route: route, entry: entry, packs: store.packs,
                                                 favourite: favouriteIDs.contains(route.id))
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open in 3D", systemImage: "mountain.2") { store.openRoute(route) }.disabled(store.isRouting)
                                    Button(favouriteIDs.contains(route.id) ? "Remove favourite" : "Add to favourites", systemImage: favouriteIDs.contains(route.id) ? "star.fill" : "star") { toggleFavourite(route.id) }
                                    Button("Export GPX", systemImage: "square.and.arrow.up") { export(route) }
                                    Button("Rename", systemImage: "pencil") { renameTarget = route; renameText = route.name }.disabled(store.isRouting)
                                    Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateRoute(route) }.disabled(store.isRouting)
                                    Button("Delete route", systemImage: "trash", role: .destructive) { removal = route }.disabled(store.isRouting)
                                }
                                .overlay(alignment: .topTrailing) {
                                    Menu {
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
                    Text("A route begins in a landscape. Open a saved area to plan a new line in 3D.")
                        .font(.footnote).foregroundStyle(RidgeTheme.muted).lineSpacing(4).padding(.horizontal, 3)
                }
            }.padding(24).frame(maxWidth: 1280).frame(maxWidth: .infinity)
        }.background(RidgeTheme.paper).foregroundStyle(RidgeTheme.ink)
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
                Eyebrow(text: "Lines worth following")
                Text("Routes").font(.system(size: 38, weight: .regular, design: .serif))
            }
            Spacer()
            Button { store.showGPXImporter = true } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: 19, weight: .medium))
                    .frame(width: 48, height: 48).background(RidgeTheme.forest, in: Circle()).foregroundStyle(RidgeTheme.panel)
            }.accessibilityLabel("Import GPX").disabled(store.isRouting)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(RidgeTheme.lime.opacity(0.22)).frame(width: 184, height: 184)
                TerrainGlyph(color: RidgeTheme.forest.opacity(0.55)).frame(width: 145, height: 125).rotationEffect(.degrees(-13))
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .font(.system(size: 56, weight: .ultraLight)).foregroundStyle(RidgeTheme.orange)
            }.padding(.top, 12).accessibilityHidden(true)
            VStack(spacing: 12) {
                Text("Every good day\nstarts with a line.")
                    .font(.system(size: 30, weight: .regular, design: .serif)).multilineTextAlignment(.center)
                Text("Choose a landscape, follow its contours and make a route your own. Your saved routes will live here.")
                    .font(.system(size: 14)).lineSpacing(4).foregroundStyle(RidgeTheme.muted).multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button("Choose a landscape") { store.tab = .explore }.buttonStyle(RidgeButtonStyle())
                Button { store.showGPXImporter = true } label: { Label("Import a GPX file", systemImage: "square.and.arrow.down") }
                    .buttonStyle(RidgeButtonStyle(secondary: true)).disabled(store.isRouting)
            }.padding(.top, 3)
        }.padding(26).frame(maxWidth: .infinity).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 28)).padding(.top, 8)
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
    private var terrainReady: Bool { entry?.installed == true }
    @State private var summary: RouteStatistics?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryMapPreview(entry: entry, route: route, packs: packs)
            VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Eyebrow(text: entry?.manifest.name ?? (route.segments.contains { $0.mode == "imported" } ? "Imported GPX" : "Saved route"))
                    Spacer(minLength: 4)
                    if favourite { Image(systemName: "star.fill").font(.caption).foregroundStyle(RidgeTheme.forest).accessibilityLabel("Favourite route") }
                }
                Text(route.name).font(.system(size: 23, weight: .regular, design: .serif)).lineLimit(2, reservesSpace: true)
                HStack(spacing: 6) {
                    Image(systemName: route.segments.contains { $0.mode == "imported" } ? "arrow.down.doc" : "point.topleft.down.to.point.bottomright.curvepath")
                    Text(route.modifiedAt, format: .dateTime.day().month(.abbreviated).year())
                }.font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
            }
            if let summary {
                HStack(alignment: .firstTextBaseline) {
                    metric("DISTANCE", value: RidgeTheme.distance(summary.distanceMeters), suffix: summary.distanceMeters >= 1000 ? "km" : "m")
                    Spacer(minLength: 8)
                    metric("ASCENT EST.", value: summary.hasElevation ? "\(Int(summary.ascentMeters.rounded()))" : "—", suffix: summary.hasElevation ? "m" : "")
                    Spacer(minLength: 8)
                    metric("WALK EST.", value: duration(summary.estimatedMinutes), suffix: "")
                }
            } else { ProgressView().tint(RidgeTheme.forest).frame(maxWidth: .infinity, minHeight: 66) }
            Rectangle().fill(RidgeTheme.line.opacity(0.7)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: terrainReady ? "checkmark.circle.fill" : "square.dashed")
                Text(terrainReady ? "Ready to open in 3D" : "Terrain area needed · GPX available")
                Spacer(minLength: 3)
                Image(systemName: "arrow.up.right")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(terrainReady ? RidgeTheme.forest : RidgeTheme.muted)
            }.padding(20)
        }.background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 24))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(RidgeTheme.forest.opacity(0.06)))
            .task(id: route.modifiedAt) {
                let snapshot = route
                let result = await Task.detached(priority: .utility) { RouteEngine.statistics(for: snapshot) }.value
                if !Task.isCancelled { summary = result }
            }
    }

    private func metric(_ title: String, value: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.7).foregroundStyle(RidgeTheme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 20, weight: .medium, design: .rounded))
                Text(suffix).font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
            }
        }
    }

    private func duration(_ minutes: Double) -> String {
        let value = max(0, Int(minutes.rounded()))
        return value >= 60 ? "\(value / 60)h \(value % 60)m" : "\(value)m"
    }
}
