import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var savedAssetBytes: Int64?
    @State private var storageError: String?
    @AppStorage("ridge.worldSourceURL") private var worldAddress = ""
    @AppStorage("ridge.downloadServer") private var serverAddress = ""
    @State private var worldAddressDraft = ""
    @State private var connectingServer = false
    @State private var serverMessage: String?
    private var savedCount: Int { store.entries.filter(\.installed).count }
    private var sources: [SourceCredit] {
        let naturalEarth = SourceCredit(name: "Natural Earth", attribution: "World atlas coastlines, lakes, rivers and geographic regions from Natural Earth.", license: "Public domain", url: "https://www.naturalearthdata.com/about/terms-of-use/")
        let overview = SourceCredit(name: "Overview elevation · Mapzen Terrain Tiles", attribution: "Overview elevation bands derived from Mapzen Terrain Tiles. Europe: produced using Copernicus data and information funded by the European Union — EU-DEM layers. United Kingdom: © Environment Agency copyright and/or database right 2015. All rights reserved. Global GMTED2010 and SRTM terrain data courtesy of the U.S. Geological Survey. Global ETOPO1 terrain data: DOC/NOAA/NESDIS/NCEI, U.S. Department of Commerce. Smoothed and converted to elevation bands for the overview; not used for route elevations.", license: "Open source data; source-specific terms", url: "https://github.com/tilezen/joerd/blob/master/docs/attribution.md")
        return Array(Set(store.entries.flatMap { $0.manifest.sources } + [naturalEarth, overview])).sorted { $0.name < $1.name }
    }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Settings").font(RidgeTheme.pageTitle)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).frame(width: 38, height: 38).background(RidgeTheme.ink.opacity(0.055), in: Circle()) }
                        .accessibilityLabel("Close settings")
                }
                worldGestureSection
                VStack(alignment: .leading, spacing: 10) {
                    Text("Map source").font(RidgeTheme.sectionTitle)
                    TextField("Hosted world.json URL (optional)", text: $worldAddressDraft).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder)
                    Button("Use this source") { worldAddress = worldAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines); dismiss() }
                    Text("Leave blank to use the included Snowdon map. Nearby detail loads as you move; Keep offline retains it for later.").font(.caption).foregroundStyle(RidgeTheme.muted)
                }
                offlineSection
                downloadServerSection
                legendSection
                storageSection
                estimatesSection
                attributionSection
                HStack {
                    Image(systemName: "mountain.2").font(.system(size: 15, weight: .medium))
                    Text("Ridge").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("Version \(version)").font(.caption)
                }.foregroundStyle(RidgeTheme.muted).padding(.vertical, 12)
            }.padding(24).padding(.top, 12).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.background(RidgeTheme.paper).foregroundStyle(RidgeTheme.ink)
            .onAppear {
                worldAddressDraft = worldAddress
                if serverAddress.isEmpty, let remote = store.entries.compactMap(\.remoteSource).first {
                    serverAddress = remote.deletingLastPathComponent().absoluteString
                }
            }
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

    private var worldGestureSection: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Map controls").font(RidgeTheme.sectionTitle)
            Text("Drag with one finger to move. Pinch to zoom. Drag two fingers left or right to turn around the terrain, or up and down to tilt. Twisting does not turn the camera; the horizon stays level.")
                .font(.subheadline).foregroundStyle(RidgeTheme.muted)
            Text("The overview button looks straight down. Zooming keeps the angle you chose.")
                .font(.caption).foregroundStyle(RidgeTheme.muted)
        }
    }
    private var offlineSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Offline maps").font(RidgeTheme.sectionTitle)
            Text("Download a region from Packs, then choose smaller areas to open in 3D. Packs include terrain, maps and paths for offline use.")
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
            }.padding(.horizontal, 15).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
            }
        }
    }

    private var downloadServerSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Download server").font(RidgeTheme.sectionTitle)
            Text("Connect to a download server to see available areas. Downloaded areas work offline.")
                .font(.system(size: 13)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
            TextField("http://your-mac.local:8787", text: $serverAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .padding(15).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                .accessibilityLabel("Download server address")
            Button {
                connectingServer = true; serverMessage = nil
                Task { @MainActor in
                    defer { connectingServer = false }
                    do {
                        guard let url = URL(string: serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                            throw RidgeError.message("Enter the download server’s address.")
                        }
                        let count = try await store.packs.connectSourceServer(url)
                        await store.refresh()
                        serverMessage = "Connected · \(count) \(count == 1 ? "pack" : "packs") available. Open Packs to download a region, or Explore to choose a smaller area."
                    } catch { serverMessage = error.localizedDescription }
                }
            } label: {
                HStack {
                    if connectingServer { ProgressView().tint(RidgeTheme.forest) }
                    Label(connectingServer ? "Connecting…" : "Connect and refresh coverage", systemImage: "externaldrive.connected.to.line.below")
                }.font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(15)
                    .background(RidgeTheme.forest.opacity(0.08), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
            }.disabled(connectingServer || store.activeTerrain != nil || serverAddress.isEmpty)
            if store.activeTerrain != nil { Text("Return to the map before changing download coverage.").font(.footnote).foregroundStyle(RidgeTheme.muted) }
            if let serverMessage { Text(serverMessage).font(.footnote).foregroundStyle(RidgeTheme.muted).lineSpacing(3) }
        }
    }

    private var legendSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Map legend").font(RidgeTheme.sectionTitle)
            MapLegendView()
                .padding(20).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.cardRadius))
            Text("Routes follow mapped walking paths and are shown in orange.")
                .font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Storage").font(RidgeTheme.sectionTitle)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("\(savedCount)").font(.system(size: 30, weight: .medium, design: .default))
                    Text("Saved areas").font(.system(size: 8, weight: .bold, design: .default)).foregroundStyle(RidgeTheme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 7) {
                    Text(savedAssetBytes.map(RidgeTheme.bytes) ?? "—").font(.system(size: 25, weight: .medium, design: .default))
                    Text("Area files").font(.system(size: 8, weight: .bold, design: .default)).foregroundStyle(RidgeTheme.muted)
                }
            }.padding(21).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.cardRadius))
            if let storageError { Text(storageError).font(.footnote).foregroundStyle(RidgeTheme.orange) }
            Text("File storage and working memory are different. Auto chooses terrain detail for the selected area using this device’s available memory, graphics capacity and temperature. Ridge checks again before opening one fixed 3D area.")
                .font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
            if let terrain = store.activeTerrain {
                let allowance = TerrainBudget.allowance(for: terrain.manifest, spacing: terrain.level.spacing)
                HStack {
                    Text("Open area · memory estimate").font(.system(size: 11))
                    Spacer()
                    Text(RidgeTheme.bytes(allowance.estimatedMemory)).font(.system(size: 11, weight: .semibold, design: .default))
                }.foregroundStyle(RidgeTheme.forest)
            }
            Text("Asset size excludes the bundled atlas, routes and app files. Removing a saved area keeps your saved routes.")
                .font(.system(size: 11)).foregroundStyle(RidgeTheme.muted).lineSpacing(3)
        }
    }

    private var estimatesSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Route estimates").font(RidgeTheme.sectionTitle)
            Text("Adaptive terrain keeps more triangles where the ground changes sharply. Its 0.5 m tolerance describes the fit to the source data, not survey accuracy. Map detail is independent.")
            Text("Walking time is a planning estimate: 4 km/h, plus one hour for every 600 m of ascent. Ascent and descent ignore elevation changes below 3 m to reduce small terrain ripples. GPX segment breaks are kept separate.")
        }.font(.system(size: 12)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
    }

    private var attributionSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Map sources and licences").font(RidgeTheme.sectionTitle)
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
                    .background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
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

}
