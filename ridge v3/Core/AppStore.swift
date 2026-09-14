import Foundation
import Observation

enum MainTab: String, CaseIterable { case explore = "Explore", areas = "My areas", routes = "Routes" }

@MainActor @Observable final class AppStore {
    var tab: MainTab = .explore
    var entries: [PackEntry] = []
    var atlas: AtlasData?
    var routes: [RidgeRoute] = []
    var pendingPack: PackEntry?
    var pendingSelection: AreaSelection?
    var pendingRemoteURL: URL?
    var activeTerrain: LoadedTerrain?
    var activeRoute: RidgeRoute?
    var editing = false
    var planningMode: RoutePlanningMode = .paths
    var camera = TerrainCameraCommand()
    var selectedPoint: GeoPoint?
    var movingWaypoint: Int?
    var isPreparing = false
    var preparationLabel = "Opening terrain"
    var progress: Double = 0
    var isRouting = false
    var errorMessage: String?
    var notice: String?
    var loaded = false
    var showGPXImporter = false
    var showPackImporter = false
    var showDownloadSheet = false
    var showSettings = false
    var preparingFromAtlas = false
    var undoStack: [RidgeRoute] = []
    var redoStack: [RidgeRoute] = []
    var pendingExtension: AreaExtensionProposal?
    var extensionSpacing = 8
    var extensionBudgetContext = TerrainBudget.currentContext()
    var extensionInProgress = false
    var extensionError: String?
    var extensionForRoute = false
    var extensionMarginMeters: Double = 500
    var viewedTerrainSpacing: Int?
    var viewingSurroundings = false
    var viewingSceneEdge = false
    let packs: PackStore
    let routeStore: RouteStore
    @ObservationIgnored private var lastCameraPose: TerrainCameraPose?
    @ObservationIgnored private var lastViewedPoint: GeoPoint?
    @ObservationIgnored private var sceneReleased = true
    @ObservationIgnored private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var noticeTask: Task<Void, Never>?
    private var pendingRoute: RidgeRoute?
    private var scopedPackURL: URL?

    init(packs: PackStore = PackStore(), routeStore: RouteStore = RouteStore()) {
        self.packs = packs
        self.routeStore = routeStore
    }

    var extensionManifest: RegionManifest? {
        guard var preview = pendingExtension?.preview else { return nil }
        preview.horizon = TerrainBudget.selectedHorizon(for: preview, spacing: extensionSpacing, context: extensionBudgetContext)
        return preview
    }

    var extensionAllowance: TerrainAllowance {
        guard let manifest = extensionManifest else {
            return TerrainAllowance(allowed: false, bytesOnDisk: 0, estimatedMemory: 0, reason: pendingExtension?.unavailableReason ?? "Choose an area to extend.")
        }
        return TerrainBudget.allowance(for: manifest, spacing: extensionSpacing, context: extensionBudgetContext)
    }

    func updateNavigation(_ state: TerrainNavigationState) {
        guard activeTerrain != nil, !extensionInProgress else { return }
        lastCameraPose = state.pose
        lastViewedPoint = state.viewedPoint ?? state.pose.target
        sceneReleased = false
        if viewingSurroundings == state.insidePlanningArea { viewingSurroundings = !state.insidePlanningArea }
        if viewedTerrainSpacing != state.spacing { viewedTerrainSpacing = state.spacing }
        if let bounds = activeTerrain?.horizon?.layers.last?.metadata.bounds ?? activeTerrain?.manifest.bounds,
           let point = lastViewedPoint {
            let uv = bounds.uv(point)
            let margin = min(min(uv.u, 1 - uv.u) * bounds.widthMeters, min(uv.v, 1 - uv.v) * bounds.depthMeters)
            let atEdge = margin < 2_000 && !state.insidePlanningArea
            if viewingSceneEdge != atEdge { viewingSceneEdge = atEdge }
        }
    }

    var areaExpansionFocus: GeoPoint? {
        if let selectedPoint, activeTerrain?.manifest.bounds.contains(selectedPoint) == false { return selectedPoint }
        return lastViewedPoint
    }

    func terrainViewReleased() {
        sceneReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    var routeNeedsDetail: Bool {
        guard let terrain = activeTerrain else { return false }
        return !RouteEngine.overviewPoints(in: activeRoute, bounds: terrain.manifest.bounds).isEmpty
    }

    func requestDetailAlongRoute() {
        guard let terrain = activeTerrain,
              let point = RouteEngine.overviewPoints(in: activeRoute, bounds: terrain.manifest.bounds).last else { return }
        requestExtension(at: point, forRoute: true)
    }

    func setExtensionMargin(_ meters: Double) {
        guard [250.0, 500, 1000, 2000].contains(meters), !extensionInProgress,
              let point = pendingExtension?.destination else { return }
        let spacing = extensionSpacing
        extensionMarginMeters = meters
        requestExtension(at: point, forRoute: extensionForRoute)
        extensionSpacing = spacing
    }

    func requestExtensionAtViewpoint() {
        guard let point = lastViewedPoint ?? lastCameraPose?.target else { return }
        requestExtension(at: point)
    }

    func requestExtension(at point: GeoPoint, forRoute: Bool = false) {
        guard let terrain = activeTerrain, point.isValid, !terrain.manifest.bounds.contains(point), !isRouting, !extensionInProgress else { return }
        extensionForRoute = forRoute
        extensionBudgetContext = TerrainBudget.currentContext()
        pendingExtension = AreaExtensionPlanner.propose(destination: point, terrain: terrain, route: activeRoute, entries: entries, context: extensionBudgetContext, marginMeters: extensionMarginMeters, bufferWholeRoute: forRoute)
        selectedPoint = point
        extensionError = nil
        extensionSpacing = terrain.level.spacing
        if let preview = pendingExtension?.preview,
           !TerrainBudget.allowance(for: preview, spacing: extensionSpacing, context: extensionBudgetContext).allowed,
           let recommended = TerrainBudget.recommendedSpacing(for: preview, context: extensionBudgetContext) {
            extensionSpacing = recommended
        }
    }

    func setExtensionSpacing(_ spacing: Int) {
        guard !extensionInProgress else { return }
        extensionSpacing = spacing
        extensionError = nil
        refreshExtensionBudget()
    }

    func refreshExtensionBudget() {
        // A live budget refresh never silently changes the displayed choice.
        extensionBudgetContext = TerrainBudget.currentContext()
    }

    func dismissExtension() {
        guard !extensionInProgress else { return }
        pendingExtension = nil
        extensionError = nil
        selectedPoint = nil
    }

    private struct ExtensionSession {
        var areaID: String
        var route: RidgeRoute?
        var editing: Bool
        var mode: RoutePlanningMode
        var movingWaypoint: Int?
        var undo: [RidgeRoute]
        var redo: [RidgeRoute]
        var camera: TerrainCameraPose?
        var proposal: AreaExtensionProposal
    }

    func confirmExtension() {
        guard !extensionInProgress, !isRouting, let terrain = activeTerrain,
              let proposal = pendingExtension, let source = proposal.source, let selection = proposal.selection else { return }
        refreshExtensionBudget()
        guard extensionAllowance.allowed else {
            extensionError = extensionAllowance.reason ?? "Choose a coarser detail level for this larger area."
            return
        }
        let session = ExtensionSession(areaID: terrain.manifest.id, route: activeRoute, editing: editing, mode: planningMode,
                                       movingWaypoint: movingWaypoint, undo: undoStack, redo: redoStack,
                                       camera: lastCameraPose, proposal: proposal)
        let spacing = extensionSpacing
        let waitForRelease = !sceneReleased
        operation?.cancel()
        let token = UUID(); operationID = token
        extensionInProgress = true
        extensionError = nil
        isPreparing = true
        preparationLabel = "Extending your planning area"
        progress = 0
        // The replacement retains only route/metadata/camera state. It must not
        // hold the previous LoadedTerrain's heights or graph while building.
        activeTerrain = nil
        operation = Task {
            defer {
                if operationID == token { extensionInProgress = false; isPreparing = false }
            }
            do {
                if waitForRelease { await waitForTerrainRelease() }
                try Task.checkCancellation()
                let sourceID = cartographySourceID(for: source)
                let worker = Task.detached(priority: .userInitiated) {
                    try AreaCropper.prepare(directory: source.directory, manifest: source.manifest, selection: selection, spacing: spacing,
                                            cartographySourceID: sourceID)
                }
                let crop = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                defer { try? FileManager.default.removeItem(at: crop.directory) }
                try Task.checkCancellation()
                var savedManifest = crop.manifest
                if let name = proposal.displayName { savedManifest.name = name }
                try await packs.install(from: crop.directory, manifest: savedManifest, spacing: spacing) { [weak self] value in
                    await self?.updateProgress(value, operationID: token)
                }
                try Task.checkCancellation()
                preparationLabel = "Opening the extended terrain"
                let expanded = try await packs.load(id: crop.manifest.id, spacing: spacing)
                try Task.checkCancellation()
                // Finish catalogue and sketch resolution while the editor is
                // retired. Publish the complete scene and route together.
                await refresh()
                try Task.checkCancellation()
                var associated = session.route
                associated?.regionID = expanded.manifest.id
                if let draft = associated {
                    associated = try await Task.detached { try RouteEngine.resolveOverview(draft, terrain: expanded) }.value
                }
                // Resolve old sketch snapshots off the main actor as well, so
                // undo/redo keep their original shapes with newly available heights.
                let snapshots = await Task.detached { [undo = session.undo, redo = session.redo] in
                    (undo.map { (try? RouteEngine.resolveOverview($0, terrain: expanded)) ?? $0 },
                     redo.map { (try? RouteEngine.resolveOverview($0, terrain: expanded)) ?? $0 })
                }.value
                var completedSession = session
                completedSession.undo = snapshots.0; completedSession.redo = snapshots.1
                try Task.checkCancellation()
                // Once the durable route association is saved, publish the new
                // state together. Cancellation before this point restores the old area.
                if let associated, !associated.points.isEmpty {
                    try await routeStore.save(associated)
                    routes.removeAll { $0.id == associated.id }
                    routes.append(associated)
                    routes.sort { $0.modifiedAt > $1.modifiedAt }
                }
                restoreExtensionState(completedSession, terrain: expanded, route: associated, completed: true)
                extensionInProgress = false
                isPreparing = false
                toast(session.route?.segments.contains(where: { $0.mode == "overview" }) == true
                      ? "Detail added. Your sketch lines remain manual connections."
                      : "Detail added. Your area is saved offline.")
            } catch {
                let cancelled = error is CancellationError
                preparationLabel = "Returning to your saved area"
                // Recovery runs independently of the cancelled preparation task.
                // The old installation is kept throughout the extension.
                do {
                    let packs = self.packs
                    let restored = try await Task.detached { try await packs.load(id: session.areaID) }.value
                    restoreExtensionState(session, terrain: restored, route: session.route, completed: false)
                    extensionError = cancelled ? "Extension cancelled. Your route and saved area are unchanged." : "The area could not be extended. Your route is unchanged. " + error.localizedDescription
                } catch {
                    activeRoute = session.route
                    pendingExtension = session.proposal
                    errorMessage = "Your original area and route are still saved, but the terrain could not be reopened: " + error.localizedDescription
                }
            }
        }
    }

    private func waitForTerrainRelease() async {
        // Even cancellation waits for the old view to release its resources
        // before recovery decodes a replacement copy of that saved scene.
        if !sceneReleased {
            await withCheckedContinuation { continuation in
                if sceneReleased { continuation.resume() } else { releaseWaiter = continuation }
            }
        }
    }

    private func restoreExtensionState(_ session: ExtensionSession, terrain: LoadedTerrain, route: RidgeRoute?, completed: Bool) {
        activeRoute = route
        editing = session.editing
        planningMode = session.mode
        movingWaypoint = session.movingWaypoint
        func reassociate(_ value: RidgeRoute) -> RidgeRoute {
            var value = value; value.regionID = terrain.manifest.id; return value
        }
        undoStack = session.undo.map(reassociate)
        redoStack = session.redo.map(reassociate)
        selectedPoint = session.proposal.destination
        pendingExtension = completed ? nil : session.proposal
        camera = session.camera.map { TerrainCameraCommand(action: .restore($0)) } ?? TerrainCameraCommand()
        lastCameraPose = session.camera
        lastViewedPoint = session.camera?.target
        viewingSurroundings = !terrain.manifest.bounds.contains(session.camera?.target ?? session.proposal.destination)
        viewedTerrainSpacing = terrain.level.spacing
        activeTerrain = terrain
    }

    func bootstrap() async {
        guard !loaded else { return }
        do {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: documents.appendingPathComponent("Exports", isDirectory: true), withIntermediateDirectories: true)
            entries = try await packs.catalogue()
            atlas = try await packs.atlas()
            routes = try await routeStore.load()
            loaded = true
            let issues = await packs.issues()
            if !issues.isEmpty { errorMessage = issues.joined(separator: "\n") }
        } catch { errorMessage = error.localizedDescription }
    }

    func refresh() async {
        do { entries = try await packs.catalogue(); routes = try await routeStore.load() }
        catch { errorMessage = error.localizedDescription }
    }

    /// Source collections remain visible; their contained examples and saved
    /// tile selections belong in My areas rather than competing on the atlas.
    var selectableEntries: [PackEntry] {
        entries.filter { candidate in
            !entries.contains { source in
                source.id != candidate.id && source.manifest.grid != nil &&
                source.manifest.bounds.areaSquareKilometers > candidate.manifest.bounds.areaSquareKilometers * 1.00001 &&
                source.manifest.bounds.contains(GeoPoint(latitude: candidate.manifest.bounds.minLatitude, longitude: candidate.manifest.bounds.minLongitude)) &&
                source.manifest.bounds.contains(GeoPoint(latitude: candidate.manifest.bounds.maxLatitude, longitude: candidate.manifest.bounds.maxLongitude))
            }
        }
    }

    func choose(_ entry: PackEntry, route: RidgeRoute? = nil) {
        guard !extensionInProgress else { return }
        scopedPackURL?.stopAccessingSecurityScopedResource(); scopedPackURL = nil
        var source = entry
        pendingSelection = nil
        if let grid = entry.manifest.grid,
           let collection = selectableEntries.first(where: { candidate in
               candidate.id != entry.id && candidate.manifest.grid?.worldTileID == grid.worldTileID &&
               candidate.manifest.bounds.contains(GeoPoint(latitude: entry.manifest.bounds.minLatitude, longitude: entry.manifest.bounds.minLongitude)) &&
               candidate.manifest.bounds.contains(GeoPoint(latitude: entry.manifest.bounds.maxLatitude, longitude: entry.manifest.bounds.maxLongitude))
           }) {
            source = collection
            let a = source.manifest.bounds.uv(GeoPoint(latitude: entry.manifest.bounds.maxLatitude, longitude: entry.manifest.bounds.minLongitude))
            let b = source.manifest.bounds.uv(GeoPoint(latitude: entry.manifest.bounds.minLatitude, longitude: entry.manifest.bounds.maxLongitude))
            pendingSelection = source.manifest.grid?.cellsSelection(AreaSelection(minU: a.u, minV: a.v, maxU: b.u, maxV: b.v))
        }
        if let route { pendingSelection = Self.routeSelection(for: route, in: source.manifest, preserving: pendingSelection) }
        pendingRemoteURL = nil; pendingPack = source; pendingRoute = route
    }

    private nonisolated static func routeSelection(for route: RidgeRoute, in manifest: RegionManifest, preserving preferred: AreaSelection?) -> AreaSelection {
        guard let grid = manifest.grid, grid.isValid else { return preferred ?? AreaSelection() }
        let points = route.points.map(\.coordinate)
        guard let first = points.first, points.allSatisfy(manifest.bounds.contains) else { return AreaSelection() }
        if let preferred, let aligned = grid.cellsSelection(preferred) {
            let a = manifest.bounds.point(u: aligned.minU, v: aligned.minV), b = manifest.bounds.point(u: aligned.maxU, v: aligned.maxV)
            let bounds = GeoBounds(minLatitude: b.latitude, minLongitude: a.longitude, maxLatitude: a.latitude, maxLongitude: b.longitude)
            if points.allSatisfy(bounds.contains) { return aligned }
        }
        var west = first.longitude, east = first.longitude, north = first.latitude, south = first.latitude
        for point in points.dropFirst() {
            west = min(west, point.longitude); east = max(east, point.longitude)
            north = max(north, point.latitude); south = min(south, point.latitude)
        }
        // Compare the actual geographic edges used by AreaCropper. This keeps
        // an endpoint exactly on an edge in the smallest containing rectangle,
        // and also handles one-point or perfectly north/south routes.
        let left = (0..<grid.columns).last { manifest.bounds.point(u: Double($0) / Double(grid.columns), v: 0).longitude <= west } ?? 0
        let right = ((left + 1)...grid.columns).first { manifest.bounds.point(u: Double($0) / Double(grid.columns), v: 0).longitude >= east } ?? grid.columns
        let top = (0..<grid.rows).last { manifest.bounds.point(u: 0, v: Double($0) / Double(grid.rows)).latitude >= north } ?? 0
        let bottom = ((top + 1)...grid.rows).first { manifest.bounds.point(u: 0, v: Double($0) / Double(grid.rows)).latitude <= south } ?? grid.rows
        return grid.rectangle(from: TerrainCell(column: left, row: top), to: TerrainCell(column: right - 1, row: bottom - 1)) ?? AreaSelection()
    }

    /// Enter the same fixed-scene installer without opening an intermediate sheet.
    func openAtlasArea(_ proposal: AtlasAreaProposal, spacing: Int = 4) {
        guard !isPreparing, !isRouting, proposal.canOpen, let source = proposal.source, let selection = proposal.selection else { return }
        pendingRoute = nil; pendingRemoteURL = nil; pendingSelection = nil
        preparingFromAtlas = true
        if let saved = proposal.saved { open(saved) }
        else { install(source, spacing: spacing, selection: selection, displayName: proposal.preview?.name) }
    }

    func expandAtlasArea(_ proposal: AtlasAreaProposal) {
        guard let terrain = activeTerrain, proposal.canOpen,
              let source = proposal.source, let selection = proposal.selection, let preview = proposal.preview,
              AtlasAreaPlanner.contains(preview.bounds, terrain.manifest.bounds),
              ((activeRoute?.points.map(\.coordinate) ?? []) + (activeRoute?.waypoints.map { $0.point.coordinate } ?? [])).allSatisfy(preview.bounds.contains) else { return }
        pendingExtension = AreaExtensionProposal(destination: preview.bounds.center, source: source, selection: selection, preview: preview, displayName: preview.name)
        extensionSpacing = terrain.level.spacing
        extensionForRoute = false
        confirmExtension()
    }

    func chooseTile(_ entry: PackEntry, column: Int, row: Int) {
        choose(entry)
        pendingSelection = entry.manifest.grid?.selection(column: column, row: row)
    }

    func dismissPendingPack() {
        scopedPackURL?.stopAccessingSecurityScopedResource(); scopedPackURL = nil
        pendingRoute = nil; pendingRemoteURL = nil; pendingSelection = nil
    }

    func install(_ entry: PackEntry, spacing: Int, selection: AreaSelection = AreaSelection(), displayName: String? = nil) {
        guard !extensionInProgress else { return }
        let remote = pendingRemoteURL
        let requestedRoute = pendingRoute
        if let requestedRoute {
            let selectedManifest = selection.isWhole ? entry.manifest : AreaCropper.preview(manifest: entry.manifest, selection: selection)
            guard RouteEngine.containingRegion(for: requestedRoute, in: [selectedManifest], installedIDs: []) != nil else {
                errorMessage = "This selection does not contain the whole route. Enlarge the selected area before saving."
                return
            }
        }
        // The sheet dismissal releases unused scopes. This operation takes the
        // selected folder's scope first and retains it until copying has finished.
        let importScope = scopedPackURL; scopedPackURL = nil
        pendingPack = nil
        operation?.cancel()
        let token = UUID(); operationID = token
        operation = Task {
            isPreparing = true; preparationLabel = remote == nil ? "Saving area offline" : "Downloading area"; progress = 0
            defer {
                importScope?.stopAccessingSecurityScopedResource()
                if operationID == token { isPreparing = false; preparingFromAtlas = false }
            }
            do {
                // Retire the previous fixed scene before preparing its replacement.
                // The live allowance must not have to cover two terrain meshes.
                activeTerrain = nil
                var openedID = entry.id
                if remote == nil && (!selection.isWhole || entry.manifest.horizon != nil) {
                    preparationLabel = "Preparing selected area"
                    let sourceID = cartographySourceID(for: entry)
                    let worker = Task.detached(priority: .userInitiated) {
                        try AreaCropper.prepare(directory: entry.directory, manifest: entry.manifest, selection: selection, spacing: spacing,
                                                cartographySourceID: sourceID)
                    }
                    let crop = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    defer { try? FileManager.default.removeItem(at: crop.directory) }
                    try Task.checkCancellation()
                    openedID = crop.manifest.id
                    var savedManifest = crop.manifest
                    if let displayName { savedManifest.name = displayName }
                    try await packs.install(from: crop.directory, manifest: savedManifest, spacing: spacing) { [weak self] value in await self?.updateProgress(value, operationID: token) }
                } else if let remote {
                    try await packs.download(manifest: entry.manifest, from: remote, spacing: spacing) { [weak self] value in await self?.updateProgress(value, operationID: token) }
                } else {
                    try await packs.install(from: entry.directory, manifest: entry.manifest, spacing: spacing) { [weak self] value in await self?.updateProgress(value, operationID: token) }
                }
                try Task.checkCancellation()
                await refresh()
                preparationLabel = "Preparing your terrain"
                let terrain = try await packs.load(id: openedID, spacing: spacing)
                try Task.checkCancellation()
                let route = try await routeForPresentation(requestedRoute, terrain: terrain)
                try Task.checkCancellation()
                present(terrain, route: route)
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func updateProgress(_ value: Double, operationID token: UUID) { if token == operationID { progress = value } }

    private func cartographySourceID(for entry: PackEntry) -> String? {
        if let sourceID = entry.manifest.cartographySourceID { return sourceID }
        guard entry.manifest.cartography != nil, let bundledRoot = PackStore.bundledRoot else { return nil }
        let source = entry.directory.standardizedFileURL.path
        let root = bundledRoot.standardizedFileURL.path
        return source == root || source.hasPrefix(root + "/") ? entry.id : nil
    }
    func cancelPreparation() {
        operation?.cancel()
        // Extension owns its cancellation recovery and must finish reopening
        // the previous scene before dismissing the preparation UI.
        if extensionInProgress { return }
        operationID = UUID(); isPreparing = false; preparingFromAtlas = false; pendingRoute = nil
    }

    func open(_ entry: PackEntry, route: RidgeRoute? = nil) {
        guard !extensionInProgress else { return }
        guard entry.installed else { choose(entry, route: route); return }
        pendingRoute = nil
        operation?.cancel()
        let token = UUID(); operationID = token
        operation = Task {
            isPreparing = true; preparationLabel = "Opening \(entry.manifest.name)"; progress = 0
            defer { if operationID == token { isPreparing = false; preparingFromAtlas = false } }
            do {
                activeTerrain = nil
                let terrain = try await packs.load(id: entry.id)
                try Task.checkCancellation()
                present(terrain, route: route)
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func present(_ terrain: LoadedTerrain, route: RidgeRoute? = nil) {
        activeRoute = route; editing = false; selectedPoint = nil; movingWaypoint = nil
        undoStack = []; redoStack = []
        planningMode = terrain.graph?.edges.isEmpty == false ? .paths : .direct
        camera = TerrainCameraCommand()
        pendingExtension = nil; extensionError = nil
        lastCameraPose = nil; lastViewedPoint = nil; viewingSurroundings = false; viewingSceneEdge = false; viewedTerrainSpacing = terrain.level.spacing
        activeTerrain = terrain
    }

    func closeTerrain() {
        guard !isRouting, !extensionInProgress else { return }
        activeTerrain = nil; activeRoute = nil; editing = false; selectedPoint = nil
        undoStack = []; redoStack = []; movingWaypoint = nil
        pendingExtension = nil; extensionError = nil
        lastCameraPose = nil; lastViewedPoint = nil; viewingSurroundings = false; viewingSceneEdge = false
    }

    func startRoute() {
        guard !isRouting, let terrain = activeTerrain else { return }
        activeRoute = RidgeRoute(name: "\(terrain.manifest.name) route", regionID: terrain.manifest.id)
        undoStack = []; redoStack = []; editing = true; movingWaypoint = nil
        toast(viewingSurroundings ? "Tap the terrain to start a route sketch." : (planningMode == .paths ? "Tap a mapped path to place your start." : "Tap the terrain to place your start."))
    }

    func tapTerrain(_ coordinate: GeoPoint, afterExtending: Bool = false) {
        guard let terrain = activeTerrain, !extensionInProgress else { return }
        guard coordinate.isValid, !isRouting else { return }
        if !editing, !terrain.manifest.bounds.contains(coordinate) {
            selectedPoint = coordinate
            toast("This is overview terrain. Tap Expand area to check available detail here.")
            return
        }
        pendingExtension = nil; extensionError = nil
        selectedPoint = coordinate
        guard editing, !isRouting else { return }
        guard activeRoute?.segments.contains(where: { $0.mode == "imported" }) != true else { editing = false; toast("Imported GPX tracks can be viewed and reversed. Start a new route to plan your own line."); return }
        if let index = movingWaypoint { moveWaypoint(index, to: coordinate); return }
        guard let route = activeRoute, route.waypoints.count < 250 else { toast("A route can contain up to 250 control points."); return }
        isRouting = true
        let mode = planningMode
        Task {
            defer { isRouting = false }
            do {
                var updated = route
                let result = try await Task.detached(priority: .userInitiated) { () -> (RoutePoint, RouteSegment?) in
                    if let last = route.waypoints.last {
                        let segment = try RouteEngine.planningSegment(from: last.point.coordinate, to: coordinate, mode: mode, terrain: terrain)
                        guard let point = segment.points.last else { throw RidgeError.message("No route could be created here.") }
                        return (point, segment)
                    }
                    let point: RoutePoint
                    if !terrain.manifest.bounds.contains(coordinate) { point = RoutePoint(coordinate: coordinate, elevation: nil) }
                    else if mode == .paths { point = try RouteEngine.snap(coordinate, terrain: terrain) }
                    else {
                        guard let elevation = terrain.elevation(at: coordinate) else { throw RidgeError.message("Terrain is missing at this location.") }
                        point = RoutePoint(coordinate: coordinate, elevation: elevation)
                    }
                    return (point, nil)
                }.value
                guard activeTerrain?.manifest.id == terrain.manifest.id, activeRoute?.id == route.id else { return }
                if let segment = result.1 { updated.segments.append(segment) }
                updated.waypoints.append(RouteWaypoint(point: result.0))
                selectedPoint = result.0.coordinate
                if await commit(updated, previous: route), result.1?.mode == "overview" || !terrain.manifest.bounds.contains(coordinate) {
                    toast("Overview terrain: sketch saved. Add detail to inspect it closely; this line is not following paths.")
                }
            } catch { toast((afterExtending ? "Area saved. " : "") + error.localizedDescription) }
        }
    }

    private func moveWaypoint(_ index: Int, to coordinate: GeoPoint) {
        guard !isRouting, let terrain = activeTerrain, let route = activeRoute,
              !route.segments.contains(where: { $0.mode == "imported" }), route.waypoints.indices.contains(index) else { return }
        isRouting = true
        Task {
            defer { isRouting = false }
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    var updated = route
                    let adjacentModes = [index - 1, index].filter { route.segments.indices.contains($0) }.map { route.segments[$0].mode }
                    let mode: RoutePlanningMode = adjacentModes.contains("paths") ? .paths : .direct
                    let point: RoutePoint
                    if !terrain.manifest.bounds.contains(coordinate) { point = RoutePoint(coordinate: coordinate, elevation: nil) }
                    else if mode == .paths { point = try RouteEngine.snap(coordinate, terrain: terrain) }
                    else {
                        guard let elevation = terrain.elevation(at: coordinate) else { throw RidgeError.message("Terrain is missing here.") }
                        point = RoutePoint(coordinate: coordinate, elevation: elevation)
                    }
                    updated.waypoints[index].point = point
                    for legIndex in [index - 1, index] where updated.segments.indices.contains(legIndex) && updated.waypoints.indices.contains(legIndex + 1) {
                        let legMode: RoutePlanningMode = updated.segments[legIndex].mode == "paths" ? .paths : .direct
                        updated.segments[legIndex] = try RouteEngine.planningSegment(from: updated.waypoints[legIndex].point.coordinate, to: updated.waypoints[legIndex + 1].point.coordinate, mode: legMode, terrain: terrain)
                    }
                    return updated
                }.value
                if await commit(updated, previous: route) {
                    movingWaypoint = nil
                    toast("Waypoint moved.")
                }
            } catch { toast(error.localizedDescription) }
        }
    }

    func finishRoute() {
        guard !isRouting else { return }
        editing = false; movingWaypoint = nil; selectedPoint = nil
        if activeRoute?.points.isEmpty != false { activeRoute = nil; toast("Empty route discarded.") }
        else { toast("Route saved on this device.") }
    }

    func closeLoop() {
        guard !isRouting, activeRoute?.segments.contains(where: { $0.mode == "imported" }) != true,
              let first = activeRoute?.waypoints.first, (activeRoute?.waypoints.count ?? 0) > 1 else { return }
        tapTerrain(first.point.coordinate)
    }

    func reverseRoute() {
        guard !isRouting, let route = activeRoute, let terrain = activeTerrain, route.points.count > 1 else { return }
        isRouting = true
        Task {
            defer { isRouting = false }
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    var copy = route
                    copy.waypoints.reverse()
                    if route.segments.contains(where: { $0.mode == "imported" }) {
                        copy.segments = route.segments.reversed().map { RouteSegment(points: $0.points.reversed(), mode: $0.mode) }
                    } else {
                        guard copy.waypoints.count > 1, route.segments.count == copy.waypoints.count - 1 else { throw RidgeError.message("This route does not have editable planning points. Export it as GPX or start a new route.") }
                        copy.segments = []
                        for i in 0..<(copy.waypoints.count - 1) {
                            let previous = route.segments[route.segments.count - 1 - i]
                            let mode: RoutePlanningMode = previous.mode == "paths" ? .paths : .direct
                            copy.segments.append(try RouteEngine.planningSegment(from: copy.waypoints[i].point.coordinate, to: copy.waypoints[i + 1].point.coordinate, mode: mode, terrain: terrain))
                        }
                    }
                    return copy
                }.value
                if await commit(updated, previous: route) { toast("Route direction reversed.") }
            } catch { toast(error.localizedDescription) }
        }
    }

    func undo() {
        guard !isRouting, var previous = undoStack.last, let current = activeRoute else { return }
        previous.modifiedAt = Date()
        isRouting = true
        Task {
            defer { isRouting = false }
            guard await persist(previous), activeRoute?.id == current.id else { return }
            undoStack.removeLast(); redoStack.append(current); activeRoute = previous; movingWaypoint = nil
        }
    }
    func redo() {
        guard !isRouting, var next = redoStack.last, let current = activeRoute else { return }
        next.modifiedAt = Date()
        isRouting = true
        Task {
            defer { isRouting = false }
            guard await persist(next), activeRoute?.id == current.id else { return }
            redoStack.removeLast(); undoStack.append(current); activeRoute = next; movingWaypoint = nil
        }
    }
    private func commit(_ updated: RidgeRoute, previous: RidgeRoute) async -> Bool {
        guard activeRoute == previous else { return false }
        var updated = updated; updated.modifiedAt = Date()
        guard await persist(updated), activeRoute == previous else { return false }
        undoStack.append(previous)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack = []; activeRoute = updated
        return true
    }
    private func persist(_ route: RidgeRoute) async -> Bool {
        if route.points.isEmpty {
            // An empty draft still belongs to the editor's undo/redo history,
            // but should not become a saved route or an empty GPX export.
            do { try await routeStore.delete(id: route.id) }
            catch RouteError.missingRoute { }
            catch { errorMessage = "The empty route could not be removed. The previous saved version is unchanged: \(error.localizedDescription)"; return false }
            routes.removeAll { $0.id == route.id }
            return true
        }
        do { try await routeStore.save(route) }
        catch { errorMessage = "Your route could not be saved. The previous saved version is unchanged: \(error.localizedDescription)"; return false }
        // The write succeeded. Refreshing the library must not turn it into a failed edit.
        routes.removeAll { $0.id == route.id }
        routes.append(route)
        routes.sort { $0.modifiedAt > $1.modifiedAt }
        return true
    }

    func renameRoute(_ route: RidgeRoute, to name: String) {
        guard !isRouting else { toast("Wait for the current route change to finish before renaming."); return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var updated = activeRoute?.id == route.id ? activeRoute! : (routes.first { $0.id == route.id } ?? route)
        updated.name = String(value.prefix(120)); updated.modifiedAt = Date()
        isRouting = true
        Task {
            defer { isRouting = false }
            guard await persist(updated) else { return }
            if activeRoute?.id == updated.id { activeRoute = updated }
            // Geometry undo should not undo a separately saved rename.
            for index in undoStack.indices where undoStack[index].id == updated.id { undoStack[index].name = updated.name }
            for index in redoStack.indices where redoStack[index].id == updated.id { redoStack[index].name = updated.name }
        }
    }
    func updateNotes(_ text: String) {
        guard !isRouting else { toast("Wait for the current route change to finish before saving notes."); return }
        guard var route = activeRoute else { return }
        route.notes = String(text.prefix(20_000)); route.modifiedAt = Date()
        isRouting = true
        Task {
            defer { isRouting = false }
            guard await persist(route) else { return }
            if activeRoute?.id == route.id { activeRoute = route }
            for index in undoStack.indices where undoStack[index].id == route.id { undoStack[index].notes = route.notes }
            for index in redoStack.indices where redoStack[index].id == route.id { redoStack[index].notes = route.notes }
        }
    }
    func deleteRoute(_ route: RidgeRoute) {
        guard !isRouting else { return }
        isRouting = true
        Task {
            defer { isRouting = false }
            do {
                try await routeStore.delete(id: route.id)
                routes.removeAll { $0.id == route.id }
                if activeRoute?.id == route.id { activeRoute = nil; editing = false; undoStack = []; redoStack = []; movingWaypoint = nil }
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func duplicateRoute(_ route: RidgeRoute) {
        guard !isRouting else { return }
        isRouting = true
        Task {
            defer { isRouting = false }
            do { let duplicate = try await routeStore.duplicate(id: route.id); routes.insert(duplicate, at: 0); toast("Route duplicated.") }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func openRoute(_ route: RidgeRoute) {
        guard !isRouting else { return }
        let current = routes.first { $0.id == route.id } ?? route
        guard let entry = containingEntry(for: current) else {
            pendingRoute = current
            errorMessage = "Import a terrain area covering this route before opening it. The GPX remains available to export."
            return
        }
        isRouting = true
        Task {
            defer { isRouting = false }
            var associated = current
            if associated.regionID != entry.id {
                associated.regionID = entry.id; associated.modifiedAt = Date()
                guard await persist(associated) else { return }
            }
            guard entry.installed else {
                choose(entry, route: associated)
                toast("Save this area to open your route in 3D.")
                return
            }
            open(entry, route: associated)
        }
    }

    func containingEntry(for route: RidgeRoute) -> PackEntry? {
        if let saved = entries.first(where: { $0.installed && $0.id == route.regionID }),
           let context = saved.manifest.horizon?.layers.last?.bounds,
           (route.points + route.waypoints.map(\.point)).allSatisfy({ context.contains($0.coordinate) }) {
            return saved
        }
        let installedIDs = Set(entries.filter(\.installed).map(\.id))
        guard let manifest = RouteEngine.containingRegion(for: route, in: entries.map(\.manifest), installedIDs: installedIDs) else { return nil }
        return entries.first { $0.id == manifest.id }
    }

    private func routeForPresentation(_ requested: RidgeRoute?, terrain: LoadedTerrain) async throws -> RidgeRoute? {
        guard let requested, var current = routes.first(where: { $0.id == requested.id }) else { return nil }
        let context = terrain.horizon?.layers.last?.metadata.bounds ?? terrain.manifest.bounds
        let inContext = current.regionID == terrain.manifest.id &&
            (current.points + current.waypoints.map(\.point)).allSatisfy { context.contains($0.coordinate) }
        guard inContext || RouteEngine.containingRegion(for: current, in: [terrain.manifest], installedIDs: [terrain.manifest.id]) != nil else { return nil }
        if current.regionID != terrain.manifest.id {
            current.regionID = terrain.manifest.id; current.modifiedAt = Date()
            guard await persist(current) else { throw RidgeError.message(errorMessage ?? "The route's terrain association could not be saved.") }
        }
        if pendingRoute?.id == requested.id { pendingRoute = nil }
        return current
    }

    func importGPX(_ url: URL) {
        guard !isRouting, !extensionInProgress else { toast("Finish extending this area before importing a route."); return }
        isRouting = true
        Task {
            defer { isRouting = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                var route = try await Task.detached { try GPXCodec.read(from: url) }.value
                let candidate = containingEntry(for: route)
                route.regionID = candidate?.id ?? ""
                guard await persist(route) else { return }
                showGPXImporter = false
                if let candidate, candidate.installed {
                    if activeTerrain?.manifest.id == candidate.id { activeRoute = route; editing = false; undoStack = []; redoStack = [] }
                    else { open(candidate, route: route) }
                    toast("GPX imported and saved.")
                } else {
                    tab = .routes
                    pendingRoute = route
                    toast(candidate == nil ? "GPX saved. Import a terrain area covering the whole route to view it in 3D." : "GPX saved. Save its terrain area to view it in 3D.")
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func importPack(_ url: URL) {
        guard !extensionInProgress else { toast("Finish extending this area before importing another pack."); return }
        let requestedRoute = pendingRoute
        scopedPackURL?.stopAccessingSecurityScopedResource(); scopedPackURL = nil
        operation?.cancel()
        let token = UUID(); operationID = token
        operation = Task {
            let scoped = url.startAccessingSecurityScopedResource()
            var scopeTransferred = false
            defer {
                if scoped && !scopeTransferred { url.stopAccessingSecurityScopedResource() }
                if operationID == token { isPreparing = false; preparingFromAtlas = false }
            }
            isPreparing = true; preparationLabel = "Checking offline area"; progress = 0
            do {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let directory = isDirectory ? url : url.deletingLastPathComponent()
                let manifest = try await packs.inspect(directory: directory)
                try Task.checkCancellation()
                if scoped { scopedPackURL = url; scopeTransferred = true }
                pendingRemoteURL = nil; pendingSelection = nil
                pendingPack = PackEntry(manifest: manifest, directory: directory, installed: entries.contains { $0.id == manifest.id && $0.installed })
                if let requestedRoute, RouteEngine.containingRegion(for: requestedRoute, in: [manifest], installedIDs: []) != nil {
                    pendingRoute = requestedRoute
                } else { pendingRoute = nil }
                showPackImporter = false
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func previewDownload(_ string: String) async throws {
        guard !extensionInProgress else { throw RidgeError.message("Finish extending this area before opening another pack.") }
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RidgeError.message("Enter a valid area manifest link.") }
        let manifest = try await packs.fetchManifest(url)
        showDownloadSheet = false
        pendingRoute = nil; pendingSelection = nil
        pendingRemoteURL = url
        pendingPack = PackEntry(manifest: manifest, directory: url.deletingLastPathComponent(), installed: false)
    }

    func removeArea(_ entry: PackEntry) {
        Task {
            do {
                try await packs.remove(id: entry.id)
                if activeTerrain?.manifest.id == entry.id { closeTerrain() }
                await refresh(); toast("Area removed. Your saved routes are kept.")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func toast(_ message: String) {
        noticeTask?.cancel(); notice = message
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { notice = nil }
        }
    }
}
