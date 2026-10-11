import SwiftUI
import UIKit

struct AtlasFocus: Equatable {
    var point: GeoPoint
    var scale: CGFloat
    var bounds: GeoBounds? = nil
    var id = UUID()
    var animated = false
    var exactViewport = false
}

struct ExploreView: View {
    @Bindable var store: AppStore
    var expanding: RegionManifest? = nil
    var expansionFocus: GeoPoint? = nil
    var onFinish: (() -> Void)? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @AppStorage("ridge.recentSearches") private var recentSearchData = Data()
    @AppStorage("ridge.atlasViewport") private var atlasViewportData = Data()
    @State private var selectedSpacing = 4
    @State private var selectionMessage: String?
    private var recentSearches: [String] { (try? JSONDecoder().decode([String].self, from: recentSearchData)) ?? [] }
    @State private var focus = AtlasFocus(point: GeoPoint(latitude: 53.6, longitude: -3.4), scale: 7400)
    @State private var selecting = false
    @State private var bounds: GeoBounds?
    @State private var viewport: GeoBounds?
    @State private var proposal: AtlasAreaProposal?
    @State private var lastValidBounds: GeoBounds?
    @State private var refreshing = false
    @State private var draggingSelection = false
    @State private var budgetRevision = 0
    @State private var retryRevision = 0
    @State private var selectionCheckID = UUID()
    @State private var readingIndex = false
    @State private var selectionFailed = false
    @State private var indexTransfer: (received: Int64, total: Int64)?
    private var spacing: Int { selectedSpacing }
    private var atlasEntries: [PackEntry] { store.selectableEntries.sorted { $0.manifest.name < $1.manifest.name } }
    private var busy: Bool { store.isPreparing || store.extensionInProgress }
    private var proposalID: String { "\(spacing)-\(String(describing: bounds))-\(draggingSelection)-\(retryRevision)-\(store.entries.map { $0.id + String($0.installed) }.joined(separator: ","))" }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height && geometry.size.width >= 700
            VStack(spacing: 0) {
                header
                if !query.isEmpty { searchResults.frame(maxHeight: 210) }
                else if !selecting && !recentSearches.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(recentSearches, id: \.self) { term in
                            Button { query = term } label: { Label(term, systemImage: "clock").font(.subheadline).padding(10).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius)) }
                        } }.padding(.horizontal, 18)
                    }.padding(.bottom, 6)
                }
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
            .onChange(of: budgetRevision) { _, _ in
                // Memory checks must not cancel an in-flight metadata download.
                guard !refreshing else { return }
                proposal?.refreshBudget(spacing: spacing)
            }
            .onAppear {
                if expanding == nil, let saved = try? JSONDecoder().decode(GeoBounds.self, from: atlasViewportData), saved.isValid {
                    focus = AtlasFocus(point: saved.center, scale: 7400, bounds: saved)
                }
                if expanding == nil, let packBounds = store.explorePackBounds {
                    focus = AtlasFocus(point: packBounds.center, scale: 7400, bounds: Self.padded(packBounds, factor: 1.15))
                    store.explorePackBounds = nil
                }
                if let expanding {
                    selectedSpacing = expanding.defaultSpacing
                    var initial = expanding.bounds
                    for point in (store.activeRoute?.points.map(\.coordinate) ?? []) + (store.activeRoute?.waypoints.map { $0.point.coordinate } ?? []) + [expansionFocus].compactMap({ $0 }) {
                        initial.minLatitude = min(initial.minLatitude, point.latitude); initial.maxLatitude = max(initial.maxLatitude, point.latitude)
                        initial.minLongitude = min(initial.minLongitude, point.longitude); initial.maxLongitude = max(initial.maxLongitude, point.longitude)
                    }
                    bounds = initial; selecting = true
                    focus = AtlasFocus(point: initial.center, scale: 600_000, bounds: Self.padded(initial, factor: 1.65))
                }
            }
            .onDisappear { rememberViewport() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { budgetRevision += 1 } else { rememberViewport() } }
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
                TextField("Search places", text: $query).font(.system(size: 15)).autocorrectionDisabled()
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
            }.padding(12).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
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
                    .font(.system(size: 11, weight: .medium)).padding(11).background(RidgeTheme.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius)).padding(12).allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                if !selecting {
                    HStack(spacing: 8) {
                        ForEach(Array(atlasEntries.prefix(3))) { entry in
                            Button { focusOn(entry.manifest.bounds) } label: {
                                Label(entry.manifest.name, systemImage: "mountain.2").font(.system(size: 12, weight: .semibold))
                                    .padding(12).background(RidgeTheme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
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
                    Text(expanding != nil ? "Expand area" : selecting ? "Select area" : "Offline maps")
                        .font(RidgeTheme.sectionTitle)
                }
                Spacer(minLength: 8)
                if selecting && !busy {
                    Button("Browse") { selecting = false; bounds = nil; proposal = nil; lastValidBounds = nil }.font(.subheadline.weight(.semibold))
                }
            }
            if busy && store.preparingFromAtlas {
                ProgressView(value: store.progress > 0 ? store.progress : nil).tint(RidgeTheme.forest)
                Text(store.preparationLabel).font(.subheadline)
                if let total = store.transferTotal { Text("\(RidgeTheme.bytes(store.transferredBytes)) of \(RidgeTheme.bytes(total))").font(.subheadline.monospacedDigit()).foregroundStyle(RidgeTheme.muted) }
                Button("Cancel") { store.cancelPreparation() }.font(.subheadline.weight(.semibold))
            } else if selecting {
                if let bounds {
                    let shown = refreshing ? bounds : proposal?.preview?.bounds ?? bounds
                    Text(proposal?.preview?.name ?? "Selected area")
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                    HStack {
                        Label(String(format: "%.1f × %.1f km", shown.widthMeters / 1000, shown.depthMeters / 1000), systemImage: "rectangle.dashed")
                        Spacer()
                        if proposal?.saved != nil { Text("Saved offline") }
                        else if let download = proposal?.download {
                            Text(download.downloadBytes == 0 ? "No download needed" : "Download " + RidgeTheme.bytes(download.downloadBytes))
                        } else if let allowance = proposal?.allowance { Text("Area files " + RidgeTheme.bytes(allowance.bytesOnDisk)) }
                    }.font(.system(size: 13, weight: .semibold))
                    if let grid = proposal?.preview?.grid {
                        Text("\(grid.columns) × \(grid.rows) tiles · \(grid.columns * grid.rows) selected")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(RidgeTheme.muted)
                    } else if refreshing && !readingIndex {
                        Text("Checking selected tiles…").font(.system(size: 11, weight: .medium)).foregroundStyle(RidgeTheme.muted)
                    }
                    HStack(spacing: 18) {
                        Button("Smaller", systemImage: "minus.magnifyingglass") { resize(0.8) }
                        Button("Larger", systemImage: "plus.magnifyingglass") { resize(1.25) }
                        Button("Draw new", systemImage: "rectangle.dashed") { selectionBinding.wrappedValue = nil; lastValidBounds = nil }
                        Spacer(minLength: 0)
                    }.font(.system(size: 12, weight: .medium))
                    Text("Adaptive terrain").font(.subheadline).foregroundStyle(RidgeTheme.muted)
                    VStack(alignment: .leading, spacing: 6) {
                        if refreshing {
                            if readingIndex {
                                Text("Downloading area index…").font(.caption)
                                if let transfer = indexTransfer, transfer.total > 0 {
                                    ProgressView(value: Double(transfer.received), total: Double(transfer.total))
                                    Text("\(RidgeTheme.bytes(transfer.received)) of \(RidgeTheme.bytes(transfer.total))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(RidgeTheme.muted)
                                } else { ProgressView().controlSize(.small) }
                                Text("Needed once to check available tiles. Terrain downloads after you confirm.")
                                    .font(.caption).foregroundStyle(RidgeTheme.muted)
                            } else {
                                Label("Checking area…", systemImage: "hourglass").font(.caption).foregroundStyle(RidgeTheme.muted)
                            }
                        } else if let reason = proposal?.reason {
                            Text(reason).font(.subheadline).foregroundStyle(RidgeTheme.orange).fixedSize(horizontal: false, vertical: true)
                            if selectionFailed { Button("Try again") { retryRevision += 1 }.font(.subheadline.weight(.semibold)) }
                            if proposal?.preview?.adaptive == nil, let coarser = fittingCoarserSpacing {
                                Button("Use \(coarser) m terrain for this area") { selectedSpacing = coarser }.font(.subheadline.weight(.semibold))
                            }
                        } else {
                            if let far = proposal?.preview?.horizon?.layers.last?.bounds {
                                Text(String(format: "Includes maps for %.0f × %.0f km of surroundings.", far.widthMeters / 1000, far.depthMeters / 1000))
                                    .font(.system(size: 12)).foregroundStyle(RidgeTheme.muted)
                            }
                            if proposal?.saved == nil, let download = proposal?.download, download.cachedBytes > 0 {
                                Text(RidgeTheme.bytes(download.cachedBytes) + " already on this device and reused.")
                                    .font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
                            }
                            Text(proposal?.saved != nil ? "Already saved on this device." : proposal?.source?.remoteSource != nil ? "Missing files download from your local server. Saved files are reused." : "Source data is on this device. No download needed.")
                                .font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    Button { openSelection() } label: {
                        HStack { Image(systemName: proposal?.saved != nil ? "mountain.2" : "square.and.arrow.down"); Text(expanding != nil ? "Save & return to 3D" : proposal?.saved != nil ? "Open in 3D" : proposal?.source?.remoteSource != nil && proposal?.download?.downloadBytes != 0 ? "Download & open in 3D" : "Save & open in 3D"); Spacer(); Image(systemName: "arrow.up.right") }.padding(.horizontal, 16)
                    }.buttonStyle(RidgeButtonStyle()).disabled(refreshing || proposal?.canOpen != true || busy)
                } else {
                    Text("Tap a highlighted tile, or drag across several tiles. Two fingers move the map; pinch to zoom. Selection stops at available coverage.")
                        .font(.system(size: 13)).foregroundStyle(RidgeTheme.muted)
                    if let selectionMessage { Text(selectionMessage).font(.subheadline).foregroundStyle(RidgeTheme.orange) }
                    Button("Select centre tile", systemImage: "viewfinder") { selectCentre() }.buttonStyle(RidgeButtonStyle())
                }
            } else {
                if expanding == nil, store.canResume, let session = store.lastSession {
                    Button { store.resumePlanning() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.clockwise")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.routeID == nil ? "Continue exploring" : "Continue planning").font(.headline)
                                Text(store.routes.first { $0.id == session.routeID }?.name ?? session.areaName).font(.subheadline).lineLimit(1)
                            }
                            Spacer(); Image(systemName: "arrow.up.right")
                        }.padding(14).background(RidgeTheme.forest.opacity(0.08), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                    }.buttonStyle(.plain).disabled(busy)
                }
                Text(atlasEntries.isEmpty ? "Connect to your download server in Settings to see available packs." : "Choose the area to open in 3D. Download whole regions from Packs.").font(.system(size: 13)).foregroundStyle(RidgeTheme.muted)
                if atlasEntries.isEmpty {
                    Button("Connect download server") { store.showSettings = true }.buttonStyle(RidgeButtonStyle())
                } else {
                    Button { selecting = true; query = "" } label: { Label("Select area", systemImage: "rectangle.dashed").frame(maxWidth: .infinity) }.buttonStyle(RidgeButtonStyle())
                }
                Text("Marked areas have prepared terrain. Shaded areas are saved offline.").font(.system(size: 11)).foregroundStyle(RidgeTheme.muted)
            }
        }.padding(20).background(RidgeTheme.panel)
    }

    private func rememberViewport() {
        guard expanding == nil, let viewport, viewport.isValid, let data = try? JSONEncoder().encode(viewport) else { return }
        atlasViewportData = data
    }

    private var fittingCoarserSpacing: Int? {
        guard let bounds, let preview = proposal?.preview, proposal?.allowance?.allowed == false else { return nil }
        return preview.levels.map(\.spacing).filter { $0 > spacing }.sorted().first {
            AtlasAreaPlanner.propose(bounds: bounds, entries: atlasEntries, spacing: $0,
                                     required: expanding?.bounds, route: expanding == nil ? nil : store.activeRoute).canOpen
        }
    }

    private func rememberSearch(_ term: String) {
        let terms = [term] + recentSearches.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        if let data = try? JSONEncoder().encode(Array(terms.prefix(6))) { recentSearchData = data }
    }

    private func placeContext(_ place: MapPlace) -> String {
        let area = atlasEntries.filter { $0.manifest.bounds.contains(place.coordinate) }
            .min { $0.manifest.bounds.areaSquareKilometers < $1.manifest.bounds.areaSquareKilometers }?.manifest.name
        let location = area ?? String(format: "%.3f, %.3f", place.coordinate.latitude, place.coordinate.longitude)
        return place.kind.capitalized + " · " + location
    }

    private var searchResults: some View {
        ScrollView {
            VStack(spacing: 0) {
                let areas = atlasEntries.filter { $0.manifest.name.localizedCaseInsensitiveContains(query) }
                let places = (atlasEntries.flatMap { $0.manifest.places } + (store.atlas?.places ?? [])).filter { $0.name.localizedCaseInsensitiveContains(query) }
                ForEach(areas) { entry in
                    Button { rememberSearch(entry.manifest.name); query = ""; focusOn(entry.manifest.bounds) } label: { Label(entry.manifest.name, systemImage: "mountain.2").frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                }
                ForEach(Array(Dictionary(grouping: places, by: \.searchIdentity).compactMap { $0.value.first }.sorted { $0.name < $1.name }.prefix(12)), id: \.searchIdentity) { place in
                    Button {
                        rememberSearch(place.name); query = ""
                        if selecting { selectionBinding.wrappedValue = bounds.flatMap { AtlasAreaPlanner.snapped(AtlasAreaPlanner.recentered($0, on: place.coordinate), entries: atlasEntries, preservingSize: true) } ?? AtlasAreaPlanner.tile(at: place.coordinate, entries: atlasEntries) }
                        focus = AtlasFocus(point: place.coordinate, scale: 1_000_000)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: place.kind == "peak" ? "mountain.2" : "mappin")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(place.name)
                                Text(placeContext(place)).font(.caption).foregroundStyle(RidgeTheme.muted)
                            }
                            Spacer()
                        }.frame(minHeight: 44).padding(.horizontal, 12).padding(.vertical, 4)
                    }
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
            selectionMessage = nil
            bounds = snapped; proposal = nil; lastValidBounds = nil; refreshing = snapped != nil
        })
    }
    private func focusOn(_ area: GeoBounds) {
        if selecting { selectionBinding.wrappedValue = bounds.flatMap { AtlasAreaPlanner.snapped(AtlasAreaPlanner.recentered($0, on: area.center), entries: atlasEntries, preservingSize: true) } ?? AtlasAreaPlanner.tile(at: area.center, entries: atlasEntries) }
        focus = AtlasFocus(point: area.center, scale: 600_000, bounds: Self.padded(area, factor: 1.25))
    }
    private func selectCentre() {
        guard let viewport else { return }
        guard let tile = AtlasAreaPlanner.tile(at: viewport.center, entries: atlasEntries) else {
            selectionMessage = "No prepared terrain at the map centre. Move to highlighted coverage or search for a place."
            return
        }
        selectionBinding.wrappedValue = tile
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
            let a = source.manifest.tilePoint(u: Double(nextLeft) / Double(grid.columns), v: Double(nextTop) / Double(grid.rows))
            let b = source.manifest.tilePoint(u: Double(nextLeft + nextColumns) / Double(grid.columns), v: Double(nextTop + nextRows) / Double(grid.rows))
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
        let checkID = UUID()
        selectionCheckID = checkID
        readingIndex = false; indexTransfer = nil; selectionFailed = false
        guard let bounds else { proposal = nil; refreshing = false; return }
        refreshing = true
        do { try await Task.sleep(for: .milliseconds(130)) } catch { return }
        do {
            // Use the already-loaded catalogue. A cached selection needs no index I/O.
            let pending = atlasEntries.filter { $0.manifest.adaptive?.index != nil && $0.manifest.bounds.intersects(bounds) }
            if !pending.isEmpty {
                readingIndex = true
                let changed = try await store.packs.hydrateAdaptiveSources(covering: bounds, candidates: pending) { received, total in
                    await MainActor.run {
                        guard selectionCheckID == checkID else { return }
                        indexTransfer = (received, total)
                    }
                }
                try Task.checkCancellation()
                readingIndex = false
                if changed { await store.refresh() }
            }
        } catch {
            guard !Task.isCancelled else { return }
            let message: String
            if error is URLError {
                message = "Couldn’t read the area index. Check that your download server is running and reachable, then try again."
            } else { message = error.localizedDescription }
            proposal = AtlasAreaProposal(requested: bounds, reason: message)
            refreshing = false; readingIndex = false; selectionFailed = true; return
        }
        let entries = store.selectableEntries, spacing = spacing, required = expanding?.bounds, route = expanding == nil ? nil : store.activeRoute
        let context = TerrainBudget.currentContext()
        var result = await Task.detached(priority: .userInitiated) { AtlasAreaPlanner.propose(bounds: bounds, entries: entries, spacing: spacing, required: required, route: route, context: context) }.value
        if let preview = result.preview, let saved = try? await store.packs.installedManifest(id: preview.id),
           AtlasAreaPlanner.reusable(saved, for: preview, spacing: spacing) {
            result.saved = PackEntry(manifest: saved, directory: result.source!.directory, installed: true)
        }
        if result.saved == nil, let preview = result.preview, preview.adaptive != nil,
           let source = result.source, source.remoteSource != nil {
            result.download = try? await store.packs.estimateAdaptiveDownload(preview, from: source)
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
        var checked = AtlasAreaPlanner.propose(bounds: bounds, entries: store.selectableEntries, spacing: spacing, required: expanding?.bounds, route: expanding == nil ? nil : store.activeRoute)
        if proposal?.preview?.id == checked.preview?.id, proposal?.preview?.bounds == checked.preview?.bounds {
            checked.saved = proposal?.saved
            checked.download = proposal?.download
        }
        proposal = checked
        guard checked.canOpen else { return }
        if expanding != nil { onFinish?(); store.expandAtlasArea(checked, spacing: spacing) }
        else { store.openAtlasArea(checked, spacing: spacing) }
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
    var onUserViewport: ((GeoBounds) -> Void)? = nil
    var snapToTiles = false
    var worldCoverage: GeoBounds? = nil
    private var maximumScale: Double { onWorldTap != nil || worldCoverage != nil ? 16_000_000 : 4_000_000 }
    var worldPreview: CGImage? = nil
    var onWorldTap: ((GeoPoint) -> Void)? = nil
    var worldOfflineBounds: [GeoBounds] = []
    var worldOfflineEdges: [WorldOfflineCoverage.Edge] = []
    var worldDownloadEdges: [WorldOfflineCoverage.Edge] = []
    var worldDownloadTiles: [GeoBounds] = []
    var worldCompletedTiles: Set<GeoBounds> = []
    var worldActiveTiles: Set<GeoBounds> = []
    var worldDownloading = false
    var worldSavedDownloadFills: [GeoBounds] = []
    var onSelectionFinished: ((GeoBounds) -> Void)? = nil
    var worldRegions:[WorldRegionMapOverlay] = []
    var selectedWorldRegion:String? = nil
    var onRegionTap:((WorldRegionPack)->Void)? = nil
    @State private var tileCompletionTimes: [GeoBounds:Date] = [:]
    // The callback identifies the world flow even before its terrain source opens.
    private var usesWorldStyle: Bool { onWorldTap != nil || worldCoverage != nil }
    private let verticalOffset: CGFloat = 0
    private let selectionInsets = EdgeInsets(top: 55, leading: 25, bottom: 60, trailing: 60)
    @State private var images: [String: UIImage] = [:]
    @State private var dragAnchor: GeoPoint?
    @State private var movingBounds: GeoBounds?
    @State private var tapAnchor: GeoPoint?
    @State private var center = CGPoint(x: 0.49056, y: 0.3185)
    @State private var scale: CGFloat = 7400
    @State private var movingMap = false
    @State private var focusFlight: Task<Void,Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            ZStack {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(usesWorldStyle ? WorldAtlasPalette.sea : Color(red:0.68,green:0.81,blue:0.86)))
                    if let atlas { drawLand(atlas, context: &context, size: size); drawPhysical(atlas, context: &context, size: size) }
                }
                WorldAtlasLayer(center: center, scale: scale, size: geometry.size)
                Canvas { context, size in
                for entry in entries where showsBounds(entry, size: size) {
                    if let image = images[entry.id] { context.draw(Image(uiImage: image), in: rectangle(entry.manifest.bounds, size: size)) }
                }
                if let worldCoverage {
                    let rect = rectangle(worldCoverage,size:size)
                    if let worldPreview, rect.width > 35 {
                        context.draw(Image(decorative:worldPreview,scale:1),in:rect)
                    } else {
                        context.fill(Path(rect),with:.color(RidgeTheme.forest.opacity(0.12)))
                    }

                }
                drawAreas(context: &context, size: size)
                if worldRegions.isEmpty { drawWorldOfflineCoverage(context: &context, size: size) }
                var downloadOutline=Path()
                for edge in worldDownloadEdges {
                    downloadOutline.move(to:screen(edge.start,size:size));downloadOutline.addLine(to:screen(edge.end,size:size))
                }
                context.stroke(downloadOutline,with:.color(RidgeTheme.paper),lineWidth:5)
                context.stroke(downloadOutline,with:.color(RidgeTheme.forest),style:StrokeStyle(lineWidth:2.5,dash:[8,5]))
                drawWorldRegions(context:&context,size:size)
                drawSelection(context: &context, size: size)
                var savedContext=context
                if let footprint=downloadFootprint(size:size) { savedContext.clip(to:footprint,style:FillStyle(eoFill:true)) }
                for bounds in worldSavedDownloadFills {
                    let rect=rectangle(bounds,size:size)
                    if CGRect(origin:.zero,size:size).intersects(rect) {
                        savedContext.fill(Path(rect),with:.color(RidgeTheme.forest.opacity(0.30)))
                    }
                }
                }
                TimelineView(.animation(minimumInterval:1.0/15,paused:!worldDownloading || reduceMotion)) { timeline in
                    Canvas { context,size in
                        var context=context
                        if let footprint=downloadFootprint(size:size) { context.clip(to:footprint,style:FillStyle(eoFill:true)) }
                        let viewport=CGRect(origin:.zero,size:size)
                        let pulse=reduceMotion ? 0.0 : (sin(timeline.date.timeIntervalSinceReferenceDate*4)+1)*0.08
                        for bounds in worldDownloadTiles {
                            let rect=rectangle(bounds,size:size)
                            guard viewport.intersects(rect) else { continue }
                            let done=worldCompletedTiles.contains(bounds), active=worldActiveTiles.contains(bounds)
                            let age=tileCompletionTimes[bounds].map { timeline.date.timeIntervalSince($0) } ?? 1
                            let fade=reduceMotion || !worldDownloading ? 1 : max(0,min(1,age/0.4))
                            let color=done ? RidgeTheme.forest : active ? RidgeTheme.orange : RidgeTheme.forest
                            context.fill(Path(rect),with:.color(color.opacity(done ? 0.30*fade : active ? 0.18+pulse : 0.04)))
                            context.stroke(Path(rect),with:.color(color.opacity(done || active ? 0.65 : 0.18)),lineWidth:1)
                            if done && rect.width>18 && rect.height>18 {
                                var tick=Path(); tick.move(to:CGPoint(x:rect.midX-4,y:rect.midY))
                                tick.addLine(to:CGPoint(x:rect.midX-1,y:rect.midY+3));tick.addLine(to:CGPoint(x:rect.midX+5,y:rect.midY-4))
                                context.stroke(tick,with:.color(RidgeTheme.forest.opacity(fade)),style:StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round))
                            }
                        }
                    }
                }.allowsHitTesting(false)
                Canvas { context,size in
                    if let atlas { drawPlaces(atlas,context:&context,size:size) }
                }.allowsHitTesting(false)
            }.contentShape(Rectangle())
                .accessibilityChildren {
                    ForEach(worldRegions) { region in
                        Button("\(region.pack.name), \(region.statusText)") { onRegionTap?(region.pack) }
                    }
                }
                .overlay {
                    AtlasTouchSurface(selecting: selecting, onDrag: { start, point, translation, twoFingers, ended in
                        focusFlight?.cancel(); focusFlight=nil
                        if selecting && !movingMap && !twoFingers {
                            draggingSelection = !ended
                            dragSelection(start: start, location: point, size: geometry.size)
                        } else {
                            center = CGPoint(x:min(1,max(0,center.x-translation.width/scale)),y:min(0.94,max(0.06,center.y-translation.height/scale)))
                        }
                        if ended {
                            if selecting && !movingMap && !twoFingers,let selectedBounds { onSelectionFinished?(selectedBounds) }
                            dragAnchor = nil; movingBounds = nil; draggingSelection = false; reportViewport(geometry.size, userInitiated: true)
                        }
                    }, onZoom: { factor, anchor, ended in
                        focusFlight?.cancel(); focusFlight=nil
                        let offset=CGPoint(x:anchor.x-geometry.size.width/2,y:anchor.y-geometry.size.height/2)
                        let before=CGPoint(x:center.x+offset.x/scale,y:center.y+offset.y/scale)
                        scale = min(maximumScale, max(350, scale * factor))
                        center=CGPoint(x:min(1,max(0,before.x-offset.x/scale)),y:min(0.94,max(0.06,before.y-offset.y/scale)))
                        if ended { reportViewport(geometry.size, userInitiated: true) }
                    }, onTap: { location in
                        if let onRegionTap {
                            let labels=regionLabels(size:geometry.size)
                            if let hit=labels.reversed().first(where: { $0.opacity>=0.5 && $0.rect.contains(location) }) { onRegionTap(hit.region.pack) }
                            else if let hit=WorldRegionMapOverlay.at(coordinate(at:location,size:geometry.size),in:worldRegions) { onRegionTap(hit.pack) }
                            return
                        }
                        if selecting && !movingMap, let onSelectionFinished {
                            let point=coordinate(at:location,size:geometry.size)
                            if let anchor=tapAnchor,let bounds=area(from:anchor,to:point) {
                                selectedBounds=bounds;tapAnchor=nil;draggingSelection=false;onSelectionFinished(bounds)
                            } else { tapAnchor=point;draggingSelection=true }
                            return
                        }
                        if let onWorldTap {
                            onWorldTap(coordinate(at: location, size: geometry.size)); return
                        }
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
                    focusFlight?.cancel()
                    let oldCenter=center,oldScale=scale
                    if let bounds = value.bounds { zoom(to: bounds, size: geometry.size, exact:value.exactViewport) }
                    else { center = world(value.point); scale = value.scale }
                    let destination=center,destinationScale=scale
                    if value.animated && !reduceMotion {
                        center=oldCenter;scale=oldScale
                        focusFlight=Task { @MainActor in
                            let start=ProcessInfo.processInfo.systemUptime
                            while !Task.isCancelled {
                                let t=min(1,(ProcessInfo.processInfo.systemUptime-start)/0.85),ease=t*t*(3-2*t)
                                center=CGPoint(x:oldCenter.x+(destination.x-oldCenter.x)*ease,y:oldCenter.y+(destination.y-oldCenter.y)*ease)
                                scale=oldScale*pow(destinationScale/oldScale,ease)
                                if t>=1 { reportViewport(geometry.size);break }
                                try? await Task.sleep(for:.milliseconds(16))
                            }
                        }
                    } else { reportViewport(geometry.size) }
                }
                .onChange(of:worldCompletedTiles) { _, tiles in
                    tileCompletionTimes=tileCompletionTimes.filter { tiles.contains($0.key) }
                    let now=Date()
                    for tile in tiles where tileCompletionTimes[tile] == nil { tileCompletionTimes[tile]=now }
                }
                .onDisappear { focusFlight?.cancel() }
                .onChange(of: geometry.size) { _, size in reportViewport(size) }
                .onChange(of: selecting) { _, _ in tapAnchor = nil; dragAnchor = nil; movingBounds = nil; movingMap = false; draggingSelection = false }
                .task {
                    if let bounds = focus.bounds { zoom(to: bounds, size: geometry.size, exact:focus.exactViewport) }
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
                .accessibilityHint(selecting ? "Drag a rectangle or tap two opposite corners. Drag handles to resize. Two fingers pan and pinch zooms." : "Drag to browse, pinch to zoom, or choose a place using search.")
                .overlay(alignment: .bottomTrailing) {
                    VStack(spacing: 8) {
                        if selecting {
                            Button { movingMap.toggle() } label: {
                                Label(movingMap ? "Select tiles" : "Move map", systemImage: movingMap ? "square.grid.3x3" : "hand.draw")
                                    .font(.system(size: 12, weight: .semibold)).padding(12)
                                    .background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                            }.buttonStyle(.plain)
                        }
                        RoundControl(symbol: "plus", label: "Zoom atlas in") { focusFlight?.cancel(); focusFlight=nil; scale = min(maximumScale, scale * 1.8); reportViewport(geometry.size, userInitiated: true) }
                        RoundControl(symbol: "minus", label: "Zoom atlas out") { focusFlight?.cancel(); focusFlight=nil; scale = max(350, scale / 1.8); reportViewport(geometry.size, userInitiated: true) }
                        RoundControl(symbol: "globe.europe.africa", label: "Show United Kingdom") { focusFlight?.cancel(); focusFlight=nil; zoom(to: GeoBounds(minLatitude:49.8,minLongitude:-8.3,maxLatitude:59.4,maxLongitude:2.0),size:geometry.size); reportViewport(geometry.size) }
                    }.padding(12)
                }
        }.clipped()
    }

    private func reportViewport(_ size: CGSize, userInitiated: Bool = false) {
        guard let bounds = area(from: coordinate(at: .zero, size: size), to: coordinate(at: CGPoint(x: size.width, y: size.height), size: size)) else { return }
        // Layout, region focus and returning from 3D also report a viewport.
        // Only deliberate navigation should restart automatic terrain entry.
        if userInitiated, let onUserViewport { onUserViewport(bounds) }
        else { onViewport(bounds) }
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

    private func zoom(to bounds: GeoBounds, size: CGSize, exact: Bool = false) {
        guard bounds.isValid else { return }
        let a = world(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
        let b = world(GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude))
        let usable = exact ? CGRect(origin:.zero,size:size) : CGRect(x: selectionInsets.leading, y: selectionInsets.top,
                            width: max(80, size.width - selectionInsets.leading - selectionInsets.trailing),
                            height: max(100, size.height - selectionInsets.top - selectionInsets.bottom))
        scale = min(maximumScale, max(350, min(usable.width / max(0.0000001, b.x - a.x), usable.height / max(0.0000001, b.y - a.y)) * (exact ? 1 : 0.9)))
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
            if usesWorldStyle {
                context.fill(path, with: .color(WorldAtlasPalette.land))
            } else {
                context.stroke(path, with: .color(Color(red:0.57,green:0.73,blue:0.78).opacity(0.5)), lineWidth: 4)
                context.fill(path, with: .color(Color(red:0.83,green:0.87,blue:0.73)))
                context.stroke(path, with: .color(RidgeTheme.forest.opacity(0.3)), lineWidth: 0.7)
            }
        }
    }
    private func drawPhysical(_ atlas: AtlasData, context: inout GraphicsContext, size: CGSize) {
        let viewport=CGRect(origin:.zero,size:size)
        for feature in atlas.physicalFeatures ?? [] {
            if usesWorldStyle && feature.kind.hasPrefix("elevation") { continue }
            let rect=rectangle(feature.bounds,size:size)
            guard rect.intersects(viewport),max(rect.width,rect.height)>2 else { continue }
            if feature.kind == "river" && scale < 14000 { continue }
            var path=Path()
            for ring in feature.rings {
                for (index,pair) in ring.enumerated() where pair.count==2 {
                    let p=screen(GeoPoint(latitude:pair[1],longitude:pair[0]),size:size)
                    if index==0 { path.move(to:p) } else { path.addLine(to:p) }
                }
                if feature.kind != "river" { path.closeSubpath() }
            }
            switch feature.kind {
            case "upland": break // Geographic range outlines are labels, not elevation.
            case "elevation150": context.fill(path,with:.color(Color(red:0.76,green:0.82,blue:0.66)),style:FillStyle(eoFill:true))
            case "elevation300": context.fill(path,with:.color(Color(red:0.68,green:0.76,blue:0.58)),style:FillStyle(eoFill:true))
            case "elevation500": context.fill(path,with:.color(Color(red:0.61,green:0.69,blue:0.51)),style:FillStyle(eoFill:true))
            case "elevation750": context.fill(path,with:.color(Color(red:0.65,green:0.66,blue:0.51)),style:FillStyle(eoFill:true))
            case "elevation1000", "elevation1500", "elevation2500": context.fill(path,with:.color(Color(red:0.72,green:0.69,blue:0.57)),style:FillStyle(eoFill:true))
            case "lake": context.fill(path,with:.color(usesWorldStyle ? WorldAtlasPalette.sea : Color(red:0.59,green:0.76,blue:0.83)),style:FillStyle(eoFill:true))
            default: context.stroke(path,with:.color(Color(red:0.41,green:0.64,blue:0.74).opacity(0.8)),lineWidth:scale>80000 ? 1.1 : 0.65)
            }
            if feature.kind == "upland",rect.width>110,rect.height>45,!feature.name.isEmpty {
                let label=context.resolve(Text(feature.name.uppercased()).font(.system(size:10,weight:.medium)).tracking(1.1).foregroundStyle(RidgeTheme.forest.opacity(0.65)))
                context.draw(label,at:CGPoint(x:rect.midX,y:rect.midY))
            }
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
    private func regionLabels(size:CGSize)->[(region:WorldRegionMapOverlay,rect:CGRect,fontSize:CGFloat,opacity:Double)] {
        let viewport=CGRect(origin:.zero,size:size)
        return worldRegions.compactMap { region in
            // A selected whole park is an overlay, not another area label
            // competing with the names on the map beneath it.
            guard region.id != region.pack.parkID else { return nil }
            var appearance=region.labelAppearance(at:Double(scale))
            if region.id==selectedWorldRegion { appearance=(max(18,appearance.size),1) }
            guard appearance.opacity>0 else { return nil }
            let anchor=screen(region.labelPoint,size:size)
            let lines=region.label.split(separator:"\n")
            let textWidth=CGFloat(lines.map(\.count).max() ?? 1)*0.72+0.5
            let textHeight=CGFloat(lines.count)*1.2+0.4
            let footprint=rectangle(region.pack.labelBounds ?? region.pack.bounds,size:size)
            let fitted=min(footprint.width/textWidth,footprint.height/textHeight)*0.9
            let fontSize=min(CGFloat(appearance.size),max(12,fitted))
            if region.id != selectedWorldRegion {
                let t=min(1,max(0,(fitted-7)/6))
                appearance.opacity *= Double(t*t*(3-2*t))
                guard appearance.opacity>0.01 else { return nil }
            }
            let width=textWidth*fontSize
            let height=textHeight*fontSize
            let rect=CGRect(x:anchor.x-width/2,y:anchor.y-height/2,width:width,height:height)
            // Clip naturally at screen edges rather than hiding the whole name.
            guard viewport.intersects(rect) else { return nil }
            return (region,rect,fontSize,appearance.opacity)
        }
    }
    private func regionPath(_ region:WorldRegionMapOverlay,size:CGSize)->Path {
        var path=Path()
        if let shapes=region.pack.mapShapes {
            for shape in shapes where rectangle(shape.bounds,size:size).intersects(CGRect(origin:.zero,size:size)) {
                for ring in shape.rings {
                    for (index,pair) in ring.enumerated() {
                        let point=screen(GeoPoint(latitude:pair[1],longitude:pair[0]),size:size)
                        if index==0 { path.move(to:point) } else { path.addLine(to:point) }
                    }
                    path.closeSubpath()
                }
            }
        } else {
            for bounds in region.fills { path.addRect(rectangle(bounds,size:size)) }
        }
        return path
    }
    private func downloadFootprint(size:CGSize)->Path? {
        guard let selectedWorldRegion else { return nil }
        let regions=worldRegions.filter { $0.id==selectedWorldRegion }
        guard !regions.isEmpty,regions.allSatisfy({ $0.pack.mapShapes != nil }) else { return nil }
        var path=Path()
        for region in regions { path.addPath(regionPath(region,size:size)) }
        return path
    }
    private func drawWorldRegions(context:inout GraphicsContext,size:CGSize) {
        guard !worldRegions.isEmpty else { return }
        let viewport=CGRect(origin:.zero,size:size)
        for region in worldRegions {
            let selected=region.id==selectedWorldRegion,available = !region.available.isEmpty
            let color:Color=region.downloadState == .saved ? RidgeTheme.forest
                : region.downloadState == .partial ? RidgeTheme.offlineBoundary : RidgeTheme.muted
            guard rectangle(region.pack.bounds,size:size).intersects(viewport) else { continue }
            let fill=regionPath(region,size:size)
            context.fill(fill,with:.color(color.opacity(region.downloadState == .saved ? 0.24 : region.downloadState == .partial ? 0.16 : selected ? 0.12 : 0.025)),style:FillStyle(eoFill:true))
            var outline=fill
            if region.pack.mapShapes == nil {
                outline=Path()
                for edge in region.edges { outline.move(to:screen(edge.start,size:size));outline.addLine(to:screen(edge.end,size:size)) }
            }
            context.stroke(outline,with:.color(color.opacity(selected ? 0.9 : 0.42)),style:StrokeStyle(lineWidth:selected ? 1.5 : 0.6,lineJoin:.round,dash:available ? [] : [3,4]))
        }
        for item in regionLabels(size:size) {
            var lettering=context
            lettering.opacity*=item.opacity
            lettering.translateBy(x:item.rect.midX,y:item.rect.midY)
            lettering.scaleBy(x:item.fontSize/40,y:item.fontSize/40)
            let lines=item.region.label.split(separator:"\n")
            for (index,line) in lines.enumerated() {
                let point=CGPoint(x:0,y:(CGFloat(index)-CGFloat(lines.count-1)/2)*48)
                // Keep glyph layout constant and scale the drawing transform;
                // fractional font relayout used to shimmer during pinching.
                let text=Text(String(line)).font(.system(size:40,weight:.regular,design:.serif)).tracking(0.8)
                for offset in [CGPoint(x:-1,y:0),CGPoint(x:1,y:0),CGPoint(x:0,y:-1),CGPoint(x:0,y:1)] {
                    lettering.draw(text.foregroundStyle(RidgeTheme.paper.opacity(0.95)),at:CGPoint(x:point.x+offset.x,y:point.y+offset.y))
                }
                lettering.draw(text.foregroundStyle(RidgeTheme.ink.opacity(item.region.available.isEmpty ? 0.6 : 0.95)),at:point)
            }
        }
    }
    private func drawWorldOfflineCoverage(context: inout GraphicsContext, size: CGSize) {
        guard !worldOfflineBounds.isEmpty else { return }
        let viewport=CGRect(origin:.zero,size:size)
        // Fill the union once. Shared saved tiles must never become a grid or
        // darken where downloads overlap. The outline is the same as in 3D.
        var fill=Path(), outline=Path()
        for bounds in worldOfflineBounds {
            let rect=rectangle(bounds,size:size)
            if rect.intersects(viewport) { fill.addRect(rect) }
        }
        context.fill(fill,with:.color(RidgeTheme.offlineBoundary.opacity(0.10)),style:FillStyle(eoFill:false))
        for edge in worldOfflineEdges {
            let a=screen(edge.start,size:size),b=screen(edge.end,size:size)
            let extent=CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:max(1,abs(a.x-b.x)),height:max(1,abs(a.y-b.y)))
            guard extent.insetBy(dx:-4,dy:-4).intersects(viewport) else { continue }
            outline.move(to:a);outline.addLine(to:b)
        }
        // Screen-space widths stay legible at UK scale and when zoomed in.
        context.stroke(outline,with:.color(RidgeTheme.paper.opacity(0.95)),style:StrokeStyle(lineWidth:5,lineCap:.round,lineJoin:.round))
        context.stroke(outline,with:.color(RidgeTheme.offlineBoundary),style:StrokeStyle(lineWidth:2.5,lineCap:.round,lineJoin:.round))
    }
    private func drawPlaces(_ atlas: AtlasData, context: inout GraphicsContext, size: CGSize) {
        guard scale > 4000 else { return }
        var occupied = worldRegions.isEmpty
            ? clusters(size:size).map { clusterLabelRect($0,size:size).insetBy(dx:-5,dy:-5) }
            : regionLabels(size:size).filter { $0.opacity>0.1 }.map { $0.rect.insetBy(dx:-6,dy:-6) }
        // Include neighbours just offscreen so panning past the edge does not
        // constantly change which of two nearby names wins the space.
        let viewport=CGRect(origin:.zero,size:size).insetBy(dx:-240,dy:-50)
        let northWest=coordinate(at:CGPoint(x:viewport.minX,y:viewport.minY),size:size)
        let southEast=coordinate(at:CGPoint(x:viewport.maxX,y:viewport.maxY),size:size)
        let detailPlaces=entries.filter { cellsAreVisible($0,size:size) }.flatMap { $0.manifest.places }
        var seen=Set<String>()
        var placedPoints:[CGPoint]=[]
        var visibleCount=0
        let labelLimit=max(5,min(12,Int(size.width*size.height/65000)+2))
        let visible=CGRect(origin:.zero,size:size)
        // The bundled list is ordered by city/town/village, then population.
        for place in [atlas.places,detailPlaces].joined() {
            let start:Double,fontSize:CGFloat,weight:Font.Weight
            switch place.kind {
            case "city": (start,fontSize,weight)=(4000,14,.semibold)
            case "town", "settlement": (start,fontSize,weight)=(55000,13,.medium)
            case "village": (start,fontSize,weight)=(240000,12,.regular)
            case "peak": (start,fontSize,weight)=(150000,12,.medium)
            default: continue
            }
            let t=min(1,max(0,(Double(scale)/start-1)/0.65))
            guard t>0,place.coordinate.latitude<=northWest.latitude,
                  place.coordinate.latitude>=southEast.latitude,
                  place.coordinate.longitude>=northWest.longitude,
                  place.coordinate.longitude<=southEast.longitude else { continue }
            let p=screen(place.coordinate,size:size)
            guard viewport.contains(p),seen.insert(place.searchIdentity).inserted,
                  !placedPoints.contains(where: { hypot($0.x-p.x,$0.y-p.y)<85 }),
                  !visible.contains(p) || visibleCount<labelLimit else { continue }
            let label=Text(place.name).font(.system(size:fontSize,weight:weight))
            let text=context.resolve(label.foregroundStyle(RidgeTheme.ink))
            let measured=text.measure(in:CGSize(width:240,height:24))
            let origins=[CGPoint(x:p.x+6,y:p.y-measured.height/2),
                         CGPoint(x:p.x-measured.width-6,y:p.y-measured.height/2),
                         CGPoint(x:p.x-measured.width/2,y:p.y-measured.height-6),
                         CGPoint(x:p.x-measured.width/2,y:p.y+6)]
            guard let rect=origins.map({ CGRect(origin:$0,size:measured) }).first(where: { rect in
                !occupied.contains { $0.intersects(rect.insetBy(dx:-5,dy:-4)) }
            }) else { continue }
            occupied.append(rect.insetBy(dx:-18,dy:-10))
            placedPoints.append(p)
            if visible.contains(p) { visibleCount+=1 }
            var lettering=context
            lettering.opacity *= t*t*(3-2*t)
            // A small paper halo stays legible over relief and download fills.
            let halo=lettering.resolve(label.foregroundStyle(RidgeTheme.paper.opacity(0.95)))
            for offset in [CGSize(width:-1,height:0),CGSize(width:1,height:0),CGSize(width:0,height:-1),CGSize(width:0,height:1)] {
                lettering.draw(halo,in:rect.offsetBy(dx:offset.width,dy:offset.height))
            }
            lettering.fill(Path(ellipseIn:CGRect(x:p.x-2,y:p.y-2,width:4,height:4)),with:.color(RidgeTheme.paper))
            lettering.fill(Path(ellipseIn:CGRect(x:p.x-1.25,y:p.y-1.25,width:2.5,height:2.5)),with:.color(RidgeTheme.ink))
            lettering.draw(text,in:rect)
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
        group.entries.count == 1 ? group.entries[0].manifest.name : "Available terrain"
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
            if let grid = entry.manifest.grid, let available = entry.manifest.adaptive?.coverage ?? entry.manifest.tiledTerrain?.cells.map(\.complete) {
                // Merge each row's available cells into runs. This shows real
                // coverage at park scale without drawing thousands of outlines.
                var coverage = Path()
                for row in 0..<grid.rows {
                    var column = 0
                    while column < grid.columns {
                        guard available[row * grid.columns + column] else { column += 1; continue }
                        let left = column
                        while column < grid.columns, available[row * grid.columns + column] { column += 1 }
                        let a = grid.point(u: Double(left) / Double(grid.columns), v: Double(row) / Double(grid.rows), in: entry.manifest.bounds)
                        let b = grid.point(u: Double(column) / Double(grid.columns), v: Double(row + 1) / Double(grid.rows), in: entry.manifest.bounds)
                        let cellRect = rectangle(GeoBounds(minLatitude: b.latitude, minLongitude: a.longitude, maxLatitude: a.latitude, maxLongitude: b.longitude), size: size)
                        if cellRect.intersects(viewport) { coverage.addRect(cellRect) }
                    }
                }
                context.fill(coverage, with: .color(RidgeTheme.selection.opacity(0.30)))
            } else {
                context.fill(Path(rect), with: .color(RidgeTheme.selection.opacity(0.19)))
                context.stroke(Path(rect), with: .color(RidgeTheme.forest.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }
            if snapToTiles, let grid = entry.manifest.grid, cellsAreVisible(entry, size: size) {
                var lines = Path()
                for column in 0...grid.columns {
                    let x = rect.minX + rect.width * CGFloat(column) / CGFloat(grid.columns)
                    lines.move(to: CGPoint(x: x, y: rect.minY)); lines.addLine(to: CGPoint(x: x, y: rect.maxY))
                }
                for row in 0...grid.rows {
                    let point = grid.point(u: 0, v: Double(row) / Double(grid.rows), in: entry.manifest.bounds)
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
            context.draw(Text(clusterTitle(group)).font(.system(size: 9, weight: .bold, design: .default)).foregroundStyle(RidgeTheme.paper), at: CGPoint(x: label.midX, y: label.midY))
        }
    }
}

/// Native recognizers keep pan/pinch independent from SwiftUI selection updates.
/// One finger selects (or browses); two fingers always navigate the map.
private struct AtlasTouchSurface: UIViewRepresentable {
    var selecting: Bool
    var onDrag: (CGPoint, CGPoint, CGSize, Bool, Bool) -> Void
    var onZoom: (CGFloat, CGPoint, Bool) -> Void
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
        view.accessibilityHint = selecting ? "Drag to select an area. Drag a corner to resize or drag inside to move. Two fingers pan and pinch zooms." : "Drag to pan and pinch to zoom. Zoom buttons are also available."
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
            gesture.setTranslation(.zero,in:view)
            if ended { starts.removeValue(forKey: key) }
        }
        @objc private func zoom(_ gesture: UIPinchGestureRecognizer) {
            parent.onZoom(gesture.scale, gesture.location(in:gesture.view), gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed)
            gesture.scale=1
        }
        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { parent.onTap(gesture.location(in: gesture.view)) }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            (gestureRecognizer === twoPan && other === pinch) || (gestureRecognizer === pinch && other === twoPan)
        }
    }
}
