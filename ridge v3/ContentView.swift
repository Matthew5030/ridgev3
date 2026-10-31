import SwiftUI
import UniformTypeIdentifiers

struct WorldPreviewPresentedKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct ContentView: View {
    var initialOpenURL: URL? = nil
    @State private var handledInitialURL = false
    @State private var store = AppStore()
    @State private var world = WorldModel()
    @State private var previewPresented = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ZStack {
            RidgeTheme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    switch store.tab {
                    case .explore: WorldExploreView(store: store, world: world)
                    case .areas: OfflinePacksView(store: store)
                    case .routes: RouteLibraryView(store: store, world: world)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !previewPresented { tabBar.disabled(store.isPreparing) }
            }
            if store.isPreparing && !store.preparingFromAtlas { PreparationOverlay(store: store) }
        }
        .tint(RidgeTheme.forest).preferredColorScheme(.light)
        .onPreferenceChange(WorldPreviewPresentedKey.self) { previewPresented=$0 }
        .task {
            await store.bootstrap()
            if !handledInitialURL, let initialOpenURL {
                handledInitialURL = true
                open(initialOpenURL)
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.savePlanningSession() } }
        .onOpenURL { open($0) }
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
        .fullScreenCover(isPresented: Binding(get: { (!store.isWorldBrowsing && store.activeTerrain != nil) || store.extensionInProgress }, set: { if !$0 { store.closeTerrain() } })) {
            Group {
                if let terrain = store.activeTerrain { TerrainPlannerView(store: store, terrain: terrain) }
                else if store.extensionInProgress { PreparationOverlay(store: store) }
            }
            .interactiveDismissDisabled(store.extensionInProgress)
        }
        .alert("Ridge", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            if let retry = store.retryPreparation { Button("Retry") { store.errorMessage = nil; retry() } }
                Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .confirmationDialog("Save route and exit?", isPresented: $store.showRouteExitConfirmation, titleVisibility: .visible) {
            Button("Save and exit") { Task { await store.saveRouteAndExplore() } }
            Button("Discard changes", role: .destructive) { Task { await store.discardRouteEditsAndExplore() } }
            Button("Keep editing", role: .cancel) { }
        } message: { Text("Save your route changes before returning to Explore.") }
        .overlay(alignment: .top) {
            if let notice = store.notice, store.activeTerrain == nil && store.tab != .explore {
                Text(notice).font(.subheadline.weight(.medium)).foregroundStyle(RidgeTheme.paper)
                    .padding(16).background(RidgeTheme.ink, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                    .padding(.horizontal, 20).padding(.top, 70).allowsHitTesting(false)
            }
        }.environment(world)
    }

    private func open(_ url: URL) {
        if url.pathExtension.lowercased() == "gpx" { store.importGPX(url) }
        else { store.importPack(url) }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach([MainTab.explore, .routes], id: \.self) { tab in
                Button { if tab == .explore { store.requestExplore() } else { store.tab = tab } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab == .explore ? "globe.europe.africa" : tab == .areas ? "square.stack.3d.up" : "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 18, weight: .medium))
                        Text(tab.rawValue).font(.system(size: 12, weight: .semibold))
                    }.frame(maxWidth: .infinity).padding(.vertical, 15)
                        .foregroundStyle(store.tab == tab ? RidgeTheme.forest : RidgeTheme.muted)
                        .background(store.tab == tab ? RidgeTheme.forest.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
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
                if let total = store.transferTotal { Text("\(RidgeTheme.bytes(store.transferredBytes)) of \(RidgeTheme.bytes(total))").font(.subheadline.monospacedDigit()).foregroundStyle(RidgeTheme.muted) }
                if store.progress > 0 { ProgressView(value: store.progress).tint(RidgeTheme.forest).frame(width: 190) }
                Button("Cancel") { store.cancelPreparation() }.font(.subheadline.weight(.medium))
            }.padding(30).background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: RidgeTheme.cardRadius)).padding(28)
        }
    }
}

#Preview { ContentView() }
