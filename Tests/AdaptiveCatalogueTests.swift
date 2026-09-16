import Foundation
@MainActor @main struct AdaptiveCatalogueTests {
    static func main() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), fm=FileManager.default
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let packs=PackStore(root:root.appendingPathComponent("areas"),bundledDirectory:nil,sourceDirectory:root.appendingPathComponent("sources"))
        let start=Date(),count=try await packs.connectSourceServer(URL(string:"http://127.0.0.1:8787")!)
        let initial=try await packs.catalogue()
        guard count==1,initial.count==1,initial[0].manifest.adaptive?.index != nil,initial[0].manifest.adaptive?.chunks.isEmpty==true else {fatalError("Catalogue eagerly loaded geometry")}
        print("Registered lightweight adaptive catalogue in \(Date().timeIntervalSince(start)) seconds")
        let point=GeoPoint(latitude:53.0793,longitude:-4.0539)
        let bounds=AtlasAreaPlanner.tile(at:point,entries:initial)!
        guard try await packs.hydrateAdaptiveSources(covering:bounds) else {fatalError("Index not loaded")}
        let ready=try await packs.catalogue()
        guard ready[0].manifest.adaptive?.chunks.count==16413 else {fatalError("Incomplete index")}
        let proposal=AtlasAreaPlanner.propose(bounds:bounds,entries:ready,context:TerrainBudget.Context(physicalMemory:8*1_073_741_824,gpuTier:.modern))
        guard proposal.canOpen,proposal.preview?.adaptive?.chunks.count==1 else {fatalError(proposal.reason ?? "Cannot select native cell")}
        // Live memory checks must only update admission, never discard metadata or
        // restart a pending source request. Preserve the selected geometry and save.
        var checked = proposal
        checked.saved = ready[0]
        checked.refreshBudget(spacing: 4, context: TerrainBudget.Context(physicalMemory: 256 * 1_048_576, gpuTier: .modern))
        guard !checked.canOpen, checked.reason != nil, checked.preview == proposal.preview,
              checked.selection == proposal.selection, checked.saved?.id == ready[0].id else { fatalError("Budget refresh changed selection or failed to refuse low memory") }
        checked.refreshBudget(spacing: 4, context: TerrainBudget.Context(physicalMemory: 8 * 1_073_741_824, gpuTier: .modern))
        guard checked.canOpen, checked.reason == nil, checked.preview == proposal.preview else { fatalError("Budget did not recover") }
        var pending = AtlasAreaProposal(requested: bounds, reason: "Index unavailable")
        pending.refreshBudget(spacing: 4)
        guard pending.reason == "Index unavailable", pending.preview == nil else { fatalError("Memory refresh hid a source error") }
        print("PASS: live budget checks preserve selection and source errors without I/O")
        let assets=AdaptiveArea.assets(proposal.preview!)
        guard assets.contains(where:{$0.byteOffset != nil && $0.remoteFile?.hasPrefix("context-source-")==true}),
              !assets.contains(where:{$0.file.hasPrefix("context-source-")}) else {fatalError("Full background download regression")}
        print("Selected native tile; context range bytes: \(assets.filter{$0.remoteFile?.hasPrefix("context-source-")==true}.reduce(0){$0+$1.byteCount})")
        var legacy=ready[0].manifest;legacy.id="legacy-source";legacy.adaptive=nil;legacy.bounds.minLatitude-=0.01;legacy.bounds.maxLatitude+=0.01;legacy.bounds.minLongitude-=0.01;legacy.bounds.maxLongitude+=0.01
        let app=AppStore(packs:packs,preferences:UserDefaults(suiteName:"ridge.adaptive.catalogue.test")!)
        app.entries=ready+[PackEntry(manifest:legacy,directory:root,installed:false)]
        guard app.selectableEntries.count==1,app.selectableEntries[0].id==ready[0].id else {fatalError("Legacy source hid adaptive coverage")}
        let again=try await packs.connectSourceServer(URL(string:"http://127.0.0.1:8787")!)
        guard again==1,try await packs.catalogue()[0].manifest.adaptive?.index==nil else {fatalError("Refresh discarded the verified local index")}
        print("PASS: normal server registration, lazy index, native selection, bounded context ranges, legacy filtering, repeat connection")
    }
}
