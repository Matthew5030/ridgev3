import SwiftUI
import MetalKit

/// One fixed, fully local relief model. Camera gestures never request more data.
@MainActor
struct TerrainView: UIViewRepresentable {
    @AppStorage(TerrainGestureStyle.defaultsKey) private var gestureStyle: TerrainGestureStyle = .moveWithOneFinger
    var terrain: LoadedTerrain
    var route: [RoutePoint]
    var waypoints: [RouteWaypoint]
    var editing: Bool
    var command: TerrainCameraCommand
    var selectedPoint: GeoPoint? = nil
    var routeSegments: [[RoutePoint]] = []
    var labelsVisible: Bool = true
    var extensionBounds: GeoBounds? = nil
    var extensionGrid: TerrainGrid? = nil
    var onNavigationChange: ((TerrainNavigationState) -> Void)? = nil
    var onRelease: (() -> Void)? = nil
    var onTap: (GeoPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TerrainHostView {
        let host = TerrainHostView()
        context.coordinator.host = host
        context.coordinator.onTap = onTap
        context.coordinator.editing = editing
        context.coordinator.installGestures(on: host, style: gestureStyle)
        host.accessibilityHint = gestureHint
        host.onNavigationChange = onNavigationChange
        host.onRelease = onRelease
        host.load(terrain)
        context.coordinator.identity = identity
        context.coordinator.lastCommand = command
        host.setRoute(route, waypoints: waypoints, selectedPoint: selectedPoint, segments: routeSegments)
        host.setLabelsVisible(labelsVisible)
        host.setCoverageEditing(editing)
        host.setExtension(bounds: extensionBounds, grid: extensionGrid)
        if command.action != .home { host.perform(command.action) }
        return host
    }

    func updateUIView(_ uiView: TerrainHostView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.editing = editing
        context.coordinator.setGestureStyle(gestureStyle)
        uiView.onNavigationChange = onNavigationChange
        uiView.onRelease = onRelease
        if context.coordinator.identity != identity {
            context.coordinator.identity = identity
            uiView.load(terrain)
        }
        uiView.setRoute(route, waypoints: waypoints, selectedPoint: selectedPoint, segments: routeSegments)
        uiView.setLabelsVisible(labelsVisible)
        uiView.setCoverageEditing(editing)
        uiView.setExtension(bounds: extensionBounds, grid: extensionGrid)
        if context.coordinator.lastCommand != command {
            context.coordinator.lastCommand = command
            uiView.perform(command.action)
        }
        uiView.accessibilityHint = gestureHint
    }

    private var gestureHint: String {
        gestureStyle.guide + (editing ? " Tap the terrain to place a route point." : " Explore freely. Use Expand area to choose more terrain around this view.")
    }

    static func dismantleUIView(_ uiView: TerrainHostView, coordinator: Coordinator) {
        uiView.releaseTerrain()
        coordinator.host = nil
        uiView.onRelease?()
    }

    private var identity: String {
        func mapIdentity(_ textures: [MapTexture]) -> String {
            textures.map { $0.file + ":" + $0.sha256 }.joined(separator: ":")
        }
        let horizon = (terrain.horizon?.layers ?? []).map {
            $0.level.file + ":" + $0.level.sha256 + ":" + mapIdentity($0.metadata.textures)
        }.joined(separator: ":")
        var atlas = ""
        if let source = terrain.cartography {
            let directory = source.imageURLs.first?.deletingLastPathComponent().path ?? ""
            let previewDirectory = source.previewURLs.first?.deletingLastPathComponent().path ?? ""
            let files = source.metadata.tiles.map { tile in
                [tile.image.file, tile.image.sha256, tile.preview.file, tile.preview.sha256].joined(separator: ":")
            }.joined(separator: ":")
            atlas = [directory, previewDirectory, files].joined(separator: ":")
        }
        return terrain.directory.path + ":" + terrain.manifest.version + ":" + terrain.level.file + ":" + terrain.level.sha256 + ":" + mapIdentity(terrain.manifest.textures) + ":" + horizon + ":" + atlas
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var host: TerrainHostView?
        var identity = ""
        var lastCommand: TerrainCameraCommand?
        var editing = false
        var onTap: ((GeoPoint) -> Void)?

        private var gestureStyle: TerrainGestureStyle?
        private var orbitGesture: UIPanGestureRecognizer?
        private var moveGesture: UIPanGestureRecognizer?

        func installGestures(on host: UIView, style: TerrainGestureStyle) {
            let orbit = UIPanGestureRecognizer(target: self, action: #selector(orbit(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            orbitGesture = orbit; moveGesture = pan
            setGestureStyle(style)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            let tap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            let reset = UITapGestureRecognizer(target: self, action: #selector(reset(_:)))
            reset.numberOfTapsRequired = 2
            tap.require(toFail: reset)
            for gesture in [orbit, pan, pinch, tap, reset] {
                gesture.delegate = self
                host.addGestureRecognizer(gesture)
            }
        }

        func setGestureStyle(_ style: TerrainGestureStyle) {
            guard gestureStyle != style else { return }
            // Cancel an in-flight drag before changing touch counts, without
            // replacing the terrain view or disturbing its camera.
            orbitGesture?.isEnabled = false; moveGesture?.isEnabled = false
            gestureStyle = style
            orbitGesture?.minimumNumberOfTouches = style.rotateTouches
            orbitGesture?.maximumNumberOfTouches = style.rotateTouches
            moveGesture?.minimumNumberOfTouches = style.moveTouches
            moveGesture?.maximumNumberOfTouches = style.moveTouches
            orbitGesture?.isEnabled = true; moveGesture?.isEnabled = true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer) ||
            (otherGestureRecognizer is UIPinchGestureRecognizer && gestureRecognizer is UIPanGestureRecognizer)
        }

        @objc private func orbit(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed,
                  gesture.numberOfTouches == gestureStyle?.rotateTouches else {
                gesture.setTranslation(.zero, in: host); return
            }
            let delta = gesture.translation(in: host)
            host?.renderer?.orbit(dx: Float(delta.x), dy: Float(delta.y))
            gesture.setTranslation(.zero, in: host)
        }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .began || gesture.state == .changed,
                  gesture.numberOfTouches == gestureStyle?.moveTouches else {
                gesture.setTranslation(.zero, in: host); return
            }
            let delta = gesture.translation(in: host)
            host?.renderer?.pan(dx: Float(delta.x), dy: Float(delta.y))
            gesture.setTranslation(.zero, in: host)
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            host?.renderer?.zoom(by: Float(gesture.scale))
            gesture.scale = 1
        }

        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            guard let host, let point = host.renderer?.pick(at: gesture.location(in: host)) else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            onTap?(point)
        }

        @objc private func reset(_ gesture: UITapGestureRecognizer) { host?.renderer?.perform(.home) }
    }
}

@MainActor
final class TerrainHostView: UIView {
    private(set) var renderer: TerrainRenderer?
    private var metalView: MTKView?
    private var errorLabel: UILabel?
    private var cartographyWarning: UILabel?
    private var warningTask: Task<Void, Never>?
    private var progress: UIActivityIndicatorView?
    private var loadTask: Task<Void, Never>?
    private var preparation: Task<TerrainRenderer, Error>?
    private var pendingRoute: [RoutePoint] = []
    private var pendingSegments: [[RoutePoint]] = []
    private var pendingWaypoints: [RouteWaypoint] = []
    private var pendingSelection: GeoPoint?
    private var pendingCoverageEditing = false
    private var pendingAction: TerrainCameraCommand.Action?
    private var pendingExtensionBounds: GeoBounds?
    private var pendingExtensionGrid: TerrainGrid?
    var onNavigationChange: ((TerrainNavigationState) -> Void)?
    var onRelease: (() -> Void)?
    private var placeLabels: [(place: MapPlace, view: TerrainPlaceLabel)] = []
    private var labelsVisible = true

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.954, green: 0.944, blue: 0.916, alpha: 1)
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Interactive 3D terrain"
        accessibilityTraits = [.allowsDirectInteraction]
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // SwiftUI can resize the host after Metal's drawable-size callback. Send
        // the final unobscured viewport in points, after applying the child frame.
        metalView?.frame = bounds
        renderer?.viewportDidChange(to: bounds.size)
    }

    func load(_ terrain: LoadedTerrain) {
        let previousPose = renderer?.navigationState.pose
        releaseTerrain()
        if let previousPose { pendingAction = .restore(previousPose) }
        accessibilityLabel = "Interactive 3D terrain"
        errorLabel?.removeFromSuperview(); errorLabel = nil
        guard let device = MTLCreateSystemDefaultDevice() else {
            showError("3D terrain needs a Metal-compatible device. Your downloaded area and routes are safely stored.")
            return
        }
        let view = MTKView(frame: bounds, device: device)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        view.clearColor = MTLClearColor(red: 0.80, green: 0.90, blue: 0.96, alpha: 1)
        view.clearDepth = 1
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 60
        addSubview(view)
        metalView = view
        prepareLabels(terrain.manifest.places)
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = UIColor(red: 0.24, green: 0.34, blue: 0.28, alpha: 1)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.accessibilityLabel = "Preparing your terrain"
        addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor)])
        spinner.startAnimating()
        progress = spinner
        let colorFormat = view.colorPixelFormat, depthFormat = view.depthStencilPixelFormat, samples = view.sampleCount
        let worker = Task.detached(priority: .userInitiated) {
            try TerrainRenderer(device: device, colorPixelFormat: colorFormat, depthPixelFormat: depthFormat, sampleCount: samples, terrain: terrain)
        }
        preparation = worker
        loadTask = Task { [weak self, weak view] in
            do {
                let renderer = try await worker.value
                try Task.checkCancellation()
                guard let self, let view, self.metalView === view else { return }
                renderer.attach(to: view)
                renderer.onCameraChange = { [weak self] in
                    guard let self else { return }
                    self.updateLabels()
                    if let state = self.renderer?.navigationState { self.onNavigationChange?(state) }
                }
                renderer.onCartographyWarning = { [weak self] message in self?.showCartographyWarning(message) }
                self.renderer = renderer
                view.delegate = renderer
                renderer.coverageEditing = self.pendingCoverageEditing
                renderer.setRoute(self.pendingRoute, waypoints: self.pendingWaypoints, selectedPoint: self.pendingSelection, segments: self.pendingSegments)
                renderer.setExtension(bounds: self.pendingExtensionBounds, grid: self.pendingExtensionGrid)
                if let action = self.pendingAction { renderer.perform(action) }
                self.progress?.removeFromSuperview(); self.progress = nil
                self.preparation = nil
                self.loadTask = nil
                view.setNeedsDisplay()
            } catch is CancellationError {
                // Closing or replacing an area cancels its preparation.
            } catch {
                guard !Task.isCancelled, let self, let view, self.metalView === view else { return }
                self.progress?.removeFromSuperview(); self.progress = nil
                view.removeFromSuperview(); self.metalView = nil
                self.preparation = nil
                self.loadTask = nil
                self.showError("This terrain couldn’t be opened. " + error.localizedDescription)
            }
        }
    }

    func setCoverageEditing(_ editing: Bool) {
        pendingCoverageEditing = editing
        renderer?.coverageEditing = editing
    }

    func setRoute(_ route: [RoutePoint], waypoints: [RouteWaypoint], selectedPoint: GeoPoint?, segments: [[RoutePoint]]) {
        pendingRoute = route; pendingWaypoints = waypoints; pendingSelection = selectedPoint; pendingSegments = segments
        renderer?.setRoute(route, waypoints: waypoints, selectedPoint: selectedPoint, segments: segments)
    }

    func perform(_ action: TerrainCameraCommand.Action) {
        pendingAction = action
        renderer?.perform(action)
    }

    func setExtension(bounds: GeoBounds?, grid: TerrainGrid?) {
        pendingExtensionBounds = bounds
        pendingExtensionGrid = grid
        renderer?.setExtension(bounds: bounds, grid: grid)
    }

    func setLabelsVisible(_ visible: Bool) {
        guard visible != labelsVisible else { return }
        labelsVisible = visible
        updateLabels()
    }

    private func prepareLabels(_ places: [MapPlace]) {
        let favourites = ["yr wyddfa", "snowdon", "crib goch", "tryfan", "garnedd ugain", "glyder fawr", "glyder fach", "y garn"]
        let ordered = places.filter { $0.kind == "peak" && $0.coordinate.isValid }.sorted { a, b in
            let ai = favourites.firstIndex(of: a.name.lowercased()) ?? 99
            let bi = favourites.firstIndex(of: b.name.lowercased()) ?? 99
            if ai != bi { return ai < bi }
            return (a.elevation ?? 0) > (b.elevation ?? 0)
        }
        for place in ordered.prefix(24) {
            let label = TerrainPlaceLabel(place: place)
            label.isHidden = true
            addSubview(label)
            placeLabels.append((place, label))
        }
    }

    private func updateLabels() {
        var occupied: [CGRect] = []
        let safe = bounds.insetBy(dx: 12, dy: 24)
        for item in placeLabels {
            guard labelsVisible, occupied.count < 8,
                  let point = renderer?.projectedPoint(item.place.coordinate) else { item.view.isHidden = true; continue }
            let size = item.view.labelSize
            var frame = CGRect(x: point.x - 3, y: point.y - size.height + 3, width: size.width, height: size.height)
            // Labels may switch sides near the right edge without moving their anchor.
            let left = frame.maxX > safe.maxX
            if left { frame.origin.x = point.x - size.width + 3 }
            guard safe.contains(frame), !occupied.contains(where: { $0.intersects(frame.insetBy(dx: -8, dy: -6)) }) else { item.view.isHidden = true; continue }
            item.view.setLeadingAnchor(!left)
            item.view.frame = frame.integral
            item.view.isHidden = false
            occupied.append(frame)
        }
    }

    func releaseTerrain() {
        preparation?.cancel(); preparation = nil
        loadTask?.cancel(); loadTask = nil
        progress?.removeFromSuperview(); progress = nil
        pendingAction = nil
        warningTask?.cancel(); warningTask = nil
        cartographyWarning?.removeFromSuperview(); cartographyWarning = nil
        for label in placeLabels { label.view.removeFromSuperview() }
        placeLabels.removeAll()
        renderer?.stop()
        metalView?.delegate = nil
        metalView?.releaseDrawables()
        renderer = nil
        metalView?.removeFromSuperview()
        metalView = nil
    }

    private func showCartographyWarning(_ message: String) {
        guard cartographyWarning == nil else { return }
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = UIColor(red: 0.24, green: 0.29, blue: 0.24, alpha: 1)
        label.backgroundColor = UIColor(red: 0.98, green: 0.965, blue: 0.92, alpha: 0.96)
        label.layer.cornerRadius = 10; label.clipsToBounds = true
        label.text = message
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 16)
        ])
        cartographyWarning = label
        UIAccessibility.post(notification: .announcement, argument: message)
        warningTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            self.cartographyWarning?.removeFromSuperview(); self.cartographyWarning = nil
            self.warningTask = nil
        }
    }

    private func showError(_ message: String) {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = UIColor(red: 0.20, green: 0.27, blue: 0.24, alpha: 1)
        label.text = message
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        errorLabel = label
        accessibilityLabel = message
    }
}

/// UIKit text stays at native display resolution instead of being baked into a
/// terrain image. A fine cream halo makes names readable over contour lines.
@MainActor
private final class TerrainPlaceLabel: UIView {
    private let nameLabel = UILabel()
    private let elevationLabel = UILabel()
    private let dot = UIView()
    private(set) var labelSize = CGSize.zero
    private var leftAnchored = true

    init(place: MapPlace) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        let ink = UIColor(red: 0.15, green: 0.24, blue: 0.20, alpha: 1)
        let paper = UIColor(red: 0.995, green: 0.985, blue: 0.945, alpha: 1)
        let nameFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
        nameLabel.attributedText = NSAttributedString(string: place.name, attributes: [.font: nameFont, .foregroundColor: ink, .strokeColor: paper, .strokeWidth: -3.5])
        nameLabel.lineBreakMode = .byTruncatingTail
        if let elevation = place.elevation, elevation.isFinite {
            elevationLabel.attributedText = NSAttributedString(string: "\(Int(elevation.rounded())) m", attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: ink.withAlphaComponent(0.85), .strokeColor: paper, .strokeWidth: -3])
        }
        addSubview(nameLabel); addSubview(elevationLabel); addSubview(dot)
        dot.backgroundColor = ink
        dot.layer.cornerRadius = 2.5
        dot.layer.borderWidth = 1
        dot.layer.borderColor = paper.cgColor
        let textWidth = min(153, max(45, nameLabel.sizeThatFits(CGSize(width: 1_000, height: 20)).width))
        labelSize = CGSize(width: textWidth + 12, height: elevationLabel.attributedText == nil ? 19 : 32)
    }
    required init?(coder: NSCoder) { nil }

    func setLeadingAnchor(_ leading: Bool) {
        guard leftAnchored != leading else { return }
        leftAnchored = leading
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x: CGFloat = leftAnchored ? 11 : 0
        nameLabel.frame = CGRect(x: x, y: 0, width: bounds.width - 12, height: 17)
        elevationLabel.frame = CGRect(x: x, y: 17, width: bounds.width - 12, height: 12)
        nameLabel.textAlignment = leftAnchored ? .left : .right
        elevationLabel.textAlignment = leftAnchored ? .left : .right
        dot.frame = CGRect(x: leftAnchored ? 0 : bounds.width - 5, y: bounds.height - 6, width: 5, height: 5)
    }
}
