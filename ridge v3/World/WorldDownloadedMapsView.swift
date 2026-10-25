import SwiftUI

struct WorldDownloadedMapsView:View {
    @Bindable var store:AppStore
    @Bindable var world:WorldModel
    @Environment(\.dismiss) private var dismiss
    @State private var summary:WorldOfflineCoverage.StorageSummary?
    @State private var selectedArea:WorldRegionPack?
    @State private var selectedLegacy:PackEntry?
    @State private var sourceDownloads:[DownloadedSourceStorage] = []
    @State private var selectedSource:PackEntry?
    @State private var removeAll = false
    @State private var error:String?
    @State private var busy = false
    @State private var legacyBytes:Int64 = 0
    private var installed:[PackEntry] { store.entries.filter(\.installed) }
    private var totalBytes:Int64 { (summary?.bytes ?? 0)+legacyBytes+sourceDownloads.reduce(0) { $0+$1.bytes } }
    var body:some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Map files",value:summary == nil ? "—" : RidgeTheme.bytes(totalBytes))
                    Text("Includes saved maps and unfinished downloads. Your routes stay when you remove maps.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let summary {
                    Section("Downloaded areas") {
                        if summary.areas.isEmpty { Text("No downloaded map areas").foregroundStyle(.secondary) }
                        ForEach(summary.areas) { area in
                            HStack {
                                Text(area.name);Spacer()
                                Button(role:.destructive) { selectedArea=area } label: { Image(systemName:"trash") }
                                    .accessibilityLabel("Remove downloaded maps in \(area.name)")
                            }
                        }
                    }
                } else { ProgressView("Reading downloaded maps…") }
                if !installed.isEmpty {
                    Section("Saved 3D areas") {
                        ForEach(installed) { entry in
                            HStack {
                                Text(entry.manifest.name);Spacer()
                                Button(role:.destructive) { selectedLegacy=entry } label: { Image(systemName:"trash") }
                                    .accessibilityLabel("Remove \(entry.manifest.name)")
                            }
                        }
                    }
                }
                if !sourceDownloads.isEmpty {
                    Section("Map packs") {
                        ForEach(sourceDownloads) { pack in
                            HStack {
                                VStack(alignment:.leading) {
                                    Text(pack.entry.manifest.name)
                                    Text(RidgeTheme.bytes(pack.bytes)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role:.destructive) { selectedSource=pack.entry } label: { Image(systemName:"trash") }
                                    .accessibilityLabel("Remove downloaded pack \(pack.entry.manifest.name)")
                            }
                        }
                    }
                }
                Section {
                    Button("Remove all downloaded maps",role:.destructive) { removeAll=true }
                        .disabled((summary?.bytes ?? 0)==0 && installed.isEmpty && sourceDownloads.isEmpty)
                }
                if let error { Section { Text(error).foregroundStyle(RidgeTheme.orange) } }
            }
            .disabled(busy || world.isRemovingDownloads || store.isPreparing || store.isRouting)
            .navigationTitle("Downloaded maps").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .overlay { if busy { ProgressView("Removing maps…").padding(24).background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) } }
            .task { await refresh() }
            .confirmationDialog("Remove downloaded maps in \(selectedArea?.name ?? "this area")?",isPresented:Binding(get:{ selectedArea != nil },set:{ if !$0 { selectedArea=nil } }),titleVisibility:.visible) {
                if let area=selectedArea { Button("Remove maps",role:.destructive) { remove(area:area) } }
            } message: { Text("Saved routes and map files still used by other areas are kept.") }
            .confirmationDialog("Remove this saved 3D area?",isPresented:Binding(get:{ selectedLegacy != nil },set:{ if !$0 { selectedLegacy=nil } }),titleVisibility:.visible) {
                if let entry=selectedLegacy { Button("Remove area",role:.destructive) { removeLegacy(entry) } }
            } message: { Text("Your saved routes are kept.") }
            .confirmationDialog("Remove this downloaded map pack?",isPresented:Binding(get:{ selectedSource != nil },set:{ if !$0 { selectedSource=nil } }),titleVisibility:.visible) {
                if let entry=selectedSource { Button("Remove pack",role:.destructive) { removeSource(entry) } }
            } message: { Text("Your saved routes and saved 3D areas are kept.") }
            .confirmationDialog("Remove all downloaded maps?",isPresented:$removeAll,titleVisibility:.visible) {
                Button("Remove all maps",role:.destructive) { remove(area:nil) }
            } message: { Text("This removes downloaded terrain, saved 3D areas and unfinished downloads from this device. Your routes and the bundled map stay. You can download areas again.") }
        }
    }
    private func refresh() async {
        do {
            summary=try await world.downloadedMapsSummary();sourceDownloads=try await store.packs.downloadedSourceStorage()
            var bytes:Int64=0
            for entry in installed { if let manifest=try await store.packs.installedManifest(id:entry.id) { bytes+=manifest.totalBytes } }
            legacyBytes=bytes
        }
        catch { self.error=error.localizedDescription }
    }
    private func remove(area:WorldRegionPack?) {
        busy=true;error=nil
        Task {
            if await world.removeDownloadedMaps(in:area) {
                if area == nil {
                    do { try await store.removeAllDownloadedAreas() }
                    catch { self.error=error.localizedDescription }
                }
            } else { error=world.downloadError ?? "The maps could not be removed." }
            await refresh();busy=false
        }
    }
    private func removeLegacy(_ entry:PackEntry) {
        busy=true;error=nil
        Task {
            do {
                try await store.packs.remove(id:entry.id)
                if store.activeTerrain?.manifest.id==entry.id { store.closeTerrain() }
                await store.refresh()
            } catch { self.error=error.localizedDescription }
            await refresh();busy=false
        }
    }
    private func removeSource(_ entry:PackEntry) {
        busy=true;error=nil
        Task {
            do { try await store.packs.removeDownloadedSource(entry) }
            catch { self.error=error.localizedDescription }
            await refresh();busy=false
        }
    }
}
