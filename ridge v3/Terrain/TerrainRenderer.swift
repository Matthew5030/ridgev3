import Foundation
import MetalKit
import simd

private struct RidgeVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
}

private struct RidgeUniforms {
    var viewProjection: simd_float4x4
    var textureRect: SIMD4<Float>
    var color: SIMD4<Float>
    var style: SIMD4<Float>
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
    var contextRect: SIMD4<Float>
    var clearRect: SIMD4<Float>
    var atmosphere: SIMD4<Float>
    var daylight: SIMD4<Float> // drawable width/height, tan(half field of view), reserved
}

private struct RidgeMesh {
    var vertices: MTLBuffer
    var indices: MTLBuffer
    var count: Int
}

private struct TerrainDraw {
    var indices: MTLBuffer
    var count: Int
    var texture: MTLTexture
    var rect: SIMD4<Float>
}

private struct BackdropSurface {
    var rect: SIMD4<Float>
    var columns: Int
    var rows: Int
    var heights: [Float]
}

private struct BackdropSeam {
    /// North, south, west, east side of the inner rectangle.
    var edge: Int
    var coordinates: [Float]
    var firstVertex: Int
}

private struct BackdropVertexLayout {
    var columns: Int
    var rows: Int
    var removedColumns: Range<Int>
    var removedRows: Range<Int>
    var count: Int { columns * rows - removedColumns.count * removedRows.count }
    func index(row: Int, column: Int) -> Int? {
        let cutRow = removedRows.contains(row)
        if cutRow && removedColumns.contains(column) { return nil }
        let precedingRows = max(0, min(row - removedRows.lowerBound, removedRows.count))
        let precedingColumns = cutRow && column >= removedColumns.upperBound ? removedColumns.count : 0
        return row * columns + column - precedingRows * removedColumns.count - precedingColumns
    }
}

private struct BackdropPlan {
    var source: LoadedBackdrop
    var surface: BackdropSurface
    var inner: BackdropSurface
    var gridU: [Float]
    var gridV: [Float]
    var textureRects: [SIMD4<Float>]
    var layout: BackdropVertexLayout
    var seams: [Int: BackdropSeam]
    var vertexCount: Int
    var indexCount: Int
}

private struct BackdropMesh {
    var plan: BackdropPlan
    var vertices: MTLBuffer
    var draws: [TerrainDraw]
}

private struct RidgeCamera {
    var target: SIMD3<Float>
    var yaw: Float
    var pitch: Float
    var distance: Float
}

private enum TerrainRenderError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let reason): return reason }
    }
}

/// The renderer owns one bounded mesh and a fixed set of local GPU textures.
/// No network, task scheduling, cache growth, or camera-dependent terrain LOD.
// Prepared on one worker, then transferred once to the main actor. Only the
// initializer calls the unisolated geometry helpers; interactive entry points
// are main-actor isolated. GPU resources are retained by submitted command buffers.
final class TerrainRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private weak var view: MTKView?
    private let terrain: LoadedTerrain
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let depth: MTLDepthStencilState
    private let overlayDepth: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private var cartography: CartographyRenderer?
    private var terrainVertices: MTLBuffer?
    private var terrainDraws: [TerrainDraw] = []
    private var backdrops: [BackdropMesh] = []
    private var contextSurfaces: [BackdropSurface] = []
    private var outerContextRect = SIMD4<Float>(0, 0, 1, 1)
    private var clearContextRect = SIMD4<Float>(0, 0, 1, 1)
    private var areaBoundary: RidgeMesh?
    private var extensionBoundary: RidgeMesh?
    private var extensionCells: RidgeMesh?
    private var extensionBounds: GeoBounds?
    private var extensionGrid: TerrainGrid?
    private var sides: RidgeMesh?
    private var shadow: RidgeMesh?
    private var routeHalo: RidgeMesh?
    private var routeInk: RidgeMesh?
    private var overviewRoute: RidgeMesh?
    private var coverageFocus: SIMD2<Float>?
    var coverageEditing = false { didSet { if coverageEditing != oldValue { view?.setNeedsDisplay() } } }
    private var markers: RidgeMesh?
    private var selection: RidgeMesh?
    private var fallbackTexture: MTLTexture
    private var mapUnitsPerTexel: Float = 0
    private var gridU: [Float] = []
    private var gridV: [Float] = []
    private let metersPerUnit: Float
    private let width: Float
    private let depthExtent: Float
    private let minimumHeight: Float
    private let primaryFloor: Float
    private let top: Float
    private let sceneTop: Float
    private let sceneContainsNoData: Bool
    private let bottom: Float = -0.022
    private var camera: RidgeCamera
    private var viewProjection = matrix_identity_float4x4
    private var right = SIMD3<Float>(1, 0, 0)
    private var up = SIMD3<Float>(0, 1, 0)
    private let fieldOfView: Float = 43 * .pi / 180
    private var route: [RoutePoint] = []
    private var routeSegments: [[RoutePoint]] = []
    private var waypoints: [RouteWaypoint] = []
    private var selectedPoint: GeoPoint?
    private var routeWidth: Float = 0
    private var didSize = false
    private var framedAtHome = true
    private var viewportSize = CGSize(width: 390, height: 844)
    private var displayLink: CADisplayLink?
    private var animation: (start: RidgeCamera, end: RidgeCamera, time: CFTimeInterval)?
    @MainActor var onCameraChange: (() -> Void)?
    @MainActor var onCartographyWarning: ((String) -> Void)?

    init(device: MTLDevice, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat, sampleCount: Int, terrain: LoadedTerrain) throws {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "ridgeVertex"),
              let fragment = library.makeFunction(name: terrain.cartography == nil ? "ridgeFragment" : "ridgeAtlasFragment"),
              let skyVertex = library.makeFunction(name: "ridgeSkyVertex"),
              let skyFragment = library.makeFunction(name: "ridgeSkyFragment") else {
            throw TerrainRenderError.unavailable("The terrain graphics resources are unavailable.")
        }
        let sourceSampleProduct = terrain.level.width.multipliedReportingOverflow(by: terrain.level.height)
        guard terrain.manifest.bounds.isValid, terrain.level.width >= 2, terrain.level.height >= 2,
              !sourceSampleProduct.overflow, terrain.heights.count == sourceSampleProduct.partialValue,
              terrain.heights.count <= TerrainBudget.absoluteMaximumSamples else {
            throw TerrainRenderError.unavailable("This terrain grid exceeds the supported scene budget or is incomplete. Choose a coarser resolution.")
        }
        let finiteHeights = terrain.heights.lazy.filter { $0.isFinite }
        guard let minimum = finiteHeights.min(), let maximum = finiteHeights.max() else {
            throw TerrainRenderError.unavailable("This area has no usable elevation samples.")
        }
        self.terrain = terrain
        self.device = device
        self.queue = queue
        let surroundings = terrain.horizon?.layers ?? []
        sceneContainsNoData = terrain.heights.contains { !$0.isFinite } || surroundings.contains { $0.heights.contains { !$0.isFinite } }
        var sceneMinimum = minimum, sceneMaximum = maximum
        for layer in surroundings {
            try Task.checkCancellation()
            let product = layer.level.width.multipliedReportingOverflow(by: layer.level.height)
            guard layer.metadata.bounds.isValid, layer.level.width >= 2, layer.level.height >= 2,
                  !product.overflow, product.partialValue == layer.heights.count,
                  layer.heights.count <= TerrainBudget.absoluteMaximumSamples else {
                throw TerrainRenderError.unavailable("The surrounding terrain is incomplete or exceeds the supported scene size.")
            }
            let finite = layer.heights.lazy.filter { $0.isFinite }
            if let low = finite.min() { sceneMinimum = min(sceneMinimum, low) }
            if let high = finite.max() { sceneMaximum = max(sceneMaximum, high) }
        }
        minimumHeight = sceneMinimum
        let w = Float(terrain.manifest.bounds.widthMeters), d = Float(terrain.manifest.bounds.depthMeters)
        metersPerUnit = max(w, d)
        width = w / max(w, d)
        depthExtent = d / max(w, d)
        primaryFloor = (minimum - sceneMinimum) / max(w, d)
        top = (maximum - sceneMinimum) / max(w, d)
        sceneTop = (sceneMaximum - sceneMinimum) / max(w, d)
        camera = RidgeCamera(target: SIMD3(0, (minimum - sceneMinimum + (maximum - minimum) * 0.35) / max(w, d), 0), yaw: -0.38, pitch: surroundings.isEmpty ? 0.94 : 20 * .pi / 180, distance: 2)

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Ridge relief, cartography and route"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.label = "Clear daylight sky"
        descriptor.vertexFunction = skyVertex
        descriptor.fragmentFunction = skyFragment
        descriptor.colorAttachments[0].isBlendingEnabled = false
        skyPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw TerrainRenderError.unavailable("The depth buffer could not be prepared.")
        }
        self.depth = depth
        depthDescriptor.isDepthWriteEnabled = false
        guard let overlayDepth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw TerrainRenderError.unavailable("The route graphics could not be prepared.")
        }
        self.overlayDepth = overlayDepth
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.label = "Crisp cartography, anisotropy 16"
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.maxAnisotropy = 16
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw TerrainRenderError.unavailable("Map texture filtering is unavailable.")
        }
        self.sampler = sampler
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        textureDescriptor.usage = .shaderRead
        guard let neutral = device.makeTexture(descriptor: textureDescriptor) else {
            throw TerrainRenderError.unavailable("The map texture could not be allocated.")
        }
        let neutralPixel: [UInt8] = [222, 226, 201, 255]
        neutralPixel.withUnsafeBytes { bytes in
            neutral.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 4)
        }
        fallbackTexture = neutral
        super.init()
        try buildTerrain()
        if let atlas = terrain.cartography {
            cartography = try CartographyRenderer(device: device, queue: queue, loaded: atlas, primaryBounds: terrain.manifest.bounds,
                                                  terrain: terrain, minimumHeight: minimumHeight, metersPerUnit: metersPerUnit)
        }
        if backdrops.isEmpty { buildSides(); buildShadow() }
    }

    @MainActor
    func attach(to view: MTKView) {
        self.view = view
        cartography?.onChange = { [weak self] in self?.view?.setNeedsDisplay() }
        cartography?.onWarning = { [weak self] message in self?.onCartographyWarning?(message) }
        if view.bounds.width > 0 && view.bounds.height > 0 { viewportSize = view.bounds.size }
        camera = homeCamera()
        didSize = view.bounds.width > 0 && view.bounds.height > 0
        constrainCamera()
    }

    @MainActor
    func stop() {
        onCameraChange = nil
        onCartographyWarning = nil
        cartography?.stop(); cartography = nil
        displayLink?.invalidate()
        displayLink = nil
        animation = nil
        terrainVertices = nil
        terrainDraws.removeAll()
        backdrops.removeAll(); contextSurfaces.removeAll(); areaBoundary = nil
        extensionBoundary = nil; extensionCells = nil
        sides = nil; shadow = nil; routeHalo = nil; routeInk = nil; overviewRoute = nil; markers = nil; selection = nil
    }

    @MainActor
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }
        // The callback's new drawable is authoritative: view.bounds can still
        // describe the previous layout here, particularly during footer changes.
        let scale = max(1, view.contentScaleFactor)
        viewportDidChange(to: CGSize(width: size.width / scale, height: size.height / scale))
    }

    @MainActor
    func viewportDidChange(to size: CGSize) {
        guard size.width > 0, size.height > 0,
              !didSize || abs(size.width - viewportSize.width) > 0.5 || abs(size.height - viewportSize.height) > 0.5 else { return }
        viewportSize = size
        if !didSize {
            cancelAnimation()
            camera = homeCamera()
            didSize = true
            constrainCamera()
        }
        // A pending-area card changes available screen space, not the camera's
        // geographic position. Preserve the pose until the next camera gesture.
        routeWidth = 0
        view?.setNeedsDisplay()
    }

    @MainActor
    func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        updateMatrices()
        onCameraChange?()
        let desiredWidth = worldUnitsPerPoint * 3.2
        if routeWidth == 0 || abs(desiredWidth / routeWidth - 1) > 0.12 {
            routeWidth = desiredWidth
            buildRoute()
            buildAreaBoundary()
            buildExtension()
        }
        encoder.label = "One fixed terrain scene"
        encoder.setRenderPipelineState(skyPipeline)
        encoder.setDepthStencilState(overlayDepth)
        var skyUniforms = uniforms(material: 0, color: SIMD4(1, 1, 1, 1))
        encoder.setFragmentBytes(&skyUniforms, length: MemoryLayout<RidgeUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentTexture(fallbackTexture, index: 0)
        if let cartography {
            cartography.update(viewProjection: viewProjection, coverage: outerContextRect, worldSize: SIMD2(width, depthExtent), top: sceneTop,
                               viewportPixels: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)))
            guard cartography.bind(encoder: encoder, command: command) else { encoder.endEncoding(); return }
        }
        if let shadow {
            encoder.setDepthStencilState(overlayDepth)
            draw(shadow, encoder: encoder, material: 4, color: SIMD4(1, 1, 1, 1))
            encoder.setDepthStencilState(depth)
        }
        if let sides { draw(sides, encoder: encoder, material: 1, color: SIMD4(0.065, 0.105, 0.089, 1), lit: true) }
        for backdrop in backdrops.reversed() {
            encoder.setVertexBuffer(backdrop.vertices, offset: 0, index: 0)
            for batch in backdrop.draws {
                var u = uniforms(material: 0, color: SIMD4(repeating: 1))
                u.textureRect = batch.rect
                encoder.setVertexBytes(&u, length: MemoryLayout<RidgeUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<RidgeUniforms>.stride, index: 1)
                encoder.setFragmentTexture(batch.texture, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.count, indexType: .uint32, indexBuffer: batch.indices, indexBufferOffset: 0)
            }
        }
        if let terrainVertices {
            encoder.setVertexBuffer(terrainVertices, offset: 0, index: 0)
            for batch in terrainDraws {
                var u = uniforms(material: 0, color: SIMD4(repeating: 1))
                u.textureRect = batch.rect
                encoder.setVertexBytes(&u, length: MemoryLayout<RidgeUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<RidgeUniforms>.stride, index: 1)
                encoder.setFragmentTexture(batch.texture, index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.count, indexType: .uint32, indexBuffer: batch.indices, indexBufferOffset: 0)
            }
        }
        encoder.setFragmentTexture(fallbackTexture, index: 0)
        if let areaBoundary, coverageBoundaryOpacity > 0 { draw(areaBoundary, encoder: encoder, material: 1, color: SIMD4(0.25, 0.36, 0.32, coverageBoundaryOpacity)) }
        encoder.setDepthStencilState(overlayDepth)
        if let extensionCells { draw(extensionCells, encoder: encoder, material: 1, color: SIMD4(0.12, 0.40, 0.47, 0.34)) }
        if let extensionBoundary { draw(extensionBoundary, encoder: encoder, material: 1, color: SIMD4(0.10, 0.38, 0.46, 0.92)) }
        encoder.setDepthStencilState(depth)
        if let routeHalo { draw(routeHalo, encoder: encoder, material: 1, color: SIMD4(0.985, 0.97, 0.92, 1)) }
        if let routeInk { draw(routeInk, encoder: encoder, material: 1, color: SIMD4(0.86, 0.19, 0.065, 1)) }
        if let overviewRoute { draw(overviewRoute, encoder: encoder, material: 1, color: SIMD4(0.78, 0.29, 0.12, 0.95)) }
        encoder.setDepthStencilState(overlayDepth)
        if let markers { draw(markers, encoder: encoder, material: 2, color: SIMD4(0.86, 0.19, 0.065, 1), markerRadius: worldUnitsPerPoint * 8.5) }
        if let selection {
            let pending = selectedPoint.map { !terrain.manifest.bounds.contains($0) } ?? false
            draw(selection, encoder: encoder, material: 3, color: pending ? SIMD4(0.10, 0.38, 0.46, 1) : SIMD4(0.86, 0.19, 0.065, 1), markerRadius: worldUnitsPerPoint * 14)
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    @MainActor
    private func uniforms(material: Float, color: SIMD4<Float>, lit: Bool = false, markerRadius: Float = 0) -> RidgeUniforms {
        RidgeUniforms(viewProjection: viewProjection, textureRect: SIMD4(0, 0, 1, 1), color: color,
                      style: SIMD4(material, markerRadius, lit ? 1 : 0, 0),
                      cameraRight: SIMD4(right.x, right.y, right.z, 0), cameraUp: SIMD4(up.x, up.y, up.z, 0),
                      contextRect: outerContextRect,
                      clearRect: clearContextRect,
                      atmosphere: SIMD4(width, depthExtent, backdrops.isEmpty ? 0 : 2_000 / metersPerUnit, 12_000 / metersPerUnit),
                      daylight: SIMD4(Float(view?.drawableSize.width ?? 1), Float(view?.drawableSize.height ?? 1), tan(fieldOfView / 2), 0))
    }

    @MainActor
    private func draw(_ mesh: RidgeMesh, encoder: MTLRenderCommandEncoder, material: Float, color: SIMD4<Float>, lit: Bool = false, markerRadius: Float = 0) {
        var u = uniforms(material: material, color: color, lit: lit, markerRadius: markerRadius)
        encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<RidgeUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&u, length: MemoryLayout<RidgeUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
    }

    private func buildTerrain() throws {
        var rectangles: [SIMD4<Float>] = []
        let mapTextures = terrain.cartography == nil ? terrain.manifest.textures : []
        for (index, texture) in mapTextures.enumerated() {
            try Task.checkCancellation()
            guard terrain.textureURLs.indices.contains(index), texture.bounds.isValid else {
                throw TerrainRenderError.unavailable("One of this area's map textures is missing.")
            }
            guard (1...16_384).contains(texture.width), (1...16_384).contains(texture.height) else {
                throw TerrainRenderError.unavailable("A map texture has unsupported dimensions.")
            }
            let northwest = terrain.manifest.bounds.uv(GeoPoint(latitude: texture.bounds.maxLatitude, longitude: texture.bounds.minLongitude))
            let southeast = terrain.manifest.bounds.uv(GeoPoint(latitude: texture.bounds.minLatitude, longitude: texture.bounds.maxLongitude))
            rectangles.append(SIMD4(Float(northwest.u), Float(northwest.v), Float(southeast.u - northwest.u), Float(southeast.v - northwest.v)))
            mapUnitsPerTexel = max(mapUnitsPerTexel,
                                   Float(texture.bounds.widthMeters) / metersPerUnit / Float(texture.width),
                                   Float(texture.bounds.depthMeters) / metersPerUnit / Float(texture.height))
        }
        // Insert texture borders into the mesh: each triangle belongs to exactly one texture.
        // This keeps geographic registration exact without a blurry rescaled mega-atlas.
        gridU = (0..<terrain.level.width).map { Float($0) / Float(terrain.level.width - 1) }
        gridV = (0..<terrain.level.height).map { Float($0) / Float(terrain.level.height - 1) }
        for rect in rectangles {
            gridU.append(contentsOf: [rect.x, rect.x + rect.z].filter { $0 > 0 && $0 < 1 })
            gridV.append(contentsOf: [rect.y, rect.y + rect.w].filter { $0 > 0 && $0 < 1 })
        }
        gridU = uniqueSorted(gridU); gridV = uniqueSorted(gridV)
        let vertexProduct = gridU.count.multipliedReportingOverflow(by: gridV.count)
        let cellProduct = (gridU.count - 1).multipliedReportingOverflow(by: gridV.count - 1)
        let indexProduct = cellProduct.partialValue.multipliedReportingOverflow(by: 6)
        guard !vertexProduct.overflow, !cellProduct.overflow, !indexProduct.overflow,
              vertexProduct.partialValue <= Int(UInt32.max) else {
            throw TerrainRenderError.unavailable("This area's terrain grid is too large. Choose a smaller area or coarser resolution.")
        }
        let vertexCount = vertexProduct.partialValue
        let backdropPlans = try planBackdrops()
        let horizonGeometry = backdropPlans.map { TerrainBudget.Geometry(meshVertexCount: $0.vertexCount, indexCount: $0.indexCount) }
        // Use the context captured before loading the height field. Counting all
        // possible triangles bounds the scene before any large GPU allocation;
        // NoData triangles will subsequently require fewer index bytes.
        let allowance = TerrainBudget.validateGeometry(for: terrain.manifest, spacing: terrain.level.spacing,
                                                       meshVertexCount: vertexCount, indexCount: indexProduct.partialValue,
                                                       context: terrain.budgetContext ?? TerrainBudget.currentContext(), horizonGeometry: horizonGeometry)
        guard allowance.allowed else {
            throw TerrainRenderError.unavailable(allowance.reason ?? "This terrain exceeds the current device allowance. Choose a smaller area or coarser resolution.")
        }
        let currentAllowance = TerrainBudget.validateGeometry(for: terrain.manifest, spacing: terrain.level.spacing,
                                                              meshVertexCount: vertexCount, indexCount: indexProduct.partialValue,
                                                              context: TerrainBudget.currentContext(),
                                                              residentBytes: Int64(terrain.heights.count + (terrain.horizon?.layers ?? []).reduce(0) { $0 + $1.heights.count }) * Int64(MemoryLayout<Float>.stride),
                                                              horizonGeometry: horizonGeometry)
        guard currentAllowance.allowed else {
            throw TerrainRenderError.unavailable(currentAllowance.reason ?? "Available memory changed while loading this area. Choose a smaller area or coarser resolution.")
        }
        let vertexBuffer = try makeTerrainBuffer(count: vertexCount, stride: MemoryLayout<RidgeVertex>.stride, label: "Fixed terrain vertices")
        let vertices = vertexBuffer.contents().bindMemory(to: RidgeVertex.self, capacity: vertexCount)
        var valid = [Bool](repeating: false, count: vertexCount)
        let du: Float = 1 / Float(terrain.level.width - 1), dv: Float = 1 / Float(terrain.level.height - 1)
        let columns = gridU.count
        for (row, v) in gridV.enumerated() {
            try Task.checkCancellation()
            for (column, u) in gridU.enumerated() {
                let index = row * columns + column
                let sample = height(u: u, v: v)
                valid[index] = sample != nil
                let y = sample ?? 0
                let u0 = max(0, u - du), u1 = min(1, u + du)
                let v0 = max(0, v - dv), v1 = min(1, v + dv)
                let dx = ((height(u: u1, v: v) ?? y) - (height(u: u0, v: v) ?? y)) / max((u1 - u0) * width, 0.000001)
                let dz = ((height(u: u, v: v1) ?? y) - (height(u: u, v: v0) ?? y)) / max((v1 - v0) * depthExtent, 0.000001)
                vertices.advanced(by: index).initialize(to: RidgeVertex(position: SIMD3((u - 0.5) * width, sample ?? .nan, (v - 0.5) * depthExtent), normal: simd_normalize(SIMD3(-dx, 1, -dz)), uv: SIMD2(u, v)))
            }
        }
        // Walk identical triangles twice: count each texture's exact allocation,
        // then write into it. No full-size CPU vertex or index copies coexist with
        // these shared Metal buffers, even while preparing a larger 1 m scene.
        func visitTriangles(_ body: (Int, UInt32, UInt32, UInt32) -> Void) throws {
            for row in 0..<(gridV.count - 1) {
                try Task.checkCancellation()
                let v = (gridV[row] + gridV[row + 1]) / 2
                let rowTextures = rectangles.indices.filter { v >= rectangles[$0].y && v <= rectangles[$0].y + rectangles[$0].w }
                for column in 0..<(columns - 1) {
                    let u = (gridU[column] + gridU[column + 1]) / 2
                    let group = rowTextures.first { u >= rectangles[$0].x && u <= rectangles[$0].x + rectangles[$0].z } ?? rectangles.count
                    let a = row * columns + column, b = a + 1, c = a + columns, d = c + 1
                    if valid[a] && valid[c] && valid[b] { body(group, UInt32(a), UInt32(c), UInt32(b)) }
                    if valid[b] && valid[c] && valid[d] { body(group, UInt32(b), UInt32(c), UInt32(d)) }
                }
            }
        }
        var counts = [Int](repeating: 0, count: rectangles.count + 1)
        try visitTriangles { group, _, _, _ in counts[group] += 3 }
        var buffers = [MTLBuffer?](repeating: nil, count: counts.count)
        var writers = [UnsafeMutablePointer<UInt32>?](repeating: nil, count: counts.count)
        for index in counts.indices where counts[index] > 0 {
            try Task.checkCancellation()
            let buffer = try makeTerrainBuffer(count: counts[index], stride: MemoryLayout<UInt32>.stride, label: "Terrain texture section")
            buffers[index] = buffer
            writers[index] = buffer.contents().bindMemory(to: UInt32.self, capacity: counts[index])
        }
        var offsets = [Int](repeating: 0, count: counts.count)
        try visitTriangles { group, a, b, c in
            if let writer = writers[group] {
                let offset = offsets[group]
                writer.advanced(by: offset).initialize(to: a)
                writer.advanced(by: offset + 1).initialize(to: b)
                writer.advanced(by: offset + 2).initialize(to: c)
                offsets[group] += 3
            }
        }
        let textureLoader = MTKTextureLoader(device: device)
        var textures: [MTLTexture] = []
        for (index, texture) in mapTextures.enumerated() {
            try Task.checkCancellation()
            let loaded = try autoreleasepool {
                try textureLoader.newTexture(URL: terrain.textureURLs[index], options: [
                    .generateMipmaps: true,
                    .SRGB: true,
                    .origin: MTKTextureLoader.Origin.topLeft.rawValue,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                    .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
                ])
            }
            loaded.label = texture.file
            textures.append(loaded)
        }
        try Task.checkCancellation()
        terrainVertices = vertexBuffer
        for index in buffers.indices {
            guard let buffer = buffers[index] else { continue }
            terrainDraws.append(TerrainDraw(indices: buffer, count: counts[index], texture: index < textures.count ? textures[index] : fallbackTexture, rect: index < rectangles.count ? rectangles[index] : SIMD4(0, 0, 1, 1)))
        }
        valid.removeAll(keepingCapacity: false)
        for plan in backdropPlans {
            try Task.checkCancellation()
            backdrops.append(try buildBackdrop(plan))
            contextSurfaces.append(plan.surface)
            outerContextRect = plan.surface.rect
        }
        // Keep the nearby band clear when a distant band surrounds it. A scene
        // with only one backdrop still keeps all primary terrain haze-free.
        if backdropPlans.count > 1 { clearContextRect = backdropPlans[0].surface.rect }
    }

    private func normalizedRect(_ bounds: GeoBounds) -> SIMD4<Float> {
        let a = terrain.manifest.bounds.uv(GeoPoint(latitude: bounds.maxLatitude, longitude: bounds.minLongitude))
        let b = terrain.manifest.bounds.uv(GeoPoint(latitude: bounds.minLatitude, longitude: bounds.maxLongitude))
        return SIMD4(Float(a.u), Float(a.v), Float(b.u - a.u), Float(b.v - a.v))
    }

    /// Only a perimeter collar uses the inner surface's sample positions. Coarse
    /// rows stay coarse everywhere else, including when the selection is 1 m.
    private func planBackdrops() throws -> [BackdropPlan] {
        var plans: [BackdropPlan] = []
        var inner = BackdropSurface(rect: SIMD4(0, 0, 1, 1), columns: terrain.level.width, rows: terrain.level.height, heights: terrain.heights)
        var innerU = gridU, innerV = gridV
        for source in terrain.horizon?.layers ?? [] {
            try Task.checkCancellation()
            let rect = normalizedRect(source.metadata.bounds)
            let epsilon: Float = 0.000002
            guard rect.x <= inner.rect.x + epsilon, rect.y <= inner.rect.y + epsilon,
                  rect.x + rect.z >= inner.rect.x + inner.rect.z - epsilon,
                  rect.y + rect.w >= inner.rect.y + inner.rect.w - epsilon,
                  terrain.cartography != nil || source.metadata.textures.count == source.textureURLs.count else {
                throw TerrainRenderError.unavailable("The surrounding terrain does not cover the selected area consistently.")
            }
            let textureRects = terrain.cartography == nil ? source.metadata.textures.map { normalizedRect($0.bounds) } : []
            var u = (0..<source.level.width).map { rect.x + Float($0) / Float(source.level.width - 1) * rect.z }
            var v = (0..<source.level.height).map { rect.y + Float($0) / Float(source.level.height - 1) * rect.w }
            for boundary in textureRects + [inner.rect] {
                u.append(contentsOf: [boundary.x, boundary.x + boundary.z].filter { $0 > rect.x && $0 < rect.x + rect.z })
                v.append(contentsOf: [boundary.y, boundary.y + boundary.w].filter { $0 > rect.y && $0 < rect.y + rect.w })
            }
            u = uniqueSorted(u); v = uniqueSorted(v)
            let base = u.count.multipliedReportingOverflow(by: v.count)
            guard !base.overflow, base.partialValue <= TerrainBudget.absoluteMaximumMeshVertices else {
                throw TerrainRenderError.unavailable("The surrounding terrain exceeds the scene budget.")
            }
            let removedColumns = u.indices.filter { u[$0] > inner.rect.x + 0.0000001 && u[$0] < inner.rect.x + inner.rect.z - 0.0000001 }
            let removedRows = v.indices.filter { v[$0] > inner.rect.y + 0.0000001 && v[$0] < inner.rect.y + inner.rect.w - 0.0000001 }
            let layout = BackdropVertexLayout(columns: u.count, rows: v.count,
                                              removedColumns: (removedColumns.first ?? 0)..<((removedColumns.last ?? -1) + 1),
                                              removedRows: (removedRows.first ?? 0)..<((removedRows.last ?? -1) + 1))
            var vertexCount = layout.count, indexCount = 0
            var seams: [Int: BackdropSeam] = [:]
            for row in 0..<(v.count - 1) {
                try Task.checkCancellation()
                for column in 0..<(u.count - 1) {
                    let midU = (u[column] + u[column + 1]) / 2, midV = (v[row] + v[row + 1]) / 2
                    if inside(midU, midV, rect: inner.rect) { continue }
                    var edge: Int?
                    if midU > inner.rect.x && midU < inner.rect.x + inner.rect.z {
                        if abs(v[row + 1] - inner.rect.y) < 0.0000001 { edge = 0 }
                        else if abs(v[row] - (inner.rect.y + inner.rect.w)) < 0.0000001 { edge = 1 }
                    }
                    if midV > inner.rect.y && midV < inner.rect.y + inner.rect.w {
                        if abs(u[column + 1] - inner.rect.x) < 0.0000001 { edge = 2 }
                        else if abs(u[column] - (inner.rect.x + inner.rect.z)) < 0.0000001 { edge = 3 }
                    }
                    var extra: [Float] = []
                    if let edge {
                        let axis = edge < 2 ? innerU : innerV
                        let lower = edge < 2 ? u[column] : v[row], upper = edge < 2 ? u[column + 1] : v[row + 1]
                        let first = cell(in: axis, value: lower)
                        for index in first..<axis.count {
                            let value = axis[index]
                            if value >= upper - 0.0000001 { break }
                            if value > lower + 0.0000001 { extra.append(value) }
                        }
                        seams[row * u.count + column] = BackdropSeam(edge: edge, coordinates: extra, firstVertex: vertexCount)
                    }
                    vertexCount += extra.count
                    indexCount += 6 + extra.count * 3
                }
            }
            guard vertexCount <= TerrainBudget.absoluteMaximumMeshVertices else {
                throw TerrainRenderError.unavailable("The surrounding terrain boundary exceeds the scene budget.")
            }
            let surface = BackdropSurface(rect: rect, columns: source.level.width, rows: source.level.height, heights: source.heights)
            plans.append(BackdropPlan(source: source, surface: surface, inner: inner, gridU: u, gridV: v, textureRects: textureRects,
                                      layout: layout, seams: seams, vertexCount: vertexCount, indexCount: indexCount))
            inner = surface; innerU = u; innerV = v
        }
        return plans
    }

    private func inside(_ u: Float, _ v: Float, rect: SIMD4<Float>) -> Bool {
        u > rect.x && u < rect.x + rect.z && v > rect.y && v < rect.y + rect.w
    }

    private func surfaceHeight(_ surface: BackdropSurface, u: Float, v: Float) -> Float? {
        let x = (u - surface.rect.x) / surface.rect.z, y = (v - surface.rect.y) / surface.rect.w
        guard x >= -0.000001, x <= 1.000001, y >= -0.000001, y <= 1.000001 else { return nil }
        let px = min(1, max(0, x)) * Float(surface.columns - 1), py = min(1, max(0, y)) * Float(surface.rows - 1)
        let x0 = min(surface.columns - 1, Int(px)), y0 = min(surface.rows - 1, Int(py))
        let x1 = min(surface.columns - 1, x0 + 1), y1 = min(surface.rows - 1, y0 + 1)
        let a = surface.heights[y0 * surface.columns + x0], b = surface.heights[y0 * surface.columns + x1]
        let c = surface.heights[y1 * surface.columns + x0], d = surface.heights[y1 * surface.columns + x1]
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite else { return nil }
        let tx = px - Float(x0), ty = py - Float(y0)
        return ((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty - minimumHeight) / metersPerUnit
    }

    private func backdropHeight(_ plan: BackdropPlan, u: Float, v: Float) -> Float? {
        let rect = plan.inner.rect, epsilon: Float = 0.0000002
        if u >= rect.x - epsilon, u <= rect.x + rect.z + epsilon, v >= rect.y - epsilon, v <= rect.y + rect.w + epsilon {
            return surfaceHeight(plan.inner, u: u, v: v)
        }
        return surfaceHeight(plan.surface, u: u, v: v)
    }

    private func buildBackdrop(_ plan: BackdropPlan) throws -> BackdropMesh {
        let vertexBuffer = try makeTerrainBuffer(count: plan.vertexCount, stride: MemoryLayout<RidgeVertex>.stride, label: "Fixed surrounding terrain vertices")
        let vertices = vertexBuffer.contents().bindMemory(to: RidgeVertex.self, capacity: plan.vertexCount)
        var valid = [Bool](repeating: false, count: plan.vertexCount)
        let columns = plan.gridU.count
        let du = plan.surface.rect.z / Float(plan.surface.columns - 1), dv = plan.surface.rect.w / Float(plan.surface.rows - 1)
        func writeVertex(_ index: Int, _ u: Float, _ v: Float) {
            let sample = backdropHeight(plan, u: u, v: v), y = sample ?? 0
            valid[index] = sample != nil
            let u0 = max(plan.surface.rect.x, u - du), u1 = min(plan.surface.rect.x + plan.surface.rect.z, u + du)
            let v0 = max(plan.surface.rect.y, v - dv), v1 = min(plan.surface.rect.y + plan.surface.rect.w, v + dv)
            let dx = ((backdropHeight(plan, u: u1, v: v) ?? y) - (backdropHeight(plan, u: u0, v: v) ?? y)) / max((u1 - u0) * width, 0.000001)
            let dz = ((backdropHeight(plan, u: u, v: v1) ?? y) - (backdropHeight(plan, u: u, v: v0) ?? y)) / max((v1 - v0) * depthExtent, 0.000001)
            vertices.advanced(by: index).initialize(to: RidgeVertex(position: SIMD3((u - 0.5) * width, sample ?? .nan, (v - 0.5) * depthExtent), normal: simd_normalize(SIMD3(-dx, 1, -dz)), uv: SIMD2(u, v)))
        }
        for (row, v) in plan.gridV.enumerated() {
            try Task.checkCancellation()
            for (column, u) in plan.gridU.enumerated() {
                if let index = plan.layout.index(row: row, column: column) { writeVertex(index, u, v) }
            }
        }
        for seam in plan.seams.values {
            try Task.checkCancellation()
            for (index, coordinate) in seam.coordinates.enumerated() {
                let u = seam.edge < 2 ? coordinate : (seam.edge == 2 ? plan.inner.rect.x : plan.inner.rect.x + plan.inner.rect.z)
                let v = seam.edge >= 2 ? coordinate : (seam.edge == 0 ? plan.inner.rect.y : plan.inner.rect.y + plan.inner.rect.w)
                writeVertex(seam.firstVertex + index, u, v)
            }
        }
        func visitTriangles(_ body: (Int, UInt32, UInt32, UInt32) -> Void) throws {
            func triangle(_ group: Int, _ a: Int, _ b: Int, _ c: Int) {
                if valid[a] && valid[b] && valid[c] { body(group, UInt32(a), UInt32(b), UInt32(c)) }
            }
            for row in 0..<(plan.gridV.count - 1) {
                try Task.checkCancellation()
                let v = (plan.gridV[row] + plan.gridV[row + 1]) / 2
                let rowTextures = plan.textureRects.indices.filter { v >= plan.textureRects[$0].y && v <= plan.textureRects[$0].y + plan.textureRects[$0].w }
                for column in 0..<(columns - 1) {
                    let u = (plan.gridU[column] + plan.gridU[column + 1]) / 2
                    if inside(u, v, rect: plan.inner.rect) { continue }
                    let group = rowTextures.first { u >= plan.textureRects[$0].x && u <= plan.textureRects[$0].x + plan.textureRects[$0].z } ?? plan.textureRects.count
                    visitBackdropCell(plan, row: row, column: column) { a, b, c in
                        triangle(group, a, b, c)
                    }
                }
            }
        }
        var counts = [Int](repeating: 0, count: plan.textureRects.count + 1)
        try visitTriangles { group, _, _, _ in counts[group] += 3 }
        var buffers = [MTLBuffer?](repeating: nil, count: counts.count)
        var writers = [UnsafeMutablePointer<UInt32>?](repeating: nil, count: counts.count)
        for index in counts.indices where counts[index] > 0 {
            try Task.checkCancellation()
            let buffer = try makeTerrainBuffer(count: counts[index], stride: MemoryLayout<UInt32>.stride, label: "Surrounding terrain texture section")
            buffers[index] = buffer; writers[index] = buffer.contents().bindMemory(to: UInt32.self, capacity: counts[index])
        }
        var offsets = [Int](repeating: 0, count: counts.count)
        try visitTriangles { group, a, b, c in
            guard let writer = writers[group] else { return }
            let offset = offsets[group]
            writer.advanced(by: offset).initialize(to: a); writer.advanced(by: offset + 1).initialize(to: b); writer.advanced(by: offset + 2).initialize(to: c)
            offsets[group] += 3
        }
        valid.removeAll(keepingCapacity: false)
        let loader = MTKTextureLoader(device: device)
        let mapTextures = terrain.cartography == nil ? plan.source.metadata.textures : []
        var textures: [MTLTexture?] = Array(repeating: nil, count: mapTextures.count)
        for (index, metadata) in mapTextures.enumerated() {
            try Task.checkCancellation()
            // A map tile completely covered by the inner terrain has no draw.
            // Keep its geographic index, but do not allocate an unused texture.
            guard counts[index] > 0 else { continue }
            let texture = try autoreleasepool {
                try loader.newTexture(URL: plan.source.textureURLs[index], options: [.generateMipmaps: true, .SRGB: true,
                    .origin: MTKTextureLoader.Origin.topLeft.rawValue, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                    .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)])
            }
            texture.label = metadata.file; textures[index] = texture
        }
        try Task.checkCancellation()
        var draws: [TerrainDraw] = []
        for index in buffers.indices {
            guard let buffer = buffers[index] else { continue }
            draws.append(TerrainDraw(indices: buffer, count: counts[index], texture: index < textures.count ? (textures[index] ?? fallbackTexture) : fallbackTexture,
                                     rect: index < plan.textureRects.count ? plan.textureRects[index] : SIMD4(0, 0, 1, 1)))
        }
        return BackdropMesh(plan: plan, vertices: vertexBuffer, draws: draws)
    }


    /// The picker and GPU index writer share this exact compact-ring topology.
    private func visitBackdropCell(_ plan: BackdropPlan, row: Int, column: Int, _ body: (Int, Int, Int) -> Void) {
        guard let a = plan.layout.index(row: row, column: column), let b = plan.layout.index(row: row, column: column + 1),
              let c = plan.layout.index(row: row + 1, column: column), let d = plan.layout.index(row: row + 1, column: column + 1) else { return }
        if let seam = plan.seams[row * plan.gridU.count + column], !seam.coordinates.isEmpty {
            let anchor: Int, start: Int, end: Int, opposite: Int
            switch seam.edge {
            case 0: (anchor, start, end, opposite) = (a, c, d, b)
            case 1: (anchor, start, end, opposite) = (c, a, b, d)
            case 2: (anchor, start, end, opposite) = (a, b, d, c)
            default: (anchor, start, end, opposite) = (b, a, c, d)
            }
            let reverse = seam.edge == 1 || seam.edge == 2
            var previous = start
            for offset in 0...seam.coordinates.count {
                let next = offset == seam.coordinates.count ? end : seam.firstVertex + offset
                if reverse { body(anchor, next, previous) }
                else { body(anchor, previous, next) }
                previous = next
            }
            if reverse { body(anchor, opposite, end) }
            else { body(anchor, end, opposite) }
        } else {
            body(a, c, b); body(b, c, d)
        }
    }

    private func makeTerrainBuffer(count: Int, stride: Int, label: String) throws -> MTLBuffer {
        let bytes = count.multipliedReportingOverflow(by: stride)
        guard count > 0, !bytes.overflow, bytes.partialValue <= device.maxBufferLength,
              let buffer = device.makeBuffer(length: bytes.partialValue, options: .storageModeShared) else {
            throw TerrainRenderError.unavailable("There is not enough memory for this terrain's geometry. Choose a smaller area or coarser resolution.")
        }
        buffer.label = label
        return buffer
    }

    private func uniqueSorted(_ values: [Float]) -> [Float] {
        var result: [Float] = []
        for value in values.sorted() where result.last.map({ abs($0 - value) > 0.0000001 }) ?? true { result.append(value) }
        return result
    }

    private func buildSides() {
        var vertices: [RidgeVertex] = []; var indices: [UInt32] = []
        func side(_ points: [SIMD2<Float>], normal: SIMD3<Float>) {
            for pair in zip(points, points.dropFirst()) {
                guard let a = position(u: pair.0.x, v: pair.0.y), let b = position(u: pair.1.x, v: pair.1.y) else { continue }
                appendQuad([a, b, SIMD3(b.x, bottom, b.z), SIMD3(a.x, bottom, a.z)], normal: normal, vertices: &vertices, indices: &indices)
            }
        }
        side(gridU.map { SIMD2($0, 0) }, normal: SIMD3(0, 0, -1))
        side(gridU.map { SIMD2($0, 1) }, normal: SIMD3(0, 0, 1))
        side(gridV.map { SIMD2(0, $0) }, normal: SIMD3(-1, 0, 0))
        side(gridV.map { SIMD2(1, $0) }, normal: SIMD3(1, 0, 0))
        appendQuad([SIMD3(-width / 2, bottom, -depthExtent / 2), SIMD3(width / 2, bottom, -depthExtent / 2), SIMD3(width / 2, bottom, depthExtent / 2), SIMD3(-width / 2, bottom, depthExtent / 2)], normal: SIMD3(0, -1, 0), vertices: &vertices, indices: &indices)
        sides = makeMesh(vertices, indices, label: "Closed relief sides and base")
    }

    private func buildShadow() {
        var vertices: [RidgeVertex] = []; var indices: [UInt32] = []
        let w = width * 0.65, d = depthExtent * 0.65
        appendQuad([SIMD3(-w, bottom - 0.001, -d), SIMD3(w, bottom - 0.001, -d), SIMD3(w, bottom - 0.001, d), SIMD3(-w, bottom - 0.001, d)], normal: SIMD3(0, 1, 0), vertices: &vertices, indices: &indices)
        shadow = makeMesh(vertices, indices, label: "Soft relief shadow")
    }

    @MainActor
    func setRoute(_ route: [RoutePoint], waypoints: [RouteWaypoint], selectedPoint: GeoPoint?, segments: [[RoutePoint]] = []) {
        if route != self.route || waypoints != self.waypoints || segments != routeSegments {
            self.route = route; self.waypoints = waypoints; routeSegments = segments
            buildRoute()
            buildMarkers()
            view?.setNeedsDisplay()
        }
        if selectedPoint != self.selectedPoint {
            self.selectedPoint = selectedPoint
            buildSelection()
            view?.setNeedsDisplay()
        }
    }

    @MainActor
    private func buildAreaBoundary() {
        guard !backdrops.isEmpty else { areaBoundary = nil; return }
        let edges = [gridU.map { SIMD2($0, 0) }, gridU.map { SIMD2($0, 1) },
                     gridV.map { SIMD2(0, $0) }, gridV.map { SIMD2(1, $0) }]
        let hasSurroundings = [outerContextRect.y < -0.000001, outerContextRect.y + outerContextRect.w > 1.000001,
                               outerContextRect.x < -0.000001, outerContextRect.x + outerContextRect.z > 1.000001]
        var paths: [[SIMD3<Float>]] = []
        for (index, edge) in edges.enumerated() where hasSurroundings[index] {
            var path: [SIMD3<Float>] = []
            for uv in edge {
                if let p = position(u: uv.x, v: uv.y) { path.append(p) }
                else if !path.isEmpty { paths.append(path); path = [] }
            }
            if !path.isEmpty { paths.append(path) }
        }
        areaBoundary = ribbon(dashed(paths, on: worldUnitsPerPoint * 9, off: worldUnitsPerPoint * 7), halfWidth: worldUnitsPerPoint * 1.1, lift: max(0.6, Float(terrain.level.spacing) * 0.08) / metersPerUnit, label: "Selected planning area edge")
    }

    @MainActor
    private func buildRoute() {
        let source = routeSegments.isEmpty ? [route] : routeSegments
        let routeDistance = source.reduce(0.0) { sum, segment in
            sum + zip(segment, segment.dropFirst()).reduce(0.0) { total, pair in
                guard pair.0.coordinate.isValid, pair.1.coordinate.isValid else { return total }
                return total + pair.0.coordinate.distance(to: pair.1.coordinate)
            }
        }
        let step = max(Double(terrain.level.spacing), Double(metersPerUnit) / 1_200, routeDistance / 18_000)
        var paths: [[SIMD3<Float>]] = [], overview: [[SIMD3<Float>]] = []
        for segment in source where segment.count > 1 {
            var current: [SIMD3<Float>] = []
            var currentDetail = true
            func flush() {
                if current.count > 1 {
                    if currentDetail { paths.append(current) } else { overview.append(current) }
                }
                current = []
            }
            for pair in zip(segment, segment.dropFirst()) {
                let sections = RouteEngine.coverageSections(from: pair.0.coordinate, to: pair.1.coordinate, bounds: terrain.manifest.bounds)
                if sections.isEmpty { flush(); continue }
                for section in sections {
                    if section.detailed != currentDetail { flush(); currentDetail = section.detailed }
                    let count = max(1, min(18_000, Int(ceil(section.from.distance(to: section.to) / step))))
                    for sample in 0...count {
                        let t = Double(sample) / Double(count)
                        let point = GeoPoint(latitude: section.from.latitude + (section.to.latitude - section.from.latitude) * t,
                                             longitude: section.from.longitude + (section.to.longitude - section.from.longitude) * t)
                        let p = section.detailed ? position(point) : scenePosition(point)
                        if let p {
                            if (current.last.map({ simd_distance($0, p) * metersPerUnit >= Float(step) * 0.5 }) ?? true) || sample == count {
                                current.append(p)
                            }
                        } else { flush() }
                    }
                }
            }
            flush()
        }
        let halfWidth = max(routeWidth, worldUnitsPerPoint * 3.2) / 2
        let lift = max(1.3, Float(terrain.level.spacing) * 0.2) / metersPerUnit
        routeHalo = ribbon(paths, halfWidth: halfWidth * 1.9, lift: lift, label: "Route cream casing")
        routeInk = ribbon(paths, halfWidth: halfWidth, lift: lift + 0.3 / metersPerUnit, label: "Route coral ink")
        overviewRoute = sceneRibbon(dashed(overview, on: worldUnitsPerPoint * 10, off: worldUnitsPerPoint * 7),
                                    halfWidth: halfWidth, liftMeters: 2, label: "Overview route dashes")
    }

    @MainActor
    private var coverageBoundaryOpacity: Float {
        if coverageEditing { return 0.62 }
        let x = abs(coverageFocus?.x ?? camera.target.x), z = abs(coverageFocus?.y ?? camera.target.z)
        let outside = SIMD2(max(0, x - width / 2), max(0, z - depthExtent / 2))
        let distance = simd_length(outside) > 0 ? simd_length(outside) : min(width / 2 - x, depthExtent / 2 - z)
        let threshold = max(250 / metersPerUnit, camera.distance * 0.4)
        return 0.62 * max(0, min(1, 1 - distance / threshold))
    }

    /// Screen-sized dashes with a fixed geometry ceiling at extreme zoom levels.
    private func dashed(_ paths: [[SIMD3<Float>]], on: Float, off: Float) -> [[SIMD3<Float>]] {
        let length = paths.reduce(Float(0)) { sum, path in sum + zip(path, path.dropFirst()).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) } }
        let scale = max(1, length / max(0.00001, (on + off) * 5000))
        let dash = max(0.000001, on * scale), gap = max(0.000001, off * scale)
        var output: [[SIMD3<Float>]] = []
        for path in paths {
            var drawing = true, remaining = dash
            var current: [SIMD3<Float>] = []
            for (a, b) in zip(path, path.dropFirst()) {
                let distance = simd_distance(a, b)
                guard distance > 0.0000001 else { continue }
                var travelled: Float = 0
                while travelled < distance {
                    let amount = min(remaining, distance - travelled)
                    let start = a + (b - a) * (travelled / distance)
                    travelled += amount
                    let end = a + (b - a) * (travelled / distance)
                    if drawing { if current.isEmpty { current.append(start) }; current.append(end) }
                    remaining -= amount
                    if remaining < 0.0000001 {
                        if drawing, current.count > 1 { output.append(current); current = [] }
                        drawing.toggle(); remaining = drawing ? dash : gap
                    }
                    if amount <= 0 { break }
                }
            }
            if current.count > 1 { output.append(current) }
        }
        return output
    }

    @MainActor
    private func ribbon(_ paths: [[SIMD3<Float>]], halfWidth: Float, lift: Float, label: String) -> RidgeMesh? {
        var vertices: [RidgeVertex] = []; var indices: [UInt32] = []
        for path in paths where path.count > 1 {
            let start = UInt32(vertices.count)
            for i in path.indices {
                let previous = path[max(0, i - 1)], next = path[min(path.count - 1, i + 1)]
                var direction = SIMD3(next.x - previous.x, 0, next.z - previous.z)
                if simd_length_squared(direction) < 0.0000000001 { direction = SIMD3(1, 0, 0) }
                direction = simd_normalize(direction)
                let across = SIMD3(-direction.z, 0, direction.x) * halfWidth
                for sign: Float in [-1, 1] {
                    var p = path[i] + across * sign
                    p.x = min(width / 2, max(-width / 2, p.x)); p.z = min(depthExtent / 2, max(-depthExtent / 2, p.z))
                    p.y = max(p.y, height(u: p.x / width + 0.5, v: p.z / depthExtent + 0.5) ?? p.y) + lift
                    vertices.append(RidgeVertex(position: p, normal: SIMD3(0, 1, 0), uv: .zero))
                }
                if i > 0 {
                    let a = start + UInt32((i - 1) * 2)
                    indices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
                }
            }
        }
        return makeMesh(vertices, indices, label: label)
    }

    @MainActor
    private func buildMarkers() {
        var vertices: [RidgeVertex] = []; var indices: [UInt32] = []
        for (index, waypoint) in waypoints.prefix(1_000).enumerated() {
            guard var p = scenePosition(waypoint.point.coordinate) else { continue }
            p.y += 0.4 / metersPerUnit
            appendQuad([p, p, p, p], normal: SIMD3(Float(index), 1, 0), vertices: &vertices, indices: &indices, billboard: true)
        }
        markers = makeMesh(vertices, indices, label: "Route waypoint markers")
    }

    @MainActor
    private func buildSelection() {
        guard let selectedPoint, var p = scenePosition(selectedPoint) else { selection = nil; return }
        p.y += 0.5 / metersPerUnit
        var vertices: [RidgeVertex] = []; var indices: [UInt32] = []
        appendQuad([p, p, p, p], normal: SIMD3(1, 1, 0), vertices: &vertices, indices: &indices, billboard: true)
        selection = makeMesh(vertices, indices, label: "Elevation inspection ring")
    }

    @MainActor
    func setExtension(bounds: GeoBounds?, grid: TerrainGrid?) {
        guard bounds != extensionBounds || grid != extensionGrid else { return }
        extensionBounds = bounds
        extensionGrid = grid
        buildExtension()
        view?.setNeedsDisplay()
    }

    @MainActor
    private func buildExtension() {
        extensionBoundary = nil; extensionCells = nil
        guard let bounds = extensionBounds, bounds.isValid else { return }
        let rect = normalizedRect(bounds)
        // Preview only the area perimeter; storage tiles are an internal detail.
        let samples = 512
        var edges: [[SIMD3<Float>]] = []
        func line(from a: SIMD2<Float>, to b: SIMD2<Float>) -> [[SIMD3<Float>]] {
            var segments: [[SIMD3<Float>]] = [], path: [SIMD3<Float>] = []
            for i in 0...samples {
                let uv = a + (b - a) * (Float(i) / Float(samples))
                if let y = exactSceneHeight(u: uv.x, v: uv.y) {
                    path.append(SIMD3((uv.x - 0.5) * width, y, (uv.y - 0.5) * depthExtent))
                } else if !path.isEmpty { segments.append(path); path = [] }
            }
            if !path.isEmpty { segments.append(path) }
            return segments
        }
        for u in [rect.x, rect.x + rect.z] {
            edges += line(from: SIMD2(u, rect.y), to: SIMD2(u, rect.y + rect.w))
        }
        for v in [rect.y, rect.y + rect.w] {
            edges += line(from: SIMD2(rect.x, v), to: SIMD2(rect.x + rect.z, v))
        }
        extensionBoundary = sceneRibbon(edges, halfWidth: worldUnitsPerPoint * 1.6, liftMeters: 2.5, label: "Proposed planning area")
        extensionCells = nil
    }

    @MainActor
    private func sceneRibbon(_ paths: [[SIMD3<Float>]], halfWidth: Float, liftMeters: Float, label: String) -> RidgeMesh? {
        var vertices: [RidgeVertex] = [], indices: [UInt32] = []
        for path in paths where path.count > 1 {
            var previous: UInt32?
            for index in path.indices {
                let point = path[index], before = path[max(0, index - 1)], after = path[min(path.count - 1, index + 1)]
                let delta = SIMD2(after.x - before.x, after.z - before.z)
                guard simd_length_squared(delta) > 0.0000000001 else { previous = nil; continue }
                let direction = simd_normalize(delta)
                let across = SIMD3(-direction.y, 0, direction.x) * halfWidth
                var pair: [SIMD3<Float>] = []
                for sign: Float in [-1, 1] {
                    var p = point + across * sign
                    guard let elevation = exactSceneHeight(u: p.x / width + 0.5, v: p.z / depthExtent + 0.5) else { break }
                    p.y = elevation + liftMeters / metersPerUnit
                    pair.append(p)
                }
                guard pair.count == 2 else { previous = nil; continue }
                let current = UInt32(vertices.count)
                for p in pair { vertices.append(RidgeVertex(position: p, normal: SIMD3(0, 1, 0), uv: .zero)) }
                if let previous, !sceneContainsNoData || sceneQuadIsCovered([vertices[Int(previous)].position, vertices[Int(previous) + 1].position] + pair) {
                    indices += [previous, previous + 1, current, previous + 1, current + 1, current]
                }
                previous = current
            }
        }
        return makeMesh(vertices, indices, label: label)
    }

    /// If a source has holes, omit an overlay segment touching any missing cell.
    /// This conservative check prevents a sparse preview ribbon bridging NoData.
    private func sceneQuadIsCovered(_ points: [SIMD3<Float>]) -> Bool {
        let u = points.map { $0.x / width + 0.5 }, v = points.map { $0.z / depthExtent + 0.5 }
        guard let minU = u.min(), let maxU = u.max(), let minV = v.min(), let maxV = v.max() else { return false }
        func checkGrid(_ gridU: [Float], _ gridV: [Float], _ valid: (Int, Int) -> Bool) -> Bool {
            guard maxU >= gridU[0], minU <= gridU[gridU.count - 1], maxV >= gridV[0], minV <= gridV[gridV.count - 1] else { return true }
            for row in cell(in: gridV, value: minV)...cell(in: gridV, value: maxV) {
                for column in cell(in: gridU, value: minU)...cell(in: gridU, value: maxU) {
                    if !valid(row, column) { return false }
                }
            }
            return true
        }
        if let terrainVertices {
            let vertices = terrainVertices.contents().assumingMemoryBound(to: RidgeVertex.self)
            if !checkGrid(gridU, gridV, { row, column in
                let a = row * gridU.count + column
                return [a, a + 1, a + gridU.count, a + gridU.count + 1].allSatisfy { vertices[$0].position.y.isFinite }
            }) { return false }
        }
        for mesh in backdrops {
            let plan = mesh.plan, vertices = mesh.vertices.contents().assumingMemoryBound(to: RidgeVertex.self)
            if !checkGrid(plan.gridU, plan.gridV, { row, column in
                if inside((plan.gridU[column] + plan.gridU[column + 1]) / 2, (plan.gridV[row] + plan.gridV[row + 1]) / 2, rect: plan.inner.rect) { return true }
                var valid = true
                visitBackdropCell(plan, row: row, column: column) { a, b, c in
                    valid = valid && vertices[a].position.y.isFinite && vertices[b].position.y.isFinite && vertices[c].position.y.isFinite
                }
                return valid
            }) { return false }
        }
        return true
    }

    private func appendQuad(_ points: [SIMD3<Float>], normal: SIMD3<Float>, vertices: inout [RidgeVertex], indices: inout [UInt32], billboard: Bool = false) {
        let offset = UInt32(vertices.count)
        let uv: [SIMD2<Float>] = billboard ? [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)] : [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        for i in 0..<4 { vertices.append(RidgeVertex(position: points[i], normal: normal, uv: uv[i])) }
        indices.append(contentsOf: [offset, offset + 1, offset + 2, offset, offset + 2, offset + 3])
    }

    private func makeBuffer<T>(_ values: [T], label: String) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        let buffer = values.withUnsafeBytes { bytes in device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared) }
        buffer?.label = label
        return buffer
    }

    private func makeMesh(_ vertices: [RidgeVertex], _ indices: [UInt32], label: String) -> RidgeMesh? {
        guard let v = makeBuffer(vertices, label: label), let i = makeBuffer(indices, label: label + " indices") else { return nil }
        return RidgeMesh(vertices: v, indices: i, count: indices.count)
    }

    private func height(u: Float, v: Float) -> Float? {
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        let columns = terrain.level.width, rows = terrain.level.height
        let x = u * Float(columns - 1), y = v * Float(rows - 1)
        let x0 = min(columns - 1, Int(x)), y0 = min(rows - 1, Int(y))
        let x1 = min(columns - 1, x0 + 1), y1 = min(rows - 1, y0 + 1)
        let a = terrain.heights[y0 * columns + x0], b = terrain.heights[y0 * columns + x1]
        let c = terrain.heights[y1 * columns + x0], d = terrain.heights[y1 * columns + x1]
        guard a.isFinite, b.isFinite, c.isFinite, d.isFinite else { return nil }
        let tx = x - Float(x0), ty = y - Float(y0)
        return ((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty - minimumHeight) / metersPerUnit
    }

    private func position(u: Float, v: Float) -> SIMD3<Float>? {
        guard let y = height(u: u, v: v) else { return nil }
        return SIMD3((u - 0.5) * width, y, (v - 0.5) * depthExtent)
    }

    private func position(_ point: GeoPoint) -> SIMD3<Float>? {
        guard terrain.manifest.bounds.contains(point) else { return nil }
        let uv = terrain.manifest.bounds.uv(point)
        return position(u: Float(uv.u), v: Float(uv.v))
    }

    @MainActor
    private var worldUnitsPerPoint: Float {
        2 * camera.distance * tan(fieldOfView / 2) / max(1, Float(viewportSize.height))
    }

    @MainActor
    var navigationState: TerrainNavigationState {
        let frame = TerrainNavigationFrame(bounds: terrain.manifest.bounds, minimumElevationMeters: Double(minimumHeight))
        let pose = frame.pose(target: camera.target, yaw: camera.yaw, pitch: camera.pitch, distance: camera.distance)
        let viewed = view.flatMap { pick(at: CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) } ?? pose.target
        let uv = terrain.manifest.bounds.uv(viewed)
        coverageFocus = SIMD2((Float(uv.u) - 0.5) * width, (Float(uv.v) - 0.5) * depthExtent)
        let inside = terrain.manifest.bounds.contains(viewed)
        let spacing: Int?
        if exactSceneHeight(u: Float(uv.u), v: Float(uv.v)) == nil { spacing = nil }
        else if inside { spacing = terrain.level.spacing }
        else { spacing = (terrain.horizon?.layers ?? []).first { $0.metadata.bounds.contains(viewed) }?.level.spacing }
        return TerrainNavigationState(pose: pose, spacing: spacing, insidePlanningArea: inside, viewedPoint: viewed)
    }

    private func scenePosition(_ point: GeoPoint) -> SIMD3<Float>? {
        guard point.isValid else { return nil }
        let uv = terrain.manifest.bounds.uv(point), u = Float(uv.u), v = Float(uv.v)
        guard let y = exactSceneHeight(u: u, v: v) else { return nil }
        return SIMD3((u - 0.5) * width, y, (v - 0.5) * depthExtent)
    }

    private func exactSceneHeight(u: Float, v: Float) -> Float? {
        let origin = SIMD3((u - 0.5) * width, sceneTop + 1, (v - 0.5) * depthExtent)
        guard let hit = sceneIntersection(origin: origin, direction: SIMD3(0, -1, 0)) else { return nil }
        return origin.y - hit
    }

    @MainActor
    private func homeCamera() -> RidgeCamera {
        let size = viewportSize
        let aspect = Float(size.width > 1 ? size.width : 390) / Float(size.height > 1 ? size.height : 844)
        let yaw: Float = -0.38, pitch: Float = backdrops.isEmpty ? 0.94 : 20 * .pi / 180
        let target = SIMD3<Float>(0, primaryFloor + (top - primaryFloor) * 0.35, 0)
        let backward = SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let cameraRight = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), backward))
        let cameraUp = simd_cross(backward, cameraRight)
        let tanVertical = tan(fieldOfView / 2), tanHorizontal = tanVertical * max(aspect, 0.1)
        var distance: Float = 0
        // Fit all eight relief-box corners in perspective. A near corner projects
        // larger than a far one, so fitting only the map's flat width clips edges.
        for x in [-width / 2, width / 2] {
            for y in [backdrops.isEmpty ? bottom : primaryFloor, top] {
                for z in [-depthExtent / 2, depthExtent / 2] {
                    let relative = SIMD3(x, y, z) - target
                    let forwardOffset = simd_dot(relative, backward)
                    distance = max(distance,
                                   forwardOffset + abs(simd_dot(relative, cameraRight)) / tanHorizontal,
                                   forwardOffset + abs(simd_dot(relative, cameraUp)) / tanVertical)
                }
            }
        }
        return RidgeCamera(target: target, yaw: yaw, pitch: pitch, distance: max(0.4, distance) * 1.08)
    }

    @MainActor
    func orbit(dx: Float, dy: Float) {
        guard dx.isFinite, dy.isFinite, abs(dx) + abs(dy) > 0.01 else { return }
        cancelAnimation()
        framedAtHome = false
        camera.yaw -= dx * 0.006
        camera.pitch += dy * 0.005
        constrainCamera()
        view?.setNeedsDisplay()
    }

    @MainActor
    func pan(dx: Float, dy: Float) {
        guard dx.isFinite, dy.isFinite, abs(dx) + abs(dy) > 0.01 else { return }
        cancelAnimation()
        framedAtHome = false
        let right = SIMD3(cos(camera.yaw), 0, -sin(camera.yaw))
        let forward = SIMD3(-sin(camera.yaw), 0, -cos(camera.yaw))
        camera.target += (-right * dx + forward * dy / max(sin(camera.pitch), 0.4)) * worldUnitsPerPoint
        constrainTarget()
        if let elevation = exactSceneHeight(u: camera.target.x / width + 0.5, v: camera.target.z / depthExtent + 0.5) {
            camera.target.y = elevation + 12 / metersPerUnit
        }
        constrainCamera()
        view?.setNeedsDisplay()
    }

    @MainActor
    func zoom(by scale: Float) {
        guard scale.isFinite && scale > 0 && abs(scale - 1) > 0.0001 else { return }
        cancelAnimation()
        framedAtHome = false
        camera.distance /= scale
        constrainCamera()
        view?.setNeedsDisplay()
    }

    @MainActor
    private func constrainTarget() {
        let frame = TerrainNavigationFrame(bounds: terrain.manifest.bounds, minimumElevationMeters: Double(minimumHeight))
        let coverage = terrain.horizon?.layers.last?.metadata.bounds ?? terrain.manifest.bounds
        camera.target = frame.clampedTarget(camera.target, coverage: coverage)
    }

    @MainActor
    private func constrainCamera() {
        camera.pitch = min(86 * .pi / 180, max((backdrops.isEmpty ? 26 : 16) * .pi / 180, camera.pitch))
        constrainTarget()
        // Context scenes use the terrain under the eye below. A newly detailed
        // distant summit must not move an otherwise unchanged geographic camera.
        let clearance = backdrops.isEmpty ? max(0.06, (top + 0.016 - camera.target.y) / sin(camera.pitch)) : max(0.06, 12 / metersPerUnit)
        // Bound raster enlargement to 1.6 logical screen points per source texel.
        // Labels, route ink and pins are rendered separately at screen resolution.
        let point = terrain.manifest.bounds.point(u: Double(camera.target.x / width + 0.5), v: Double(camera.target.z / depthExtent + 0.5))
        let contextMap = terrain.manifest.bounds.contains(point) ? nil : (terrain.horizon?.layers ?? []).first { $0.metadata.bounds.contains(point) }?.metadata.textures.first { $0.bounds.contains(point) }
        let texel = cartography.map { $0.nativeMetersPerTexel(at: point) / metersPerUnit }
            ?? contextMap.map { max(Float($0.bounds.widthMeters) / Float($0.width), Float($0.bounds.depthMeters) / Float($0.height)) / metersPerUnit }
            ?? mapUnitsPerTexel
        let textureDistance = texel * Float(max(1, viewportSize.height)) / (2 * tan(fieldOfView / 2) * 1.6)
        let minimum = max(clearance, textureDistance)
        camera.distance = min(max(homeCamera().distance * 1.55, 2.5, minimum * 1.1), max(minimum, camera.distance))
        // A low oblique view may put the camera over a surrounding ridge. Lift
        // its orbit only as needed at the eye position, rather than forcing a
        // valley scene above every distant summit in the saved surroundings.
        if !contextSurfaces.isEmpty {
            for _ in 0..<12 {
                let eye = camera.target + camera.distance * SIMD3(sin(camera.yaw) * cos(camera.pitch), sin(camera.pitch), cos(camera.yaw) * cos(camera.pitch))
                guard let elevation = sceneHeight(u: eye.x / width + 0.5, v: eye.z / depthExtent + 0.5), eye.y < elevation + 12 / metersPerUnit else { break }
                camera.distance += (elevation + 12 / metersPerUnit - eye.y) / sin(camera.pitch)
            }
            // This bound is finite even for steep terrain or partial coverage.
            let absoluteClearance = max(0, sceneTop + 12 / metersPerUnit - camera.target.y) / sin(camera.pitch)
            let eye = camera.target + camera.distance * SIMD3(sin(camera.yaw) * cos(camera.pitch), sin(camera.pitch), cos(camera.yaw) * cos(camera.pitch))
            if let elevation = sceneHeight(u: eye.x / width + 0.5, v: eye.z / depthExtent + 0.5), eye.y < elevation + 12 / metersPerUnit {
                camera.distance = max(camera.distance, absoluteClearance)
            }
            camera.distance = min(max(camera.distance, minimum), max(homeCamera().distance * 3, absoluteClearance + 1))
        }
    }

    @MainActor
    func perform(_ action: TerrainCameraCommand.Action) {
        framedAtHome = action == .home
        var destination = camera
        switch action {
        case .home: destination = homeCamera()
        case .north: destination.yaw = camera.yaw + shortestAngle(from: camera.yaw, to: 0)
        case .overhead: destination.pitch = 86 * .pi / 180; destination.yaw = camera.yaw + shortestAngle(from: camera.yaw, to: 0)
        case .zoomIn: destination.distance /= 1.5
        case .zoomOut: destination.distance *= 1.5
        case .focus(let point):
            guard let p = scenePosition(point) else { return }
            destination.target = p + SIMD3(0, 0.012, 0)
            destination.distance = min(camera.distance, 0.5)
        case .restore(let pose):
            let frame = TerrainNavigationFrame(bounds: terrain.manifest.bounds, minimumElevationMeters: Double(minimumHeight))
            let distance = Float(pose.distanceMeters / frame.metersPerUnit)
            guard let target = frame.target(for: pose), distance.isFinite, distance > 0 else { return }
            cancelAnimation()
            camera = RidgeCamera(target: target, yaw: pose.yaw, pitch: pose.pitch, distance: distance)
            constrainCamera()
            view?.setNeedsDisplay()
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            cancelAnimation(); camera = destination; constrainCamera(); view?.setNeedsDisplay(); return
        }
        cancelAnimation()
        animation = (camera, destination, CACurrentMediaTime())
        let proxy = TerrainFrameProxy(renderer: self)
        let link = CADisplayLink(target: proxy, selector: #selector(TerrainFrameProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @MainActor
    fileprivate func animationFrame() {
        guard let animation else { cancelAnimation(); return }
        let t = min(1, Float((CACurrentMediaTime() - animation.time) / 0.48))
        let s = t * t * (3 - 2 * t)
        camera.target = simd_mix(animation.start.target, animation.end.target, SIMD3(repeating: s))
        camera.yaw = animation.start.yaw + (animation.end.yaw - animation.start.yaw) * s
        camera.pitch = animation.start.pitch + (animation.end.pitch - animation.start.pitch) * s
        camera.distance = animation.start.distance + (animation.end.distance - animation.start.distance) * s
        constrainCamera()
        view?.setNeedsDisplay()
        if t >= 1 { cancelAnimation() }
    }

    @MainActor
    private func cancelAnimation() { displayLink?.invalidate(); displayLink = nil; animation = nil }
    private func shortestAngle(from: Float, to: Float) -> Float { atan2(sin(to - from), cos(to - from)) }

    @MainActor
    private func updateMatrices() {
        let aspect = Float(max(1, viewportSize.width) / max(1, viewportSize.height))
        let eye = camera.target + camera.distance * SIMD3(sin(camera.yaw) * cos(camera.pitch), sin(camera.pitch), cos(camera.yaw) * cos(camera.pitch))
        let backward = simd_normalize(eye - camera.target)
        right = simd_normalize(simd_cross(SIMD3(0, 1, 0), backward))
        up = simd_cross(backward, right)
        let look = simd_float4x4(columns: (
            SIMD4(right.x, up.x, backward.x, 0), SIMD4(right.y, up.y, backward.y, 0), SIMD4(right.z, up.z, backward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye), -simd_dot(backward, eye), 1)))
        let extent = max(abs(outerContextRect.x * width), abs((outerContextRect.x + outerContextRect.z) * width),
                         abs(outerContextRect.y * depthExtent), abs((outerContextRect.y + outerContextRect.w) * depthExtent))
        let near: Float = 0.002, far: Float = max(16, extent * 3 + camera.distance * 2 + sceneTop * 2)
        let ys = 1 / tan(fieldOfView / 2), xs = ys / max(aspect, 0.1), zs = far / (near - far)
        let projection = simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, near * zs, 0)))
        viewProjection = projection * look
    }

    /// Geographic labels stay native and sharp. Peaks hidden by nearer terrain
    /// are culled before UIKit performs its small screen-space collision pass.
    @MainActor
    func projectedPoint(_ point: GeoPoint) -> CGPoint? {
        guard let view, var p = position(point) else { return nil }
        p.y += max(0.0012, 3 / metersPerUnit)
        let clip = viewProjection * SIMD4(p.x, p.y, p.z, 1)
        guard clip.w > 0, clip.z >= 0, clip.z <= clip.w else { return nil }
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        guard abs(ndc.x) < 1.05, abs(ndc.y) < 1.05 else { return nil }
        let eye = camera.target + camera.distance * SIMD3(sin(camera.yaw) * cos(camera.pitch), sin(camera.pitch), cos(camera.yaw) * cos(camera.pitch))
        for i in 1..<64 {
            let t = Float(i) / 64
            let sample = p + (eye - p) * t
            if let h = sceneHeight(u: sample.x / width + 0.5, v: sample.z / depthExtent + 0.5), h > sample.y + 0.001 { return nil }
        }
        return CGPoint(x: CGFloat((ndc.x + 1) / 2) * view.bounds.width, y: CGFloat((1 - ndc.y) / 2) * view.bounds.height)
    }

    /// Visit the exact triangles submitted to Metal and return the closest hit
    /// across all loaded resolutions. A surrounding ridge cannot be picked through.
    @MainActor
    func pick(at location: CGPoint) -> GeoPoint? {
        guard let view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        updateMatrices()
        let inverse = viewProjection.inverse
        let x = Float(location.x / view.bounds.width) * 2 - 1, y = 1 - Float(location.y / view.bounds.height) * 2
        let a = inverse * SIMD4(x, y, 0, 1), b = inverse * SIMD4(x, y, 1, 1)
        let origin = SIMD3(a.x, a.y, a.z) / a.w
        let far = SIMD3(b.x, b.y, b.z) / b.w
        let direction = simd_normalize(far - origin)
        guard let hit = sceneIntersection(origin: origin, direction: direction) else { return nil }
        let p = origin + direction * hit
        let frame = TerrainNavigationFrame(bounds: terrain.manifest.bounds, minimumElevationMeters: Double(minimumHeight))
        return frame.pickedPoint(u: p.x / width + 0.5, v: p.z / depthExtent + 0.5)
    }

    private func sceneIntersection(origin: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
              direction.x.isFinite, direction.y.isFinite, direction.z.isFinite else { return nil }
        var nearest: Float?
        func remember(_ hit: Float?) { if let hit { nearest = min(nearest ?? .infinity, hit) } }
        if let terrainVertices {
            let vertices = terrainVertices.contents().assumingMemoryBound(to: RidgeVertex.self)
            remember(walkGrid(origin: origin, direction: direction, u: gridU, v: gridV) { row, column in
                let a = row * gridU.count + column, b = a + 1, c = a + gridU.count, d = c + 1
                return nearestTriangle(origin: origin, direction: direction, vertices: vertices, triangles: [(a, c, b), (b, c, d)])
            })
        }
        for mesh in backdrops {
            let plan = mesh.plan
            let vertices = mesh.vertices.contents().assumingMemoryBound(to: RidgeVertex.self)
            remember(walkGrid(origin: origin, direction: direction, u: plan.gridU, v: plan.gridV) { row, column in
                let u = (plan.gridU[column] + plan.gridU[column + 1]) / 2
                let v = (plan.gridV[row] + plan.gridV[row + 1]) / 2
                if inside(u, v, rect: plan.inner.rect) { return nil }
                var closest: Float?
                visitBackdropCell(plan, row: row, column: column) { a, b, c in
                    if let hit = triangleIntersection(origin: origin, direction: direction,
                                                      a: vertices[a].position, b: vertices[b].position, c: vertices[c].position) {
                        closest = min(closest ?? .infinity, hit)
                    }
                }
                return closest
            })
        }
        return nearest
    }

    private func nearestTriangle(origin: SIMD3<Float>, direction: SIMD3<Float>, vertices: UnsafePointer<RidgeVertex>, triangles: [(Int, Int, Int)]) -> Float? {
        var nearest: Float?
        for (a, b, c) in triangles {
            if let hit = triangleIntersection(origin: origin, direction: direction,
                                              a: vertices[a].position, b: vertices[b].position, c: vertices[c].position) {
                nearest = min(nearest ?? .infinity, hit)
            }
        }
        return nearest
    }

    /// Bounded 2D grid traversal avoids scanning millions of terrain triangles.
    private func walkGrid(origin: SIMD3<Float>, direction: SIMD3<Float>, u: [Float], v: [Float], hitInCell: (Int, Int) -> Float?) -> Float? {
        guard let firstU = u.first, let lastU = u.last, let firstV = v.first, let lastV = v.last, u.count > 1, v.count > 1,
              let interval = boxIntersection(origin: origin, direction: direction,
                  minimum: SIMD3((firstU - 0.5) * width, -0.00001, (firstV - 0.5) * depthExtent),
                  maximum: SIMD3((lastU - 0.5) * width, sceneTop + 0.00001, (lastV - 0.5) * depthExtent)) else { return nil }
        var t = max(0, interval.0)
        let start = origin + direction * (t + 0.0000001)
        var column = cell(in: u, value: start.x / width + 0.5)
        var row = cell(in: v, value: start.z / depthExtent + 0.5)
        let stepX = direction.x >= 0 ? 1 : -1, stepZ = direction.z >= 0 ? 1 : -1
        for _ in 0..<(u.count + v.count + 8) {
            guard column >= 0, column < u.count - 1, row >= 0, row < v.count - 1, t <= interval.1 + 0.00001 else { return nil }
            if let hit = hitInCell(row, column), hit >= t - 0.00001, hit <= interval.1 + 0.00001 { return hit }
            let boundaryX = (u[stepX > 0 ? column + 1 : column] - 0.5) * width
            let boundaryZ = (v[stepZ > 0 ? row + 1 : row] - 0.5) * depthExtent
            let tx = abs(direction.x) < 0.0000001 ? Float.infinity : (boundaryX - origin.x) / direction.x
            let tz = abs(direction.z) < 0.0000001 ? Float.infinity : (boundaryZ - origin.z) / direction.z
            if !tx.isFinite && !tz.isFinite { return nil }
            if abs(tx - tz) < 0.0000001 { column += stepX; row += stepZ; t = tx }
            else if tx < tz { column += stepX; t = tx }
            else { row += stepZ; t = tz }
        }
        return nil
    }

    private func cell(in coordinates: [Float], value: Float) -> Int {
        var low = 0, high = coordinates.count - 1
        while low + 1 < high { let mid = (low + high) / 2; if coordinates[mid] <= value { low = mid } else { high = mid } }
        return min(coordinates.count - 2, max(0, low))
    }

    private func sceneHeight(u: Float, v: Float) -> Float? {
        if u >= 0, u <= 1, v >= 0, v <= 1 { return height(u: u, v: v) }
        for surface in contextSurfaces {
            if u >= surface.rect.x, u <= surface.rect.x + surface.rect.z, v >= surface.rect.y, v <= surface.rect.y + surface.rect.w {
                return surfaceHeight(surface, u: u, v: v)
            }
        }
        return nil
    }

    private func boxIntersection(origin: SIMD3<Float>, direction: SIMD3<Float>, minimum: SIMD3<Float>, maximum: SIMD3<Float>) -> (Float, Float)? {
        var lo: Float = 0, hi: Float = .infinity
        for axis in 0..<3 {
            if abs(direction[axis]) < 0.0000001 { if origin[axis] < minimum[axis] || origin[axis] > maximum[axis] { return nil }; continue }
            let a = (minimum[axis] - origin[axis]) / direction[axis], b = (maximum[axis] - origin[axis]) / direction[axis]
            lo = max(lo, min(a, b)); hi = min(hi, max(a, b))
            if hi < lo { return nil }
        }
        return (lo, hi)
    }

    private func triangleIntersection(origin: SIMD3<Float>, direction: SIMD3<Float>, a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>) -> Float? {
        guard a.y.isFinite, b.y.isFinite, c.y.isFinite else { return nil }
        let e1 = b - a, e2 = c - a, h = simd_cross(direction, e2)
        let determinant = simd_dot(e1, h)
        guard abs(determinant) > 0.0000000001 else { return nil }
        let inverse = 1 / determinant, s = origin - a
        let u = inverse * simd_dot(s, h)
        guard u >= -0.000001 && u <= 1.000001 else { return nil }
        let q = simd_cross(s, e1), v = inverse * simd_dot(direction, q)
        guard v >= -0.000001 && u + v <= 1.000001 else { return nil }
        let t = inverse * simd_dot(e2, q)
        return t >= 0 ? t : nil
    }
}

@MainActor
private final class TerrainFrameProxy: NSObject {
    weak var renderer: TerrainRenderer?
    init(renderer: TerrainRenderer) { self.renderer = renderer }
    @objc func tick() { renderer?.animationFrame() }
}
