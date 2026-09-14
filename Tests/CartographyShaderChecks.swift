// Offscreen tests use the shipping Metal fragment, not a copy of its lookup.
// This file is concatenated with CartographyRendererTests by the runner.
private struct MapTestVertex {
    var position: SIMD3<Float>
    var normal = SIMD3<Float>(0, 1, 0)
    var uv: SIMD2<Float>
}

private struct MapTestUniforms {
    var viewProjection = matrix_identity_float4x4
    var textureRect = SIMD4<Float>(0, 0, 1, 1)
    var color = SIMD4<Float>(repeating: 1)
    var style = SIMD4<Float>(repeating: 0)
    var cameraRight = SIMD4<Float>(1, 0, 0, 0)
    var cameraUp = SIMD4<Float>(0, 1, 0, 0)
    var contextRect = SIMD4<Float>(0, 0, 2, 1)
    var atmosphere = SIMD4<Float>(repeating: 0)
}

extension CartographyRendererTests {
    @MainActor
    static func shaderChecks(device: MTLDevice, queue: MTLCommandQueue, directory: URL) throws {
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let description = MTLRenderPipelineDescriptor()
            description.vertexFunction = library.makeFunction(name: "ridgeVertex")
            description.fragmentFunction = library.makeFunction(name: fragment)
            description.colorAttachments[0].pixelFormat = .rgba8Unorm
            return try device.makeRenderPipelineState(descriptor: description)
        }
        let atlasPipeline = try pipeline("ridgeAtlasFragment"), referencePipeline = try pipeline("ridgeFragment")
        let samplerDescription = MTLSamplerDescriptor()
        samplerDescription.minFilter = .linear; samplerDescription.magFilter = .linear; samplerDescription.mipFilter = .linear
        samplerDescription.sAddressMode = .clampToEdge; samplerDescription.tAddressMode = .clampToEdge
        samplerDescription.maxAnisotropy = 16
        let sampler = device.makeSamplerState(descriptor: samplerDescription)!
        let vertices = [MapTestVertex(position: SIMD3(-1, 1, 0.5), uv: SIMD2(0, 0)),
                        MapTestVertex(position: SIMD3(-1, -1, 0.5), uv: SIMD2(0, 1)),
                        MapTestVertex(position: SIMD3(1, 1, 0.5), uv: SIMD2(2, 0)),
                        MapTestVertex(position: SIMD3(1, 1, 0.5), uv: SIMD2(2, 0)),
                        MapTestVertex(position: SIMD3(-1, -1, 0.5), uv: SIMD2(0, 1)),
                        MapTestVertex(position: SIMD3(1, -1, 0.5), uv: SIMD2(2, 1))]
        func parameters(rows: Int = 1, firstPreviewCount: Int = 2) -> CartographyUniforms {
            CartographyUniforms(grid: SIMD4(2, UInt32(rows), UInt32(firstPreviewCount), 0),
                sampling: SIMD4(Float(CartographyAtlas.imageCoreSize) / Float(CartographyAtlas.imageSize),
                                Float(CartographyAtlas.gutter) / Float(CartographyAtlas.imageSize),
                                Float(CartographyAtlas.previewCoreSize) / Float(CartographyAtlas.previewSize),
                                Float(CartographyAtlas.gutter) / Float(CartographyAtlas.previewSize)),
                mediumSampling: SIMD4(Float(CartographyAtlas.mediumCoreSize) / Float(CartographyAtlas.mediumSize),
                                      Float(CartographyAtlas.mediumGutter) / Float(CartographyAtlas.mediumSize), 0, 0))
        }
        func render(width: Int, height: Int, previewA: MTLTexture, previewB: MTLTexture,
                    native: MTLTexture, medium: MTLTexture, pages: [SIMD4<UInt32>],
                    rowEdges: [Float] = [0, 1], firstPreviewCount: Int = 2,
                    reference: MTLTexture? = nil, textureRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)) -> [UInt8] {
            let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            description.usage = [.renderTarget]; description.storageMode = .private
            let target = device.makeTexture(descriptor: description)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let command = queue.makeCommandBuffer()!, encoder = command.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(reference == nil ? atlasPipeline : referencePipeline)
            vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            var uniforms = MapTestUniforms(); uniforms.textureRect = textureRect
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MapTestUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MapTestUniforms>.stride, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)
            if let reference { encoder.setFragmentTexture(reference, index: 0) }
            else {
                var atlas = parameters(rows: rowEdges.count - 1, firstPreviewCount: firstPreviewCount)
                encoder.setFragmentBytes(&atlas, length: MemoryLayout<CartographyUniforms>.stride, index: 2)
                [Float(0), 1, 2].withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 3) }
                rowEdges.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 4) }
                pages.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 5) }
                encoder.setFragmentTexture(previewA, index: 1)
                encoder.setFragmentTexture(native, index: 3); encoder.setFragmentTexture(medium, index: 4)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()
            let rowBytes = ((width * 4 + 255) / 256) * 256
            let output = device.makeBuffer(length: rowBytes * height, options: .storageModeShared)!
            let blit = command.makeBlitCommandEncoder()!
            blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1), to: output,
                      destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, "Actual fragment failed to render")
            let bytes = output.contents().assumingMemoryBound(to: UInt8.self)
            return (0..<height).flatMap { y in Array(UnsafeBufferPointer(start: bytes + y * rowBytes, count: width * 4)) }
        }
        func fill(_ texture: MTLTexture, colors: [SIMD3<UInt8>]) {
            let mosaic = texture.textureType == .type2D
            let width = mosaic ? texture.width / 2 : texture.width
            let height = mosaic ? texture.height / 2 : texture.height
            let rowBytes = ((width * 4 + 255) / 256) * 256
            for (slice, color) in colors.enumerated() {
                let staging = device.makeBuffer(length: rowBytes * height, options: .storageModeShared)!
                let bytes = staging.contents().assumingMemoryBound(to: UInt8.self)
                for y in 0..<height { for x in 0..<width {
                    let offset = y * rowBytes + x * 4
                    bytes[offset] = color.x; bytes[offset + 1] = color.y; bytes[offset + 2] = color.z; bytes[offset + 3] = 255
                } }
                let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
                blit.copy(from: staging, sourceOffset: 0, sourceBytesPerRow: rowBytes, sourceBytesPerImage: rowBytes * height,
                          sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture,
                          destinationSlice: mosaic ? 0 : slice, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: mosaic ? (slice % 2) * width : 0, y: mosaic ? (slice / 2) * height : 0, z: 0))
                let view = mosaic ? texture : texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D,
                                                   levels: 0..<texture.mipmapLevelCount, slices: slice..<(slice + 1))!
                blit.generateMipmaps(for: view); blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            }
        }
        let previewDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 128, height: 128, mipmapped: true)
        previewDescription.storageMode = .private; previewDescription.usage = .shaderRead
        let previewA = device.makeTexture(descriptor: previewDescription)!, previewB = previewA
        let native = try CartographyRenderer.testArray(device: device, size: CartographyAtlas.imageSize, slices: 2)
        let medium = try CartographyRenderer.testArray(device: device, size: CartographyAtlas.mediumSize, slices: 2)
        fill(previewA, colors: [SIMD3(255, 0, 0), SIMD3(0, 255, 0), SIMD3(0, 0, 255), SIMD3(255, 255, 0)])
        fill(native, colors: [SIMD3(255, 0, 255), SIMD3(0, 255, 255)])
        fill(medium, colors: [SIMD3(255, 255, 255), SIMD3(0, 0, 0)])
        let empty = Array(repeating: SIMD4<UInt32>(repeating: 0), count: 4)
        let preview = render(width: 160, height: 80, previewA: previewA, previewB: previewB, native: native, medium: medium,
                             pages: empty, rowEdges: [0, 0.3, 1])
        func pixel(_ image: [UInt8], x: Int, y: Int, width: Int = 160) -> [Int] {
            let offset = (y * width + x) * 4
            return (0..<3).map { Int(image[offset + $0]) }
        }
        check(pixel(preview, x: 20, y: 10)[0] > 200 && pixel(preview, x: 20, y: 10)[2] == 0, "Preview mosaic north-west lookup failed")
        check(pixel(preview, x: 120, y: 10)[1] > 200 && pixel(preview, x: 120, y: 10)[0] == 0, "Preview mosaic east lookup failed")
        check(pixel(preview, x: 20, y: 40)[2] > 200 && pixel(preview, x: 20, y: 40)[0] == 0, "Preview mosaic/nonuniform row lookup failed")
        check(pixel(preview, x: 120, y: 40)[0] > 200 && pixel(preview, x: 120, y: 40)[1] > 200, "Preview mosaic south-east lookup failed")
        var nativePages = empty; nativePages[0] = SIMD4(2, Float(1).bitPattern, 0, 0)
        var mediumPages = empty; mediumPages[0] = SIMD4(0, 0, 1, Float(1).bitPattern)
        let full = render(width: 160, height: 80, previewA: previewA, previewB: previewB, native: native, medium: medium,
                          pages: nativePages, rowEdges: [0, 0.3, 1])
        check(pixel(full, x: 20, y: 10)[0] == 0 && pixel(full, x: 20, y: 10)[2] > 200, "Native cache slice routing failed")
        let middle = render(width: 160, height: 80, previewA: previewA, previewB: previewB, native: native, medium: medium,
                            pages: mediumPages, rowEdges: [0, 0.3, 1])
        check(pixel(middle, x: 20, y: 10).allSatisfy { $0 > 200 }, "Medium cache routing failed")
        nativePages[0].y = Float(0.5).bitPattern
        let half = render(width: 160, height: 80, previewA: previewA, previewB: previewB, native: native, medium: medium,
                          pages: nativePages, rowEdges: [0, 0.3, 1])
        let firstPixel = pixel(preview, x: 20, y: 10), lastPixel = pixel(full, x: 20, y: 10), halfPixel = pixel(half, x: 20, y: 10)
        check((0..<3).allSatisfy { abs(2 * halfPixel[$0] - firstPixel[$0] - lastPixel[$0]) <= 2 }, "Actual shader page fade is discontinuous")

        let firstBounds = GeoBounds(minLatitude: 53, minLongitude: -4.02, maxLatitude: 53.01, maxLongitude: -4.01)
        let secondBounds = GeoBounds(minLatitude: 53, minLongitude: -4.01, maxLatitude: 53.01, maxLongitude: -4)
        func pattern(width: Int, height: Int, offset: Int, name: String, bounds: GeoBounds, scale: Int = 1) throws -> MapTexture {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            func linear(_ byte: UInt8) -> Double {
                let value = Double(byte) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            for y in 0..<height { for x in 0..<width {
                var sum: Double = 0
                for dx in 0..<scale {
                    let phase = ((offset + x * scale + dx + 11) % 64 + 64) % 64
                    sum += linear(phase < 32 ? 245 : 10)
                }
                let average = sum / Double(scale)
                let encoded = average <= 0.0031308 ? average * 12.92 : 1.055 * pow(average, 1 / 2.4) - 0.055
                let value = UInt8(clamping: Int((encoded * 255).rounded()))
                let index = (y * width + x) * 4
                bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
            } }
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let url = directory.appendingPathComponent(name)
            let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(target, image, nil); precondition(CGImageDestinationFinalize(target))
            let data = try Data(contentsOf: url)
            return MapTexture(file: name, width: width, height: height, byteCount: Int64(data.count),
                              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bounds: bounds)
        }
        let left = try pattern(width: 1032, height: 1032, offset: -4, name: "stripe-left.png", bounds: firstBounds)
        let right = try pattern(width: 1032, height: 1032, offset: 1020, name: "stripe-right.png", bounds: secondBounds)
        let atlas = CartographyAtlas(columns: 2, rows: 1, longitudeEdges: [-4.02, -4.01, -4], latitudeEdges: [53.01, 53],
                                     tiles: [CartographyTile(image: left, preview: left), CartographyTile(image: right, preview: right)])
        let loaded = LoadedCartography(metadata: atlas, imageURLs: [left, right].map { directory.appendingPathComponent($0.file) }, previewURLs: [])
        for index in 0..<2 {
            try CartographyRenderer.testMediumUpload(device: device, queue: queue, atlas: loaded, tile: index, destination: medium, slice: index)
            try CartographyRenderer.testUpload(device: device, queue: queue, url: loaded.imageURLs[index], metadata: atlas.tiles[index].image, destination: native, slice: index)
        }
        let referenceMetadata = try pattern(width: 520, height: 264, offset: -16, name: "stripe-continuous.png", bounds: atlas.bounds, scale: 4)
        let referenceDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 520, height: 264, mipmapped: true)
        referenceDescription.storageMode = .private; referenceDescription.usage = [.shaderRead, .pixelFormatView]
        let reference = device.makeTexture(descriptor: referenceDescription)!
        try CartographyRenderer.testUpload(device: device, queue: queue, url: directory.appendingPathComponent(referenceMetadata.file),
                                           metadata: referenceMetadata, destination: reference, slice: 0)
        if ProcessInfo.processInfo.environment["RIDGE_CARTOGRAPHY_CAPTURE"] != nil {
            func raw(_ texture: MTLTexture, level: Int) -> [UInt8] {
                let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
                let rowBytes = ((width * 4 + 255) / 256) * 256
                let output = device.makeBuffer(length: rowBytes * height, options: .storageModeShared)!
                let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: width, height: height, depth: 1), to: output, destinationOffset: 0,
                          destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * height)
                blit.endEncoding(); command.commit(); command.waitUntilCompleted()
                let bytes = output.contents().assumingMemoryBound(to: UInt8.self)
                return (0..<width).map { bytes[(height / 2) * rowBytes + $0 * 4] }
            }
            for level in 0...2 {
                let a = raw(medium, level: level), b = raw(reference, level: level)
                let difference = (4..<(a.count - 4)).map { abs(Int(a[$0]) - Int(b[$0])) }.max()!
                FileHandle.standardOutput.write(Data("Medium/reference mip\(level) interior maximum: \(difference)\n".utf8))
            }
        }
        let ready = [SIMD4<UInt32>(0, 0, 1, Float(1).bitPattern), SIMD4<UInt32>(0, 0, 2, Float(1).bitPattern)]
        for (footprint, height) in [(64, 64), (80, 80), (96, 96), (80, 24), (96, 28)] {
            let width = footprint * 2
            let actual = render(width: width, height: height, previewA: previewA, previewB: previewB, native: native, medium: medium, pages: ready)
            let expected = render(width: width, height: height, previewA: previewA, previewB: previewB, native: native, medium: medium, pages: ready,
                                  reference: reference, textureRect: SIMD4(-16.0 / 1024, -16.0 / 1024, 2080.0 / 1024, 1056.0 / 1024))
            var seamMaximum = 0, interiorMaximum = 0, total = 0
            for x in 8..<(width - 8) {
                let error = abs(pixel(actual, x: x, y: height / 2, width: width)[0] - pixel(expected, x: x, y: height / 2, width: width)[0])
                total += error
                if abs(x - footprint) <= 4 { seamMaximum = max(seamMaximum, error) } else { interiorMaximum = max(interiorMaximum, error) }
            }
            let report = "Fragment medium seam at \(footprint)×\(height)px/cell: max \(seamMaximum)/255, interior max \(interiorMaximum)/255, mean \(Double(total) / Double(width - 16))\n"
            FileHandle.standardOutput.write(Data(report.utf8))
            if let output = ProcessInfo.processInfo.environment["RIDGE_CARTOGRAPHY_CAPTURE"] {
                let comparison = actual + expected
                let comparisonImage = CGImage(width: width, height: height * 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                              provider: CGDataProvider(data: Data(comparison) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                let captureURL = URL(fileURLWithPath: output).appendingPathComponent("medium-seam-\(footprint)-\(height).png")
                let capture = CGImageDestinationCreateWithURL(captureURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(capture, comparisonImage, nil); precondition(CGImageDestinationFinalize(capture))
            }
            check(seamMaximum <= 5, "Medium shared-edge sampling diverged from a continuous image")
            check(interiorMaximum <= 5, "Medium sampling or upload scale changed the map away from its edge")
        }
        let nativeReferenceMetadata = try pattern(width: 2056, height: 1032, offset: -4, name: "stripe-native-continuous.png", bounds: atlas.bounds)
        let nativeReferenceDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 2056, height: 1032, mipmapped: true)
        nativeReferenceDescription.storageMode = .private; nativeReferenceDescription.usage = [.shaderRead, .pixelFormatView]
        let nativeReference = device.makeTexture(descriptor: nativeReferenceDescription)!
        try CartographyRenderer.testUpload(device: device, queue: queue, url: directory.appendingPathComponent(nativeReferenceMetadata.file),
                                           metadata: nativeReferenceMetadata, destination: nativeReference, slice: 0)
        let nativeReady = [SIMD4<UInt32>(1, Float(1).bitPattern, 0, 0), SIMD4<UInt32>(2, Float(1).bitPattern, 0, 0)]
        for height in [512, 160] {
            let actual = render(width: 1024, height: height, previewA: previewA, previewB: previewB, native: native, medium: medium, pages: nativeReady)
            let expected = render(width: 1024, height: height, previewA: previewA, previewB: previewB, native: native, medium: medium, pages: nativeReady,
                                  reference: nativeReference, textureRect: SIMD4(-4.0 / 1024, -4.0 / 1024, 2056.0 / 1024, 1032.0 / 1024))
            let errors = (16..<1008).map { x in abs(pixel(actual, x: x, y: height / 2, width: 1024)[0] - pixel(expected, x: x, y: height / 2, width: 1024)[0]) }
            let maximum = errors.max()!
            FileHandle.standardOutput.write(Data("Fragment native seam at512×\(height)px/cell: maximum \(maximum)/255\n".utf8))
            check(maximum <= 2, "Native explicit gradients/gutters changed a continuous image")
        }
    }
}
