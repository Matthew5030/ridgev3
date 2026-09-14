import SwiftUI

struct RouteLibraryView: View {
    @Bindable var store: AppStore
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
                if store.routes.isEmpty { emptyState }
                else {
                    HStack(spacing: 7) {
                        Circle().fill(RidgeTheme.forest).frame(width: 5, height: 5)
                        Text("\(store.routes.count) \(store.routes.count == 1 ? "ROUTE" : "ROUTES") · SAVED ON THIS DEVICE")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1)
                    }.foregroundStyle(RidgeTheme.muted)
                    LazyVStack(spacing: 16) {
                        ForEach(store.routes) { route in
                            let entry = store.entries.first { $0.id == route.regionID }
                            Button { store.openRoute(route) } label: {
                                LibraryRouteCard(route: route, areaName: entry?.manifest.name,
                                                 terrainReady: entry?.installed == true)
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Open in 3D", systemImage: "mountain.2") { store.openRoute(route) }.disabled(store.isRouting)
                                    Button("Export GPX", systemImage: "square.and.arrow.up") { export(route) }
                                    Button("Rename", systemImage: "pencil") { renameTarget = route; renameText = route.name }.disabled(store.isRouting)
                                    Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateRoute(route) }.disabled(store.isRouting)
                                    Button("Delete route", systemImage: "trash", role: .destructive) { removal = route }.disabled(store.isRouting)
                                }
                                .overlay(alignment: .topTrailing) {
                                    Menu {
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
                    Text("A route begins in a landscape. Open a saved area to plan a new line in 3D.")
                        .font(.footnote).foregroundStyle(RidgeTheme.muted).lineSpacing(4).padding(.horizontal, 3)
                }
            }.padding(24)
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
    let areaName: String?
    let terrainReady: Bool
    @State private var summary: LibraryRouteSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 9) {
                Eyebrow(text: areaName ?? "Imported GPX")
                Text(route.name).font(.system(size: 26, weight: .regular, design: .serif)).lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: route.segments.contains { $0.mode == "imported" } ? "arrow.down.doc" : "point.topleft.down.to.point.bottomright.curvepath")
                    Text(route.modifiedAt, format: .dateTime.day().month(.abbreviated).year())
                }.font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
            }.padding(.trailing, 35)
            if let summary {
                if !summary.profiles.isEmpty { LibraryElevationStrip(profiles: summary.profiles).frame(height: 54).padding(.top, 2).accessibilityHidden(true) }
                HStack(alignment: .firstTextBaseline) {
                    metric("DISTANCE", value: RidgeTheme.distance(summary.stats.distanceMeters), suffix: summary.stats.distanceMeters >= 1000 ? "km" : "m")
                    Spacer(minLength: 8)
                    metric("ASCENT EST.", value: summary.stats.hasElevation ? "\(Int(summary.stats.ascentMeters.rounded()))" : "—", suffix: summary.stats.hasElevation ? "m" : "")
                    Spacer(minLength: 8)
                    metric("WALK EST.", value: duration(summary.stats.estimatedMinutes), suffix: "")
                }
            } else { ProgressView().tint(RidgeTheme.forest).frame(maxWidth: .infinity, minHeight: 66) }
            Rectangle().fill(RidgeTheme.line.opacity(0.7)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: terrainReady ? "checkmark.circle.fill" : "square.dashed")
                Text(terrainReady ? "Ready to open in 3D" : "Terrain area needed · GPX available")
                Spacer(minLength: 3)
                Image(systemName: "arrow.up.right")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(terrainReady ? RidgeTheme.forest : RidgeTheme.muted)
        }.padding(22).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(RidgeTheme.forest.opacity(0.06)))
            .task(id: route.modifiedAt) {
                let snapshot = route
                summary = await Task.detached(priority: .utility) { LibraryRouteSummary.make(snapshot) }.value
            }
    }

    private func metric(_ title: String, value: String, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(0.7).foregroundStyle(RidgeTheme.muted)
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

private struct LibraryProfilePoint: Sendable { let x: Double; let y: Double }
private struct LibraryRouteSummary: Sendable {
    let stats: RouteStatistics
    let profiles: [[LibraryProfilePoint]]
    static func make(_ route: RidgeRoute) -> Self {
        let stats = RouteEngine.statistics(for: route)
        let segments = route.segments.isEmpty ? [RouteSegment(points: route.waypoints.map(\.point), mode: "direct")] : route.segments
        var paths: [[LibraryProfilePoint]] = [], totalDistance = 0.0
        var minimum = Double.infinity, maximum = -Double.infinity
        let stride = max(1, segments.reduce(0) { $0 + $1.points.count } / 180)
        for segment in segments {
            var path: [LibraryProfilePoint] = []
            for index in segment.points.indices {
                let point = segment.points[index]
                if index > 0 { totalDistance += segment.points[index - 1].coordinate.distance(to: point.coordinate) }
                guard let height = point.elevation, height.isFinite else {
                    if !path.isEmpty { paths.append(path); path = [] }
                    continue
                }
                minimum = min(minimum, height); maximum = max(maximum, height)
                if index % stride == 0 || index == segment.points.count - 1 { path.append(LibraryProfilePoint(x: totalDistance, y: height)) }
            }
            if !path.isEmpty { paths.append(path) }
        }
        guard totalDistance > 0, minimum.isFinite else { return Self(stats: stats, profiles: []) }
        let range = max(30, maximum - minimum)
        let normalized = paths.filter { $0.count > 1 }.map { path in
            path.map { LibraryProfilePoint(x: $0.x / totalDistance, y: ($0.y - minimum) / range) }
        }
        return Self(stats: stats, profiles: normalized)
    }
}

private struct LibraryElevationStrip: View {
    let profiles: [[LibraryProfilePoint]]
    var body: some View {
        Canvas { context, size in
            for profile in profiles {
                guard let first = profile.first, let last = profile.last else { continue }
                var line = Path()
                for (index, point) in profile.enumerated() {
                    let position = CGPoint(x: point.x * size.width, y: size.height - 5 - point.y * (size.height - 12))
                    if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: last.x * size.width, y: size.height))
                fill.addLine(to: CGPoint(x: first.x * size.width, y: size.height)); fill.closeSubpath()
                context.fill(fill, with: .linearGradient(Gradient(colors: [RidgeTheme.forest.opacity(0.13), RidgeTheme.forest.opacity(0.015)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(RidgeTheme.forest.opacity(0.65)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
