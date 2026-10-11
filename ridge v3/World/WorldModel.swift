import Foundation
import Observation
import CoreGraphics

@MainActor @Observable final class WorldModel {
    @ObservationIgnored var cameraPose: TerrainCameraPose?
    var source: WorldSource?
    var overview: WorldOverview?
    var backdrop: WorldBackdrop?
    var preview: CGImage?
    var previewBounds: GeoBounds?
    var streaming = false
    var loadedRadius = 0.0
    @ObservationIgnored private var loadedCenter: GeoPoint?
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var savingOffline: Task<Void,Never>?
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
    var requestFocus: GeoPoint?
    var catalog: WorldCatalog?
    var libraryRoot: URL?
    var loadingRegionID: String?
    var downloadPhase: String?
    var coverageMessage: String?
    @ObservationIgnored private var files = WorldLandscapeStore()
    @ObservationIgnored private let catalogs: WorldCatalogStore
    @ObservationIgnored private let cacheURL: URL?
    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
        self.catalogs = WorldCatalogStore(cacheURL: cacheURL)
        self.files = WorldLandscapeStore(cacheURL: cacheURL)
    }
    @ObservationIgnored private var regionLoad: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var requestedPoint: GeoPoint?
    @ObservationIgnored private var navigationDestination: GeoPoint?
    @ObservationIgnored private var retryPoint: GeoPoint?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var wanted: [WorldTileRequest] = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var policyCenter: GeoPoint?
    @ObservationIgnored private var policyDistance = 0.0
    @ObservationIgnored private var reduceDetailUntil = Date.distantPast

    func configure(mode: String, local: String) async {
        cancelRegionLoad(); generation += 1; let token = generation
        work?.cancel(); work = nil; wanted = []; failed = []; tiles = [:]; previewPages = [:]
        tilesByID = [:]; changedTileIDs = []
        source = nil; overview = nil; backdrop = nil; preview = nil; previewBounds = nil; routeTerrain = nil
        loadedCenter = nil; loadedRadius = 0; retryAfter = .distantPast
        savingOffline?.cancel(); savingOffline = nil; offlineMessage = nil
        files = WorldLandscapeStore(cacheURL:cacheURL); navigationDestination = nil
        catalog = nil; libraryRoot = nil; cameraPose = nil; in3D = false; message = nil; coverageMessage = nil
        retryPoint = nil; requestFocus = nil
        isLoading = true
        defer { if generation == token { isLoading = false } }
        do {
            let root = try WorldLibrary.root(mode: mode, local: local)
            let value = try await catalogs.open(root: root)
            guard generation == token, !Task.isCancelled else { return }
            libraryRoot = root; catalog = value
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            message = error.localizedDescription
        }
    }
    func windowDisplacement(from point: GeoPoint) -> Double { loadedCenter?.distance(to:point) ?? 0 }
    func hasCoverage(_ point: GeoPoint) -> Bool {
        if let source, source.bounds.contains(point) { return source.tiles.contains { $0.mesh.bounds.contains(point) } }
        return catalog?.region(at: point) != nil
    }
    /// The camera asks for geography, never for a storage region. Keep one
    /// candidate in flight and coalesce motion rather than restarting every pan.
    @discardableResult func browse(_ point: GeoPoint) -> Bool {
        requestedPoint = point
        guard let catalog, let region = catalog.region(at:point), let root = libraryRoot else {
            coverageMessage = catalog == nil ? nil : "Detailed terrain isn’t available here yet. You can keep browsing the overview."
            return false
        }
        let ready = source?.tiles.contains { $0.mesh.bounds.contains(point) } == true
        let radius = WorldWindow.radius(distance:distance,pitch:cameraPose?.pitch ?? 0.85)
        guard WorldWindow.needsUpdate(center:point,radius:radius+3000,loadedCenter:loadedCenter,loadedRadius:loadedRadius) else {
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
        let requestedRadius = WorldWindow.nextRadius(desired:radius+3000,loaded:loadedRadius)
        let oldFiles = files
        let frame = source?.frame ?? region.bounds
        let sessionID = source?.id ?? region.id
        let candidate = WorldLandscapeStore(cacheURL:cacheURL)
        selectionGeneration += 1; let ticket = selectionGeneration
        loadingRegionID = region.id; windowCenter = point; windowRadius = requestedRadius
        isLoading = initial; streaming = true; message = nil
        downloadPhase = initial ? "Loading nearby terrain" : nil
        regionLoad = Task { [weak self] in
            guard let self else { return }
            do {
                let previous = initial ? nil : await oldFiles.snapshot()
                var (next,elevation,graph,background,pages) = try await candidate.window(center:point,radius:requestedRadius,frame:frame,catalog:catalog,root:root,previous:previous)
                next.id = sessionID
                try Task.checkCancellation()
                guard ticket == selectionGeneration else { return }
                // Only the first entry needs a rendered atlas preview. Window
                // shifts retain it with its original geographic bounds.
                let image = initial ? try await candidate.preview(source:next,backdrop:background,pages:pages) : preview
                guard ticket == selectionGeneration, !Task.isCancelled else { return }
                if initial { previewBounds = next.bounds }
                install(next,elevation:elevation,graph:graph,background:background,image:image,pages:pages,files:candidate)
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
                message = source == nil ? "Couldn’t load terrain. Check your map source and connection, then retry." : "Couldn’t load more terrain. Check your connection and retry. The map already loaded is still available."
                loadingRegionID = nil; regionLoad = nil; windowCenter = nil
                isLoading = false; streaming = false; downloadPhase = nil
            }
        }
        return ready
    }
    @ObservationIgnored private var windowCenter: GeoPoint?
    @ObservationIgnored private var windowRadius = 0.0
    func pauseDownload() { cancelRegionLoad() }
    private func install(_ next: WorldSource, elevation: WorldOverview, graph: WalkingGraph, background: WorldBackdrop, image: CGImage?, pages: [String:WorldPreparedTile], files candidate: WorldLandscapeStore) {
        generation += 1; work?.cancel(); work = nil; wanted = []; failed = []; policyCenter = nil
        files = candidate; source = next; overview = elevation; backdrop = background; preview = image
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
        if browse(point) { requestFocus = point }
        else if loadingRegionID != nil { navigationDestination = point }
    }
    func update(center: GeoPoint, distance: Double) {
        guard let source else { return }
        self.center = center; self.distance = distance
        if navigationDestination == nil { browse(center) }
        if let previous = policyCenter, previous.distance(to: center) < 140, abs(distance / max(1,policyDistance) - 1) < 0.22 { pump(); return }
        self.center = center; self.distance = distance
        policyCenter = center; policyDistance = distance
        let proposed = WorldWorkingSet.requests(source: source, center: center, distance: distance, previous:wanted)
        let next = Date() < reduceDetailUntil ? proposed.prefix(12).map { WorldTileRequest(id: $0.id, pixels: 128, fine: false) } : proposed
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
                    failed.insert(request.id); message = "Some detail is unavailable. The overview is still usable."
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
    func keepOffline() {
        guard let source, savingOffline == nil else { return }
        let store = files
        offlineMessage = "Saving terrain, maps and walking paths for offline use…"
        savingOffline = Task { [weak self] in
            do {
                try await store.pin(source.tiles,source:source)
                try Task.checkCancellation()
                self?.offlineMessage = "This area is saved for offline use. You can continue exploring beyond it while connected."
            } catch {
                if !Task.isCancelled { self?.offlineMessage = "Couldn’t finish saving this area. Check your connection and try again." }
            }
            self?.savingOffline = nil
        }
    }
}
