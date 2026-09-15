import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Small generated data for workflow tests, independent of optional map packs.
enum TerrainFixture {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func png(size: Int) throws -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.7, green: 0.8, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { throw RidgeError.message("Fixture PNG encoding failed") }
        return data as Data
    }

    static func make(template: URL, directory: URL) throws -> RegionManifest {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var source = try JSONDecoder().decode(RegionManifest.self, from: Data(contentsOf: template.appendingPathComponent("pack.json")))
        source.id = "workflow-fixture"; source.name = "Generated workflow terrain"
        source.horizon = nil; source.detailTextures = nil; source.cartographySourceID = nil; source.tiledTerrain = nil
        source.graphFile = nil; source.graphByteCount = nil; source.graphSHA256 = nil; source.places = []
        source.grid = TerrainGrid(gridID: "ridge-eryri-uniform-v1", worldTileID: "workflow-grid", originColumn: 0, originRow: 0, columns: 4, rows: 4)
        source.bounds = GeoBounds(minLatitude: 53, minLongitude: -4.1, maxLatitude: 53.0184, maxLongitude: -4.0694)
        source.levels = try [1, 2, 4, 8, 16, 32].map { spacing in
            let side = 4 * 512 / spacing + 1
            let data = [Int16](repeating: Int16(1000).littleEndian, count: side * side).withUnsafeBytes { Data($0) }
            let file = "terrain-\(spacing)m.bin"
            try data.write(to: directory.appendingPathComponent(file))
            return TerrainLOD(spacing: spacing, width: side, height: side, file: file, byteCount: Int64(data.count), sha256: hash(data))
        }
        source.defaultSpacing = 8
        let native = try png(size: CartographyAtlas.imageSize), preview = try png(size: CartographyAtlas.previewSize)
        let longitude = (0...4).map { source.bounds.point(u: Double($0) / 4, v: 0).longitude }
        let latitude = (0...4).map { source.bounds.point(u: 0, v: Double($0) / 4).latitude }
        var tiles: [CartographyTile] = []
        for row in 0..<4 { for column in 0..<4 {
            let bounds = GeoBounds(minLatitude: latitude[row + 1], minLongitude: longitude[column], maxLatitude: latitude[row], maxLongitude: longitude[column + 1])
            func image(_ bytes: Data, size: Int, suffix: String) throws -> MapTexture {
                let file = "map-\(column)-\(row)-\(suffix).png"
                try bytes.write(to: directory.appendingPathComponent(file))
                return MapTexture(file: file, width: size, height: size, byteCount: Int64(bytes.count), sha256: hash(bytes), bounds: bounds)
            }
            tiles.append(CartographyTile(image: try image(native, size: CartographyAtlas.imageSize, suffix: "native"),
                                        preview: try image(preview, size: CartographyAtlas.previewSize, suffix: "preview")))
        } }
        source.textures = []
        source.cartography = CartographyAtlas(columns: 4, rows: 4, longitudeEdges: longitude, latitudeEdges: latitude, tiles: tiles)
        try PackStore.validate(source)
        try JSONEncoder().encode(source).write(to: directory.appendingPathComponent("pack.json"))
        return source
    }
}
