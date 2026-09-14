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
            message = "Ready to test the entire prepared mesh. All chunks stay in memory; moving the camera never loads terrain."
            result = ["status": "ready", "physicalMemoryBytes": "\(ProcessInfo.processInfo.physicalMemory)", "availableMemoryBytes": "\(available)", "compactResidentBytes": "\(m.residentBytes)", "currentRendererBytes": "\(m.metalGeometryBytes)", "triangles": "\(m.triangles)"]
            #if targetEnvironment(simulator)
            result["environment"] = "Simulator: fixed 1 GiB verification budget, not a device reading"
            #else
            result["environment"] = "physical device"
            #endif
            saveResult()
        } catch { message = "The experiment pack could not be opened. \(error.localizedDescription)" }
    }
    func load() {
        guard !loading, scene == nil, let m = manifest, let device = MTLCreateSystemDefaultDevice() else { return }
        available = memoryAllowance()
        // Test actual compact geometry, without the production grid sample cap.
        // Leave space for the OS-facing view, framebuffers and in-flight file read.
        let reserve: Int64 = 512 * 1024 * 1024
        let recommended = Int64(clamping: device.recommendedMaxWorkingSetSize)
        let gpuRemaining = recommended > 0 ? max(0, recommended - Int64(clamping: device.currentAllocatedSize)) : available
        result["gpuWorkingSetSource"] = recommended > 0 ? "Metal recommendation" : "Metal recommendation unavailable; using process allowance"
        result["availableMemoryBytes"] = "\(available)"; result["gpuRemainingBytes"] = "\(gpuRemaining)"
        guard available > 0 else { message = "iOS did not provide a memory allowance. The full-scene test has not started."; result["status"] = "memory-reading-unavailable"; saveResult(); return }
        guard m.residentBytes + reserve <= available, m.residentBytes <= gpuRemaining else {
            message = "The full scene does not fit this device’s current allowance. It needs \(RidgeTheme.bytes(m.residentBytes)) for compact terrain plus 512 MB headroom; iOS currently reports \(RidgeTheme.bytes(available)) available. No terrain was allocated or reduced."
            result["status"] = "refused-before-allocation"; result["reason"] = message; saveResult(); return
        }
        result["status"] = "loading"; saveResult()
        loading = true; message = "Loading all \(m.chunks.count.formatted()) chunks…"
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
                scene = loaded; progress = 1; result["loadedFraction"] = "1.0"; message = "All \(m.chunks.count.formatted()) chunks resident · \(Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)))) s to load."
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
    func cancel() { task?.cancel(); worker?.cancel(); scene = nil }
    private func saveResult() {
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.documentsDirectory.appendingPathComponent("EryriStressResult.json"), options: .atomic)
        }
    }
}

struct AdaptiveParkTestView: View {
    var onClose: (() -> Void)? = nil
    @State private var model = ParkTestModel()
    @State private var wholePark = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.72, green: 0.86, blue: 0.96).ignoresSafeArea()
            if let scene = model.scene { ParkMetalView(scene: scene, wholePark: wholePark, onFrame: model.frameCompleted).ignoresSafeArea() }
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(model.manifest?.name ?? "Eryri · full park stress test").font(.title2.bold()); Spacer(); Button("Done") { model.cancel(); if let onClose { onClose() } else { dismiss() } } }
                Text("0.5 m surface tolerance · experimental terrain only").font(.subheadline)
                if let m = model.manifest {
                    Text("\(m.triangles.formatted()) triangles · \(RidgeTheme.bytes(m.residentBytes)) compact terrain · \(RidgeTheme.bytes(m.metalGeometryBytes)) in the current renderer").font(.callout)
                    Text("Prepared 1 m coverage is missing over \(m.uncoveredParkAreaKm2.formatted(.number.precision(.fractionLength(1)))) km² of the park. Those gaps stay empty. Map textures, route planning and horizon terrain are excluded from this diagnostic, so a successful load is not a full-app performance result.").font(.footnote)
                }
                Text(model.message).font(.callout).textSelection(.enabled)
                if model.loading { ProgressView(value: model.progress); Button("Cancel load") { model.cancel() } }
                else if model.scene == nil { Button("Test full scene") { model.load() }.buttonStyle(.borderedProminent).disabled(model.manifest == nil) }
                else {
                    Button(wholePark ? "Return to Crib Goch" : "Fit entire park") { wholePark.toggle() }.buttonStyle(.borderedProminent)
                    Text("Uses your one/two-finger move and rotate settings. Pinch to zoom. Every chunk stays resident.").font(.footnote)
                }
            }.padding(22).frame(maxWidth: 640).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).padding(20)
        }.task { model.inspect(); if ProcessInfo.processInfo.arguments.contains("--eryri-auto-test") { model.load() } }
            .onDisappear { model.cancel() }
    }
}

private struct ParkMetalView: UIViewRepresentable {
    let scene: ParkScene
    let wholePark: Bool
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
        if context.coordinator.whole != wholePark { context.coordinator.whole = wholePark; context.coordinator.home() }
    }
    static func dismantleUIView(_ view: MTKView, coordinator: ParkRenderer) { view.isPaused = true; view.delegate = nil }
}

private final class ParkRenderer: NSObject, MTKViewDelegate {
    struct Uniforms { var vp: simd_float4x4; var rect: SIMD4<Float> }
    let scene: ParkScene
    var style: TerrainGestureStyle = .moveWithOneFinger
    var onFrame: ((Double, String?) -> Void)?
    private var reportedFrame = false
    var whole = false
    var target = SIMD3<Float>(0, 0.7, 0), yaw: Float = 0.6, pitch: Float = 0.55, distance: Float = 5
    private var queue: MTLCommandQueue?, pipeline: MTLRenderPipelineState?, depth: MTLDepthStencilState?
    private weak var view: MTKView?
    init(scene: ParkScene) { self.scene = scene; super.init(); home() }
    func home() {
        if whole { target = .zero; distance = 110; pitch = 0.85 }
        else { let center = scene.manifest.bounds.center; target = SIMD3(Float((-4.054 - center.longitude) * cos(center.latitude * .pi / 180) * 111.195), 0.8, Float((center.latitude - 53.075) * 111.195)); distance = 5; pitch = 0.55 }
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
