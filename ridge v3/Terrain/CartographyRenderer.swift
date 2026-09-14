import Foundation
import MetalKit
import ImageIO
import CryptoKit
import QuartzCore
import simd

struct CartographyPageRequest: Equatable, Sendable {
    var tile: Int
    var slot: Int
    var generation: UInt64
}

/// Fixed capacity, one pending page, deterministic LRU. This policy knows
/// nothing about terrain resolution or the boundary of a planning area.
struct CartographyPageCache {
    struct Slot {
        var tile: Int? = nil
        var ready = false
        var loadedAt: TimeInterval = 0
        var lastUse: UInt64 = 0
    }
    let tileCount: Int
    private(set) var slots: [Slot]
    private(set) var priorities: [Int] = []
    private(set) var pending: CartographyPageRequest?
    private(set) var failed = Set<Int>()
    private var clock: UInt64 = 0
    private var generation: UInt64 = 0
    static let fadeDuration: TimeInterval = 0.24

    init(tileCount: Int, capacity: Int = CartographyAtlas.maximumResidentImages) {
        self.tileCount = tileCount
        slots = Array(repeating: Slot(), count: min(tileCount, max(0, capacity)))
    }

    mutating func prioritize(_ tiles: [Int]) {
        var seen = Set<Int>()
        priorities = Array(tiles.filter { (0..<tileCount).contains($0) && seen.insert($0).inserted }.prefix(slots.count))
        clock &+= 1
        for index in slots.indices where slots[index].tile.map(priorities.contains) == true { slots[index].lastUse = clock }
    }

    mutating func reserve() -> CartographyPageRequest? {
        guard pending == nil,
              let tile = priorities.first(where: { tile in !failed.contains(tile) && !slots.contains(where: { $0.tile == tile }) }) else { return nil }
        let slot = slots.firstIndex(where: { $0.tile == nil }) ?? slots.indices.filter { index in
            !priorities.contains(slots[index].tile ?? -1)
        }.min { a, b in slots[a].lastUse == slots[b].lastUse ? a < b : slots[a].lastUse < slots[b].lastUse }
        guard let slot else { return nil }
        generation &+= 1
        let request = CartographyPageRequest(tile: tile, slot: slot, generation: generation)
        slots[slot] = Slot(tile: tile, ready: false, loadedAt: 0, lastUse: clock)
        pending = request
        return request
    }

    @discardableResult
    mutating func finish(_ request: CartographyPageRequest, succeeded: Bool, cancelled: Bool, now: TimeInterval) -> Bool {
        guard pending == request else { return false }
        pending = nil
        if succeeded && !cancelled {
            slots[request.slot].ready = true
            slots[request.slot].loadedAt = now
        } else {
            slots[request.slot] = Slot()
            if !cancelled { failed.insert(request.tile) }
        }
        return true
    }

    func table(now: TimeInterval) -> [SIMD2<UInt32>] {
        var result = Array(repeating: SIMD2<UInt32>(0, 0), count: tileCount)
        for (index, slot) in slots.enumerated() where slot.ready {
            guard let tile = slot.tile else { continue }
            let fade = Float(min(1, max(0, (now - slot.loadedAt) / Self.fadeDuration)))
            result[tile] = SIMD2(UInt32(index + 1), fade.bitPattern)
        }
        return result
    }

    func isFading(now: TimeInterval) -> Bool { slots.contains { $0.ready && now - $0.loadedAt < Self.fadeDuration } }
    mutating func reject(tile: Int) { if (0..<tileCount).contains(tile) { failed.insert(tile) } }
}

struct CartographyVisibleTile {
    var index: Int
    var rect: SIMD4<Float>
    var heightRange: SIMD2<Float>? = nil
}

/// Screen-space cartography priority, evaluated against a conservative height
/// box. Neither terrain sample spacing nor primary-area membership is an input.
enum CartographyVisibility {
    /// Build small conservative boxes once from the already resident heights.
    /// Neighbor samples include every interpolated triangle crossing a map edge.
    static func heightRanges(atlas: CartographyAtlas, terrain: LoadedTerrain, minimumHeight: Float, metersPerUnit: Float) throws -> [SIMD2<Float>] {
        var result = Array(repeating: SIMD2<Float>(.infinity, -.infinity), count: atlas.tiles.count)
        func cell(_ edges: [Double], _ value: Double, descending: Bool) -> Int {
            var low = 0, high = edges.count - 1
            while low + 1 < high {
                let middle = (low + high) / 2
                if descending ? edges[middle] >= value : edges[middle] <= value { low = middle } else { high = middle }
            }
            return min(edges.count - 2, max(0, low))
        }
        func include(bounds: GeoBounds, columns: Int, rows: Int, heights: [Float]) throws {
            let columnCells = (0..<columns).map { column -> ClosedRange<Int> in
                let left = bounds.minLongitude + Double(max(0, column - 1)) / Double(columns - 1) * (bounds.maxLongitude - bounds.minLongitude)
                let right = bounds.minLongitude + Double(min(columns - 1, column + 1)) / Double(columns - 1) * (bounds.maxLongitude - bounds.minLongitude)
                return cell(atlas.longitudeEdges, left, descending: false)...cell(atlas.longitudeEdges, right, descending: false)
            }
            for row in 0..<rows {
                try Task.checkCancellation()
                let north = bounds.maxLatitude - Double(max(0, row - 1)) / Double(rows - 1) * (bounds.maxLatitude - bounds.minLatitude)
                let south = bounds.maxLatitude - Double(min(rows - 1, row + 1)) / Double(rows - 1) * (bounds.maxLatitude - bounds.minLatitude)
                let rowCells = cell(atlas.latitudeEdges, north, descending: true)...cell(atlas.latitudeEdges, south, descending: true)
                for column in 0..<columns {
                    let value = heights[row * columns + column]
                    guard value.isFinite else { continue }
                    let elevation = (value - minimumHeight) / metersPerUnit
                    for tileRow in rowCells { for tileColumn in columnCells[column] {
                        let index = tileRow * atlas.columns + tileColumn
                        result[index].x = min(result[index].x, elevation)
                        result[index].y = max(result[index].y, elevation)
                    } }
                }
            }
        }
        try include(bounds: terrain.manifest.bounds, columns: terrain.level.width, rows: terrain.level.height, heights: terrain.heights)
        for layer in terrain.horizon?.layers ?? [] {
            try include(bounds: layer.metadata.bounds, columns: layer.level.width, rows: layer.level.height, heights: layer.heights)
        }
        return result
    }

    static func priorities(tiles: [CartographyVisibleTile], viewProjection: simd_float4x4,
                           coverage: SIMD4<Float>, worldSize: SIMD2<Float>, top: Float,
                           viewportPixels: SIMD2<Float>, capacity: Int,
                           minimumFootprint: Float = Float(CartographyAtlas.previewCoreSize) * 1.15) -> [Int] {
        var ranked: [(Int, Float)] = []
        for tile in tiles {
            let x0 = max(tile.rect.x, coverage.x), y0 = max(tile.rect.y, coverage.y)
            let x1 = min(tile.rect.x + tile.rect.z, coverage.x + coverage.z)
            let y1 = min(tile.rect.y + tile.rect.w, coverage.y + coverage.w)
            guard x0 < x1, y0 < y1 else { continue }
            var clips: [SIMD4<Float>] = []
            clips.reserveCapacity(8)
            let heights = tile.heightRange ?? SIMD2(0, top)
            for u in [x0, x1] { for v in [y0, y1] { for h in [heights.x, heights.y] {
                clips.append(viewProjection * SIMD4((u - 0.5) * worldSize.x, h, (v - 0.5) * worldSize.y, 1))
            } } }
            if clips.allSatisfy({ $0.x < -$0.w }) || clips.allSatisfy({ $0.x > $0.w })
                || clips.allSatisfy({ $0.y < -$0.w }) || clips.allSatisfy({ $0.y > $0.w })
                || clips.allSatisfy({ $0.z < 0 }) || clips.allSatisfy({ $0.z > $0.w }) { continue }
            let projected = clips.filter { $0.w > 0.000001 }.map { SIMD2($0.x, $0.y) / $0.w }
            guard !projected.isEmpty else { continue }
            let minX = max(-1, projected.map(\.x).min()!), maxX = min(1, projected.map(\.x).max()!)
            let minY = max(-1, projected.map(\.y).min()!), maxY = min(1, projected.map(\.y).max()!)
            guard minX < maxX, minY < maxY else { continue }
            let pixels = SIMD2((maxX - minX) * viewportPixels.x, (maxY - minY) * viewportPixels.y) * 0.5
            guard max(pixels.x, pixels.y) > minimumFootprint else { continue }
            let center = SIMD2((minX + maxX) * 0.5, (minY + maxY) * 0.5)
            let score = pixels.x * pixels.y / (1 + simd_length_squared(center) * 0.6)
            ranked.append((tile.index, score))
        }
        ranked.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return ranked.prefix(capacity).map(\.0)
    }
}

private struct CartographyUniforms {
    var grid: SIMD4<UInt32>
    var sampling: SIMD4<Float> // native core/size, gutter/size, preview core/size, gutter/size
    var mediumSampling: SIMD4<Float> // medium core/size, gutter/size, reserved
}

private enum CartographyRenderError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case .failed(let message): return message } }
}

/// All map data is local. Only this fixed GPU working set changes with the view;
/// the terrain mesh and the downloaded file set remain completely unchanged.
final class CartographyRenderer: @unchecked Sendable {
    // Also bounds the brief handoff between a cancelled old scene and its
    // replacement. No two ImageIO/upload jobs may coexist across coordinators.
    private static let decodeLock = NSLock()
    private let loaded: LoadedCartography
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let preview: MTLTexture
    private let native: MTLTexture
    private let medium: MTLTexture
    private let columns: MTLBuffer
    private let rows: MTLBuffer
    private let tables: [MTLBuffer]
    private let uniforms: CartographyUniforms
    private let visibleTiles: [CartographyVisibleTile]
    private let primaryBounds: GeoBounds
    private var cache: CartographyPageCache
    private var mediumCache: CartographyPageCache
    private var pendingMedium = false
    private var frameInUse = [false, false, false]
    private var waitingForFrame = false
    private var stopped = false
    private var decoder: Task<Void, Never>?
    private var fadeTick: Task<Void, Never>?
    private var warned = false
    @MainActor var onChange: (() -> Void)?
    @MainActor var onWarning: ((String) -> Void)?

    init(device: MTLDevice, queue: MTLCommandQueue, loaded: LoadedCartography, primaryBounds: GeoBounds,
         terrain: LoadedTerrain, minimumHeight: Float, metersPerUnit: Float) throws {
        try loaded.metadata.validate()
        let atlas = loaded.metadata, count = atlas.tiles.count
        guard loaded.imageURLs.count == count, loaded.previewURLs.count == count else {
            throw CartographyRenderError.failed("The saved map atlas is incomplete.")
        }
        self.device = device; self.queue = queue; self.loaded = loaded; self.primaryBounds = primaryBounds
        let admittedMemory = atlas.estimatedMemoryBytes(device: device)
        guard admittedMemory <= CartographyAtlas.maximumMemoryBytes else {
            throw CartographyRenderError.failed("The saved map exceeds this device's safe map budget. Select a smaller area.")
        }
        cache = CartographyPageCache(tileCount: count)
        mediumCache = CartographyPageCache(tileCount: count, capacity: CartographyAtlas.maximumResidentMediumImages)
        let previewDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
            width: atlas.columns * CartographyAtlas.previewCoreSize, height: atlas.rows * CartographyAtlas.previewCoreSize, mipmapped: true)
        previewDescription.storageMode = .private; previewDescription.usage = .shaderRead
        guard let preview = device.makeTexture(descriptor: previewDescription) else {
            throw CartographyRenderError.failed("The saved map overview could not be allocated.")
        }
        self.preview = preview
        preview.label = "Continuous offline map overview"
        native = try Self.makeArray(device: device, size: CartographyAtlas.imageSize, slices: min(count, CartographyAtlas.maximumResidentImages), label: "Fixed native map cache")
        medium = try Self.makeArray(device: device, size: CartographyAtlas.mediumSize, slices: min(count, CartographyAtlas.maximumResidentMediumImages), label: "Fixed middle-distance map cache")
        // Texture-array alignment differs by GPU. Check the actual allocation
        // against the admission estimate before any image is decoded.
        let actualMemory = Int64(preview.allocatedSize) + Int64(native.allocatedSize) + Int64(medium.allocatedSize)
            + CartographyAtlas.decodeUploadMemoryBytes + CartographyAtlas.metadataMemoryBytes
        guard actualMemory <= min(admittedMemory, CartographyAtlas.maximumMemoryBytes) else {
            throw CartographyRenderError.failed("This device needs more map memory than this area's safe budget. Select a smaller area.")
        }
        let u = atlas.longitudeEdges.map { Float(($0 - primaryBounds.minLongitude) / (primaryBounds.maxLongitude - primaryBounds.minLongitude)) }
        let v = atlas.latitudeEdges.map { Float((primaryBounds.maxLatitude - $0) / (primaryBounds.maxLatitude - primaryBounds.minLatitude)) }
        columns = try Self.buffer(device: device, values: u, label: "Map longitude edges")
        rows = try Self.buffer(device: device, values: v, label: "Map latitude edges")
        let heightRanges = try CartographyVisibility.heightRanges(atlas: atlas, terrain: terrain, minimumHeight: minimumHeight, metersPerUnit: metersPerUnit)
        visibleTiles = atlas.tiles.indices.map { index in
            let row = index / atlas.columns, column = index % atlas.columns
            return CartographyVisibleTile(index: index, rect: SIMD4(u[column], v[row], u[column + 1] - u[column], v[row + 1] - v[row]),
                                          heightRange: heightRanges[index].x.isFinite ? heightRanges[index] : nil)
        }
        var tableBuffers: [MTLBuffer] = []
        for index in 0..<3 {
            guard let buffer = device.makeBuffer(length: count * MemoryLayout<SIMD4<UInt32>>.stride, options: .storageModeShared) else {
                throw CartographyRenderError.failed("The map page table could not be allocated.")
            }
            buffer.label = "Map page table frame \(index)"
            tableBuffers.append(buffer)
        }
        tables = tableBuffers
        uniforms = CartographyUniforms(grid: SIMD4(UInt32(atlas.columns), UInt32(atlas.rows), 0, 0),
            sampling: SIMD4(Float(CartographyAtlas.imageCoreSize) / Float(CartographyAtlas.imageSize), Float(CartographyAtlas.gutter) / Float(CartographyAtlas.imageSize),
                            Float(CartographyAtlas.previewCoreSize) / Float(CartographyAtlas.previewSize), Float(CartographyAtlas.gutter) / Float(CartographyAtlas.previewSize)),
            mediumSampling: SIMD4(Float(CartographyAtlas.mediumCoreSize) / Float(CartographyAtlas.mediumSize),
                                  Float(CartographyAtlas.mediumGutter) / Float(CartographyAtlas.mediumSize), 0, 0))
        try Self.uploadPreviews(device: device, queue: queue, loaded: loaded, destination: preview)
        try Task.checkCancellation()
    }

    @MainActor
    func update(viewProjection: simd_float4x4, coverage: SIMD4<Float>, worldSize: SIMD2<Float>, top: Float, viewportPixels: SIMD2<Float>) {
        guard !stopped else { return }
        cache.prioritize(CartographyVisibility.priorities(tiles: visibleTiles, viewProjection: viewProjection, coverage: coverage,
                                                        worldSize: worldSize, top: top, viewportPixels: viewportPixels, capacity: cache.slots.count,
                                                        minimumFootprint: Float(CartographyAtlas.mediumCoreSize) * 1.15))
        mediumCache.prioritize(CartographyVisibility.priorities(tiles: visibleTiles, viewProjection: viewProjection, coverage: coverage,
                                                              worldSize: worldSize, top: top, viewportPixels: viewportPixels, capacity: mediumCache.slots.count))
        let active = pendingMedium ? mediumCache : cache
        if let pending = active.pending, !active.priorities.contains(pending.tile) { decoder?.cancel() }
        pump()
    }

    /// At most three immutable GPU snapshots may be in flight. When saturated,
    /// the caller skips its frame; completion requests the latest view once.
    @MainActor
    func bind(encoder: MTLRenderCommandEncoder, command: MTLCommandBuffer) -> Bool {
        guard !stopped, let index = frameInUse.firstIndex(of: false) else { waitingForFrame = true; return false }
        frameInUse[index] = true
        let now = CACurrentMediaTime(), nativePages = cache.table(now: now), mediumPages = mediumCache.table(now: now)
        let table = nativePages.indices.map { SIMD4(nativePages[$0].x, nativePages[$0].y, mediumPages[$0].x, mediumPages[$0].y) }
        table.withUnsafeBytes { bytes in tables[index].contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count) }
        var parameters = uniforms
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<CartographyUniforms>.stride, index: 2)
        encoder.setFragmentBuffer(columns, offset: 0, index: 3)
        encoder.setFragmentBuffer(rows, offset: 0, index: 4)
        encoder.setFragmentBuffer(tables[index], offset: 0, index: 5)
        encoder.setFragmentTexture(preview, index: 1)
        encoder.setFragmentTexture(native, index: 3)
        encoder.setFragmentTexture(medium, index: 4)
        command.addCompletedHandler { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.frameInUse[index] = false
                if self.waitingForFrame { self.waitingForFrame = false; self.onChange?() }
            }
        }
        scheduleFade(now: now)
        return true
    }

    func nativeMetersPerTexel(at point: GeoPoint) -> Float {
        let atlas = loaded.metadata
        func cell(_ edges: [Double], _ value: Double, descending: Bool) -> Int {
            var low = 0, high = edges.count - 1
            while low + 1 < high {
                let middle = (low + high) / 2
                if descending ? edges[middle] >= value : edges[middle] <= value { low = middle } else { high = middle }
            }
            return min(edges.count - 2, max(0, low))
        }
        let row = cell(atlas.latitudeEdges, point.latitude, descending: true), column = cell(atlas.longitudeEdges, point.longitude, descending: false)
        let bounds = atlas.tiles[row * atlas.columns + column].image.bounds
        return Float(max(bounds.widthMeters, bounds.depthMeters) / Double(CartographyAtlas.imageCoreSize))
    }

    @MainActor
    func stop() {
        stopped = true
        onChange = nil; onWarning = nil
        decoder?.cancel(); decoder = nil
        fadeTick?.cancel(); fadeTick = nil
    }

    @MainActor
    private func pump() {
        guard !stopped, decoder == nil else { return }
        let request: CartographyPageRequest
        if let next = cache.reserve() { request = next; pendingMedium = false }
        else if let next = mediumCache.reserve() { request = next; pendingMedium = true }
        else { return }
        let device = device, queue = queue, destination = pendingMedium ? medium : native, isMedium = pendingMedium
        let url = loaded.imageURLs[request.tile], metadata = loaded.metadata.tiles[request.tile].image
        let mediumAtlas = isMedium ? loaded : nil
        // Capture only an upload packet. A detached decode never retains the
        // scene, its height arrays, the host view or this cache coordinator.
        decoder = Task.detached(priority: .userInitiated) { [weak self] in
            var failure: String?
            var cancelled = false
            do {
                try autoreleasepool {
                    try Self.upload(device: device, queue: queue, url: url, metadata: metadata,
                                    destination: destination, slice: request.slot, generateMipmaps: true,
                                    mediumAtlas: mediumAtlas, tile: request.tile)
                }
            } catch is CancellationError { cancelled = true }
            catch { failure = error.localizedDescription }
            if Task.isCancelled { cancelled = true }
            let result = (failure, cancelled)
            await MainActor.run { [weak self] in self?.finish(request, medium: isMedium, failure: result.0, cancelled: result.1) }
        }
    }

    @MainActor
    private func finish(_ request: CartographyPageRequest, medium: Bool, failure: String?, cancelled: Bool) {
        guard !stopped else { return }
        let now = CACurrentMediaTime()
        let accepted = medium ? mediumCache.finish(request, succeeded: failure == nil, cancelled: cancelled, now: now)
            : cache.finish(request, succeeded: failure == nil, cancelled: cancelled, now: now)
        guard accepted else { return }
        decoder = nil
        if failure != nil && !cancelled && !warned {
            warned = true
            onWarning?("Some detailed map images could not be read. The saved overview remains available.")
        }
        if failure != nil && !cancelled {
            // A medium gutter can fail because a neighbour is damaged while
            // this cell's native image is still usable when viewed closely.
            if !medium { cache.reject(tile: request.tile) }
            mediumCache.reject(tile: request.tile)
        }
        onChange?()
        pump()
    }

    @MainActor
    private func scheduleFade(now: TimeInterval) {
        guard fadeTick == nil, cache.isFading(now: now) || mediumCache.isFading(now: now) else { return }
        fadeTick = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.fadeTick = nil
            self.onChange?()
        }
    }

    private static func makeArray(device: MTLDevice, size: Int, slices: Int, label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm_srgb
        descriptor.width = size; descriptor.height = size; descriptor.arrayLength = slices
        descriptor.mipmapLevelCount = Int(floor(log2(Double(size)))) + 1
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .pixelFormatView]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw CartographyRenderError.failed("The bounded map cache could not be allocated.") }
        texture.label = label
        return texture
    }

    private static func buffer<T>(device: MTLDevice, values: [T], label: String) throws -> MTLBuffer {
        let buffer = values.withUnsafeBytes { bytes in device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared) }
        guard let buffer else { throw CartographyRenderError.failed("The map grid could not be allocated.") }
        buffer.label = label
        return buffer
    }

    /// Decode individually into one reusable 1.125 MiB staging buffer. Submit
    /// 32 tiny preview copies together instead of waiting for the GPU per PNG.
    /// This stays inside the existing single-job reserve, including on cancel.
    private static func uploadPreviews(device: MTLDevice, queue: MTLCommandQueue,
                                       loaded: LoadedCartography, destination: MTLTexture) throws {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        try Task.checkCancellation()
        let atlas = loaded.metadata, batchSize = 32
        let size = CartographyAtlas.previewSize
        let rowBytes = ((size * 4 + 255) / 256) * 256
        let pageBytes = rowBytes * size
        guard loaded.previewURLs.count == atlas.tiles.count,
              destination.width == atlas.columns * CartographyAtlas.previewCoreSize,
              destination.height == atlas.rows * CartographyAtlas.previewCoreSize,
              let staging = device.makeBuffer(length: pageBytes * min(batchSize, atlas.tiles.count), options: .storageModeShared),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CartographyRenderError.failed("The map preview staging buffer could not be allocated.")
        }
        for start in stride(from: 0, to: atlas.tiles.count, by: batchSize) {
            let count = min(batchSize, atlas.tiles.count - start)
            for slot in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let context = CGContext(data: staging.contents().advanced(by: slot * pageBytes), width: size, height: size,
                                                  bitsPerComponent: 8, bytesPerRow: rowBytes, space: space,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                        throw CartographyRenderError.failed("A map preview could not be decoded.")
                    }
                    context.setBlendMode(.copy)
                    try drawFile(url: loaded.previewURLs[start + slot], metadata: atlas.tiles[start + slot].preview, into: context)
                }
            }
            try Task.checkCancellation()
            guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
                throw CartographyRenderError.failed("The map previews could not be uploaded.")
            }
            for slot in 0..<count {
                let index = start + slot
                let offset = slot * pageBytes + CartographyAtlas.gutter * rowBytes + CartographyAtlas.gutter * 4
                blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: rowBytes, sourceBytesPerImage: pageBytes,
                          sourceSize: MTLSize(width: CartographyAtlas.previewCoreSize, height: CartographyAtlas.previewCoreSize, depth: 1),
                          to: destination, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: (index % atlas.columns) * CartographyAtlas.previewCoreSize,
                                                       y: (index / atlas.columns) * CartographyAtlas.previewCoreSize, z: 0))
            }
            if start + count == atlas.tiles.count { blit.generateMipmaps(for: destination) }
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw CartographyRenderError.failed("The map previews could not be uploaded.") }
            // The same buffer can be reused only after this batch has finished.
            try Task.checkCancellation()
        }
    }

    private static func upload(device: MTLDevice, queue: MTLCommandQueue, url: URL, metadata: MapTexture,
                               destination: MTLTexture, slice: Int, generateMipmaps: Bool,
                               mediumAtlas: LoadedCartography? = nil, tile: Int = 0,
                               previewCell: SIMD2<Int>? = nil) throws {
        decodeLock.lock()
        defer { decodeLock.unlock() }
        try Task.checkCancellation()
        let width = previewCell == nil ? destination.width : CartographyAtlas.previewSize
        let height = previewCell == nil ? destination.height : CartographyAtlas.previewSize
        let bytesPerRow = ((width * 4 + 255) / 256) * 256
        guard let staging = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: staging.contents(), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw CartographyRenderError.failed("A saved map image could not be decoded.")
        }
        context.interpolationQuality = .high
        if let mediumAtlas {
            try CartographyMediumDecoder.draw(tile: tile, atlas: mediumAtlas, into: context)
        } else {
            try drawFile(url: url, metadata: metadata, into: context)
        }
        try Task.checkCancellation()
        guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            throw CartographyRenderError.failed("A saved map image could not be uploaded.")
        }
        let offset = previewCell == nil ? 0 : CartographyAtlas.gutter * bytesPerRow + CartographyAtlas.gutter * 4
        let size = previewCell == nil ? MTLSize(width: width, height: height, depth: 1)
            : MTLSize(width: CartographyAtlas.previewCoreSize, height: CartographyAtlas.previewCoreSize, depth: 1)
        let origin = previewCell.map { MTLOrigin(x: $0.x * CartographyAtlas.previewCoreSize, y: $0.y * CartographyAtlas.previewCoreSize, z: 0) }
            ?? MTLOrigin(x: 0, y: 0, z: 0)
        blit.copy(from: staging, sourceOffset: offset, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: size, to: destination, destinationSlice: slice, destinationLevel: 0, destinationOrigin: origin)
        if generateMipmaps {
            guard let page = destination.makeTextureView(pixelFormat: destination.pixelFormat, textureType: .type2D,
                                                         levels: 0..<destination.mipmapLevelCount, slices: slice..<(slice + 1)) else {
                blit.endEncoding()
                throw CartographyRenderError.failed("A detailed map page could not be prepared.")
            }
            blit.generateMipmaps(for: page)
        }
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw CartographyRenderError.failed("A saved map image could not be uploaded.") }
        try Task.checkCancellation()
    }

    private static func drawFile(url: URL, metadata: MapTexture, into context: CGContext) throws {
        guard url.isFileURL, metadata.byteCount > 0, metadata.byteCount <= CartographyAtlas.maximumImageFileBytes else {
            throw CartographyRenderError.failed("A detailed map file is invalid.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == metadata.byteCount else { throw CartographyRenderError.failed("A saved map image is incomplete.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(metadata.byteCount) + 1) ?? Data()
        guard data.count == metadata.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256.lowercased() else {
            throw CartographyRenderError.failed("A saved map image failed its integrity check.")
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == metadata.width,
              properties[kCGImagePropertyPixelHeight] as? Int == metadata.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CartographyRenderError.failed("A saved map image has invalid dimensions.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        try Task.checkCancellation()
    }
}
