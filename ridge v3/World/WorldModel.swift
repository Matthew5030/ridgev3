import Foundation
import Observation
import CoreGraphics

@MainActor @Observable final class WorldModel {
    @ObservationIgnored var cameraPose: TerrainCameraPose?
    var distantTerrain: WorldDistantTerrain?
    @ObservationIgnored private let distantStore: WorldDistantTerrainStore
    @ObservationIgnored private var distantLoad: Task<Void,Never>?
    var source: WorldSource?
    var overview: WorldOverview?
    var backdrop: WorldBackdrop?
    var streaming = false
    var loadedRadius = 0.0
    @ObservationIgnored var mapPreparationViewport:GeoBounds?
    @ObservationIgnored private var loadedCenter: GeoPoint?
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var downloadTask: Task<Void,Never>?
    @ObservationIgnored private var downloadGeneration = 0
    var downloadCenter: GeoPoint?
    var downloadRadius = 8000.0
    var drawingDownload = false
    var downloadSelection: GeoBounds?
    var completedDownloadTiles = Set<GeoBounds>()
    var activeDownloadTiles = Set<GeoBounds>()
    var downloadPlan: WorldDownloadPlan?
    var downloadRegion: WorldRegionPack?
    var regionTileProgress = WorldRegionTileProgress()
    var regionPlan: WorldRegionDownloadPlan?
    var regionChecked = 0
    var regionTotal = 0
    var regionSaved = 0
    var regionComplete = false
    var checkingDownload = false
    var downloadedBytes: Int64 = 0
    var downloadRate = WorldDownloadRate()
    var isRemovingDownloads = false
    var downloadError: String?
    var downloadedDestination: GeoPoint?
    @ObservationIgnored var entrySpan: Double?
    @ObservationIgnored private var previewPages: [String:WorldPreparedTile] = [:]
    var routeTerrain: LoadedTerrain?
    var tiles: [String: WorldPreparedTile] = [:]
    var revision = 0
    @ObservationIgnored var changedTileIDs = Set<String>()
    @ObservationIgnored private var tilesByID: [String:WorldTile] = [:]
    var isLoading = false
    var message: String?
    var center = GeoPoint(latitude: 53.0763, longitude: -4.0546)
    var distance = 6000.0
    var in3D = false
    var pending = 0
    var offlineMessage: String?
    var offlineBounds: [GeoBounds] = []
    var offlineCoverageRevision = 0
    var requestedDownloadPoint:GeoPoint?
    var offlineDisplayBounds: [GeoBounds] = []
    var offlineEdges: [WorldOfflineCoverage.Edge] = []
    var isSavingOffline = false
    var isConnectingDownload = false
    @ObservationIgnored private var offlineRefresh = 0
    var nearOfflineBoundary: Bool { offlineEdges.contains { $0.distance(to:center)<1500 } }
    var insideOfflineArea: Bool { offlineBounds.contains { $0.contains(center) } }
    private func refreshOfflineCoverage() { Task { [weak self] in await self?.reloadOfflineCoverage() } }
    private func reloadOfflineCoverage() async {
        offlineRefresh += 1; let ticket=offlineRefresh
        let cache=WorldOfflineCoverage.cache(cacheURL)
        let value=await Task.detached(priority:.utility) {
            let bounds=WorldOfflineCoverage.savedBounds(at:cache)
            return (bounds,WorldOfflineCoverage.outline(bounds),WorldOfflineCoverage.displayBounds(bounds))
        }.value
        guard ticket==offlineRefresh else { return }
        offlineBounds=value.0;offlineEdges=value.1;offlineDisplayBounds=value.2;offlineCoverageRevision += 1
    }
    var requestFocus: GeoPoint?
    var catalog: WorldCatalog?
    var libraryRoot: URL?
    var loadingRegionID: String?
    var downloadPhase: String?
    var coverageMessage: String?
    @ObservationIgnored private var files = WorldLandscapeStore()
    @ObservationIgnored private let catalogs: WorldCatalogStore
    @ObservationIgnored private let cacheURL: URL?
    init(cacheURL: URL? = nil, distantStore: WorldDistantTerrainStore = WorldDistantTerrainStore()) {
        self.cacheURL = cacheURL
        self.distantStore = distantStore
        self.catalogs = WorldCatalogStore(cacheURL: cacheURL)
        self.files = WorldLandscapeStore(cacheURL: cacheURL)
    }
    @ObservationIgnored private var regionLoad: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var requestedPoint: GeoPoint?
    @ObservationIgnored private var catalogRefresh:Task<Void,Never>?
    @ObservationIgnored private var navigationDestination: GeoPoint?
    @ObservationIgnored private var retryPoint: GeoPoint?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var wanted: [WorldTileRequest] = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var policyCenter: GeoPoint?
    @ObservationIgnored private var policyDistance = 0.0
    @ObservationIgnored private var reduceDetailUntil = Date.distantPast

    func configure(mode: String, local: String, preservingSelection: Bool = false) async {
        guard !isRemovingDownloads else { return }
        catalogRefresh?.cancel();catalogRefresh=nil
        let selectedRegion = preservingSelection ? downloadRegion : nil
        cancelRegionLoad(); distantLoad?.cancel(); distantLoad=nil; distantTerrain=nil; generation += 1; let token = generation
        work?.cancel(); work = nil; wanted = []; failed = []; tiles = [:]; previewPages = [:]
        tilesByID = [:]; changedTileIDs = []
        source = nil; overview = nil; backdrop = nil; routeTerrain = nil
        loadedCenter = nil; loadedRadius = 0; retryAfter = .distantPast
        cancelDownload(); offlineMessage=nil;downloadedDestination=nil;requestedDownloadPoint=nil
        downloadRegion=selectedRegion
        catalog = nil; libraryRoot = nil; cameraPose = nil; in3D = false; message = nil; coverageMessage = nil
        retryPoint = nil; requestFocus = nil
        isLoading = true
        defer { if generation == token { isLoading = false } }
        offlineBounds=[];offlineEdges=[];offlineDisplayBounds=[]
        await reloadOfflineCoverage()
        guard generation==token else { return }
        files = WorldLandscapeStore(cacheURL:cacheURL); navigationDestination = nil
        do {
            let root = try WorldLibrary.root(mode: mode, local: local)
            let value = try await catalogs.open(root: root,preferCached:true)
            guard generation == token, !Task.isCancelled else { return }
            libraryRoot = root; catalog = value
            // A region can be selected while the catalogue is still opening.
            // Rebuild its card now instead of leaving a stale connection error
            // and no download action after the server has become available.
            if let pack=downloadRegion { offerRegionDownload(pack) }
            // Open saved maps immediately, then refresh coverage and published
            // download formats without leaving the catalogue stale indefinitely.
            catalogRefresh=Task { [weak self] in
                guard let self else { return }
                do {
                    let fresh=try await catalogs.open(root:root,preferCached:false)
                    guard generation==token,!Task.isCancelled else { return }
                    if catalog?.revision != fresh.revision { loadedCenter=nil;retryAfter = .distantPast }
                    catalog=fresh
                    if let selected=downloadRegion,!isSavingOffline,!regionComplete { offerRegionDownload(selected) }
                } catch { /* The existing offline catalogue remains usable. */ }
            }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            message = error.localizedDescription
        }
    }
    func windowDisplacement(from point: GeoPoint) -> Double { loadedCenter?.distance(to:point) ?? 0 }
    func hasCoverage(_ point: GeoPoint) -> Bool {
        offlineBounds.contains { $0.contains(point) }
    }
    func canEnterTerrain(at point:GeoPoint) -> Bool {
        guard hasCoverage(point),let source,overview != nil,source.bounds.contains(point) else { return false }
        if !streaming,source.tiles.contains(where: { $0.mesh.bounds.contains(point) }) { return true }
        // A matching, already textured local horizon is enough to begin flying.
        // Routing remains unavailable until the detailed window is committed.
        return distantTerrain.map { $0.frame==source.frame && $0.center.distance(to:point)<20000 } ?? false
    }
    /// Navigation only opens completed downloads. All stores used to render
    /// this window are cache-only, including later fine geometry and textures.
    @discardableResult func browse(_ point: GeoPoint) -> Bool {
        guard !isRemovingDownloads else { return false }
        requestedPoint = point
        guard let catalog, let region = catalog.region(at:point), let root = libraryRoot else {
            coverageMessage = catalog == nil ? nil : "Detailed terrain isn’t available here yet. You can keep browsing the overview."
            return false
        }
        loadDistantTerrain(around:point,frame:source?.frame ?? region.bounds)
        guard hasCoverage(point) else {
            coverageMessage="This area isn’t downloaded. Download it to explore and plan routes here."
            if !in3D { requestedDownloadPoint=point }
            return false
        }
        // The previous focus may have been outside published or saved coverage.
        // Clear that warning as soon as this destination is valid, including
        // while its overview/detail is still preparing.
        coverageMessage=nil
        let ready = source?.tiles.contains { $0.mesh.bounds.contains(point) } == true
        // Finish the nearby detail window before extending it. The textured
        // overview can begin the flight while that first window is preparing.
        let preparationRadius=mapPreparationViewport.flatMap { $0.depthMeters<WorldCameraTransition.overheadSpanLimit ? WorldMapSurface.preparationRadius($0) : nil } ?? WorldWindow.entryRadius
        let radius = in3D ? WorldWindow.radius(distance:distance,pitch:cameraPose?.pitch ?? 0.85)+3000 : preparationRadius
        guard WorldWindow.needsUpdate(center:point,radius:radius,loadedCenter:loadedCenter,loadedRadius:loadedRadius) else {
            if ready { coverageMessage = nil }
            return ready
        }
        if let loading = windowCenter, regionLoad != nil {
            // Normal drags finish the existing small addition. A distant search
            // cancels it so that old work cannot publish at the new destination.
            if loading.distance(to:point) < max(6000,windowRadius*0.65) { return ready }
            cancelRegionLoad()
        }
        guard Date() >= retryAfter else { return ready }
        let initial = source == nil
        let requestedRadius = WorldWindow.nextRadius(desired:radius,loaded:loadedRadius)
        let oldFiles = files
        let frame = source?.frame ?? region.bounds
        let sessionID = source?.id ?? region.id
        let priority = WorldWindow.leadingPoint(from:loadedCenter,to:point)
        let savedBounds=offlineBounds
        let candidate = WorldLandscapeStore(cacheURL:cacheURL)
        selectionGeneration += 1; let ticket = selectionGeneration
        loadingRegionID = region.id; windowCenter = point; windowRadius = requestedRadius
        isLoading = initial; streaming = true; message = nil
        preparedWindowTiles.removeAll(keepingCapacity:true)
        downloadPhase = !in3D ? "Preparing downloaded terrain" : nil
        regionLoad = Task { [weak self] in
            guard let self else { return }
            do {
                let previous = initial ? nil : await oldFiles.snapshot()
                var (next,elevation,graph,background,pages) = try await candidate.window(center:point,radius:requestedRadius,frame:frame,catalog:catalog,root:root,previous:previous,priority:priority,offlineBounds:savedBounds,preview: { [weak self] metadata,elevation in
                    await self?.receivePreview(metadata,elevation:elevation,files:candidate,ticket:ticket,sessionID:sessionID)
                }) { [weak self] metadata,elevation,background,pages in
                    await self?.receiveAddition(metadata,elevation:elevation,background:background,pages:pages,files:candidate,ticket:ticket)
                }
                next.id = sessionID
                try Task.checkCancellation()
                guard ticket == selectionGeneration else { return }
                // The atlas already has textured relief. Rendering a second
                // full SceneKit scene just for its snapshot delayed 3D entry
                // and duplicated geometry uploads at the memory peak.
                install(next,elevation:elevation,graph:graph,background:background,pages:pages,files:candidate)
                loadedCenter = point; loadedRadius = requestedRadius
                if let destination = navigationDestination, hasCoverage(destination) {
                    requestFocus = destination; navigationDestination = nil
                }
                retryPoint = nil; retryAfter = .distantPast; coverageMessage = nil
                loadingRegionID = nil; regionLoad = nil; windowCenter = nil
                isLoading = false; streaming = false; downloadPhase = nil
                // Movement during preparation is consumed here, even after the
                // user has lifted their finger. The fine queue also resumes.
                update(center:requestedPoint ?? point,distance:distance)
            } catch {
                guard ticket == selectionGeneration, !Task.isCancelled else { return }
                NSLog("Ridge terrain window: %@",error.localizedDescription)
                retryPoint = requestedPoint; retryAfter = Date().addingTimeInterval(15)
                message = "Couldn’t open the downloaded terrain. Retry, or download this area again to repair missing files."
                loadingRegionID = nil; regionLoad = nil; windowCenter = nil
                isLoading = false; streaming = false; downloadPhase = nil
            }
        }
        return ready
    }
    private func receivePreview(_ metadata:WorldSource,elevation:WorldOverview,files candidate:WorldLandscapeStore,ticket:Int,sessionID:String) {
        guard ticket==selectionGeneration,source == nil else { return }
        var starter=metadata;starter.id=sessionID
        files=candidate;overview=elevation;backdrop=WorldBackdrop(geometries:[:],meshes:[:]);source=starter
        revision+=1
    }
    private func receiveAddition(_ metadata: WorldSource, elevation: WorldOverview, background: WorldBackdrop, pages: [String:WorldPreparedTile], files candidate: WorldLandscapeStore, ticket: Int) {
        guard ticket==selectionGeneration else { return }
        if !in3D {
            preparedWindowTiles.formUnion(pages.keys)
            downloadPhase = "Preparing terrain · \(preparedWindowTiles.count) of \(metadata.tiles.count) tiles"
        }
        guard var current=source, var visible=backdrop else { return }
        // Additions become usable immediately; retire old coverage only when the
        // replacement window finishes. Routing is swapped at that final commit.
        let additions=metadata.tiles.filter { pages[$0.id] != nil }
        var byID=Dictionary(uniqueKeysWithValues:current.tiles.map { ($0.id,$0) })
        for tile in additions { byID[tile.id]=tile; tilesByID[tile.id]=tile }
        current.tiles=byID.values.sorted { $0.id<$1.id }
        current.bounds=metadata.bounds;current.places=metadata.places;current.sources=metadata.sources
        current.revision=UUID().uuidString
        visible.geometries.merge(background.geometries) { _,new in new }
        for id in background.geometries.keys { visible.meshes[id]=background.meshes[id] }
        previewPages.merge(pages) { _,new in new }
        files=candidate;overview=elevation;backdrop=visible;source=current;revision+=1
    }
    private func loadDistantTerrain(around point: GeoPoint,frame:GeoBounds) {
        guard distantLoad == nil, distantTerrain == nil || distantTerrain!.center.distance(to:point) > 20000 else { return }
        distantLoad = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { distantLoad=nil } }
            do {
                let next = try await distantStore.build(center:point,frame:frame)
                guard !Task.isCancelled else { return }
                distantTerrain=next
            } catch { if !Task.isCancelled { NSLog("Ridge distant terrain: %@",error.localizedDescription) } }
        }
    }
    @ObservationIgnored private var windowCenter: GeoPoint?
    @ObservationIgnored private var windowRadius = 0.0
    @ObservationIgnored private var preparedWindowTiles = Set<String>()
    func pauseDownload() { cancelRegionLoad();cancelDownload() }
    private func install(_ next: WorldSource, elevation: WorldOverview, graph: WalkingGraph, background: WorldBackdrop, pages: [String:WorldPreparedTile], files candidate: WorldLandscapeStore) {
        generation += 1; work?.cancel(); work = nil; wanted = []; failed = []; policyCenter = nil
        // Rendering uses already admitted, cache-only files. Rechecking every
        // saved region here makes each camera window pay for the whole library.
        files = candidate; source = next; overview = elevation; backdrop = background
        tilesByID = Dictionary(uniqueKeysWithValues:next.tiles.map { ($0.id,$0) })
        changedTileIDs.removeAll(keepingCapacity:true)
        // All windows use the same frame, so overlapping meshes, images and
        // scene nodes can stay exactly where they are.
        let previous = tiles
        tiles = previous.filter { pages[$0.key] != nil }
        previewPages = pages
        let spacing = max(1, Int((next.bounds.widthMeters / Double(elevation.width - 1)).rounded()))
        let level = TerrainLOD(spacing: spacing, width: elevation.width, height: elevation.height, file: next.overview.file, byteCount: Int64(next.overview.byteCount), sha256: next.overview.sha256)
        let manifest = RegionManifest(schemaVersion: 1, id: next.id, name: next.name, subtitle: "", bounds: next.bounds, sourceResolution: 1, heightScale: 1, noDataValue: -32768,
            levels: [level], textures: [], graphFile: next.graph.file, graphSHA256: next.graph.sha256, graphByteCount: Int64(next.graph.byteCount), places: next.places,
            sources: next.sources, defaultSpacing: spacing, version: next.revision, summary: "", verticalDatum: "Source EGM96")
        routeTerrain = LoadedTerrain(manifest: manifest, level: level, heights: elevation.heights, textureURLs: [], graph: graph, directory: Bundle.main.bundleURL)
        revision += 1
    }
    func cancelRegionLoad() {
        if loadingRegionID != nil { isLoading = false }
        selectionGeneration += 1; regionLoad?.cancel(); regionLoad = nil; loadingRegionID = nil
        downloadPhase = nil
        streaming = false; windowCenter = nil; navigationDestination = nil
    }
    /// Search within 3D waits for the destination landscape before flying there.
    func visit(_ point: GeoPoint) {
        navigationDestination = nil
        if !hasCoverage(point) { requestedDownloadPoint=point;return }
        if browse(point) { requestFocus = point }
        else if loadingRegionID != nil { navigationDestination = point }
    }
    @ObservationIgnored private var closePreviewDetail=false
    @ObservationIgnored private var policyReducedDetail=false
    func cancelPendingCameraFocus() { requestFocus=nil;navigationDestination=nil }
    func prepareFlightElevations(_ points:[GeoPoint]) async throws -> ([Float?],[MapPlace]) {
        guard let catalog,let root=libraryRoot else { throw RidgeError.message("Open a downloaded map before previewing.") }
        let reader=WorldLandscapeStore(cacheURL:cacheURL)
        return try await reader.flightElevations(points,catalog:catalog,root:root,saved:offlineBounds)
    }
    func setClosePreviewDetail(_ enabled: Bool) {
        guard enabled != closePreviewDetail else { return }
        closePreviewDetail=enabled;policyCenter=nil
    }
    func update(center: GeoPoint, distance: Double,renderingSurface:Bool=false) {
        self.center = center; self.distance = distance
        guard in3D || renderingSurface, let source else { return }
        if navigationDestination == nil { browse(center) }
        let reducedDetail=Date()<reduceDetailUntil
        let crossedPreviewTile=closePreviewDetail && policyCenter.map { previous in
            source.tiles.first { $0.mesh.bounds.contains(previous) }?.id != source.tiles.first { $0.mesh.bounds.contains(center) }?.id
        } == true
        if reducedDetail==policyReducedDetail,!crossedPreviewTile, let previous = policyCenter, previous.distance(to: center) < (closePreviewDetail ? 60 : 140), abs(distance / max(1,policyDistance) - 1) < 0.22 { pump(); return }
        self.center = center; self.distance = distance
        policyCenter = center; policyDistance = distance;policyReducedDetail=reducedDetail
        let proposed = WorldWorkingSet.requests(source: source, center: center, distance: distance, previous:wanted,closePreview:closePreviewDetail)
        let next = reducedDetail ? proposed.prefix(12).map { WorldTileRequest(id: $0.id, pixels: 128, fine: false) } : proposed
        guard next != wanted else { return }
        wanted = next; failed = []
        let requests = Dictionary(uniqueKeysWithValues: next.map { ($0.id,$0) })
        // Retire geometry outside the bounded working set, but leave the image
        // attached until its replacement is ready. A detail change must never
        // expose an untextured tile.
        for id in Array(tiles.keys) {
            guard let desired=requests[id] else { tiles.removeValue(forKey:id);changedTileIDs.insert(id);continue }
            if tiles[id]?.request.fine == true && !desired.fine {
                changedTileIDs.insert(id)
                tiles[id]?.mesh=nil;tiles[id]?.geometry=nil;tiles[id]?.request.fine=false
            }
        }
        revision += 1
        pump()
    }
    func preparedTile(_ id: String) -> WorldPreparedTile? { tiles[id] ?? previewPages[id] }
    private func pump() {
        guard work == nil, let source else { return }
        let token = generation
        // Only one tile is decoded/rasterized at once. Movement changes the queue,
        // not the camera or the scene; superseded results are discarded.
        work = Task { [weak self] in
            guard let self else { return }
            defer { if token == generation { work = nil; pending = 0 } }
            while !Task.isCancelled && token == generation {
                let requests = WorldWorkingSet.pending(wanted:wanted,current:tiles.mapValues(\.request)).filter { !self.failed.contains($0.id) }
                pending = requests.count
                guard let request = requests.first, let tile = tilesByID[request.id] else { return }
                do {
                    let prepared = try await files.prepare(tile, request: request, sourceBounds: source.frame, previous:tiles[request.id])
                    guard token == generation, !Task.isCancelled else { return }
                    if wanted.contains(request) { tiles[request.id] = prepared; changedTileIDs.insert(request.id); revision += 1 }
                } catch {
                    guard token == generation, !Task.isCancelled else { return }
                    failed.insert(request.id); message = "Some downloaded detail is missing. Download this area again to repair it."
                }
            }
        }
    }
    func retry() {
        failed = []; message = nil; retryAfter = .distantPast
        if let point = retryPoint ?? requestedPoint {
            if in3D { visit(point) } else { browse(point) }
        }
        pump()
    }
    func suspend() { cancelRegionLoad(); generation += 1; work?.cancel(); work = nil; pending = 0; isLoading = false; changedTileIDs.formUnion(tiles.keys); tiles = [:]; revision += 1 }
    func resume() {
        if catalog != nil, let point = requestedPoint { browse(point) }
        pump()
    }
    func memoryWarning() {
        reduceDetailUntil = Date().addingTimeInterval(30)
        changedTileIDs.formUnion(tiles.keys)
        tiles = [:]; wanted = wanted.prefix(12).map { WorldTileRequest(id: $0.id, pixels: 256, fine: false) }; revision += 1
        message = "Detail reduced to free memory."; pump()
    }
    /// Metadata inspection is allowed here; the transfer waits for confirmation.
    func offerDownload(at point: GeoPoint, radius: Double? = nil, selection: GeoBounds? = nil) {
        guard !isSavingOffline else { return }
        downloadRegion=nil;regionPlan=nil;regionComplete=false
        cancelRegionLoad();downloadGeneration+=1;let ticket=downloadGeneration
        downloadTask?.cancel();downloadPlan=nil;downloadError=nil;downloadedBytes=0
        downloadCenter=point;downloadRadius=radius ?? downloadRadius;downloadSelection=selection
        completedDownloadTiles=[];activeDownloadTiles=[]
        guard let catalog,let root=libraryRoot else {
            downloadError="Connect to your map source in Settings to check this area.";checkingDownload=false;return
        }
        checkingDownload=true
        let store=WorldDownloadStore(cacheURL:cacheURL),radius=downloadRadius
        downloadTask=Task { [weak self] in
            do {
                let plan=try await store.plan(center:point,radius:radius,catalog:catalog,root:root,selection:selection)
                try Task.checkCancellation()
                guard let self,ticket==downloadGeneration else { return }
                downloadPlan=plan;completedDownloadTiles=plan.readyBounds;checkingDownload=false;downloadTask=nil
            } catch {
                guard let self,ticket==downloadGeneration,!Task.isCancelled else { return }
                checkingDownload=false;downloadError=error.localizedDescription;downloadTask=nil
            }
        }
    }
    func downloadAndOpen() {
        guard !isRemovingDownloads else { return }
        guard let plan=downloadPlan,!isSavingOffline else { return }
        downloadGeneration+=1;let ticket=downloadGeneration
        isSavingOffline=true;isConnectingDownload=plan.bytes>0;downloadedBytes=0;downloadError=nil
        downloadRate=WorldDownloadRate(startedAt:Date())
        let store=WorldDownloadStore(cacheURL:cacheURL)
        downloadTask=Task { [weak self] in
            do {
                if let part=plan.parts.first(where: { $0.missingBytes>0 }) { try await part.files.checkDownloadConnection() }
                try Task.checkCancellation()
                guard let self,ticket==downloadGeneration else { return }
                isConnectingDownload=false
                try await store.download(plan,tilesProgress: { [weak self] done,active in
                    await self?.receiveTileProgress(done,active:active,ticket:ticket)
                }) { [weak self] bytes in
                    await self?.receiveDownloadProgress(bytes,ticket:ticket)
                }
                try Task.checkCancellation()
                guard ticket==downloadGeneration else { return }
                await reloadOfflineCoverage()
                guard ticket==downloadGeneration,!Task.isCancelled else { return }
                downloadTask=nil;isSavingOffline=false;downloadCenter=nil;downloadPlan=nil;coverageMessage=nil
                drawingDownload=false;downloadSelection=nil
                downloadedDestination=plan.center
                visit(plan.center)
            } catch {
                guard let self,ticket==downloadGeneration,!Task.isCancelled else { return }
                isSavingOffline=false;isConnectingDownload=false;downloadTask=nil;activeDownloadTiles=[]
                downloadError=error.localizedDescription+" Completed files are kept; retry to continue."
                await reloadOfflineCoverage()
                guard ticket==downloadGeneration,let catalog,let root=libraryRoot else { return }
                checkingDownload=true
                let remaining=try? await store.plan(center:plan.center,radius:plan.radius,catalog:catalog,root:root,selection:plan.selection)
                guard ticket==downloadGeneration,!Task.isCancelled else { return }
                downloadPlan=remaining;completedDownloadTiles=remaining?.readyBounds ?? [];checkingDownload=false;downloadedBytes=0
            }
        }
    }
    func setDrawingDownload(_ enabled: Bool) {
        guard !isSavingOffline else { return }
        let point=downloadCenter ?? center
        cancelDownload();drawingDownload=enabled
        if enabled { downloadCenter=point } else { offerDownload(at:point) }
    }
    private func receiveTileProgress(_ done: Set<GeoBounds>,active: Set<GeoBounds>,ticket:Int) {
        guard ticket==downloadGeneration else { return }
        completedDownloadTiles=done;activeDownloadTiles=active
    }
    private func receiveDownloadProgress(_ bytes: Int64,ticket:Int) {
        guard ticket==downloadGeneration else { return }
        downloadedBytes=bytes
        downloadRate.record(bytes)
    }
    /// Regional saves never install a scene or move the camera. The user picks
    /// where to explore after the files are safely on disk.
    func offerRegionDownload(_ pack: WorldRegionPack) {
        guard !isRemovingDownloads else { return }
        guard !isSavingOffline else { return }
        cancelDownload();cancelRegionLoad()
        downloadRegion=pack;regionChecked=0;regionSaved=0;regionComplete=false
        guard let catalog,let root=libraryRoot else {
            downloadError=isLoading ? nil : "The map catalogue isn’t connected. Retry the connection or check the map source in Settings."
            return
        }
        guard pack.terrainAvailability(in:catalog).canDownload else {
            downloadError=WorldRegionPack.unavailableMessage
            return
        }
        regionTotal=pack.sources(in:catalog).count
        if let estimate=WorldRegionDownloadPlan.estimate(pack:pack,catalog:catalog,root:root) {
            regionPlan=estimate
            return
        }
        // Compatibility with older catalogues which have no published sizes.
        checkingDownload=true;let ticket=downloadGeneration
        let downloads=WorldRegionDownloadStore(cacheURL:cacheURL)
        downloadTask=Task { [weak self] in
            do {
                let plan=try await downloads.plan(pack:pack,catalog:catalog,root:root) { [weak self] checked,total in
                    await self?.receiveRegionCheck(checked,total:total,ticket:ticket)
                }
                try Task.checkCancellation()
                guard let self,ticket==downloadGeneration else { return }
                regionPlan=plan;checkingDownload=false;downloadTask=nil
            } catch {
                guard let self,ticket==downloadGeneration,!Task.isCancelled else { return }
                checkingDownload=false;downloadError=error.localizedDescription;downloadTask=nil
            }
        }
    }
    private func receiveRegionCheck(_ checked:Int,total:Int,ticket:Int) {
        guard ticket==downloadGeneration else { return }
        regionChecked=checked;regionTotal=total
    }
    private func receiveRegionProgress(_ bytes:Int64,saved:Int,ticket:Int) {
        guard ticket==downloadGeneration else { return }
        isConnectingDownload=false;downloadedBytes=bytes;regionSaved=saved
        downloadRate.record(bytes)
    }
    private func receiveRegionTiles(_ value:WorldRegionTileProgress,ticket:Int) {
        guard ticket==downloadGeneration,isSavingOffline else { return }
        regionTileProgress=value
    }
    func downloadRegionPack() {
        guard !isRemovingDownloads else { return }
        guard let plan=regionPlan,!isSavingOffline else { return }
        guard plan.pack.terrainAvailability(in:catalog).canDownload else {
            regionPlan=nil;downloadError=WorldRegionPack.unavailableMessage
            return
        }
        downloadGeneration+=1;let ticket=downloadGeneration
        isSavingOffline=true;isConnectingDownload=plan.bytes>0;downloadedBytes=0;downloadError=nil;regionSaved=0
        downloadRate=WorldDownloadRate(startedAt:Date())
        regionTileProgress=WorldRegionTileProgress()
        let downloads=WorldRegionDownloadStore(cacheURL:cacheURL)
        downloadTask=Task { [weak self] in
            do {
                try await downloads.download(plan,tileProgress: { [weak self] value in
                    await self?.receiveRegionTiles(value,ticket:ticket)
                }) { [weak self] bytes,saved in
                    await self?.receiveRegionProgress(bytes,saved:saved,ticket:ticket)
                }
                try Task.checkCancellation()
                guard let self,ticket==downloadGeneration else { return }
                await reloadOfflineCoverage()
                guard ticket==downloadGeneration,!Task.isCancelled else { return }
                isSavingOffline=false;isConnectingDownload=false;regionComplete=true;downloadTask=nil
                // A routing update can reuse every terrain tile yet replace the
                // graph. Rebuild the next local window from the new catalogue.
                loadedCenter=nil;retryAfter = .distantPast
                regionTileProgress=WorldRegionTileProgress()
            } catch {
                guard let self,ticket==downloadGeneration,!Task.isCancelled else { return }
                isSavingOffline=false;isConnectingDownload=false;downloadTask=nil;regionPlan=nil
                regionTileProgress.active=[]
                downloadError=error.localizedDescription+" Completed files are kept. Check the remaining download to continue."
                await reloadOfflineCoverage()
            }
        }
    }
    func pauseRegionDownload() {
        guard downloadRegion != nil else { return }
        downloadGeneration+=1;downloadTask?.cancel();downloadTask=nil
        isSavingOffline=false;isConnectingDownload=false;checkingDownload=false;regionPlan=nil
        regionTileProgress.active=[]
        downloadError="Paused. Completed files are kept. Check the remaining download to continue."
        refreshOfflineCoverage()
    }
    func cancelDownload() {
        let wasSaving=isSavingOffline
        downloadRate=WorldDownloadRate()
        regionTileProgress=WorldRegionTileProgress()
        downloadRegion=nil;regionPlan=nil;regionComplete=false;regionChecked=0;regionSaved=0;regionTotal=0
        downloadGeneration+=1;downloadTask?.cancel();downloadTask=nil
        drawingDownload=false;downloadSelection=nil;completedDownloadTiles=[];activeDownloadTiles=[]
        checkingDownload=false;isSavingOffline=false;isConnectingDownload=false;downloadCenter=nil;downloadPlan=nil;downloadError=nil;downloadedBytes=0
        if wasSaving { refreshOfflineCoverage() }
    }
    func downloadedMapsSummary() async throws -> WorldOfflineCoverage.StorageSummary {
        let library=try WorldRegionPack.loadLibrary(),cache=WorldOfflineCoverage.cache(cacheURL),catalog=catalog
        return await Task.detached(priority:.utility) {
            WorldOfflineCoverage.storageSummary(at:cache,areas:library.areas+library.parks,catalog:catalog)
        }.value
    }
    @discardableResult func removeDownloadedMaps(in area:WorldRegionPack? = nil) async -> Bool {
        guard !isRemovingDownloads else { return false }
        isRemovingDownloads=true
        let jobs=[downloadTask,work,regionLoad,catalogRefresh,distantLoad].compactMap { $0 }
        jobs.forEach { $0.cancel() }
        cancelDownload();cancelRegionLoad();suspend();catalogRefresh=nil;distantLoad=nil
        in3D=false;source=nil;overview=nil;backdrop=nil;routeTerrain=nil;distantTerrain=nil
        previewPages=[:];tilesByID=[:];loadedCenter=nil;loadedRadius=0
        // Wait for network writers to close before touching resumable files.
        for job in jobs { await job.value }
        let cache=WorldOfflineCoverage.cache(cacheURL),catalog=catalog
        var success=true
        do {
            try await Task.detached(priority:.userInitiated) {
                try WorldOfflineCoverage.removeDownloads(in:area,catalog:catalog,at:cache)
            }.value
        } catch { downloadError=error.localizedDescription;success=false }
        files=WorldLandscapeStore(cacheURL:cacheURL)
        await reloadOfflineCoverage()
        isRemovingDownloads=false
        if success,let area { offerRegionDownload(area) }
        return success
    }
}
