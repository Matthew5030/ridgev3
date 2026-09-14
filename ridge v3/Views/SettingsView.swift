import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    @AppStorage(TerrainGestureStyle.defaultsKey) private var gestureStyle: TerrainGestureStyle = .moveWithOneFinger
    @Environment(\.dismiss) private var dismiss
    @State private var savedAssetBytes: Int64?
    @State private var storageError: String?
    @State private var showParkTest = false
    private var savedCount: Int { store.entries.filter(\.installed).count }
    private var sources: [SourceCredit] {
        let naturalEarth = SourceCredit(name: "Natural Earth", attribution: "World atlas land outlines from Natural Earth.", license: "Public domain", url: "https://www.naturalearthdata.com/about/terms-of-use/")
        return Array(Set(store.entries.flatMap { $0.manifest.sources } + [naturalEarth])).sorted { $0.name < $1.name }
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: "Make yourself at home")
                        Text("Settings").font(.system(size: 32, weight: .regular, design: .serif))
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 38, height: 38).background(RidgeTheme.ink.opacity(0.055), in: Circle()) }
                        .accessibilityLabel("Close settings")
                }
                gestureSection
                introduction
                offlineSection
                legendSection
                storageSection
                estimatesSection
                attributionSection
                if store.activeTerrain == nil && FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("EryriAdaptiveTest/manifest.json").path) {
                    Button("Eryri adaptive · full park stress test") { showParkTest = true }.buttonStyle(.bordered)
                }
                HStack {
                    Image(systemName: "mountain.2").font(.system(size: 15, weight: .medium))
                    Text("RIDGE").font(.system(size: 13, weight: .black, design: .rounded)).tracking(3)
                    Spacer()
                    Text("VERSION \(version)").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
                }.foregroundStyle(RidgeTheme.muted).padding(.vertical, 12)
            }.padding(24).padding(.top, 12)
        }.background(RidgeTheme.paper).foregroundStyle(RidgeTheme.ink)
            .fullScreenCover(isPresented: $showParkTest) { AdaptiveParkTestView() }
            .task(id: store.entries.filter(\.installed).map(\.id).joined(separator: ",")) {
                var total: Int64 = 0
                do {
                    for entry in store.entries where entry.installed {
                        if let manifest = try await store.packs.installedManifest(id: entry.id) { total += manifest.totalBytes }
                    }
                    savedAssetBytes = total
                } catch { storageError = "Saved area sizes could not be read." }
            }
    }

    private var gestureSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Eyebrow(text: "Moving around in 3D")
            Text("Make the map feel natural.").font(.system(size: 23, weight: .regular, design: .serif))
            VStack(spacing: 10) {
                ForEach(TerrainGestureStyle.allCases) { style in
                    Button { gestureStyle = style } label: {
                        HStack(spacing: 14) {
                            Image(systemName: style == .moveWithOneFinger ? "hand.draw" : "arrow.trianglehead.2.clockwise.rotate.90")
                                .font(.system(size: 20)).frame(width: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(style.title).font(.system(size: 15, weight: .semibold))
                                Text(style.subtitle).font(.system(size: 12)).foregroundStyle(RidgeTheme.muted)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: gestureStyle == style ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22)).foregroundStyle(gestureStyle == style ? RidgeTheme.forest : RidgeTheme.muted.opacity(0.4))
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(gestureStyle == style ? RidgeTheme.forest.opacity(0.07) : RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(gestureStyle == style ? RidgeTheme.forest.opacity(0.4) : RidgeTheme.line) }
                    }.buttonStyle(.plain)
                        .accessibilityLabel(style.title + ". " + style.subtitle)
                        .accessibilityAddTraits(gestureStyle == style ? .isSelected : [])
                }
            }
            Text("Pinch to zoom. Double-tap to fit the area. Your choice applies immediately and is remembered on this device.")
                .font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
        }
    }

    private var introduction: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text("A different perspective.").font(.system(size: 24, weight: .regular, design: .serif))
                Text("Real terrain. A carefully drawn map. Space to think about the way ahead.")
                    .font(.system(size: 13)).lineSpacing(4).foregroundStyle(RidgeTheme.muted)
            }
            TerrainGlyph().frame(width: 76, height: 100).accessibilityHidden(true)
        }.padding(23).frame(maxWidth: .infinity, alignment: .leading).background(RidgeTheme.lime.opacity(0.25), in: RoundedRectangle(cornerRadius: 24))
    }

    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Eyebrow(text: "Made for offline exploring")
            Text("Save once. Explore at your pace.").font(.system(size: 23, weight: .regular, design: .serif))
            Text("The world atlas is included with Ridge. Save a prepared area to keep its terrain, map and walking network on your device. Moving the camera and planning a route make no network requests.")
                .font(.system(size: 13)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
            if store.activeTerrain == nil {
            VStack(spacing: 0) {
                actionRow("Import an area from Files", symbol: "folder", subtitle: "Open a prepared Ridge area folder") {
                    dismiss()
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(350)); store.showPackImporter = true }
                }
                Divider().overlay(RidgeTheme.line).padding(.leading, 48)
                actionRow("Download from a link", symbol: "link", subtitle: "Check the area and size before saving") {
                    dismiss()
                    Task { @MainActor in try? await Task.sleep(for: .milliseconds(350)); store.showDownloadSheet = true }
                }
            }.padding(.horizontal, 15).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 19))
            }
        }
    }

    private var legendSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Eyebrow(text: "Reading the landscape")
            VStack(spacing: 17) {
                legendRow("Contours", subtitle: "10 m intervals · heavier lines every 50 m", kind: .contour)
                legendRow("Paths & bridleways", subtitle: "Dashed rose and purple lines", kind: .path)
                legendRow("Water", subtitle: "Lakes, streams and watercourses", kind: .water)
                legendRow("Woodland", subtitle: "Pale green mapped areas", kind: .woodland)
                legendRow("Your route", subtitle: "Orange line with a pale border", kind: .route)
            }.padding(20).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 22))
            Text("Follow paths uses the saved walking network. Direct line joins the points you choose across the terrain, without following mapped paths. Both appear in orange.")
                .font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Eyebrow(text: "On this device")
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(savedCount)").font(.system(size: 30, weight: .medium, design: .rounded))
                    Text("SAVED AREAS").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(RidgeTheme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    Text(savedAssetBytes.map(RidgeTheme.bytes) ?? "—").font(.system(size: 25, weight: .medium, design: .rounded))
                    Text("SAVED AREA ASSETS").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(RidgeTheme.muted)
                }
            }.padding(21).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 21))
            if let storageError { Text(storageError).font(.footnote).foregroundStyle(RidgeTheme.orange) }
            Text("File storage and working memory are different. Auto chooses terrain detail for the selected area using this device’s available memory, graphics capacity and temperature. Ridge checks again before opening one fixed 3D area.")
                .font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
            if let terrain = store.activeTerrain {
                let allowance = TerrainBudget.allowance(for: terrain.manifest, spacing: terrain.level.spacing)
                HStack {
                    Text("Open area · memory estimate").font(.system(size: 11))
                    Spacer()
                    Text(RidgeTheme.bytes(allowance.estimatedMemory)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                }.foregroundStyle(RidgeTheme.forest)
            }
            Text("Asset size excludes the bundled atlas, routes and app files. Removing a saved area keeps your saved routes.")
                .font(.system(size: 11)).foregroundStyle(RidgeTheme.muted).lineSpacing(3)
        }
    }

    private var estimatesSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Eyebrow(text: "Understanding the numbers")
            Text("Terrain resolution is the distance between height samples. Choosing finer terrain does not change map-texture detail.")
            Text("Walking time is a planning estimate: 4 km/h, plus one hour for every 600 m of ascent. Ascent and descent ignore elevation changes below 3 m to reduce small terrain ripples. GPX segment breaks are kept separate.")
        }.font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
    }

    private var attributionSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Eyebrow(text: "The people behind the map")
            ForEach(sources, id: \.self) { source in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(source.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(RidgeTheme.ink)
                        Spacer(minLength: 8)
                        if let url = URL(string: source.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            Link(destination: url) { Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28) }
                                .accessibilityLabel("Source information for \(source.name)")
                        }
                    }
                    Text(source.attribution).font(.system(size: 12)).lineSpacing(3)
                    Text(source.license).font(.system(size: 10, weight: .medium)).foregroundStyle(RidgeTheme.forest)
                }.foregroundStyle(RidgeTheme.muted).padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 18))
            }
        }
    }

    private func actionRow(_ title: String, symbol: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 25)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(RidgeTheme.muted)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(RidgeTheme.muted)
            }.padding(.vertical, 18)
        }.buttonStyle(.plain).disabled(store.isPreparing || store.isRouting)
    }

    private func legendRow(_ title: String, subtitle: String, kind: LegendSwatch.Kind) -> some View {
        HStack(spacing: 14) {
            LegendSwatch(kind: kind).frame(width: 48, height: 31).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(RidgeTheme.muted)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LegendSwatch: View {
    enum Kind { case contour, path, water, woodland, route }
    let kind: Kind
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(RidgeTheme.paper))
            switch kind {
            case .water:
                var lake = Path()
                lake.move(to: CGPoint(x: 5, y: 18)); lake.addCurve(to: CGPoint(x: 42, y: 9), control1: CGPoint(x: 9, y: -3), control2: CGPoint(x: 28, y: 23))
                lake.addCurve(to: CGPoint(x: 5, y: 18), control1: CGPoint(x: 35, y: 34), control2: CGPoint(x: 9, y: 28))
                context.fill(lake, with: .color(Color(red: 0.66, green: 0.80, blue: 0.82)))
            case .woodland:
                context.fill(Path(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerRadius: 7), with: .color(Color(red: 0.78, green: 0.85, blue: 0.74)))
            case .contour:
                for index in 0..<3 {
                    var line = Path()
                    let y = CGFloat(5 + index * 9)
                    line.move(to: CGPoint(x: 3, y: y + 4)); line.addCurve(to: CGPoint(x: 45, y: y), control1: CGPoint(x: 20, y: y - 12), control2: CGPoint(x: 30, y: y + 13))
                    context.stroke(line, with: .color(Color(red: 0.66, green: 0.60, blue: 0.49)), lineWidth: index == 1 ? 1.4 : 0.65)
                }
            case .path, .route:
                var line = Path()
                line.move(to: CGPoint(x: 4, y: 23)); line.addCurve(to: CGPoint(x: 44, y: 8), control1: CGPoint(x: 14, y: 0), control2: CGPoint(x: 29, y: 32))
                if kind == .route { context.stroke(line, with: .color(RidgeTheme.panel), style: StrokeStyle(lineWidth: 7, lineCap: .round)) }
                context.stroke(line, with: .color(kind == .route ? RidgeTheme.orange : Color(red: 0.67, green: 0.39, blue: 0.44)), style: StrokeStyle(lineWidth: kind == .route ? 3 : 2, lineCap: .round, dash: kind == .route ? [] : [4, 3]))
            }
        }
    }
}
