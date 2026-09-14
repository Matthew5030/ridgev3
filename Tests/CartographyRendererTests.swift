// Appended to CartographyRenderer.swift by the test runner so the upload and
// frame-pool checks can exercise its private implementation without exposing it.
import UniformTypeIdentifiers

extension CartographyRenderer {
    static func testPreviewUpload(device: MTLDevice, queue: MTLCommandQueue, loaded: LoadedCartography, destination: MTLTexture) throws {
        try uploadPreviews(device: device, queue: queue, loaded: loaded, destination: destination)
    }
    static func testUpload(device: MTLDevice, queue: MTLCommandQueue, url: URL, metadata: MapTexture, destination: MTLTexture, slice: Int) throws {
        try upload(device: device, queue: queue, url: url, metadata: metadata, destination: destination, slice: slice, generateMipmaps: true)
    }
    static func testArray(device: MTLDevice, size: Int, slices: Int) throws -> MTLTexture {
        try makeArray(device: device, size: size, slices: slices, label: "Cartography test")
    }
    static func testMediumUpload(device: MTLDevice, queue: MTLCommandQueue, atlas: LoadedCartography, tile: Int,
                                 destination: MTLTexture, slice: Int) throws {
        try upload(device: device, queue: queue, url: atlas.imageURLs[tile], metadata: atlas.metadata.tiles[tile].image,
                   destination: destination, slice: slice, generateMipmaps: true, mediumAtlas: atlas, tile: tile)
    }
}

@main
struct CartographyRendererTests {
    @MainActor static var assertions = 0
    @MainActor static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); assertions += 1
    }

    @MainActor
    static func main() async throws {
        var cache = CartographyPageCache(tileCount: 8, capacity: 2)
        cache.prioritize([2, 1, 2, -1, 99])
        check(cache.priorities == [2, 1], "Priority list must be valid, unique and capacity bounded")
        let first = cache.reserve()!
        check(first.tile == 2 && cache.reserve() == nil, "Only one decode can be reserved")
        check(cache.table(now: 10).allSatisfy { $0.x == 0 }, "An unuploaded slot became visible")
        check(cache.finish(first, succeeded: true, cancelled: false, now: 10), "Valid upload was not published")
        check(cache.table(now: 10)[2].x == 1 && Float(bitPattern: cache.table(now: 10)[2].y) == 0, "Native page did not start at preview")
        check(abs(Float(bitPattern: cache.table(now: 10.12)[2].y) - 0.5) < 0.00001, "Native page fade is not continuous")
        check(Float(bitPattern: cache.table(now: 11)[2].y) == 1, "Native page fade did not finish")
        let second = cache.reserve()!
        _ = cache.finish(second, succeeded: true, cancelled: false, now: 11)
        cache.prioritize([2, 3])
        let replacement = cache.reserve()!
        check(replacement.tile == 3 && replacement.slot == second.slot, "Visible page was evicted instead of the old page")
        check(!cache.finish(second, succeeded: true, cancelled: false, now: 12), "Stale completion overwrote a new reservation")
        cache.prioritize([2, 4])
        check(cache.reserve() == nil, "Changing view spawned a second pending decode")
        _ = cache.finish(replacement, succeeded: false, cancelled: true, now: 12)
        check(!cache.failed.contains(3), "Cancellation permanently rejected a valid page")
        let latest = cache.reserve()!
        check(latest.tile == 4, "Cancelled decode did not yield to latest view")
        _ = cache.finish(latest, succeeded: false, cancelled: false, now: 12)
        check(cache.failed.contains(4) && cache.reserve() == nil, "Corrupt page was retried indefinitely")
        for capacity in [CartographyAtlas.maximumResidentImages, CartographyAtlas.maximumResidentMediumImages] {
            var moving = CartographyPageCache(tileCount: 4_096, capacity: capacity)
            for step in 0..<80 {
                moving.prioritize((0..<capacity).map { (step * 7 + $0) % 4_096 })
                while let request = moving.reserve() { _ = moving.finish(request, succeeded: true, cancelled: false, now: Double(step)) }
                check(moving.slots.count == capacity && Set(moving.slots.compactMap(\.tile)).count == capacity, "Camera motion grew or duplicated the fixed cache")
            }
        }

        // Orthographic projection makes footprint expectations independent of
        // terrain tessellation and of a camera's primary-area origin.
        let overhead = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0.5, 1)))
        let tiles = [CartographyVisibleTile(index: 0, rect: SIMD4(0, 0, 0.5, 1)),
                     CartographyVisibleTile(index: 1, rect: SIMD4(0.5, 0, 0.5, 1)),
                     CartographyVisibleTile(index: 2, rect: SIMD4(3, 0, 1, 1))]
        let visible = CartographyVisibility.priorities(tiles: tiles, viewProjection: overhead, coverage: SIMD4(-1, -1, 5, 3),
                                                       worldSize: SIMD2(1, 1), top: 0, viewportPixels: SIMD2(1_024, 1_024), capacity: 16)
        check(visible == [0, 1], "Frustum culling or deterministic ties are wrong")
        let tiny = CartographyVisibility.priorities(tiles: tiles, viewProjection: overhead, coverage: SIMD4(0, 0, 1, 1),
                                                    worldSize: SIMD2(1, 1), top: 0, viewportPixels: SIMD2(100, 100), capacity: 16)
        check(tiny.isEmpty, "Small footprints unnecessarily decoded native images")
        let clipped = CartographyVisibility.priorities(tiles: tiles, viewProjection: overhead, coverage: SIMD4(0.5, 0, 0.5, 1),
                                                       worldSize: SIMD2(1, 1), top: 0, viewportPixels: SIMD2(1_024, 1_024), capacity: 16)
        check(clipped == [1], "Map pages outside loaded terrain were requested")
        for (core, size, gutter) in [(CartographyAtlas.imageCoreSize, CartographyAtlas.imageSize, CartographyAtlas.gutter),
                                      (CartographyAtlas.mediumCoreSize, CartographyAtlas.mediumSize, CartographyAtlas.mediumGutter),
                                      (CartographyAtlas.previewCoreSize, CartographyAtlas.previewSize, CartographyAtlas.gutter)] {
            check(core + 2 * gutter == size, "A texture tier shifts the geographic core")
            check(abs((0.5 * Float(core) + Float(gutter)) / Float(size) - 0.5) < 0.00001, "Texture tier centers disagree")
        }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            print("PASS \(assertions) deterministic cache and visibility checks; GPU checks unavailable on this host")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ridge-map-render-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        if ProcessInfo.processInfo.environment["RIDGE_SHADER_ONLY"] == "1" {
            try shaderChecks(device: device, queue: queue, directory: directory)
            print("PASS \(assertions) deterministic and actual fragment checks")
            return
        }
        let bounds = GeoBounds(minLatitude: 53, minLongitude: -4.01, maxLatitude: 53.01, maxLongitude: -4)
        func image(size: Int, name: String, transparent: Bool = false) throws -> MapTexture {
            var bytes = [UInt8](repeating: transparent ? 0 : 255, count: size * size * 4)
            for y in 0..<size { for x in 0..<size {
                if transparent { continue }
                let index = (y * size + x) * 4
                bytes[index] = y < size / 2 ? 245 : 15
                bytes[index + 1] = 30
                bytes[index + 2] = y < size / 2 ? 10 : 230
            } }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let cgImage = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let url = directory.appendingPathComponent(name)
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, cgImage, nil)
            precondition(CGImageDestinationFinalize(destination))
            let data = try Data(contentsOf: url)
            return MapTexture(file: name, width: size, height: size, byteCount: Int64(data.count),
                              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bounds: bounds)
        }
        func read(_ texture: MTLTexture, level: Int = 0) -> [UInt8] {
            let width = max(1, texture.width >> level), height = max(1, texture.height >> level), row = ((width * 4 + 255) / 256) * 256
            let buffer = device.makeBuffer(length: row * height, options: .storageModeShared)!
            let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                      destinationBytesPerRow: row, destinationBytesPerImage: row * height)
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: row * height))
        }
        let nativeMetadata = try image(size: CartographyAtlas.imageSize, name: "native.png")
        let previewMetadata = try image(size: CartographyAtlas.previewSize, name: "preview.png")
        for size in [CartographyAtlas.imageSize, CartographyAtlas.mediumSize] {
            let texture = try CartographyRenderer.testArray(device: device, size: size, slices: 2)
            try CartographyRenderer.testUpload(device: device, queue: queue, url: directory.appendingPathComponent(nativeMetadata.file), metadata: nativeMetadata, destination: texture, slice: 0)
            let bytes = read(texture)
            check(bytes[0] > 200 && bytes[2] < 40, "Native/medium upload flipped the north edge south")
            let bottom = (((size * 4 + 255) / 256) * 256) * (size - 1)
            check(bytes[bottom] < 40 && bytes[bottom + 2] > 200, "Native/medium upload changed the south edge")
            let mip = read(texture, level: 2)
            check(mip[0] > 200 && mip[2] < 40, "Single-slice mip generation failed")
            var bad = nativeMetadata; bad.sha256 = String(repeating: "0", count: 64)
            do {
                try CartographyRenderer.testUpload(device: device, queue: queue, url: directory.appendingPathComponent(nativeMetadata.file), metadata: bad, destination: texture, slice: 1)
                preconditionFailure("Corrupt native page was uploaded")
            } catch { check(true, "Corrupt page rejected") }
        }
        let atlas = CartographyAtlas(columns: 1, rows: 1, longitudeEdges: [bounds.minLongitude, bounds.maxLongitude],
                                      latitudeEdges: [bounds.maxLatitude, bounds.minLatitude], tiles: [CartographyTile(image: nativeMetadata, preview: previewMetadata)])
        let level = TerrainLOD(spacing: 32, width: 2, height: 2, file: "test.bin", byteCount: 8, sha256: String(repeating: "0", count: 64))
        let manifest = RegionManifest(schemaVersion: 1, id: "test", name: "Test", subtitle: "", bounds: bounds, sourceResolution: 1,
                                      heightScale: 1, noDataValue: -32768, levels: [level], textures: [], graphFile: nil, graphSHA256: nil,
                                      graphByteCount: nil, places: [], sources: [], defaultSpacing: 32, version: "test", summary: "")
        let terrain = LoadedTerrain(manifest: manifest, level: level, heights: [0, 12, 20, 30], textureURLs: [], graph: nil, directory: directory)
        let loaded = LoadedCartography(metadata: atlas, imageURLs: [directory.appendingPathComponent(nativeMetadata.file)], previewURLs: [directory.appendingPathComponent(previewMetadata.file)])
        // Exercise two batches, a partial final batch and geographic row wraps.
        // This upload-only fixture repeats an already-verified PNG payload.
        var batchAtlas = atlas
        batchAtlas.columns = 7; batchAtlas.rows = 5
        batchAtlas.tiles = Array(repeating: atlas.tiles[0], count: 35)
        var batch = LoadedCartography(metadata: batchAtlas,
                                      imageURLs: Array(repeating: loaded.imageURLs[0], count: 35),
                                      previewURLs: Array(repeating: loaded.previewURLs[0], count: 35))
        let mosaicDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 7 * 64, height: 5 * 64, mipmapped: true)
        mosaicDescription.storageMode = .private; mosaicDescription.usage = .shaderRead
        let mosaic = device.makeTexture(descriptor: mosaicDescription)!
        try CartographyRenderer.testPreviewUpload(device: device, queue: queue, loaded: batch, destination: mosaic)
        let mosaicPixels = read(mosaic), mosaicStride = ((mosaic.width * 4 + 255) / 256) * 256
        for index in 0..<35 {
            let north = (index / 7 * 64 + 16) * mosaicStride + (index % 7 * 64 + 16) * 4
            let south = north + 32 * mosaicStride
            check(mosaicPixels[north] == 245 && mosaicPixels[north + 2] == 10, "Batched preview lost north pixels at cell \(index)")
            check(mosaicPixels[south] == 15 && mosaicPixels[south + 2] == 230, "Batched preview lost south pixels at cell \(index)")
        }
        let clearPreview = try image(size: CartographyAtlas.previewSize, name: "clear-preview.png", transparent: true)
        batch.metadata.tiles[33].preview = clearPreview
        batch.previewURLs[33] = directory.appendingPathComponent(clearPreview.file)
        try CartographyRenderer.testPreviewUpload(device: device, queue: queue, loaded: batch, destination: mosaic)
        let clearPixels = read(mosaic)
        let reusedOffset = (33 / 7 * 64 + 16) * mosaicStride + (33 % 7 * 64 + 16) * 4
        check(clearPixels[reusedOffset..<(reusedOffset + 4)].allSatisfy { $0 == 0 }, "Reused staging retained a previous tile beneath transparent pixels")
        batch.previewURLs[33] = loaded.previewURLs[0]
        batch.metadata = batchAtlas
        batch.metadata.tiles[33].preview.sha256 = String(repeating: "0", count: 64)
        do {
            try CartographyRenderer.testPreviewUpload(device: device, queue: queue, loaded: batch, destination: mosaic)
            preconditionFailure("A corrupt preview in the final batch was accepted")
        } catch { check(true, "Corrupt preview rejects the batched load") }
        batch.metadata = batchAtlas
        let cancelFixture = batch
        let cancelledUpload = Task { @MainActor in
            try CartographyRenderer.testPreviewUpload(device: device, queue: queue, loaded: cancelFixture, destination: mosaic)
        }
        cancelledUpload.cancel()
        do { try await cancelledUpload.value; preconditionFailure("Cancelled preview upload continued") }
        catch is CancellationError { check(true, "Cancellation stops preview upload") }
        var renderer: CartographyRenderer? = try CartographyRenderer(device: device, queue: queue, loaded: loaded, primaryBounds: bounds,
                                                                     terrain: terrain, minimumHeight: 0, metersPerUnit: 1_000)
        weak var released = renderer
        var wakeups = 0
        renderer?.onChange = { wakeups += 1 }
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 16, height: 16, mipmapped: false)
        targetDescriptor.usage = .renderTarget
        let target = device.makeTexture(descriptor: targetDescriptor)!
        var commands: [MTLCommandBuffer] = []
        for index in 0..<4 {
            let command = queue.makeCommandBuffer()!, pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            let bound = renderer!.bind(encoder: encoder, command: command)
            check(bound == (index < 3), "More than three page-table frames became writable")
            encoder.endEncoding()
            if bound { commands.append(command) }
        }
        for command in commands {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        check(wakeups == 1, "Frame completion caused an idle redraw loop")
        renderer?.update(viewProjection: overhead, coverage: SIMD4(0, 0, 1, 1), worldSize: SIMD2(1, 1), top: 0.03, viewportPixels: SIMD2(1_024, 1_024))
        renderer?.stop(); renderer = nil
        check(released == nil, "Detached map work retained the cache coordinator after release")
        released = nil
        try shaderChecks(device: device, queue: queue, directory: directory)
        print("PASS \(assertions) cache, visibility, upload, hash, mip, frame-pool, detach and actual fragment checks")
    }
}
