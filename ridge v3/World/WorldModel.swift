import Foundation
import Observation
import CoreGraphics

@MainActor @Observable final class WorldModel {
    @ObservationIgnored var cameraPose: TerrainCameraPose?
    var source: WorldSource?
    var overview: WorldOverview?
    var backdrop: WorldBackdrop?
    var preview: CGImage?
    @ObservationIgnored var entrySpan: Double?
    @ObservationIgnored private var previewPages: [String:WorldPreparedTile] = [:]
    var routeTerrain: LoadedTerrain?
    var tiles: [String: WorldPreparedTile] = [:]
    var revision = 0
    var isLoading = false
    var message: String?
    var center = GeoPoint(latitude: 53.0763, longitude: -4.0546)
    var distance = 6000.0
    var in3D = false
    var pending = 0
    var saving = false
    var offlineMessage: String?
    var requestFocus: GeoPoint?
    var catalog: WorldCatalog?
    var libraryRoot: URL?
    var loadingRegionID: String?
    var coverageMessage: String?
    @ObservationIgnored private var files = WorldSourceStore()
    @ObservationIgnored private let catalogs: WorldCatalogStore
    @ObservationIgnored private let cacheURL: URL?
    init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
        self.catalogs = WorldCatalogStore(cacheURL: cacheURL)
        self.files = WorldSourceStore(cacheURL: cacheURL)
    }
    @ObservationIgnored private var regionLoad: Task<Void, Never>?
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var requestedPoint: GeoPoint?
    @ObservationIgnored private var failedRegionID: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var wanted: [WorldTileRequest] = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var openedAddress = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var policyCenter: GeoPoint?
    @ObservationIgnored private var policyDistance = 0.0
    @ObservationIgnored private var reduceDetailUntil = Date.distantPast

    func configure(mode: String, local: String) async {
        cancelRegionLoad(); generation += 1; let token = generation
        work?.cancel(); work = nil; wanted = []; failed = []; tiles = [:]; previewPages = [:]
        source = nil; overview = nil; backdrop = nil; preview = nil; routeTerrain = nil
        catalog = nil; libraryRoot = nil; cameraPose = nil; in3D = false; message = nil; coverageMessage = nil; failedRegionID = nil
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
    func hasCoverage(_ point: GeoPoint) -> Bool {
        if let source, source.bounds.contains(point) { return source.tiles.contains { $0.mesh.bounds.contains(point) } }
        return catalog?.region(at: point) != nil
    }
    /// Called by both atlas zooming and the 3D camera. No region picker is involved.
    @discardableResult func browse(_ point: GeoPoint) -> Bool {
        requestedPoint = point
        guard let region = catalog?.region(at: point, retaining: source?.id), let root = libraryRoot else {
            cancelRegionLoad()
            coverageMessage = catalog == nil ? nil : "Detailed terrain isn’t available here from this source yet. You can keep browsing the overview."
            return false
        }
        coverageMessage = nil
        if region.id == source?.id {
            if loadingRegionID != nil { cancelRegionLoad() }
            guard hasCoverage(point) else { coverageMessage = "Detailed terrain is missing at this location. The overview is still available."; return false }
            return true
        }
        guard region.id != loadingRegionID, region.id != failedRegionID else { return false }
        cancelRegionLoad(); let ticket = selectionGeneration
        loadingRegionID = region.id; isLoading = true; message = nil
        // Each candidate owns its URL base. An old in-flight request must never
        // read filenames from a newly selected region or a different server.
        let candidate = WorldSourceStore(cacheURL: cacheURL)
        regionLoad = Task { [weak self] in
            guard let self else { return }
            defer {
                if ticket == selectionGeneration { loadingRegionID = nil; isLoading = false; regionLoad = nil }
            }
            do {
                let address = root.appendingPathComponent(region.path).absoluteString
                let (next, elevation, graph) = try await candidate.open(address: address)
                guard next.id == region.id, next.bounds == region.bounds else { throw RidgeError.message("The map does not match its catalogue.") }
                let background = try await candidate.backdrop(source: next, overview: elevation)
                let (image, pages) = try await candidate.preview(source: next, backdrop: background)
                try Task.checkCancellation()
                guard ticket == selectionGeneration else { return }
                generation += 1; work?.cancel(); work = nil; wanted = []; failed = []; policyCenter = nil
                files = candidate; source = next; overview = elevation; backdrop = background; preview = image
                tiles = pages; previewPages = pages; openedAddress = address; failedRegionID = nil
                if let point = requestedPoint { center = point }
                let spacing = max(1, Int((next.bounds.widthMeters / Double(elevation.width - 1)).rounded()))
                let level = TerrainLOD(spacing: spacing, width: elevation.width, height: elevation.height, file: next.overview.file, byteCount: Int64(next.overview.byteCount), sha256: next.overview.sha256)
                let manifest = RegionManifest(schemaVersion: 1, id: next.id, name: next.name, subtitle: "", bounds: next.bounds, sourceResolution: 1, heightScale: 1, noDataValue: -32768,
                    levels: [level], textures: [], graphFile: next.graph.file, graphSHA256: next.graph.sha256, graphByteCount: Int64(next.graph.byteCount), places: next.places,
                    sources: next.sources, defaultSpacing: spacing, version: next.revision, summary: "", verticalDatum: "Source EGM96")
                routeTerrain = LoadedTerrain(manifest: manifest, level: level, heights: elevation.heights, textureURLs: [], graph: graph, directory: Bundle.main.bundleURL)
                revision += 1
            } catch {
                guard ticket == selectionGeneration, !Task.isCancelled else { return }
                failedRegionID = region.id
                message = "Couldn’t load terrain here. Check your connection and try again."
            }
        }
        return false
    }
    func cancelRegionLoad() {
        if loadingRegionID != nil { isLoading = false }
        selectionGeneration += 1; regionLoad?.cancel(); regionLoad = nil; loadingRegionID = nil
    }
    func update(center: GeoPoint, distance: Double) {
        guard let source else { return }
        self.center = center; self.distance = distance
        if !source.bounds.contains(center) || loadingRegionID != nil { browse(center) }
        if let previous = policyCenter, previous.distance(to: center) < 140, abs(distance / max(1,policyDistance) - 1) < 0.22 { return }
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
            guard let desired=requests[id] else { tiles.removeValue(forKey:id);continue }
            if tiles[id]?.request.fine == true && !desired.fine {
                tiles[id]?.mesh=nil;tiles[id]?.geometry=nil;tiles[id]?.request.fine=false
            }
        }
        revision += 1
        pump()
    }
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
                guard let request = requests.first, let tile = source.tiles.first(where: { $0.id == request.id }) else { return }
                do {
                    let prepared = try await files.prepare(tile, request: request, sourceBounds: source.bounds, previous:tiles[request.id])
                    guard token == generation, !Task.isCancelled else { return }
                    let firstPage = tiles[request.id] == nil && !request.fine && wanted.contains(where: { $0.id == request.id && $0.pixels >= request.pixels })
                    if wanted.contains(request) || firstPage { tiles[request.id] = prepared; revision += 1 }
                } catch {
                    guard token == generation, !Task.isCancelled else { return }
                    failed.insert(request.id); message = "Some detail is unavailable. The overview is still usable."
                }
            }
        }
    }
    func retry() {
        failed = []; failedRegionID = nil; message = nil
        if let point = requestedPoint { browse(point) }
        pump()
    }
    func suspend() { cancelRegionLoad(); generation += 1; work?.cancel(); work = nil; pending = 0; isLoading = false; tiles = previewPages; revision += 1 }
    func resume() {
        if catalog != nil, let point = requestedPoint { browse(point) }
        pump()
    }
    func memoryWarning() {
        reduceDetailUntil = Date().addingTimeInterval(30)
        tiles = [:]; wanted = wanted.prefix(12).map { WorldTileRequest(id: $0.id, pixels: 256, fine: false) }; revision += 1
        message = "Detail reduced to free memory."; pump()
    }
    func keepOffline() {
        guard let source, !saving else { return }
        if openedAddress.isEmpty { offlineMessage = "This Snowdon map is already included and works offline."; return }
        let ids = Set(wanted.prefix(36).map(\.id)); let chosen = source.tiles.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        saving = true; offlineMessage = "Saving this area…"
        let files = self.files
        Task {
            defer { saving = false }
            do { try await files.pin(chosen, source: source, surroundings: source.tiles.map(\.map)); offlineMessage = "This area is available offline." }
            catch { offlineMessage = "Could not finish saving. Completed files remain cached; try again." }
        }
    }
}
