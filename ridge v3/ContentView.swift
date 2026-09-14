import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store = AppStore()
    @State private var showAdaptivePark = false
    var body: some View {
        ZStack {
            RidgeTheme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    switch store.tab {
                    case .explore: ExploreView(store: store, onOpenAdaptive: { showAdaptivePark = true })
                    case .areas: AreaLibraryView(store: store)
                    case .routes: RouteLibraryView(store: store)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                tabBar.disabled(store.isPreparing)
            }
            if store.isPreparing && !store.preparingFromAtlas { PreparationOverlay(store: store) }
        }
        .tint(RidgeTheme.forest).preferredColorScheme(.light)
        .task { await store.bootstrap() }
        .onOpenURL { url in if url.pathExtension.lowercased() == "gpx" { store.importGPX(url) } else { store.importPack(url) } }
        .sheet(item: $store.pendingPack, onDismiss: { store.dismissPendingPack() }) { entry in AreaDetailView(store: store, entry: entry).presentationDragIndicator(.visible) }
        .sheet(isPresented: $store.showDownloadSheet) { DownloadLinkView(store: store).presentationDetents([.medium]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store).presentationDragIndicator(.visible) }
        .fileImporter(isPresented: Binding(get: { store.showPackImporter || store.showGPXImporter }, set: { if !$0 { store.showPackImporter = false; store.showGPXImporter = false } }),
                      allowedContentTypes: store.showPackImporter ? [.folder, UTType(exportedAs: "com.bilellaworks.ridgepack", conformingTo: .package)] : [.ridgeGPX, .xml], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if ["gpx", "xml"].contains(url.pathExtension.lowercased()) { store.importGPX(url) }
                else { store.importPack(url) }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: Binding(get: { store.activeTerrain != nil || store.extensionInProgress }, set: { if !$0 { store.closeTerrain() } })) {
            Group {
                if let terrain = store.activeTerrain { TerrainPlannerView(store: store, terrain: terrain) }
                else if store.extensionInProgress { PreparationOverlay(store: store) }
            }
            .interactiveDismissDisabled(store.extensionInProgress)
        }
        .fullScreenCover(isPresented: $showAdaptivePark) { AdaptiveParkTestView() }
        .alert("Ridge", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .overlay(alignment: .top) {
            if let notice = store.notice, store.activeTerrain == nil {
                Text(notice).font(.subheadline.weight(.medium)).foregroundStyle(RidgeTheme.paper)
                    .padding(16).background(RidgeTheme.ink, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 20).padding(.top, 70).allowsHitTesting(false)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(MainTab.allCases, id: \.self) { tab in
                Button { store.tab = tab } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab == .explore ? "globe.europe.africa" : tab == .areas ? "square.stack.3d.up" : "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 18, weight: .medium))
                        Text(tab.rawValue).font(.system(size: 12, weight: .semibold))
                    }.frame(maxWidth: .infinity).padding(.vertical, 15)
                        .foregroundStyle(store.tab == tab ? RidgeTheme.forest : RidgeTheme.muted)
                        .background(store.tab == tab ? RidgeTheme.forest.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 17))
                }.accessibilityAddTraits(store.tab == tab ? .isSelected : [])
            }
        }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 3)
            .background(RidgeTheme.panel).overlay(alignment: .top) { Rectangle().fill(RidgeTheme.line.opacity(0.6)).frame(height: 0.5) }
    }
}

struct PreparationOverlay: View {
    @Bindable var store: AppStore
    var body: some View {
        ZStack {
            RidgeTheme.ink.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView().controlSize(.large).tint(RidgeTheme.forest)
                Text(store.preparationLabel).font(.headline)
                if store.progress > 0 { ProgressView(value: store.progress).tint(RidgeTheme.forest).frame(width: 190) }
                Text("A complete area. Ready to explore offline.").font(.footnote).foregroundStyle(RidgeTheme.muted)
                Button("Cancel") { store.cancelPreparation() }.font(.subheadline.weight(.medium))
            }.padding(30).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 28)).padding(28)
        }
    }
}

#Preview { ContentView() }
