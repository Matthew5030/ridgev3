import SwiftUI
import MetalKit
import CryptoKit
import os

struct AdaptiveParkManifest: Decodable, Sendable {
    struct Chunk: Decodable, Sendable {
        let id: String, path: String, sha256: String
        let bounds: GeoBounds
        let byteOffset: Int64?
        let vertices: Int, triangles: Int, indexWidth: Int, compactBytes: Int64
    }
    let schemaVersion: Int
    let name: String, meshFormat: String
    let surfaceToleranceMetres: Double, parkAreaKm2: Double, uncoveredParkAreaKm2: Double
    let vertices: Int64, triangles: Int64, compactBytes: Int64, metalGeometryBytes: Int64
    let bounds: GeoBounds
    let chunks: [Chunk]
    var residentBytes: Int64 {
        // Two page-aligned buffers per chunk, including allocation padding.
        chunks.reduce(0) { $0 + Int64((($1.vertices * 6 + 16383) / 16384 + ($1.triangles * 3 * $1.indexWidth + 16383) / 16384) * 16384) }
    }

    func selection(containing requested: GeoBounds) -> AdaptiveParkManifest? {
        let chosen = chunks.filter { chunk in
            chunk.bounds.minLatitude < requested.maxLatitude && chunk.bounds.maxLatitude > requested.minLatitude &&
            chunk.bounds.minLongitude < requested.maxLongitude && chunk.bounds.maxLongitude > requested.minLongitude
        }
        guard !chosen.isEmpty else { return nil }
        let selectedBounds = GeoBounds(
            minLatitude: chosen.map(\.bounds.minLatitude).min()!,
            minLongitude: chosen.map(\.bounds.minLongitude).min()!,
            maxLatitude: chosen.map(\.bounds.maxLatitude).max()!,
            maxLongitude: chosen.map(\.bounds.maxLongitude).max()!)
        return AdaptiveParkManifest(
            schemaVersion: schemaVersion, name: "Eryri adaptive area", meshFormat: meshFormat,
            surfaceToleranceMetres: surfaceToleranceMetres, parkAreaKm2: parkAreaKm2,
            uncoveredParkAreaKm2: uncoveredParkAreaKm2,
            vertices: chosen.reduce(0) { $0 + Int64($1.vertices) },
            triangles: chosen.reduce(0) { $0 + Int64($1.triangles) },
            compactBytes: chosen.reduce(0) { $0 + $1.compactBytes },
            metalGeometryBytes: chosen.reduce(0) { $0 + Int64($1.vertices * 48 + $1.triangles * 12) },
            bounds: selectedBounds, chunks: chosen)
    }
}

private struct ParkDraw {
    let vertices: MTLBuffer, indices: MTLBuffer
    let count: Int, indexType: MTLIndexType
    let rect: SIMD4<Float>
}
private final class ParkScene: @unchecked Sendable {
    let device: MTLDevice
    let manifest: AdaptiveParkManifest
    let draws: [ParkDraw]
    init(device: MTLDevice, manifest: AdaptiveParkManifest, draws: [ParkDraw]) { self.device = device; self.manifest = manifest; self.draws = draws }
}
private struct ParkFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor @Observable
private final class ParkTestModel {
    static var directory: URL { URL.documentsDirectory.appendingPathComponent("EryriAdaptiveTest", isDirectory: true) }
    var manifest: AdaptiveParkManifest?
    var scene: ParkScene?
    var message = "Reading experiment…"
    var progress: Double = 0
    var loading = false
    var available: Int64 = 0
    var task: Task<Void, Never>?
    private var worker: Task<ParkScene, Error>?
    var result: [String: String] = [:]

    private func memoryAllowance() -> Int64 {
        #if targetEnvironment(simulator)
        // iOS process allowance is unavailable in Simulator. This is only a
        // small renderer-verification budget, never an iPad capacity result.
        return 1024 * 1024 * 1024
        #else
        return Int64(clamping: os_proc_available_memory())
        #endif
    }
    func inspect() {
        do {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent("manifest.json"))
            guard data.count < 30_000_000 else { throw ParkFailure(message: "Experiment manifest is too large.") }
            let m = try JSONDecoder().decode(AdaptiveParkManifest.self, from: data)
            guard m.schemaVersion == 1, m.meshFormat == "RME1", m.bounds.isValid,
                  !m.chunks.isEmpty, m.chunks.count <= 20_000,
                  m.chunks.allSatisfy({ $0.bounds.isValid && $0.vertices >= 3 && $0.vertices <= 263169 && $0.triangles > 0 && $0.triangles <= 524288 && [2,4].contains($0.indexWidth) && (($0.byteOffset == nil && $0.path.hasPrefix("meshes/")) || ($0.byteOffset != nil && $0.byteOffset! >= 0 && $0.path == "terrain.rmeshpack")) && !$0.path.contains("..") }),
                  m.vertices == m.chunks.reduce(0, { $0 + Int64($1.vertices) }),
                  m.triangles == m.chunks.reduce(0, { $0 + Int64($1.triangles) }) else { throw ParkFailure(message: "Invalid experiment manifest.") }
            manifest = m
            available = memoryAllowance()
            message = "Drag the rectangle to choose a planning area. Terrain is loaded once when you open it."
            result = ["status": "ready", "physicalMemoryBytes": "\(ProcessInfo.processInfo.physicalMemory)", "availableMemoryBytes": "\(available)", "compactResidentBytes": "\(m.residentBytes)", "currentRendererBytes": "\(m.metalGeometryBytes)", "triangles": "\(m.triangles)"]
            #if targetEnvironment(simulator)
            result["environment"] = "Simulator: fixed 1 GiB verification budget, not a device reading"
            #else
            result["environment"] = "physical device"
            #endif
            saveResult()
        } catch { message = "The experiment pack could not be opened. \(error.localizedDescription)" }
    }
    func load(_ requested: GeoBounds) {
        guard !loading, scene == nil, let source = manifest,
              let m = source.selection(containing: requested), let device = MTLCreateSystemDefaultDevice() else { return }
        available = memoryAllowance()
        // Test actual compact geometry, without the production grid sample cap.
        // Leave space for the OS-facing view, framebuffers and in-flight file read.
        let reserve: Int64 = 512 * 1024 * 1024
        let recommended = Int64(clamping: device.recommendedMaxWorkingSetSize)
        let gpuRemaining = recommended > 0 ? max(0, recommended - Int64(clamping: device.currentAllocatedSize)) : available
        result["gpuWorkingSetSource"] = recommended > 0 ? "Metal recommendation" : "Metal recommendation unavailable; using process allowance"
        result["availableMemoryBytes"] = "\(available)"; result["gpuRemainingBytes"] = "\(gpuRemaining)"
        guard available > 0 else { message = "iOS did not provide a memory allowance. This area has not been opened."; result["status"] = "memory-reading-unavailable"; saveResult(); return }
        guard m.residentBytes + reserve <= available, m.residentBytes <= gpuRemaining else {
            message = "This area is too large at adaptive 0.5 m. It needs \(RidgeTheme.bytes(m.residentBytes)) for terrain plus 512 MB headroom; iOS currently reports \(RidgeTheme.bytes(available)) available. Make the rectangle smaller."
            result["status"] = "refused-before-allocation"; result["reason"] = message; saveResult(); return
        }
        result["status"] = "loading"; saveResult()
        result["selectionBounds"] = "\(m.bounds.minLatitude),\(m.bounds.minLongitude),\(m.bounds.maxLatitude),\(m.bounds.maxLongitude)"
        result["compactResidentBytes"] = "\(m.residentBytes)"; result["triangles"] = "\(m.triangles)"
        loading = true; message = "Preparing \(m.chunks.count.formatted()) terrain chunks…"
        let start = Date(), directory = Self.directory
        worker = Task.detached(priority: .userInitiated) {
            let packedFile = m.chunks.contains(where: { $0.byteOffset != nil }) ? try FileHandle(forReadingFrom: directory.appendingPathComponent("terrain.rmeshpack")) : nil
            defer { try? packedFile?.close() }
            var draws: [ParkDraw] = []; draws.reserveCapacity(m.chunks.count)
            let center = m.bounds.center
            let sx = cos(center.latitude * .pi / 180) * 111.195, sy = 111.195
            for (i, c) in m.chunks.enumerated() {
                try Task.checkCancellation()
                let draw: ParkDraw = try autoreleasepool {
                    let url = directory.appendingPathComponent(c.path)
                    let d: Data
                    if let offset = c.byteOffset, let packedFile {
                        try packedFile.seek(toOffset: UInt64(offset))
                        d = try packedFile.read(upToCount: 28 + c.vertices * 6 + c.triangles * 3 * c.indexWidth) ?? Data()
                    } else { d = try Data(contentsOf: url) }
                    guard d.count == 28 + c.vertices * 6 + c.triangles * 3 * c.indexWidth,
                          SHA256.hash(data: d).map({ String(format: "%02x", $0) }).joined() == c.sha256 else { throw ParkFailure(message: "Mesh checksum failed: \(c.id)") }
                    return try d.withUnsafeBytes { raw in
                        func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
                        guard Array(d.prefix(4)) == Array("RME1".utf8), u32(4) == c.vertices, u32(8) == c.triangles, u32(12) == c.indexWidth, u32(16) == 513,
                              Float(bitPattern: u32(20)) == Float(0.1), Float(bitPattern: u32(24)) == 0 else { throw ParkFailure(message: "Unsupported mesh header: \(c.id)") }
                        guard let base = raw.baseAddress,
                              let vb = device.makeBuffer(bytes: base.advanced(by: 28), length: c.vertices * 6, options: .storageModeShared),
                              let ib = device.makeBuffer(bytes: base.advanced(by: 28 + c.vertices * 6), length: c.triangles * 3 * c.indexWidth, options: .storageModeShared) else { throw ParkFailure(message: "Metal could not allocate chunk \(i + 1).") }
                        return ParkDraw(vertices: vb, indices: ib, count: c.triangles * 3, indexType: c.indexWidth == 2 ? .uint16 : .uint32,
                                        rect: SIMD4(Float((c.bounds.minLongitude - center.longitude) * sx), Float((center.latitude - c.bounds.maxLatitude) * sy), Float((c.bounds.maxLongitude - c.bounds.minLongitude) * sx), Float((c.bounds.maxLatitude - c.bounds.minLatitude) * sy)))
                    }
                }
                draws.append(draw)
                if i % 100 == 0 { await self.updateProgress(Double(i + 1) / Double(m.chunks.count)) }
            }
            try Task.checkCancellation()
            return ParkScene(device: device, manifest: m, draws: draws)
        }
        task = Task {
            do {
                let loaded = try await worker!.value
                try Task.checkCancellation()
                scene = loaded; progress = 1; result["loadedFraction"] = "1.0"; message = "\(m.chunks.count.formatted()) chunks ready · \(Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)))) s to load."
                result["status"] = "fully-loaded"; result["loadSeconds"] = "\(Date().timeIntervalSince(start))"; result["gpuAllocatedBytes"] = "\(device.currentAllocatedSize)"; saveResult()
            } catch is CancellationError { message = "Load cancelled. Terrain memory released." }
              catch { message = error.localizedDescription; result["status"] = "load-failed"; result["reason"] = message; saveResult() }
            loading = false; worker = nil; task = nil
        }
    }
    private func updateProgress(_ value: Double) { progress = value; result["loadedFraction"] = "\(value)"; saveResult() }
    func frameCompleted(seconds: Double, error: String?) {
        result["firstFrameGPUSeconds"] = "\(seconds)"
        result["status"] = error == nil ? "fully-loaded-and-rendered" : "render-failed"
        if let error { message = error; result["reason"] = error }
        saveResult()
    }
    func releaseScene(showSelectionMessage: Bool = false) {
        task?.cancel(); worker?.cancel(); task = nil; worker = nil
        scene = nil; loading = false; progress = 0
        if showSelectionMessage {
            message = "Drag the rectangle to choose a planning area. Terrain is loaded once when you open it."
        }
    }
    func cancel() { releaseScene() }
    private func saveResult() {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("EryriStressResult.json"), options: .atomic)
        }
    }
}

struct AdaptiveParkTestView: View {
    var onClose: (() -> Void)? = nil
    @State private var model = ParkTestModel()
    @State private var requested: GeoBounds?
    @Environment(\.dismiss) private var dismiss

    private var selected: AdaptiveParkManifest? {
        guard let requested else { return nil }
        return model.manifest?.selection(containing: requested)
    }

    private var selectedFits: Bool {
        guard let selected, model.available > 0 else { return false }
        return selected.residentBytes + 512 * 1024 * 1024 <= model.available
    }

    var body: some View {
        Group {
            if let scene = model.scene { terrain(scene) }
            else { selectionPage }
        }
        .task {
            model.inspect()
            if requested == nil, let source = model.manifest {
                requested = Self.area(center: GeoPoint(latitude: 53.075, longitude: -4.054), kilometres: 8, inside: source.bounds)
            }
            if ProcessInfo.processInfo.arguments.contains("--eryri-auto-test"), let requested { model.load(requested) }
        }
            .onDisappear { model.cancel() }
    }

    private var selectionPage: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > 760
            Group {
                if wide {
                    HStack(spacing: 0) { selectionMap; selectionPanel.frame(width: 360) }
                } else {
                    VStack(spacing: 0) { selectionMap; selectionPanel }
                }
            }
        }
        .background(RidgeTheme.paper).foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
    }

    @ViewBuilder private var selectionMap: some View {
        if let source = model.manifest, let binding = Binding($requested) {
            ParkSelectionMap(manifest: source, selection: binding)
                .overlay(alignment: .topLeading) {
                    Label("Drag to move your area", systemImage: "hand.draw")
                        .font(.system(size: 11, weight: .semibold)).padding(11)
                        .background(RidgeTheme.panel.opacity(0.94), in: Capsule()).padding(16)
                }
        } else {
            ProgressView("Reading Eryri terrain…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectionPanel: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow(text: "Eryri · adaptive terrain")
                    Text("Choose your landscape").font(.system(size: 28, weight: .regular, design: .serif))
                }
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").frame(width: 38, height: 38) }
                    .accessibilityLabel("Close adaptive terrain")
            }
            Text("The complete park source stays offline on this iPad. Ridge opens only the fixed rectangle you choose.")
                .font(.system(size: 13)).foregroundStyle(RidgeTheme.muted).lineSpacing(4)
            if let selection = selected {
                HStack {
                    metric("AREA", String(format: "%.1f × %.1f km", selection.bounds.widthMeters / 1000, selection.bounds.depthMeters / 1000))
                    Spacer(); metric("TERRAIN", RidgeTheme.bytes(selection.residentBytes))
                    Spacer(); metric("CHUNKS", selection.chunks.count.formatted())
                }.padding(16).background(RidgeTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 17))
                HStack(spacing: 16) {
                    Button("Smaller", systemImage: "minus.magnifyingglass") { resize(0.78) }
                    Button("Larger", systemImage: "plus.magnifyingglass") { resize(1.28) }
                }.font(.system(size: 13, weight: .semibold))
                Label(selectedFits ? "Fits this iPad’s current memory allowance" : "Too large for the current memory allowance", systemImage: selectedFits ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selectedFits ? RidgeTheme.forest : RidgeTheme.orange)
            }
            Text(model.message).font(.system(size: 12)).foregroundStyle(model.message.contains("too large") ? RidgeTheme.orange : RidgeTheme.muted)
            if model.loading {
                ProgressView(value: model.progress).tint(RidgeTheme.forest)
                Button("Cancel") { model.releaseScene(showSelectionMessage: true) }.font(.subheadline.weight(.semibold))
            } else {
                Button {
                    if let requested { model.load(requested) }
                } label: {
                    HStack { Image(systemName: "mountain.2"); Text("Open this area in 3D"); Spacer(); Image(systemName: "arrow.up.right") }
                        .padding(.horizontal, 15)
                }.buttonStyle(RidgeButtonStyle()).disabled(selected == nil || !selectedFits)
            }
            Text("Adaptive 0.5 m is measured surface error against the prepared 1 m LiDAR. Empty cells show places where the prepared source has no complete coverage.")
                .font(.system(size: 11)).foregroundStyle(RidgeTheme.muted).lineSpacing(3)
        }.padding(22).background(RidgeTheme.panel)
    }

    private func terrain(_ scene: ParkScene) -> some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.72, green: 0.86, blue: 0.96).ignoresSafeArea()
            ParkMetalView(scene: scene, onFrame: model.frameCompleted).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Eryri adaptive area").font(.headline)
                        Text("\(scene.manifest.chunks.count.formatted()) chunks · \(RidgeTheme.bytes(scene.manifest.residentBytes)) · fixed scene")
                            .font(.caption).foregroundStyle(RidgeTheme.muted)
                    }
                    Spacer()
                    Button("Done") { close() }
                }
                Text(model.message).font(.caption)
                HStack {
                    Button("Change area", systemImage: "rectangle.dashed") { model.releaseScene(showSelectionMessage: true) }
                    Button("Expand area", systemImage: "arrow.up.left.and.arrow.down.right") {
                        requested = Self.resized(scene.manifest.bounds, factor: 1.45, inside: model.manifest?.bounds ?? scene.manifest.bounds)
                        model.releaseScene(showSelectionMessage: true)
                    }.buttonStyle(.borderedProminent)
                }
                Text("One finger moves · two fingers rotate · pinch zooms. Expanding replaces this scene; camera movement never loads more terrain.")
                    .font(.caption2).foregroundStyle(RidgeTheme.muted)
            }.padding(18).frame(maxWidth: 600).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(18)
        }
    }

    private func resize(_ factor: Double) {
        guard let requested, let source = model.manifest else { return }
        self.requested = Self.resized(requested, factor: factor, inside: source.bounds)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: label); Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
        }
    }

    private func close() { model.cancel(); if let onClose { onClose() } else { dismiss() } }

    private static func area(center: GeoPoint, kilometres: Double, inside outer: GeoBounds) -> GeoBounds {
        let halfLatitude = kilometres / 111.195 / 2
        let halfLongitude = kilometres / (111.195 * cos(center.latitude * .pi / 180)) / 2
        return clamped(GeoBounds(minLatitude: center.latitude - halfLatitude, minLongitude: center.longitude - halfLongitude,
                                 maxLatitude: center.latitude + halfLatitude, maxLongitude: center.longitude + halfLongitude), inside: outer)
    }

    private static func resized(_ bounds: GeoBounds, factor: Double, inside outer: GeoBounds) -> GeoBounds {
        let center = bounds.center
        let latitude = (bounds.maxLatitude - bounds.minLatitude) * factor / 2
        let longitude = (bounds.maxLongitude - bounds.minLongitude) * factor / 2
        return clamped(GeoBounds(minLatitude: center.latitude - latitude, minLongitude: center.longitude - longitude,
                                 maxLatitude: center.latitude + latitude, maxLongitude: center.longitude + longitude), inside: outer)
    }

    fileprivate static func clamped(_ bounds: GeoBounds, inside outer: GeoBounds) -> GeoBounds {
        let latitude = min(bounds.maxLatitude - bounds.minLatitude, outer.maxLatitude - outer.minLatitude)
        let longitude = min(bounds.maxLongitude - bounds.minLongitude, outer.maxLongitude - outer.minLongitude)
        let south = min(outer.maxLatitude - latitude, max(outer.minLatitude, bounds.center.latitude - latitude / 2))
        let west = min(outer.maxLongitude - longitude, max(outer.minLongitude, bounds.center.longitude - longitude / 2))
        return GeoBounds(minLatitude: south, minLongitude: west, maxLatitude: south + latitude, maxLongitude: west + longitude)
    }
}

private struct ParkSelectionMap: View {
    let manifest: AdaptiveParkManifest
    @Binding var selection: GeoBounds
    @State private var dragStart: GeoBounds?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.78, green: 0.87, blue: 0.88)))
                var coverage = Path()
                for chunk in manifest.chunks { coverage.addRect(rect(chunk.bounds, size: size)) }
                context.fill(coverage, with: .color(Color(red: 0.74, green: 0.79, blue: 0.64)))
                let selected = rect(selection, size: size)
                context.fill(Path(roundedRect: selected, cornerRadius: 5), with: .color(RidgeTheme.lime.opacity(0.25)))
                context.stroke(Path(roundedRect: selected, cornerRadius: 5), with: .color(RidgeTheme.orange), style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                context.draw(Text("N ↑").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(RidgeTheme.ink), at: CGPoint(x: size.width - 32, y: 24))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil { dragStart = selection }
                    guard let start = dragStart, geometry.size.width > 0, geometry.size.height > 0 else { return }
                    let longitude = Double(value.translation.width / geometry.size.width) * (manifest.bounds.maxLongitude - manifest.bounds.minLongitude)
                    let latitude = -Double(value.translation.height / geometry.size.height) * (manifest.bounds.maxLatitude - manifest.bounds.minLatitude)
                    let moved = GeoBounds(minLatitude: start.minLatitude + latitude, minLongitude: start.minLongitude + longitude,
                                          maxLatitude: start.maxLatitude + latitude, maxLongitude: start.maxLongitude + longitude)
                    selection = AdaptiveParkTestView.clamped(moved, inside: manifest.bounds)
                }
                .onEnded { _ in dragStart = nil })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eryri adaptive terrain coverage and selected planning rectangle")
        .accessibilityHint("Drag to move the selected area. Use Smaller and Larger to change its size.")
        .background(RidgeTheme.paper)
    }

    private func rect(_ bounds: GeoBounds, size: CGSize) -> CGRect {
        let x = (bounds.minLongitude - manifest.bounds.minLongitude) / (manifest.bounds.maxLongitude - manifest.bounds.minLongitude) * size.width
        let y = (manifest.bounds.maxLatitude - bounds.maxLatitude) / (manifest.bounds.maxLatitude - manifest.bounds.minLatitude) * size.height
        let width = (bounds.maxLongitude - bounds.minLongitude) / (manifest.bounds.maxLongitude - manifest.bounds.minLongitude) * size.width
        let height = (bounds.maxLatitude - bounds.minLatitude) / (manifest.bounds.maxLatitude - manifest.bounds.minLatitude) * size.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct ParkMetalView: UIViewRepresentable {
    let scene: ParkScene
    let onFrame: (Double, String?) -> Void
    @AppStorage(TerrainGestureStyle.defaultsKey) private var gestureStyle: TerrainGestureStyle = .moveWithOneFinger
    func makeCoordinator() -> ParkRenderer { ParkRenderer(scene: scene) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: scene.device)
        context.coordinator.onFrame = onFrame
        context.coordinator.install(view); context.coordinator.style = gestureStyle
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.style = gestureStyle
    }
    static func dismantleUIView(_ view: MTKView, coordinator: ParkRenderer) { view.isPaused = true; view.delegate = nil }
}

private final class ParkRenderer: NSObject, MTKViewDelegate {
    struct Uniforms { var vp: simd_float4x4; var rect: SIMD4<Float> }
    let scene: ParkScene
    var style: TerrainGestureStyle = .moveWithOneFinger
    var onFrame: ((Double, String?) -> Void)?
    private var reportedFrame = false
    var target = SIMD3<Float>(0, 0.7, 0), yaw: Float = 0.6, pitch: Float = 0.55, distance: Float = 5
    private var queue: MTLCommandQueue?, pipeline: MTLRenderPipelineState?, depth: MTLDepthStencilState?
    private weak var view: MTKView?
    init(scene: ParkScene) { self.scene = scene; super.init(); home() }
    func home() {
        target = SIMD3(0, 0.55, 0)
        distance = Float(max(scene.manifest.bounds.widthMeters, scene.manifest.bounds.depthMeters) / 1000) * 0.78
        distance = max(2.2, distance)
        pitch = 0.58
    }
    func install(_ view: MTKView) {
        self.view = view; view.clearColor = MTLClearColor(red: 0.72, green: 0.86, blue: 0.96, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm; view.depthStencilPixelFormat = .depth32Float; view.preferredFramesPerSecond = 30
        queue = scene.device.makeCommandQueue()
        let descriptor = MTLRenderPipelineDescriptor(), library = scene.device.makeDefaultLibrary()
        descriptor.vertexFunction = library?.makeFunction(name: "parkVertex"); descriptor.fragmentFunction = library?.makeFunction(name: "parkFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat; descriptor.depthAttachmentPixelFormat = .depth32Float
        do { pipeline = try scene.device.makeRenderPipelineState(descriptor: descriptor) }
        catch { onFrame?(0, "The terrain shader could not be prepared: \(error.localizedDescription)"); return }
        let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = .less; d.isDepthWriteEnabled = true; depth = scene.device.makeDepthStencilState(descriptor: d)
        view.delegate = self
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:))))
    }
    @objc private func pan(_ g: UIPanGestureRecognizer) {
        let d = g.translation(in: view); g.setTranslation(.zero, in: view)
        if g.numberOfTouches == style.rotateTouches { yaw -= Float(d.x) * 0.006; pitch = min(1.5, max(0.06, pitch + Float(d.y) * 0.006)) }
        else if g.numberOfTouches == style.moveTouches { let dx = Float(d.x) * distance * 0.001, dy = Float(d.y) * distance * 0.001; target.x -= dx * cos(yaw) + dy * sin(yaw); target.z += dx * sin(yaw) - dy * cos(yaw) }
    }
    @objc private func zoom(_ g: UIPinchGestureRecognizer) { distance = max(0.1, min(180, distance / Float(g.scale))); g.scale = 1 }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let command = queue?.makeCommandBuffer(), let pipeline, let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let eye = target + distance * SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let back = simd_normalize(eye - target), right = simd_normalize(simd_cross(SIMD3<Float>(0,1,0), back)), up = simd_cross(back, right)
        let look = simd_float4x4(columns: (SIMD4(right.x,up.x,back.x,0), SIMD4(right.y,up.y,back.y,0), SIMD4(right.z,up.z,back.z,0), SIMD4(-simd_dot(right,eye),-simd_dot(up,eye),-simd_dot(back,eye),1)))
        let ys: Float = 1 / tan(0.55), aspect = Float(max(1,view.drawableSize.width) / max(1,view.drawableSize.height)), near: Float = 0.005, far: Float = 500
        let zs = far / (near - far)
        let projection = simd_float4x4(columns: (SIMD4(ys/aspect,0,0,0), SIMD4(0,ys,0,0), SIMD4(0,0,zs,-1), SIMD4(0,0,near*zs,0))), vp = projection * look
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depth)
        for draw in scene.draws {
            // Only omit off-screen draw calls; the full mesh remains resident.
            let r = draw.rect
            var corners: [SIMD4<Float>] = []
            for x in [r.x,r.x+r.z] { for z in [r.y,r.y+r.w] { for y: Float in [-0.1,1.2] { corners.append(vp * SIMD4(x,y,z,1)) } } }
            if corners.allSatisfy({$0.x < -$0.w}) || corners.allSatisfy({$0.x > $0.w}) || corners.allSatisfy({$0.y < -$0.w}) || corners.allSatisfy({$0.y > $0.w}) || corners.allSatisfy({$0.z < 0}) || corners.allSatisfy({$0.z > $0.w}) { continue }
            var u = Uniforms(vp: vp, rect: r)
            encoder.setVertexBuffer(draw.vertices, offset: 0, index: 0); encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: draw.count, indexType: draw.indexType, indexBuffer: draw.indices, indexBufferOffset: 0)
        }
        encoder.endEncoding()
        if !reportedFrame {
            reportedFrame = true
            let callback = onFrame
            command.addCompletedHandler { buffer in
                let seconds = max(0, buffer.gpuEndTime - buffer.gpuStartTime)
                let error = buffer.error?.localizedDescription
                DispatchQueue.main.async { callback?(seconds, error) }
            }
        }
        command.present(drawable); command.commit()
    }
}
