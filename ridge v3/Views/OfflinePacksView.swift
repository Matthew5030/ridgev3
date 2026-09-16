import SwiftUI

struct OfflinePacksView: View {
    @Bindable var store: AppStore
    @State private var showAreas = false
    @State private var regions: [UKPackRegion] = []
    @State private var regionError: String?
    private var sources: [PackEntry] { store.entries.filter { $0.manifest.adaptive?.isSource == true && $0.remoteSource != nil } }

    var body: some View {
        Group {
            if showAreas {
                VStack(spacing: 0) {
                    HStack { Button { showAreas = false } label: { Label("Packs", systemImage: "chevron.left") }; Spacer() }.padding(.horizontal, 24).padding(.top, 14)
                    AreaLibraryView(store: store)
                }
            } else { packList }
        }.task { do { regions = try UKPackRegion.load() } catch { regionError = error.localizedDescription } }
    }

    private var packList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Packs").font(RidgeTheme.pageTitle)
                    Spacer()
                    Button { store.showSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.accessibilityLabel("Download settings")
                }
                Text("Download a region once. Then choose a smaller area to explore in 3D.")
                    .font(.subheadline).foregroundStyle(RidgeTheme.muted)
                if sources.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Connect your download server").font(RidgeTheme.sectionTitle)
                        Text("Available packs will appear here. Saved maps work without the server.").font(.subheadline).foregroundStyle(RidgeTheme.muted)
                        Button("Open Settings") { store.showSettings = true }.buttonStyle(RidgeButtonStyle())
                    }.padding(20).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.cardRadius))
                } else {
                    Text("Available packs").font(RidgeTheme.sectionTitle)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 460), spacing: 18)], alignment: .leading, spacing: 18) {
                        ForEach(sources) { entry in OfflinePackCard(store: store, entry: entry) }
                    }
                }
                Button { showAreas = true } label: {
                    HStack {
                        Label("Saved 3D areas", systemImage: "mountain.2")
                        Spacer()
                        Text("\(store.entries.filter(\.installed).count)")
                        Image(systemName: "chevron.right")
                    }.font(.subheadline).padding(18).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                }.buttonStyle(.plain)
                DisclosureGroup("UK regions · \(regions.count)") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("The UK terrain is grouped into these regions. Full map and path packs are not ready yet. Eryri is available separately above; it is not the whole North Wales region.")
                            .font(.footnote).foregroundStyle(RidgeTheme.muted).padding(.top, 12)
                        ForEach(regions) { region in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(region.name).font(.subheadline.weight(.medium))
                                    Text("Maps and paths pending").font(.caption).foregroundStyle(RidgeTheme.muted)
                                }
                                Spacer()
                                Text(RidgeTheme.bytes(region.terrainBytes) + " terrain")
                                    .font(.caption.monospacedDigit()).foregroundStyle(RidgeTheme.muted)
                            }
                            Divider()
                        }
                        Text("Terrain sizes are not full download sizes. Detailed LiDAR has gaps; coarse terrain covers the wider landscape.")
                            .font(.caption).foregroundStyle(RidgeTheme.muted)
                    }
                }.font(.subheadline.weight(.medium))
                if let regionError { Text(regionError).font(.footnote).foregroundStyle(RidgeTheme.orange) }
            }.padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }.background(RidgeTheme.paper).foregroundStyle(RidgeTheme.ink)
    }
}

private struct OfflinePackCard: View {
    @Bindable var store: AppStore
    var entry: PackEntry
    @State private var summary: OfflinePackSummary?
    @State private var error: String?
    @State private var checking = false
    @State private var removing = false
    @State private var confirmRemoval = false
    @State private var retry = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(entry.manifest.name).font(RidgeTheme.sectionTitle); Spacer(); Image(systemName: summary?.complete == true ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(RidgeTheme.forest) }
            Text("Terrain, maps and walking paths").font(.subheadline).foregroundStyle(RidgeTheme.muted)
            if let summary {
                Text(summary.complete ? "Available offline" : RidgeTheme.bytes(summary.download.downloadBytes) + " to download")
                    .font(.headline).foregroundStyle(summary.complete ? RidgeTheme.forest : RidgeTheme.ink)
                Text(RidgeTheme.bytes(summary.download.totalBytes) + " pack" + (summary.download.cachedBytes > 0 && !summary.complete ? " · " + RidgeTheme.bytes(summary.download.cachedBytes) + " already saved" : ""))
                    .font(.caption.monospacedDigit()).foregroundStyle(RidgeTheme.muted)
                if summary.complete {
                    Button("Choose area to explore") { store.explorePack(summary.entry) }.buttonStyle(RidgeButtonStyle())
                } else {
                    Button(summary.download.cachedBytes > 0 ? "Continue download" : "Download pack") { store.downloadOfflinePack(summary.entry) }.buttonStyle(RidgeButtonStyle())
                    Text("Keep Ridge open while downloading. You can cancel and continue later. Choose your 3D area after the pack is saved.").font(.caption).foregroundStyle(RidgeTheme.muted)
                }
                if summary.download.cachedBytes > 0 {
                    Button("Remove pack download", role: .destructive) { confirmRemoval = true }.font(.caption)
                }
            } else if checking { ProgressView("Checking pack size…").font(.subheadline) }
            if let error {
                Text(error).font(.footnote).foregroundStyle(RidgeTheme.orange)
                Button("Try again") { retry += 1 }.font(.subheadline)
            }
            if removing { ProgressView("Removing download…") }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.cardRadius))
            .disabled(store.isPreparing || removing)
            .task(id: "\(entry.id)-\(store.offlinePackRevision)-\(retry)") {
                guard !store.isPreparing else { return }
                checking = true; error = nil
                defer { checking = false }
                do { summary = try await store.packs.offlinePackSummary(entry) }
                catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .confirmationDialog("Remove this pack’s downloaded files? Saved 3D areas and routes will stay on this device and may retain some of the storage.", isPresented: $confirmRemoval, titleVisibility: .visible) {
                Button("Remove download", role: .destructive) {
                    removing = true
                    Task { @MainActor in
                        defer { removing = false; retry += 1 }
                        do { try await store.packs.removeOfflinePack(entry); summary = nil }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
    }
}
