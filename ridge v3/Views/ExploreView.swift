import SwiftUI
import UIKit

struct AtlasFocus: Equatable {
    var point: GeoPoint
    var scale: CGFloat
    var bounds: GeoBounds? = nil
    var id = UUID()
}

struct ExploreView: View {
    @Bindable var store: AppStore
    var expanding: RegionManifest? = nil
    var expansionFocus: GeoPoint? = nil
    var onFinish: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var focus = AtlasFocus(point: GeoPoint(latitude: 53.6, longitude: -3.4), scale: 7400)
    @State private var selecting = false
    @State private var bounds: GeoBounds?
    @State private var viewport: GeoBounds?
    @State private var proposal: AtlasAreaProposal?
    @State private var lastValidBounds: GeoBounds?
    @State private var refreshing = false
    @State private var draggingSelection = false
    @State private var budgetRevision = 0
    private var spacing: Int { expanding?.defaultSpacing ?? 4 }
    private var atlasEntries: [PackEntry] { store.selectableEntries.sorted { $0.manifest.name < $1.manifest.name } }
    private var busy: Bool { store.isPreparing || store.extensionInProgress }
    private var proposalID: String { "\(String(describing: bounds))-\(draggingSelection)-\(budgetRevision)-\(store.entries.map { $0.id + String($0.installed) }.joined(separator: ","))" }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height && geometry.size.width >= 700
            VStack(spacing: 0) {
                header
                if !query.isEmpty { searchResults.frame(maxHeight: 180) }
                if wide {
                    HStack(spacing: 0) {
                        atlas
                        ScrollView { selectionPanel }.frame(width: 330).background(RidgeTheme.panel)
                    }
                } else {
                    atlas
                    selectionPanel
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.background(RidgeTheme.paper).foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
            .task(id: proposalID) { await updateProposal() }
            .onAppear {
                if let expanding {
                    var initial = expanding.bounds
                    for point in (store.activeRoute?.points.map(\.coordinate) ?? []) + (store.activeRoute?.waypoints.map { $0.point.coordinate } ?? []) + [expansionFocus].compactMap({ $0 }) {
                        initial.minLatitude = min(initial.minLatitude, point.latitude); initial.maxLatitude = max(initial.maxLatitude, point.latitude)
                        initial.minLongitude = min(initial.minLongitude, point.longitude); initial.maxLongitude = max(initial.maxLongitude, point.longitude)
                    }
                    bounds = initial; selecting = true
                    focus = AtlasFocus(point: initial.center, scale: 600_000, bounds: Self.padded(initial, factor: 1.65))
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { budgetRevision += 1 } }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in budgetRevision += 1 }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in budgetRevision += 1 }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    if scenePhase == .active && selecting && !busy { budgetRevision += 1 }
                }
            }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if expanding != nil {
                Button { onFinish?() } label: { Image(systemName: "xmark").frame(width: 40, height: 40) }.accessibilityLabel("Return to terrain")
            } else {
                Image(systemName: "mountain.2").font(.title3).accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(RidgeTheme.muted)
                TextField("Where will you go?", text: $query).font(.system(size: 15)).autocorrectionDisabled()
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
            }.padding(12).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 15))
            if expanding == nil {
                Button { store.showSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 40, height: 40) }.accessibilityLabel("Settings")
            }
        }.padding(.horizontal, 18).padding(.vertical, 10).disabled(busy)
    }

    private var atlas: some View {
        OfflineAtlasView(atlas: store.atlas, entries: atlasEntries, savedEntries: store.entries.filter(\.installed),
                         focus: focus, selecting: selecting, selectedBounds: selectionBinding, draggingSelection: $draggingSelection,
                         admittedBounds: lastValidBounds, selectionAllowed: proposal?.canOpen ?? false,
                         requiredBounds: expanding?.bounds, route: expanding == nil ? [] : store.activeRoute?.points.map(\.coordinate) ?? [],
                         routeSegments: expanding == nil ? [] : store.activeRoute?.segments.map { $0.points.map(\.coordinate) } ?? [],
                         onViewport: { viewport = $0 }, snapToTiles: true)
            .overlay(alignment: .topLeading) {
                Label(selecting ? "Tap a tile · Drag to select · Pinch to zoom" : "Drag to pan · Pinch to zoom", systemImage: selecting ? "rectangle.dashed" : "hand.draw")
                    .font(.system(size: 11, weight: .medium)).padding(11).background(RidgeTheme.panel.opacity(0.94), in: Capsule()).padding(12).allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                if !selecting {
                    HStack(spacing: 8) {
                        ForEach(Array(atlasEntries.prefix(3))) { entry in
                            Button { focusOn(entry.manifest.bounds) } label: {
                                Label(entry.manifest.name, systemImage: "mountain.2").font(.system(size: 12, weight: .semibold))
                                    .padding(12).background(RidgeTheme.panel.opacity(0.96), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }.padding(12)
                }
            }.disabled(busy)
    }

    private var selectionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow(text: selecting ? "Your area, ready offline" : "A place to begin")
                    Text(expanding != nil ? "Expand your area" : selecting ? "Choose your landscape" : "Where will you go?")
                        .font(.system(size: 24, weight: .regular, design: .serif))
                }
                Spacer(minLength: 8)
                if selecting && !busy {
                    Button("Browse") { selecting = false; bounds = nil; proposal = nil; lastValidBounds = nil }.font(.subheadline.weight(.semibold))
                }
            }
            if busy && store.preparingFromAtlas {
                ProgressView(value: store.progress > 0 ? store.progress : nil).tint(RidgeTheme.forest)
                Text(store.preparationLabel).font(.subheadline)
                Button("Cancel") { store.cancelPreparation() }.font(.subheadline.weight(.semibold))
            } else if selecting {
                if let bounds {
                    let shown = refreshing ? bounds : proposal?.preview?.bounds ?? bounds
                    Text(proposal?.preview?.name ?? "Checking selected location…")
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    HStack {
                        Label(String(format: "%.1f × %.1f km", shown.widthMeters / 1000, shown.depthMeters / 1000), systemImage: "rectangle.dashed")
                        Spacer()
                        if let allowance = proposal?.allowance { Text("Est. " + RidgeTheme.bytes(allowance.bytesOnDisk)) }
                    }.font(.system(size: 13, weight: .semibold))
                    if let grid = proposal?.preview?.grid {
                        Text("\(grid.columns) × \(grid.rows) tiles · \(grid.columns * grid.rows) selected")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(RidgeTheme.muted)
                    } else {
                        Text("Checking selected tiles…").font(.system(size: 11, weight: .medium)).foregroundStyle(RidgeTheme.muted)
                    }
                    HStack(spacing: 18) {
                        Button("Smaller", systemImage: "minus.magnifyingglass") { resize(0.8) }
                        Button("Larger", systemImage: "plus.magnifyingglass") { resize(1.25) }
                        Button("Draw new", systemImage: "rectangle.dashed") { selectionBinding.wrappedValue = nil; lastValidBounds = nil }
                        Spacer(minLength: 0)
                    }.font(.system(size: 12, weight: .medium))
                    VStack(alignment: .leading, spacing: 6) {
                        if refreshing {
                            Label("Checking area…", systemImage: "hourglass").font(.caption).foregroundStyle(RidgeTheme.muted)
                        } else if let reason = proposal?.reason {
                            Text(reason).font(.system(size: 12)).foregroundStyle(RidgeTheme.orange).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(proposal?.preview?.horizon != nil ? "Surrounding terrain included · \(spacing) m terrain" : "\(spacing) m terrain · Same sharp map")
                                .font(.system(size: 12)).foregroundStyle(RidgeTheme.muted)
                            Text(proposal?.saved != nil ? "Already saved on this device." : proposal?.source?.remoteSource != nil ? "Missing files download from your local server. Saved files are reused." : "Source data is on this device. No download needed.")
                                .font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    Button { openSelection() } label: {
                        HStack { Image(systemName: proposal?.saved != nil ? "mountain.2" : "square.and.arrow.down"); Text(expanding != nil ? "Save & return to 3D" : proposal?.saved != nil ? "Open in 3D" : proposal?.source?.remoteSource != nil ? "Download & open in 3D" : "Save & open in 3D"); Spacer(); Image(systemName: "arrow.up.right") }.padding(.horizontal, 16)
                    }.buttonStyle(RidgeButtonStyle()).disabled(refreshing || proposal?.canOpen != true || busy)
                } else {
                    Text("Tap a highlighted tile, or drag across several tiles. Two fingers move the map; pinch to zoom. Selection stops at available coverage.")
                        .font(.system(size: 13)).foregroundStyle(RidgeTheme.muted)
                    Button("Select centre tile", systemImage: "viewfinder") { selectCentre() }.buttonStyle(RidgeButtonStyle())
                }
            } else {
                Text("Find a place, draw an area and explore it in 3D.").font(.system(size: 13)).foregroundStyle(RidgeTheme.muted)
                Button { selecting = true; query = "" } label: { Label("Select area", systemImage: "rectangle.dashed").frame(maxWidth: .infinity) }.buttonStyle(RidgeButtonStyle())
                Text("Marked areas have prepared terrain. Shaded areas are saved offline.").font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
            }
        }.padding(20).background(RidgeTheme.panel)
    }

    private var searchResults: some View {
        ScrollView {
            VStack(spacing: 0) {
                let areas = atlasEntries.filter { $0.manifest.name.localizedCaseInsensitiveContains(query) }
                let places = (atlasEntries.flatMap { $0.manifest.places } + (store.atlas?.places ?? [])).filter { $0.name.localizedCaseInsensitiveContains(query) }
                ForEach(areas) { entry in
                    Button { query = ""; focusOn(entry.manifest.bounds) } label: { Label(entry.manifest.name, systemImage: "mountain.2").frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                }
                ForEach(Array(Dictionary(grouping: places, by: \.name).compactMap { $0.value.first }.sorted { $0.name < $1.name }.prefix(6)), id: \.name) { place in
                    Button {
                        query = ""
                        if selecting { selectionBinding.wrappedValue = bounds.flatMap { AtlasAreaPlanner.snapped(AtlasAreaPlanner.recentered($0, on: place.coordinate), entries: atlasEntries, preservingSize: true) } ?? AtlasAreaPlanner.tile(at: place.coordinate, entries: atlasEntries) }
                        focus = AtlasFocus(point: place.coordinate, scale: 1_000_000)
                    } label: { Label(place.name, systemImage: "mappin").frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                }
                if areas.isEmpty && places.isEmpty { Text("No matching places in the offline atlas.").font(.footnote).padding(12) }
            }
        }.background(RidgeTheme.panel).padding(.horizontal, 18)
    }

    private var selectionBinding: Binding<GeoBounds?> {
        Binding(get: { bounds }, set: { value in
            var snapped = value.flatMap { AtlasAreaPlanner.snapped($0, entries: atlasEntries) }
            if let required = expanding?.bounds, let chosen = snapped {
                snapped = AtlasAreaPlanner.snapped(GeoBounds(minLatitude: min(required.minLatitude, chosen.minLatitude), minLongitude: min(required.minLongitude, chosen.minLongitude), maxLatitude: max(required.maxLatitude, chosen.maxLatitude), maxLongitude: max(required.maxLongitude, chosen.maxLongitude)), entries: atlasEntries)
            }
            guard bounds != snapped else { return }
            bounds = snapped; proposal = nil; lastValidBounds = nil; refreshing = snapped != nil
        })
    }
    private func focusOn(_ area: GeoBounds) {
        if selecting { selectionBinding.wrappedValue = bounds.flatMap { AtlasAreaPlanner.snapped(AtlasAreaPlanner.recentered($0, on: area.center), entries: atlasEntries, preservingSize: true) } ?? AtlasAreaPlanner.tile(at: area.center, entries: atlasEntries) }
        focus = AtlasFocus(point: area.center, scale: 600_000, bounds: Self.padded(area, factor: 1.25))
    }
    private func selectCentre() {
        guard let viewport else { return }
        let point = atlasEntries.first(where: { $0.manifest.bounds.contains(viewport.center) }) != nil ? viewport.center : atlasEntries.first?.manifest.bounds.center
        selectionBinding.wrappedValue = point.flatMap { AtlasAreaPlanner.tile(at: $0, entries: atlasEntries) }
        if let bounds { focus = AtlasFocus(point: bounds.center, scale: 600_000, bounds: Self.padded(bounds, factor: 8)) }
    }
    private func resize(_ factor: Double) {
        guard let current = bounds else { return }
        var resized = Self.padded(current, factor: factor)
        if let source = proposal?.source, let selected = proposal?.selection, let grid = source.manifest.grid,
           proposal?.preview?.bounds == current {
            let left = Int((selected.minU * Double(grid.columns)).rounded()), top = Int((selected.minV * Double(grid.rows)).rounded())
            let columns = Int(((selected.maxU - selected.minU) * Double(grid.columns)).rounded())
            let rows = Int(((selected.maxV - selected.minV) * Double(grid.rows)).rounded())
            let nextColumns = factor < 1 ? max(1, columns - 2) : columns + 2
            let nextRows = factor < 1 ? max(1, rows - 2) : rows + 2
            let nextLeft = left + (columns - nextColumns) / 2, nextTop = top + (rows - nextRows) / 2
            let a = source.manifest.bounds.point(u: Double(nextLeft) / Double(grid.columns), v: Double(nextTop) / Double(grid.rows))
            let b = source.manifest.bounds.point(u: Double(nextLeft + nextColumns) / Double(grid.columns), v: Double(nextTop + nextRows) / Double(grid.rows))
            resized = GeoBounds(minLatitude: b.latitude, minLongitude: a.longitude, maxLatitude: a.latitude, maxLongitude: b.longitude)
        }
        if let required = expanding?.bounds {
            selectionBinding.wrappedValue = GeoBounds(minLatitude: min(required.minLatitude, resized.minLatitude), minLongitude: min(required.minLongitude, resized.minLongitude), maxLatitude: max(required.maxLatitude, resized.maxLatitude), maxLongitude: max(required.maxLongitude, resized.maxLongitude))
        } else { selectionBinding.wrappedValue = resized }
    }
    private static func padded(_ bounds: GeoBounds, factor: Double) -> GeoBounds {
        let p = bounds.center, lat = (bounds.maxLatitude - bounds.minLatitude) * factor / 2, lon = (bounds.maxLongitude - bounds.minLongitude) * factor / 2
        return GeoBounds(minLatitude: max(-85, p.latitude - lat), minLongitude: max(-180, p.longitude - lon), maxLatitude: min(85, p.latitude + lat), maxLongitude: min(180, p.longitude + lon))
    }
    private func updateProposal() async {
        guard let bounds else { proposal = nil; refreshing = false; return }
        refreshing = true
        do { try await Task.sleep(for: .milliseconds(130)) } catch { return }
        let entries = store.entries, spacing = spacing, required = expanding?.bounds, route = expanding == nil ? nil : store.activeRoute
        let context = TerrainBudget.currentContext()
        var result = await Task.detached(priority: .userInitiated) { AtlasAreaPlanner.propose(bounds: bounds, entries: entries, spacing: spacing, required: required, route: route, context: context) }.value
        if let preview = result.preview, let saved = try? await store.packs.installedManifest(id: preview.id),
           AtlasAreaPlanner.reusable(saved, for: preview, spacing: spacing) {
            result.saved = PackEntry(manifest: saved, directory: result.source!.directory, installed: true)
        }
        guard !Task.isCancelled else { return }
        proposal = result; refreshing = false
        if result.canOpen {
            lastValidBounds = result.preview?.bounds
            // Keep the user's footprint separate from outward storage snapping.
            // Feeding snapped bounds back into the next move adds another row
            // and column on each drag, eventually selecting the whole source.
        }
    }
    private func openSelection() {
        guard let bounds else { return }
        // Recheck live memory at the commit point; never silently lower detail.
        var checked = AtlasAreaPlanner.propose(bounds: bounds, entries: store.entries, spacing: spacing, required: expanding?.bounds, route: expanding == nil ? nil : store.activeRoute)
        if proposal?.preview?.id == checked.preview?.id, proposal?.preview?.bounds == checked.preview?.bounds {
            checked.saved = proposal?.saved
        }
        proposal = checked
        guard checked.canOpen else { return }
        if expanding != nil { onFinish?(); store.expandAtlasArea(checked) }
        else { store.openAtlasArea(checked, spacing: spacing) }
    }
}

struct FeaturedAreaCard: View {
    let entry: PackEntry
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 10 : 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.installed ? "YOUR OFFLINE AREA" : "PREPARED LANDSCAPE").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1.2).foregroundStyle(RidgeTheme.muted)
                Text(entry.manifest.name).font(.system(size: compact ? 20 : 23, weight: .medium, design: .serif)).foregroundStyle(RidgeTheme.ink)
                Text(entry.manifest.subtitle).font(.system(size: 11)).foregroundStyle(RidgeTheme.muted).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: entry.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                    Text(entry.installed ? "SAVED OFFLINE" : String(format: "%.1f KM²", entry.manifest.bounds.areaSquareKilometers))
                }.font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(RidgeTheme.forest).padding(.top, 6)
            }
            TerrainGlyph(color: RidgeTheme.forest.opacity(0.75)).frame(width: compact ? 36 : 58, height: compact ? 76 : 94)
        }.frame(width: compact ? nil : 274, height: compact ? 114 : 128, alignment: .leading)
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
            .padding(compact ? 14 : 18).background(RidgeTheme.lime.opacity(0.24), in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(RidgeTheme.forest.opacity(0.09)))
    }
}

struct OfflineAtlasView: View {
    let atlas: AtlasData?
    let entries: [PackEntry]
    let savedEntries: [PackEntry]
    var focus: AtlasFocus
    var selecting: Bool
    @Binding var selectedBounds: GeoBounds?
    @Binding var draggingSelection: Bool
    var admittedBounds: GeoBounds?
    var selectionAllowed: Bool
    var requiredBounds: GeoBounds?
    var route: [GeoPoint]
    var routeSegments: [[GeoPoint]]
    var onViewport: (GeoBounds) -> Void
    var snapToTiles = false
    private let verticalOffset: CGFloat = 0
    private let selectionInsets = EdgeInsets(top: 55, leading: 25, bottom: 60, trailing: 60)
    @State private var images: [String: UIImage] = [:]
    @State private var dragAnchor: GeoPoint?
    @State private var movingBounds: GeoBounds?
    @State private var tapAnchor: GeoPoint?
    @State private var center = CGPoint(x: 0.49056, y: 0.3185)
    @State private var scale: CGFloat = 7400
    @State private var gestureCenter: CGPoint?
    @State private var gestureScale: CGFloat?
    @State private var movingMap = false
    private func world(_ point: GeoPoint) -> CGPoint {
        let lat = min(85, max(-85, point.latitude)) * .pi / 180
        return CGPoint(x: (point.longitude + 180) / 360, y: (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2)
    }
    private func screen(_ point: GeoPoint, size: CGSize) -> CGPoint {
        let p = world(point)
        return CGPoint(x: (p.x - center.x) * scale + size.width / 2, y: (p.y - center.y) * scale + size.height / 2 + verticalOffset)
    }
    private func rectangle(_ bounds: GeoBounds, size: CGSize) -> CGRect {
        let a = screen(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude), size: size)
        let b = screen(GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude), size: size)
        return CGRect(x: a.x, y: a.y, width: max(0.1, b.x - a.x), height: max(0.1, b.y - a.y))
    }
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(RidgeTheme.ocean))
                if let atlas { drawLand(atlas, context: &context, size: size) }
                for entry in entries where showsBounds(entry, size: size) {
                    if let image = images[entry.id] { context.draw(Image(uiImage: image), in: rectangle(entry.manifest.bounds, size: size)) }
                }
                drawAreas(context: &context, size: size)
                if let atlas { drawPlaces(atlas, context: &context, size: size) }
                drawSelection(context: &context, size: size)
            }.contentShape(Rectangle())
                .overlay {
                    AtlasTouchSurface(selecting: selecting, onDrag: { start, point, translation, twoFingers, ended in
                        if selecting && !movingMap && !twoFingers {
                            draggingSelection = !ended
                            dragSelection(start: start, location: point, size: geometry.size)
                        } else {
                            if gestureCenter == nil { gestureCenter = center }
                            if let origin = gestureCenter { center = CGPoint(x: min(1, max(0, origin.x - translation.width / scale)), y: min(0.94, max(0.06, origin.y - translation.height / scale))) }
                        }
                        if ended { gestureCenter = nil; dragAnchor = nil; movingBounds = nil; draggingSelection = false }
                        reportViewport(geometry.size)
                    }, onZoom: { factor, ended in
                        if gestureScale == nil { gestureScale = scale }
                        scale = min(4_000_000, max(350, (gestureScale ?? scale) * factor))
                        if ended { gestureScale = nil }
                        reportViewport(geometry.size)
                    }, onTap: { location in
                        if selecting && !movingMap {
                            let point = coordinate(at: location, size: geometry.size)
                            if snapToTiles {
                                guard let tile = AtlasAreaPlanner.tile(at: point, entries: entries) else { selectedBounds = nil; return }
                                if let bounds = selectedBounds {
                                    selectedBounds = AtlasAreaPlanner.snapped(AtlasAreaPlanner.recentered(bounds, on: tile.center), entries: entries, preservingSize: true)
                                } else { selectedBounds = tile }
                            } else if let bounds = selectedBounds {
                                selectedBounds = AtlasAreaPlanner.recentered(bounds, on: point); tapAnchor = nil
                            } else if let anchor = tapAnchor { selectedBounds = area(from: anchor, to: point); tapAnchor = nil }
                            else { tapAnchor = point }
                            return
                        }
                        if let group = clusters(size: geometry.size).first(where: { clusterLabelRect($0, size: geometry.size).insetBy(dx: -10, dy: -10).contains(location) }) {
                            zoom(to: group.entries[0].manifest.bounds, size: geometry.size)
                        } else if let entry = entries.first(where: { rectangle($0.manifest.bounds, size: geometry.size).insetBy(dx: -10, dy: -10).contains(location) }) {
                            zoom(to: entry.manifest.bounds, size: geometry.size)
                        }
                        reportViewport(geometry.size)
                    })
                }
                .onChange(of: focus) { _, value in
                    if let bounds = value.bounds { zoom(to: bounds, size: geometry.size) }
                    else { center = world(value.point); scale = value.scale }
                    reportViewport(geometry.size)
                }
                .onChange(of: geometry.size) { _, size in reportViewport(size) }
                .onChange(of: selecting) { _, _ in tapAnchor = nil; dragAnchor = nil; movingBounds = nil; movingMap = false }
                .onAppear {
                    if let bounds = focus.bounds { zoom(to: bounds, size: geometry.size) }
                    else { center = world(focus.point); scale = focus.scale }
                    reportViewport(geometry.size)
                }
                .task(id: entries.map(\.id).joined(separator: ",")) {
                    var rendered: [String: UIImage] = [:]
                    for entry in entries.prefix(8) {
                        guard !Task.isCancelled else { return }
                        let image = await Task.detached(priority: .utility) {
                            var manifest = entry.manifest
                            if manifest.cartography != nil { manifest.textures = [] }
                            return AreaPreview.render(manifest, directory: entry.directory)
                        }.value
                        if let image { rendered[entry.id] = image }
                    }
                    if !Task.isCancelled { images = rendered }
                }
                .accessibilityLabel(selecting ? "Area selection map" : "Offline atlas")
                .accessibilityHint(selecting ? "Tap a tile or drag to select whole tiles. Two fingers pan the map and pinch zooms. Move map lets one finger pan without changing the selection." : "Drag to browse, pinch to zoom, or choose a place using search.")
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 8) {
                        if selecting {
                            Button { movingMap.toggle() } label: {
                                Label(movingMap ? "Select tiles" : "Move map", systemImage: movingMap ? "square.grid.3x3" : "hand.draw")
                                    .font(.system(size: 12, weight: .semibold)).padding(12)
                                    .background(RidgeTheme.panel, in: Capsule())
                            }.buttonStyle(.plain)
                        }
                        RoundControl(symbol: "plus", label: "Zoom atlas in") { scale = min(4_000_000, scale * 1.8); reportViewport(geometry.size) }
                        RoundControl(symbol: "minus", label: "Zoom atlas out") { scale = max(350, scale / 1.8); reportViewport(geometry.size) }
                        RoundControl(symbol: "globe.europe.africa", label: "Show United Kingdom") { center = world(GeoPoint(latitude: 54.2, longitude: -3.4)); scale = min(7400, geometry.size.height * 20); reportViewport(geometry.size) }
                    }.padding(12)
                }
        }.clipped()
    }

    private func reportViewport(_ size: CGSize) {
        if let bounds = area(from: coordinate(at: .zero, size: size), to: coordinate(at: CGPoint(x: size.width, y: size.height), size: size)) { onViewport(bounds) }
    }
    private func area(from a: GeoPoint, to b: GeoPoint) -> GeoBounds? {
        let bounds = GeoBounds(minLatitude: max(-85, min(a.latitude, b.latitude)), minLongitude: max(-180, min(a.longitude, b.longitude)), maxLatitude: min(85, max(a.latitude, b.latitude)), maxLongitude: min(180, max(a.longitude, b.longitude)))
        return bounds.isValid ? bounds : nil
    }
    private func corners(_ bounds: GeoBounds) -> [GeoPoint] {
        [GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude), GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.maxLongitude), GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude), GeoPoint(latitude: bounds.minLatitude, longitude: bounds.minLongitude)]
    }
    private func dragSelection(start: CGPoint, location: CGPoint, size: CGSize) {
        tapAnchor = nil
        if dragAnchor == nil {
            if let bounds = selectedBounds {
                let points = corners(bounds)
                let rect = rectangle(bounds, size: size)
                let handleRadius = min(24, min(rect.width, rect.height) / 3)
                if let corner = points.indices.min(by: { hypot(screen(points[$0], size: size).x - start.x, screen(points[$0], size: size).y - start.y) < hypot(screen(points[$1], size: size).x - start.x, screen(points[$1], size: size).y - start.y) }),
                   hypot(screen(points[corner], size: size).x - start.x, screen(points[corner], size: size).y - start.y) <= handleRadius {
                    dragAnchor = points[(corner + 2) % 4]
                } else if rectangle(bounds, size: size).contains(start) {
                    movingBounds = bounds; dragAnchor = coordinate(at: start, size: size)
                }
            }
            if dragAnchor == nil { dragAnchor = coordinate(at: start, size: size) }
        }
        guard let anchor = dragAnchor else { return }
        let point = coordinate(at: location, size: size)
        if let original = movingBounds {
            let lat = point.latitude - anchor.latitude, lon = point.longitude - anchor.longitude
            let candidate = GeoBounds(minLatitude: original.minLatitude + lat, minLongitude: original.minLongitude + lon, maxLatitude: original.maxLatitude + lat, maxLongitude: original.maxLongitude + lon)
            if candidate.isValid { selectedBounds = snapToTiles ? AtlasAreaPlanner.snapped(candidate, entries: entries, preservingSize: true) : candidate }
        } else if let bounds = area(from: anchor, to: point) {
            selectedBounds = snapToTiles ? AtlasAreaPlanner.snapped(bounds, entries: entries) : bounds
        }
    }

    private func drawSelection(context: inout GraphicsContext, size: CGSize) {
        if let requiredBounds {
            context.stroke(Path(rectangle(requiredBounds, size: size)), with: .color(RidgeTheme.forest.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        }
        for segment in routeSegments where segment.count > 1 {
            var path = Path(); path.move(to: screen(segment[0], size: size))
            for point in segment.dropFirst() { path.addLine(to: screen(point, size: size)) }
            context.stroke(path, with: .color(RidgeTheme.paper), lineWidth: 5)
            context.stroke(path, with: .color(RidgeTheme.orange), lineWidth: 2.5)
        }
        for point in [route.first, route.last].compactMap({ $0 }) {
            let p = screen(point, size: size)
            let marker = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            context.fill(marker, with: .color(RidgeTheme.orange)); context.stroke(marker, with: .color(RidgeTheme.paper), lineWidth: 2)
        }
        if let admittedBounds, !selectionAllowed {
            context.stroke(Path(rectangle(admittedBounds, size: size)), with: .color(RidgeTheme.forest.opacity(0.7)), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
        }
        if selecting, let bounds = selectedBounds {
            let rect = rectangle(bounds, size: size)
            let color = selectionAllowed ? RidgeTheme.forest : RidgeTheme.orange
            context.fill(Path(rect), with: .color(color.opacity(0.09)))
            context.stroke(Path(rect), with: .color(RidgeTheme.paper), lineWidth: 5)
            context.stroke(Path(rect), with: .color(color), lineWidth: 2)
            for corner in corners(bounds) {
                let p = screen(corner, size: size), handle = CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)
                context.fill(Path(roundedRect: handle, cornerRadius: 4), with: .color(RidgeTheme.paper))
                context.stroke(Path(roundedRect: handle, cornerRadius: 4), with: .color(color), lineWidth: 2)
            }
        }
        if let anchor = tapAnchor {
            let p = screen(anchor, size: size)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(RidgeTheme.forest))
        }
    }

    private func coordinate(at point: CGPoint, size: CGSize) -> GeoPoint {
        let x = center.x + (point.x - size.width / 2) / scale
        let y = center.y + (point.y - size.height / 2 - verticalOffset) / scale
        return GeoPoint(latitude: atan(sinh(.pi * (1 - 2 * Double(y)))) * 180 / .pi, longitude: Double(x) * 360 - 180)
    }

    private func zoom(to bounds: GeoBounds, size: CGSize) {
        guard bounds.isValid else { return }
        let a = world(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
        let b = world(GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude))
        let usable = CGRect(x: selectionInsets.leading, y: selectionInsets.top,
                            width: max(80, size.width - selectionInsets.leading - selectionInsets.trailing),
                            height: max(100, size.height - selectionInsets.top - selectionInsets.bottom))
        scale = min(4_000_000, max(350, min(usable.width / max(0.0000001, b.x - a.x), usable.height / max(0.0000001, b.y - a.y)) * 0.9))
        center = CGPoint(x: (a.x + b.x) / 2 - (usable.midX - size.width / 2) / scale,
                         y: (a.y + b.y) / 2 - (usable.midY - size.height / 2 - verticalOffset) / scale)
    }

    private func cellsAreVisible(_ entry: PackEntry, size: CGSize) -> Bool {
        guard let grid = entry.manifest.grid, grid.isValid else { return false }
        let rect = rectangle(entry.manifest.bounds, size: size)
        return rect.width / CGFloat(grid.columns) >= 8 && rect.height / CGFloat(grid.rows) >= 8
    }

    private func showsBounds(_ entry: PackEntry, size: CGSize) -> Bool {
        let rect = rectangle(entry.manifest.bounds, size: size)
        return cellsAreVisible(entry, size: size) || (rect.width >= 64 && rect.height >= 40)
    }
    private func drawLand(_ atlas: AtlasData, context: inout GraphicsContext, size: CGSize) {
        let visible = CGRect(origin: .zero, size: size).insetBy(dx: -50, dy: -50)
        for polygon in atlas.land {
            var path = Path()
            for (index, pair) in polygon.enumerated() where pair.count >= 2 {
                let p = screen(GeoPoint(latitude: pair[1], longitude: pair[0]), size: size)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            guard path.boundingRect.intersects(visible) else { continue }
            context.fill(path, with: .color(RidgeTheme.paper)); context.stroke(path, with: .color(RidgeTheme.forest.opacity(0.25)), lineWidth: 0.75)
        }
    }
    private func drawCoverage(_ atlas: AtlasData, context: inout GraphicsContext, size: CGSize) {
        for cell in atlas.coverage {
            let rect = rectangle(cell.bounds, size: size)
            guard rect.intersects(CGRect(origin: .zero, size: size)) else { continue }
            // This is an index of source coverage, not ready or downloaded tiles.
            context.fill(Path(rect), with: .color(RidgeTheme.muted.opacity(cell.status == "unavailable" ? 0.025 : 0.065)))
            context.stroke(Path(rect), with: .color(RidgeTheme.muted.opacity(0.3)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        }
    }
    private func drawPlaces(_ atlas: AtlasData, context: inout GraphicsContext, size: CGSize) {
        guard scale > 1200 else { return }
        var occupied = clusters(size: size).map { clusterLabelRect($0, size: size).insetBy(dx: -5, dy: -5) }
        let detailPlaces = entries.filter { cellsAreVisible($0, size: size) }.flatMap { $0.manifest.places }.sorted { ($0.elevation ?? 0) > ($1.elevation ?? 0) }
        var seen: Set<String> = []
        for place in detailPlaces + atlas.places {
            guard seen.insert(place.id).inserted else { continue }
            let p = screen(place.coordinate, size: size)
            guard CGRect(origin: .zero, size: size).contains(p) else { continue }
            let text = context.resolve(Text(place.name).font(.system(size: scale > 80_000 ? 13 : 10, weight: .medium)).foregroundStyle(RidgeTheme.muted))
            let measured = text.measure(in: CGSize(width: 220, height: 24))
            let box = CGRect(x: p.x, y: p.y - 2 - measured.height / 2, width: measured.width + 10, height: measured.height).insetBy(dx: -5, dy: -4)
            guard !occupied.contains(where: { $0.intersects(box) }) else { continue }
            occupied.append(box)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)), with: .color(RidgeTheme.muted))
            context.draw(text, in: CGRect(x: p.x + 5, y: p.y - 2 - measured.height / 2, width: measured.width, height: measured.height))
        }
    }
    private struct AreaCluster {
        var point: CGPoint
        var entries: [PackEntry]
    }
    private func clusters(size: CGSize) -> [AreaCluster] {
        var groups: [AreaCluster] = []
        for entry in entries where !showsBounds(entry, size: size) {
            let point = screen(entry.manifest.bounds.center, size: size)
            if let index = groups.firstIndex(where: { hypot($0.point.x - point.x, $0.point.y - point.y) < 44 }) {
                groups[index].entries.append(entry)
            } else { groups.append(AreaCluster(point: point, entries: [entry])) }
        }
        return groups
    }

    private func clusterTitle(_ group: AreaCluster) -> String {
        group.entries.count == 1 ? group.entries[0].manifest.name.uppercased() : "PREPARED TERRAIN"
    }

    private func clusterLabelRect(_ group: AreaCluster, size: CGSize) -> CGRect {
        let width = min(220, max(125, CGFloat(clusterTitle(group).count) * 5.6 + 22))
        let x = group.point.x + width + 26 > size.width ? max(8, group.point.x - width - 14) : group.point.x + 14
        return CGRect(x: x, y: group.point.y - 15, width: width, height: 30)
    }

    private func drawAreas(context: inout GraphicsContext, size: CGSize) {
        let viewport = CGRect(origin: .zero, size: size)
        for entry in entries.sorted(by: { $0.manifest.bounds.areaSquareKilometers > $1.manifest.bounds.areaSquareKilometers }) where showsBounds(entry, size: size) {
            let rect = rectangle(entry.manifest.bounds, size: size)
            guard rect.intersects(viewport) else { continue }
            if let source = entry.manifest.tiledTerrain, let grid = entry.manifest.grid {
                // Merge each row's available cells into runs. This shows real
                // coverage at park scale without drawing thousands of outlines.
                var coverage = Path()
                for row in 0..<grid.rows {
                    var column = 0
                    while column < grid.columns {
                        guard source.cells[row * grid.columns + column].complete else { column += 1; continue }
                        let left = column
                        while column < grid.columns, source.cells[row * grid.columns + column].complete { column += 1 }
                        let a = entry.manifest.bounds.point(u: Double(left) / Double(grid.columns), v: Double(row) / Double(grid.rows))
                        let b = entry.manifest.bounds.point(u: Double(column) / Double(grid.columns), v: Double(row + 1) / Double(grid.rows))
                        let cellRect = rectangle(GeoBounds(minLatitude: b.latitude, minLongitude: a.longitude, maxLatitude: a.latitude, maxLongitude: b.longitude), size: size)
                        if cellRect.intersects(viewport) { coverage.addRect(cellRect) }
                    }
                }
                context.fill(coverage, with: .color(RidgeTheme.lime.opacity(0.30)))
            } else {
                context.fill(Path(rect), with: .color(RidgeTheme.lime.opacity(0.19)))
                context.stroke(Path(rect), with: .color(RidgeTheme.forest.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            if snapToTiles, let grid = entry.manifest.grid, cellsAreVisible(entry, size: size) {
                var lines = Path()
                for column in 0...grid.columns {
                    let x = rect.minX + rect.width * CGFloat(column) / CGFloat(grid.columns)
                    lines.move(to: CGPoint(x: x, y: rect.minY)); lines.addLine(to: CGPoint(x: x, y: rect.maxY))
                }
                for row in 0...grid.rows {
                    let point = entry.manifest.bounds.point(u: 0, v: Double(row) / Double(grid.rows))
                    let y = screen(point, size: size).y
                    lines.move(to: CGPoint(x: rect.minX, y: y)); lines.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                context.stroke(lines, with: .color(RidgeTheme.paper.opacity(0.8)), lineWidth: 2)
                context.stroke(lines, with: .color(RidgeTheme.forest.opacity(0.5)), lineWidth: 0.8)
            }
            if rect.width > 80 && rect.width < 220 {
                context.draw(Text(entry.manifest.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(RidgeTheme.forest), at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
        // Fill all footprints once with nonzero winding: overlapping saved areas
        // form continuous coverage without darker overlaps or internal borders.
        var savedCoverage = Path()
        for entry in savedEntries {
            let rect = rectangle(entry.manifest.bounds, size: size)
            guard rect.intersects(viewport), rect.width >= 4 else { continue }
            savedCoverage.addRect(rect)
        }
        context.fill(savedCoverage, with: .color(RidgeTheme.forest.opacity(0.10)), style: FillStyle(eoFill: false))
        for group in clusters(size: size) {
            let p = group.point
            guard viewport.insetBy(dx: -150, dy: -25).contains(p) else { continue }
            context.fill(Path(ellipseIn: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)), with: .color(RidgeTheme.forest.opacity(0.13)))
            context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(RidgeTheme.forest))
            let label = clusterLabelRect(group, size: size)
            context.fill(Path(roundedRect: label, cornerRadius: 10), with: .color(RidgeTheme.forest))
            context.draw(Text(clusterTitle(group)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(RidgeTheme.paper), at: CGPoint(x: label.midX, y: label.midY))
        }
    }
}

/// Native recognizers keep pan/pinch independent from SwiftUI selection updates.
/// One finger selects (or browses); two fingers always navigate the map.
private struct AtlasTouchSurface: UIViewRepresentable {
    var selecting: Bool
    var onDrag: (CGPoint, CGPoint, CGSize, Bool, Bool) -> Void
    var onZoom: (CGFloat, Bool) -> Void
    var onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .clear; view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = true
        updateAccessibility(view)
        context.coordinator.install(on: view)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self; updateAccessibility(view) }
    private func updateAccessibility(_ view: UIView) {
        view.accessibilityLabel = selecting ? "Area selection map" : "Offline atlas"
        view.accessibilityHint = selecting ? "Tap a tile. Drag a corner to resize or drag inside to move. Two fingers pan and pinch zooms. Move map enables one-finger navigation." : "Drag to pan and pinch to zoom. Zoom buttons are also available."
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: AtlasTouchSurface
        private var onePan: UIPanGestureRecognizer!
        private var twoPan: UIPanGestureRecognizer!
        private var pinch: UIPinchGestureRecognizer!
        private var starts: [ObjectIdentifier: CGPoint] = [:]
        init(_ parent: AtlasTouchSurface) { self.parent = parent }
        func install(on view: UIView) {
            onePan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            onePan.minimumNumberOfTouches = 1; onePan.maximumNumberOfTouches = 1
            onePan.allowedScrollTypesMask = .all
            twoPan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            twoPan.minimumNumberOfTouches = 2; twoPan.maximumNumberOfTouches = 2
            pinch = UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:)))
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            tap.require(toFail: onePan); tap.require(toFail: twoPan); tap.require(toFail: pinch)
            for gesture in [onePan!, twoPan!, pinch!, tap] { gesture.delegate = self; view.addGestureRecognizer(gesture) }
        }
        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view), delta = gesture.translation(in: view), key = ObjectIdentifier(gesture)
            let ended = gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed
            let start = starts[key] ?? CGPoint(x: point.x - delta.x, y: point.y - delta.y)
            starts[key] = start
            parent.onDrag(start, point, CGSize(width: delta.x, height: delta.y), gesture === twoPan, ended)
            if ended { starts.removeValue(forKey: key) }
        }
        @objc private func zoom(_ gesture: UIPinchGestureRecognizer) {
            parent.onZoom(gesture.scale, gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed)
        }
        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { parent.onTap(gesture.location(in: gesture.view)) }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gestureRecognizer === twoPan && other === pinch) || (gestureRecognizer === pinch && other === twoPan)
        }
    }
}
