import SwiftUI
import ImageIO

struct AreaPreview: View {
    var manifest: RegionManifest
    var directory: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RidgeTheme.lime.opacity(0.2)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { TerrainGlyph().padding(35) }
        }.clipped().task(id: manifest.id) {
            let m = manifest, d = directory
            image = await Task.detached(priority: .utility) { Self.render(m, directory: d) }.value
        }
    }
    nonisolated static func render(_ manifest: RegionManifest, directory: URL) -> UIImage? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let size = CGSize(width: 700, height: 700)
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor(red: 0.94, green: 0.94, blue: 0.86, alpha: 1).setFill(); renderer.fill(CGRect(origin: .zero, size: size))
            var maps = manifest.textures.map { ($0, 0) }
            if let overview = manifest.tiledTerrain?.overview { maps = [(overview, 0)] }
            if maps.isEmpty, let atlas = manifest.cartography {
                maps = atlas.tiles.compactMap { tile in
                    let bounds = tile.image.bounds
                    guard bounds.maxLongitude > manifest.bounds.minLongitude, bounds.minLongitude < manifest.bounds.maxLongitude,
                          bounds.maxLatitude > manifest.bounds.minLatitude, bounds.minLatitude < manifest.bounds.maxLatitude else { return nil }
                    let width = (bounds.maxLongitude - bounds.minLongitude) / (manifest.bounds.maxLongitude - manifest.bounds.minLongitude) * 700
                    return (width > Double(CartographyAtlas.previewCoreSize) ? tile.image : tile.preview, CartographyAtlas.gutter)
                }
            }
            for (texture, gutter) in maps {
                autoreleasepool {
                let url = directory.appendingPathComponent(texture.file)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 700, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
                let a = manifest.bounds.uv(GeoPoint(latitude: texture.bounds.maxLatitude, longitude: texture.bounds.minLongitude))
                let b = manifest.bounds.uv(GeoPoint(latitude: texture.bounds.minLatitude, longitude: texture.bounds.maxLongitude))
                let core = CGRect(x: a.u * 700, y: a.v * 700, width: (b.u - a.u) * 700, height: (b.v - a.v) * 700)
                let margin = Double(gutter) / Double(texture.width - 2 * gutter)
                renderer.cgContext.saveGState(); renderer.cgContext.clip(to: core)
                UIImage(cgImage: image).draw(in: core.insetBy(dx: -core.width * margin, dy: -core.height * margin))
                renderer.cgContext.restoreGState()
                }
            }
        }
    }
}

struct AreaDetailView: View {
    @Bindable var store: AppStore
    let entry: PackEntry
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var spacing = 4
    @State private var automaticDetail = false
    @State private var configuredDetail = false
    @State private var budgetContext = TerrainBudget.currentContext()
    @State private var savedSelection: (id: String, spacing: Int)?
    @State private var selecting = false
    @State private var selection = AreaSelection()
    @State private var previewCache = AreaSelectionPreviewCache()
    private var manifest: RegionManifest { entry.manifest }
    private var selectionPreview: RegionManifest {
        guard store.pendingRemoteURL == nil, !selection.isWhole || manifest.horizon != nil else { return manifest }
        return previewCache.preview(manifest: manifest, selection: selection, context: budgetContext)
    }
    private var selectedManifest: RegionManifest {
        guard store.pendingRemoteURL == nil, !selection.isWhole || manifest.horizon != nil else { return manifest }
        var selected = selectionPreview
        selected.horizon = TerrainBudget.selectedHorizon(for: selected, spacing: spacing, context: budgetContext)
        return selected
    }
    private var savedSpacing: Int? { savedSelection?.id == selectedManifest.id ? savedSelection?.spacing : nil }
    private var allowance: TerrainAllowance { TerrainBudget.allowance(for: selectedManifest, spacing: spacing, context: budgetContext) }
    private var usesTileGrid: Bool { manifest.grid != nil && store.pendingRemoteURL == nil }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: usesTileGrid ? 16 : 24) {
                if usesTileGrid {
                    VStack(alignment: .leading, spacing: 7) {
                        Eyebrow(text: manifest.name)
                        Text("Choose your tiles").font(.system(size: 30, weight: .regular, design: .serif))
                    }
                    TileSelectionView(manifest: manifest, directory: entry.directory, selection: $selection)
                } else if selecting || !selection.isWhole {
                    AreaSelectionView(manifest: manifest, directory: entry.directory, selection: $selection).allowsHitTesting(selecting).aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 24))
                } else {
                ZStack(alignment: .bottomLeading) {
                    AreaPreview(manifest: manifest, directory: entry.directory).frame(height: 210)
                    LinearGradient(colors: [.clear, RidgeTheme.ink.opacity(0.65)], startPoint: .center, endPoint: .bottom)
                    HStack { Image(systemName: "square.dashed"); Text(String(format: "%.1f × %.1f km", manifest.bounds.widthMeters / 1000, manifest.bounds.depthMeters / 1000)); Spacer(); Text("N ↑") }
                        .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.white).padding(20)
                }.clipShape(RoundedRectangle(cornerRadius: 24))
                }
                if store.pendingRemoteURL == nil && !usesTileGrid {
                    HStack {
                        Button { selecting.toggle() } label: { Label(selecting ? "Selection ready" : "Select a smaller area", systemImage: selecting ? "checkmark" : "crop") }.font(.subheadline.weight(.semibold))
                        Spacer()
                        if selecting || !selection.isWhole { Button("Whole area") { selection = AreaSelection() }.font(.footnote) }
                    }
                    if selecting { Text("Drag a rectangle, or tap two opposite corners. Smaller areas can use finer terrain with the same map detail.").font(.footnote).foregroundStyle(RidgeTheme.muted) }
                }
                if !usesTileGrid { VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: manifest.subtitle)
                    Text(manifest.name).font(.system(size: 36, weight: .regular, design: .serif)).foregroundStyle(RidgeTheme.ink)
                    Text(manifest.summary).font(.system(size: 14)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
                } }
                if !usesTileGrid { VStack(alignment: .leading, spacing: 13) {
                    HStack { Text("Terrain detail").font(.headline); Spacer(); automaticButton }
                    HStack(spacing: 6) {
                        ForEach([1, 2, 4, 8, 16, 32], id: \.self) { value in
                            let allowed = TerrainBudget.allowance(for: selectionPreview, spacing: value, context: budgetContext).allowed
                            Button { automaticDetail = false; spacing = value } label: {
                                VStack(spacing: 4) {
                                    Text("\(value)").font(.system(size: 19, weight: .semibold, design: .rounded))
                                    Text("METRE").font(.system(size: 7, weight: .bold, design: .monospaced)).tracking(0.5)
                                }.frame(maxWidth: .infinity).padding(.vertical, 14)
                                    .foregroundStyle(spacing == value ? RidgeTheme.panel : allowed ? RidgeTheme.ink : RidgeTheme.muted.opacity(0.45))
                                    .background(spacing == value ? RidgeTheme.forest : RidgeTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                            }.accessibilityLabel("\(value) metre terrain. \(allowed ? "Available" : (selectedManifest.levels.contains(where: { $0.spacing == value }) ? "Smaller area needed" : "Not included in this pack"))").accessibilityAddTraits(spacing == value ? .isSelected : [])
                        }
                    }
                    if let reason = allowance.reason {
                        Label(reason, systemImage: "rectangle.dashed").font(.footnote).foregroundStyle(RidgeTheme.orange).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label(automaticDetail ? "\(spacing) m selected for this device and area." : "Fits the current device allowance.", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(RidgeTheme.forest)
                    }
                    Text("Map sharpness stays the same. This changes the spacing between terrain samples.").font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).lineSpacing(3)
                    if selectedManifest.horizon != nil {
                        Label("Surrounding terrain is saved with this area.", systemImage: "mountain.2").font(.footnote).foregroundStyle(RidgeTheme.forest)
                    }
                }
                HStack(alignment: .top) {
                    detailMetric("AREA", value: String(format: selectedManifest.bounds.areaSquareKilometers < 1 ? "%.2f km²" : "%.1f km²", selectedManifest.bounds.areaSquareKilometers))
                    Spacer()
                    detailMetric(selection.isWhole ? "SAVE SIZE" : "EST. SIZE", value: allowance.bytesOnDisk > 0 ? RidgeTheme.bytes(allowance.bytesOnDisk) : "—")
                    Spacer()
                    detailMetric("PATHS", value: selectedManifest.graphFile == nil ? "Manual" : "Offline")
                }.padding(18).background(RidgeTheme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
                VStack(spacing: 10) {
                    Button { saveSelection() } label: {
                        HStack { Image(systemName: store.pendingRemoteURL == nil ? "square.and.arrow.down" : "arrow.down"); Text("Save & open in 3D"); Spacer(); Image(systemName: "arrow.up.right") }.padding(.horizontal, 18)
                    }.buttonStyle(RidgeButtonStyle()).disabled(!allowance.allowed).opacity(allowance.allowed ? 1 : 0.45)
                    if let savedSpacing {
                        Button("Open saved \(savedSpacing) m selection") { dismiss(); store.open(PackEntry(manifest: selectedManifest, directory: entry.directory, installed: true)) }.font(.subheadline.weight(.semibold)).padding(8)
                    }
                    Text(store.pendingRemoteURL == nil ? "Saved locally, ready without a connection." : "Downloads complete files. No connection needed while exploring.").font(.system(size: 11)).foregroundStyle(RidgeTheme.muted).multilineTextAlignment(.center)
                }
                }
                if !usesTileGrid { HStack { Image(systemName: "info.circle"); Text("Source terrain: \(Int(manifest.sourceResolution)) m LiDAR · \(manifest.version)") }.font(.system(size: 10)).foregroundStyle(RidgeTheme.muted) }
            }.padding(usesTileGrid ? 20 : 24)
        }.background(RidgeTheme.panel).foregroundStyle(RidgeTheme.ink)
            .safeAreaInset(edge: .bottom, spacing: 0) { if usesTileGrid { gridFooter } }
            .onAppear {
                if let requested = store.pendingSelection { selection = requested }
                else if usesTileGrid, let grid = manifest.grid {
                    let point = manifest.places.first(where: { $0.name == "Yr Wyddfa" })?.coordinate ?? manifest.bounds.center
                    let uv = manifest.bounds.uv(point)
                    selection = grid.selection(column: min(grid.columns - 1, max(0, Int(uv.u * Double(grid.columns)))), row: min(grid.rows - 1, max(0, Int(uv.v * Double(grid.rows))))) ?? AreaSelection()
                }
                refreshBudget(allowUpgrade: true)
                if !configuredDetail {
                    spacing = TerrainBudget.defaultSpacing(for: selectionPreview, context: budgetContext) ?? 4
                    configuredDetail = true
                }
            }
            .onChange(of: selection) { _, _ in refreshBudget(allowUpgrade: true) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { refreshBudget() } }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in refreshBudget() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in refreshBudget() }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    if scenePhase == .active { refreshBudget() }
                }
            }
            .task(id: selectedManifest.id) {
                let id = selectedManifest.id
                let saved = try? await store.packs.installedManifest(id: id)?.defaultSpacing
                if !Task.isCancelled { savedSelection = saved.map { (id: id, spacing: $0) } }
            }
    }
    private var gridFooter: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Terrain detail").font(.system(size: 12, weight: .semibold))
                Spacer()
                automaticButton
            }
            HStack(spacing: 6) {
                ForEach([1, 2, 4, 8, 16, 32], id: \.self) { value in
                    let available = TerrainBudget.allowance(for: selectionPreview, spacing: value, context: budgetContext).allowed
                    Button { automaticDetail = false; spacing = value } label: {
                        Text("\(value) m").font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .foregroundStyle(spacing == value ? RidgeTheme.paper : available ? RidgeTheme.ink : RidgeTheme.muted.opacity(0.45))
                            .background(spacing == value ? RidgeTheme.forest : RidgeTheme.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                    }.accessibilityLabel("\(value) metre terrain. \(available ? "Available" : "Unavailable for this selection")").accessibilityAddTraits(spacing == value ? .isSelected : [])
                }
            }
            if let reason = allowance.reason {
                Text(reason).font(.system(size: 11)).foregroundStyle(RidgeTheme.orange).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    Text(selectedManifest.horizon != nil ? "\(spacing) m · horizon included" : automaticDetail ? "\(spacing) m selected for this device" : "\(spacing) m · your choice")
                    Spacer(minLength: 0)
                    Text("Est. \(RidgeTheme.bytes(allowance.bytesOnDisk))")
                }.font(.system(size: 10)).foregroundStyle(RidgeTheme.muted)
            }
            Button { saveSelection() } label: {
                HStack { Image(systemName: "square.and.arrow.down"); Text("Save & open in 3D"); Spacer(); Image(systemName: "arrow.up.right") }.padding(.horizontal, 18)
            }.buttonStyle(RidgeButtonStyle()).disabled(!allowance.allowed).opacity(allowance.allowed ? 1 : 0.45)
            if let savedSpacing {
                Button("Open saved \(savedSpacing) m selection") { dismiss(); store.open(PackEntry(manifest: selectedManifest, directory: entry.directory, installed: true)) }
                    .font(.system(size: 12, weight: .semibold)).padding(.vertical, 2)
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
            .background(RidgeTheme.panel)
            .overlay(alignment: .top) { Rectangle().fill(RidgeTheme.line).frame(height: 0.5) }
    }

    private var automaticButton: some View {
        Button {
            automaticDetail = true
            refreshBudget(allowUpgrade: true)
        } label: {
            Label("Auto", systemImage: automaticDetail ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(automaticDetail ? RidgeTheme.lime.opacity(0.55) : RidgeTheme.ink.opacity(0.04), in: Capsule())
        }.foregroundStyle(RidgeTheme.forest)
            .accessibilityLabel("Automatic terrain detail")
            .accessibilityAddTraits(automaticDetail ? .isSelected : [])
    }

    private func refreshBudget(allowUpgrade: Bool = false) {
        let context = TerrainBudget.currentContext()
        budgetContext = context
        guard automaticDetail else { return }
        // Live pressure may reduce the recommendation. Only a changed area or
        // an explicit Auto tap upgrades it, so background fluctuations do not
        // repeatedly switch the user's chosen detail back and forth.
        if allowUpgrade || !TerrainBudget.allowance(for: selectionPreview, spacing: spacing, context: context).allowed {
            spacing = TerrainBudget.recommendedSpacing(for: selectionPreview, context: context)
                ?? selectedManifest.levels.map(\.spacing).max() ?? manifest.defaultSpacing
        }
    }

    private func saveSelection() {
        refreshBudget()
        guard allowance.allowed else { return }
        store.install(entry, spacing: spacing, selection: selection)
    }

    private func detailMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) { Eyebrow(text: label); Text(value).font(.system(size: 18, weight: .medium, design: .rounded)).foregroundStyle(RidgeTheme.ink) }
    }
}

/// Cropping and complete map-coverage validation depend on the source and
/// selection, not live memory headroom. Cache just that work; admission still
/// resolves against the latest device snapshot for every detail choice.
private final class AreaSelectionPreviewCache {
    private var source: RegionManifest?
    private var selection: AreaSelection?
    private var value: RegionManifest?

    func preview(manifest: RegionManifest, selection: AreaSelection, context: TerrainBudget.Context) -> RegionManifest {
        if source == manifest, self.selection == selection, let value { return value }
        let result = AreaCropper.preview(manifest: manifest, selection: selection, context: context)
        source = manifest
        self.selection = selection
        value = result
        return result
    }
}

struct AreaLibraryView: View {
    @Bindable var store: AppStore
    @State private var removal: PackEntry?
    private var saved: [PackEntry] { store.entries.filter(\.installed) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { VStack(alignment: .leading, spacing: 8) { Eyebrow(text: "Your offline collection"); Text("My areas").font(.system(size: 38, weight: .regular, design: .serif)) }; Spacer(); addMenu }
                if saved.isEmpty {
                    VStack(spacing: 18) {
                        TerrainGlyph().frame(width: 125, height: 110)
                        Text("A landscape to call your own.").font(.system(size: 23, design: .serif)).multilineTextAlignment(.center)
                        Text("Save an area from the atlas. Its terrain, map and walking paths will all be here, even without a connection.").font(.subheadline).foregroundStyle(RidgeTheme.muted).multilineTextAlignment(.center).lineSpacing(4)
                        Button("Explore the atlas") { store.tab = .explore }.buttonStyle(RidgeButtonStyle())
                    }.padding(28).frame(maxWidth: .infinity).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 26)).padding(.top, 25)
                }
                ForEach(saved) { entry in
                    Button { store.open(entry) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            AreaPreview(manifest: entry.manifest, directory: entry.directory).frame(height: 178).clipped()
                            HStack {
                                VStack(alignment: .leading, spacing: 6) { Text(entry.manifest.name).font(.system(size: 25, design: .serif)); Text(entry.manifest.subtitle).font(.caption).foregroundStyle(RidgeTheme.muted) }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.title3).padding(12).background(RidgeTheme.lime.opacity(0.45), in: Circle())
                            }.padding(20)
                            HStack { Label("Saved offline", systemImage: "checkmark.circle.fill"); Spacer(); Text(String(format: "%.1f km²", entry.manifest.bounds.areaSquareKilometers)) }.font(.caption).foregroundStyle(RidgeTheme.forest).padding(.horizontal, 20).padding(.bottom, 18)
                        }.background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 24)).clipShape(RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain).contextMenu {
                        Button("Open terrain", systemImage: "mountain.2") { store.open(entry) }
                        Button("Change resolution", systemImage: "square.grid.3x3") { store.choose(entry) }
                        Button("Remove saved area", systemImage: "trash", role: .destructive) { removal = entry }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Your data, on your device")
                    Text("Import a prepared area from Files, or download one using its direct link. Ridge never requests new terrain as you move around.").font(.footnote).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
                }.padding(.top, 10)
            }.padding(24)
        }.foregroundStyle(RidgeTheme.ink)
            .confirmationDialog("Remove this saved area? Your routes will be kept.", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                Button("Remove area", role: .destructive) { if let removal { store.removeArea(removal) }; removal = nil }
            }
    }
    private var addMenu: some View {
        Menu {
            Button("Import area from Files", systemImage: "folder") { store.showPackImporter = true }
            Button("Download from a link", systemImage: "link") { store.showDownloadSheet = true }
            Button("Choose from atlas", systemImage: "globe.europe.africa") { store.tab = .explore }
        } label: { Image(systemName: "plus").font(.title3).frame(width: 48, height: 48).background(RidgeTheme.forest, in: Circle()).foregroundStyle(RidgeTheme.panel) }.accessibilityLabel("Add offline area")
    }
}

struct DownloadLinkView: View {
    @Bindable var store: AppStore
    @State private var link = ""
    @State private var working = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Eyebrow(text: "Add a landscape")
            Text("Download an area").font(.system(size: 30, design: .serif))
            Text("Paste the manifest link for a prepared Ridge area. You’ll see its coverage and size before downloading.").font(.subheadline).foregroundStyle(RidgeTheme.muted)
            TextField("https://…/pack.json", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).padding(16).background(RidgeTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            if let error { Text(error).font(.footnote).foregroundStyle(RidgeTheme.orange) }
            Button {
                working = true
                Task { do { try await store.previewDownload(link) } catch { self.error = error.localizedDescription }; working = false }
            } label: { if working { ProgressView().tint(.white) } else { Text("Check area") } }.buttonStyle(RidgeButtonStyle()).disabled(working || link.isEmpty)
            Spacer(minLength: 0)
        }.padding(28).padding(.top, 15).background(RidgeTheme.panel).foregroundStyle(RidgeTheme.ink)
    }
}
