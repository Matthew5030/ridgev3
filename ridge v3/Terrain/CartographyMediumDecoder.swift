import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Builds one geographic medium page while the caller holds the global decode
/// lock. Only one encoded file and decoded native image are retained at a time.
enum CartographyMediumDecoder {
    static func draw(tile index: Int, atlas: LoadedCartography, into context: CGContext) throws {
        try Task.checkCancellation()
        let side = CartographyAtlas.mediumSize
        guard context.width == side, context.height == side, context.bitsPerComponent == 8,
              context.bitsPerPixel == 32, context.bytesPerRow >= side * 4,
              let output = context.data else { throw Failure("The middle-distance map buffer is invalid.") }
        let scale = CartographyAtlas.imageCoreSize / CartographyAtlas.mediumCoreSize
        guard scale == 4 else { throw Failure("The middle-distance map scale is invalid.") }
        let nativeSide = side * scale
        let nativeBytesPerRow = nativeSide * 4
        // Quartz's high-quality reduction changes sample phase with image
        // extent. Assemble at native scale first, then apply one fixed linear
        // colour filter so neighbouring pages always share identical samples.
        let native = UnsafeMutableRawPointer.allocate(byteCount: nativeBytesPerRow * nativeSide, alignment: 64)
        defer { native.deallocate() }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: native, width: nativeSide, height: nativeSide,
                                     bitsPerComponent: 8, bytesPerRow: nativeBytesPerRow, space: space,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw Failure("The middle-distance map canvas could not be prepared.")
        }
        try drawNativeCanvas(tile: index, atlas: atlas, into: canvas)
        let input = native.assumingMemoryBound(to: UInt8.self)
        let destination = output.assumingMemoryBound(to: UInt8.self)
        for y in 0..<side {
            try Task.checkCancellation()
            for x in 0..<side {
                let start = y * scale * nativeBytesPerRow + x * scale * 4
                let pixel = y * context.bytesPerRow + x * 4
                for channel in 0..<3 {
                    var linear: Float = 0
                    for dy in 0..<scale {
                        for dx in 0..<scale {
                            linear += linearValues[Int(input[start + dy * nativeBytesPerRow + dx * 4 + channel])]
                        }
                    }
                    destination[pixel + channel] = encodedValues[min(encodedValues.count - 1, Int((linear / 16 * Float(encodedValues.count - 1)).rounded()))]
                }
                destination[pixel + 3] = 255
            }
        }
        try Task.checkCancellation()
    }

    private static let linearValues: [Float] = (0...255).map { value in
        let s = Float(value) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    private static let encodedValues: [UInt8] = (0...65535).map { value in
        let linear = Double(value) / 65535
        let s = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return UInt8(clamping: Int((s * 255).rounded()))
    }

    private static func drawNativeCanvas(tile index: Int, atlas: LoadedCartography, into context: CGContext) throws {
        try Task.checkCancellation()
        let metadata = atlas.metadata
        let total = metadata.columns.multipliedReportingOverflow(by: metadata.rows)
        guard metadata.columns > 0, metadata.rows > 0, !total.overflow,
              total.partialValue == metadata.tiles.count, total.partialValue <= CartographyAtlas.maximumTiles,
              metadata.longitudeEdges.count == metadata.columns + 1,
              metadata.latitudeEdges.count == metadata.rows + 1,
              atlas.imageURLs.count == metadata.tiles.count,
              metadata.tiles.indices.contains(index),
              context.width == CartographyAtlas.mediumSize * 4, context.height == CartographyAtlas.mediumSize * 4,
              context.bitsPerComponent == 8 else { throw Failure("The middle-distance map page is invalid.") }
        let column = index % metadata.columns, row = index / metadata.columns
        let target = metadata.tiles[index].image.bounds
        guard target.isValid else { throw Failure("The middle-distance map has invalid geographic bounds.") }
        let dx = target.maxLongitude - target.minLongitude
        let dy = target.maxLatitude - target.minLatitude
        let fraction = Double(CartographyAtlas.mediumGutter) / Double(CartographyAtlas.mediumCoreSize)
        let canvas = GeoBounds(minLatitude: target.minLatitude - dy * fraction,
                               minLongitude: target.minLongitude - dx * fraction,
                               maxLatitude: target.maxLatitude + dy * fraction,
                               maxLongitude: target.maxLongitude + dx * fraction)
        let firstColumn = max(0, column - 1), lastColumn = min(metadata.columns - 1, column + 1)
        let firstRow = max(0, row - 1), lastRow = min(metadata.rows - 1, row + 1)
        let neighbourhood = GeoBounds(minLatitude: metadata.latitudeEdges[lastRow + 1],
                                      minLongitude: metadata.longitudeEdges[firstColumn],
                                      maxLatitude: metadata.latitudeEdges[firstRow],
                                      maxLongitude: metadata.longitudeEdges[lastColumn + 1])
        let coverage = metadata.bounds
        let needed = GeoBounds(minLatitude: max(canvas.minLatitude, coverage.minLatitude),
                               minLongitude: max(canvas.minLongitude, coverage.minLongitude),
                               maxLatitude: min(canvas.maxLatitude, coverage.maxLatitude),
                               maxLongitude: min(canvas.maxLongitude, coverage.maxLongitude))
        guard neighbourhood.isValid, coverage.isValid, needed.isValid,
              neighbourhood.minLatitude <= needed.minLatitude, neighbourhood.maxLatitude >= needed.maxLatitude,
              neighbourhood.minLongitude <= needed.minLongitude, neighbourhood.maxLongitude >= needed.maxLongitude else {
            throw Failure("The map cells cannot supply a bounded middle-distance gutter.")
        }
        func rectangle(_ bounds: GeoBounds) -> CGRect {
            CGRect(x: (bounds.minLongitude - canvas.minLongitude) / (canvas.maxLongitude - canvas.minLongitude) * Double(context.width),
                   y: (bounds.minLatitude - canvas.minLatitude) / (canvas.maxLatitude - canvas.minLatitude) * Double(context.height),
                   width: (bounds.maxLongitude - bounds.minLongitude) / (canvas.maxLongitude - canvas.minLongitude) * Double(context.width),
                   height: (bounds.maxLatitude - bounds.minLatitude) / (canvas.maxLatitude - canvas.minLatitude) * Double(context.height))
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.clear(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.setBlendMode(.copy)
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        for neighbourRow in firstRow...lastRow {
            for neighbourColumn in firstColumn...lastColumn {
                try Task.checkCancellation()
                let neighbour = neighbourRow * metadata.columns + neighbourColumn
                let texture = metadata.tiles[neighbour].image
                let bounds = texture.bounds
                let expected = GeoBounds(minLatitude: metadata.latitudeEdges[neighbourRow + 1],
                                         minLongitude: metadata.longitudeEdges[neighbourColumn],
                                         maxLatitude: metadata.latitudeEdges[neighbourRow],
                                         maxLongitude: metadata.longitudeEdges[neighbourColumn + 1])
                guard bounds == expected, bounds.isValid else { throw Failure("A map neighbour has invalid geographic bounds.") }
                guard intersects(bounds, canvas) else { continue }
                try autoreleasepool {
                    let image = try decode(atlas.imageURLs[neighbour], metadata: texture)
                    try Task.checkCancellation()
                    let gx = (bounds.maxLongitude - bounds.minLongitude) * Double(CartographyAtlas.gutter) / Double(CartographyAtlas.imageCoreSize)
                    let gy = (bounds.maxLatitude - bounds.minLatitude) * Double(CartographyAtlas.gutter) / Double(CartographyAtlas.imageCoreSize)
                    let imageBounds = GeoBounds(minLatitude: bounds.minLatitude - gy, minLongitude: bounds.minLongitude - gx,
                                                maxLatitude: bounds.maxLatitude + gy, maxLongitude: bounds.maxLongitude + gx)
                    // A neighbour supplies only its own geographic core. Its
                    // native gutters remain available to the downsample filter.
                    // CGContext uses south-to-low-y drawing coordinates; high
                    // context y appears in low bitmap row indices. Direct
                    // CGImage drawing therefore keeps north at texture v=0,
                    // with no vertical transform or context y flip.
                    context.saveGState()
                    context.clip(to: rectangle(bounds))
                    context.draw(image, in: rectangle(imageBounds))
                    context.restoreGState()
                    try extendCoverageEdge(image, bounds: bounds, canvas: canvas,
                                           west: neighbourColumn == 0, east: neighbourColumn == metadata.columns - 1,
                                           north: neighbourRow == 0, south: neighbourRow == metadata.rows - 1,
                                           into: context, rectangle: rectangle)
                    try Task.checkCancellation()
                }
            }
        }
        try Task.checkCancellation()
    }

    private static func decode(_ url: URL, metadata: MapTexture) throws -> CGImage {
        try Task.checkCancellation()
        guard url.isFileURL, url.lastPathComponent == metadata.file,
              metadata.width == CartographyAtlas.imageSize, metadata.height == CartographyAtlas.imageSize,
              metadata.byteCount > 0, metadata.byteCount <= CartographyAtlas.maximumImageFileBytes else {
            throw Failure("A detailed map neighbour is invalid.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == metadata.byteCount else {
            throw Failure("A saved map neighbour is incomplete.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Int(metadata.byteCount) + 1) ?? Data()
        guard data.count == metadata.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.sha256.lowercased() else {
            throw Failure("A saved map neighbour failed its integrity check.")
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == CartographyAtlas.imageSize,
              properties[kCGImagePropertyPixelHeight] as? Int == CartographyAtlas.imageSize else {
            throw Failure("A saved map neighbour has invalid dimensions.")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw Failure("A saved map neighbour could not be decoded.")
        }
        try Task.checkCancellation()
        return image
    }

    /// Only pixels beyond the actual atlas edge are extended. Each edge strip
    /// comes from its nearest canonical core row/column, including true corners.
    private static func extendCoverageEdge(_ image: CGImage, bounds: GeoBounds, canvas: GeoBounds,
                                           west: Bool, east: Bool, north: Bool, south: Bool,
                                           into context: CGContext, rectangle: (GeoBounds) -> CGRect) throws {
        let first = CartographyAtlas.gutter
        let last = first + CartographyAtlas.imageCoreSize - 1
        let core = CartographyAtlas.imageCoreSize
        func draw(_ pixels: CGRect, _ area: GeoBounds) throws {
            guard area.minLongitude < area.maxLongitude, area.minLatitude < area.maxLatitude,
                  intersects(area, canvas) else { return }
            guard let strip = image.cropping(to: pixels) else { throw Failure("A map coverage edge could not be prepared.") }
            context.draw(strip, in: rectangle(area))
        }
        if west && canvas.minLongitude < bounds.minLongitude {
            try draw(CGRect(x: first, y: first, width: 1, height: core),
                     GeoBounds(minLatitude: bounds.minLatitude, minLongitude: canvas.minLongitude, maxLatitude: bounds.maxLatitude, maxLongitude: bounds.minLongitude))
        }
        if east && canvas.maxLongitude > bounds.maxLongitude {
            try draw(CGRect(x: last, y: first, width: 1, height: core),
                     GeoBounds(minLatitude: bounds.minLatitude, minLongitude: bounds.maxLongitude, maxLatitude: bounds.maxLatitude, maxLongitude: canvas.maxLongitude))
        }
        if north && canvas.maxLatitude > bounds.maxLatitude {
            try draw(CGRect(x: first, y: first, width: core, height: 1),
                     GeoBounds(minLatitude: bounds.maxLatitude, minLongitude: bounds.minLongitude, maxLatitude: canvas.maxLatitude, maxLongitude: bounds.maxLongitude))
        }
        if south && canvas.minLatitude < bounds.minLatitude {
            try draw(CGRect(x: first, y: last, width: core, height: 1),
                     GeoBounds(minLatitude: canvas.minLatitude, minLongitude: bounds.minLongitude, maxLatitude: bounds.minLatitude, maxLongitude: bounds.maxLongitude))
        }
        for (horizontal, x, minLongitude, maxLongitude) in [(west, first, canvas.minLongitude, bounds.minLongitude),
                                                           (east, last, bounds.maxLongitude, canvas.maxLongitude)] {
            for (vertical, y, minLatitude, maxLatitude) in [(north, first, bounds.maxLatitude, canvas.maxLatitude),
                                                          (south, last, canvas.minLatitude, bounds.minLatitude)] where horizontal && vertical {
                try draw(CGRect(x: x, y: y, width: 1, height: 1), GeoBounds(minLatitude: minLatitude, minLongitude: minLongitude, maxLatitude: maxLatitude, maxLongitude: maxLongitude))
            }
        }
    }

    private static func intersects(_ a: GeoBounds, _ b: GeoBounds) -> Bool {
        a.minLongitude < b.maxLongitude && a.maxLongitude > b.minLongitude && a.minLatitude < b.maxLatitude && a.maxLatitude > b.minLatitude
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
