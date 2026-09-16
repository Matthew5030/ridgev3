import Foundation
import CryptoKit
import zlib

struct AdaptiveTerrainError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Published immutable geometry descriptor, also stored with each saved selection.
struct AdaptiveChunk: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var bounds: GeoBounds
    var path: String
    var byteCount: Int
    var sha256: String
    var decodedByteCount: Int
    var decodedSHA256: String
    var vertices: Int
    var triangles: Int
    var indexWidth: Int
    var topologyByteCount: Int
    var topologySHA256: String
    var byteOffset: Int64?
    var maxErrorMetres: Double
    /// Asset location within a registered, immutable download source.
    var sourceID: String? = nil

    var fileName: String { id + ".rat.zlib" }
    var residentBytes: Int64 {
        // CPU compact vertices/indices, triangle lookup, GPU vertices/UInt32 indices.
        Int64(vertices) * 54 + Int64(triangles) * Int64(3 * indexWidth + 12 + 20) + 65536
    }
    func validate() throws {
        let safe: (String) -> Bool = { !$0.isEmpty && $0.count <= 160 && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) } }
        guard safe(id), safe(path), sourceID.map(safe) ?? true, bounds.isValid,
              (4...263169).contains(vertices), (2...524288).contains(triangles),
              indexWidth == (vertices <= 65536 ? 2 : 4),
              decodedByteCount == 28 + vertices * 6 + triangles * 3 * indexWidth,
              (32...600000).contains(topologyByteCount), (1...1000000).contains(byteCount),
              [sha256, decodedSHA256, topologySHA256].allSatisfy({ $0.count == 64 && $0.allSatisfy { $0.isHexDigit } }),
              byteOffset.map({ $0 >= 0 && $0 <= Int64.max - Int64(byteCount) }) ?? true,
              maxErrorMetres.isFinite, (0...0.5).contains(maxErrorMetres) else {
            throw AdaptiveTerrainError(message: "Invalid adaptive terrain chunk.")
        }
    }
}

/// Compact CPU copy of the exact decoded triangles; reusable for picking and GPX elevation.
struct AdaptiveMesh: Sendable {
    let chunk: AdaptiveChunk
    let data: Data
    let scale: Float
    let offset: Float
    let minimum: Float
    let maximum: Float
    // Uniform native-coordinate buckets contain triangle IDs, not resampled heights.
    let buckets: [[Int32]]
    static let bucketSide = 32

    func vertex(_ index: Int) -> SIMD3<Float> {
        let p = 28 + index * 6
        return SIMD3(Float(data.le16(p)), Float(Int16(bitPattern: data.le16(p + 4))) * scale + offset, Float(data.le16(p + 2)))
    }
    func index(_ index: Int) -> Int {
        let p = 28 + chunk.vertices * 6 + index * chunk.indexWidth
        return chunk.indexWidth == 2 ? Int(data.le16(p)) : Int(data.le32(p))
    }
    func elevation(at point: GeoPoint) -> Double? {
        guard chunk.bounds.contains(point) else { return nil }
        let uv = chunk.bounds.uv(point)
        return height(x: Float(uv.u * 512), y: Float(uv.v * 512)).map(Double.init)
    }
    func height(x: Float, y: Float) -> Float? {
        guard x >= 0, x <= 512, y >= 0, y <= 512 else { return nil }
        let bx = min(31, Int(x / 16)), by = min(31, Int(y / 16))
        for triangle in buckets[by * 32 + bx] {
            let i = Int(triangle) * 3
            let a = vertex(index(i)), b = vertex(index(i + 1)), c = vertex(index(i + 2))
            let d = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
            guard abs(d) > 0.00001 else { continue }
            let u = ((b.z - c.z) * (x - c.x) + (c.x - b.x) * (y - c.z)) / d
            let v = ((c.z - a.z) * (x - c.x) + (a.x - c.x) * (y - c.z)) / d
            if u >= -0.00001, v >= -0.00001, u + v <= 1.00001 { return u * a.y + v * b.y + (1 - u - v) * c.y }
        }
        return nil
    }
}

extension Data {
    fileprivate func le16(_ p: Int) -> UInt16 { UInt16(self[p]) | UInt16(self[p + 1]) << 8 }
    fileprivate func le32(_ p: Int) -> UInt32 { UInt32(le16(p)) | UInt32(le16(p + 2)) << 16 }
    fileprivate mutating func append16(_ n: UInt16) { append(UInt8(truncatingIfNeeded: n)); append(UInt8(truncatingIfNeeded: n >> 8)) }
    fileprivate mutating func append32(_ n: UInt32) { append16(UInt16(truncatingIfNeeded: n)); append16(UInt16(truncatingIfNeeded: n >> 16)) }
}

/// Implements the published canonical RTIN traversal (MARTINI, ISC), without error analysis.
enum AdaptiveTerrainCodec {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func inflate(_ compressed: Data, byteCount: Int) throws -> Data {
        guard byteCount > 0, byteCount <= 16_777_216, !compressed.isEmpty, compressed.count <= 16_777_216 else { throw AdaptiveTerrainError(message: "Invalid compressed terrain size.") }
        var data = Data(count: byteCount), size = uLongf(byteCount)
        let status = data.withUnsafeMutableBytes { out in compressed.withUnsafeBytes { input in
            uncompress(out.bindMemory(to: Bytef.self).baseAddress!, &size, input.bindMemory(to: Bytef.self).baseAddress!, uLong(compressed.count))
        } }
        guard status == Z_OK, size == byteCount else { throw AdaptiveTerrainError(message: "The terrain download is incomplete or damaged.") }
        return data
    }
    static func decode(_ compressed: Data, chunk: AdaptiveChunk) throws -> AdaptiveMesh {
        try chunk.validate(); try Task.checkCancellation()
        guard compressed.count == chunk.byteCount, hash(compressed) == chunk.sha256 else { throw AdaptiveTerrainError(message: "Adaptive download checksum mismatch.") }
        let topology = try inflate(compressed, byteCount: chunk.topologyByteCount)
        guard hash(topology) == chunk.topologySHA256 else { throw AdaptiveTerrainError(message: "Adaptive topology checksum mismatch.") }
        let data = try reconstruct(topology)
        guard data.count == chunk.decodedByteCount, hash(data) == chunk.decodedSHA256,
              data.le32(4) == chunk.vertices, data.le32(8) == chunk.triangles else { throw AdaptiveTerrainError(message: "Adaptive mesh checksum mismatch.") }
        let scale = Float(bitPattern: data.le32(20)), offset = Float(bitPattern: data.le32(24))
        guard scale.isFinite, scale > 0, scale <= 100, offset.isFinite else { throw AdaptiveTerrainError(message: "Invalid adaptive elevation scale.") }
        var minimum = Float.infinity, maximum = -Float.infinity
        for i in 0..<chunk.vertices {
            let p = 28 + i * 6
            let h = Float(Int16(bitPattern: data.le16(p + 4))) * scale + offset
            minimum = min(minimum, h); maximum = max(maximum, h)
        }
        var buckets = [[Int32]](repeating: [], count: 1024)
        let start = 28 + chunk.vertices * 6
        func index(_ n: Int) -> Int { let p = start + n * chunk.indexWidth; return chunk.indexWidth == 2 ? Int(data.le16(p)) : Int(data.le32(p)) }
        for t in 0..<chunk.triangles {
            if t % 4096 == 0 { try Task.checkCancellation() }
            let points = (0..<3).map { n -> (Int, Int) in let p = 28 + index(t * 3 + n) * 6; return (Int(data.le16(p)), Int(data.le16(p + 2))) }
            let xs = points.map { min(31, $0.0 / 16) }, ys = points.map { min(31, $0.1 / 16) }
            for y in ys.min()!...ys.max()! { for x in xs.min()!...xs.max()! { buckets[y * 32 + x].append(Int32(t)) } }
        }
        return AdaptiveMesh(chunk: chunk, data: data, scale: scale, offset: offset, minimum: minimum, maximum: maximum, buckets: buckets)
    }
    static func reconstruct(_ data: Data) throws -> Data {
        guard data.count >= 32, data.prefix(4) == Data("RAT1".utf8), data.le32(16) == 513 else { throw AdaptiveTerrainError(message: "Unsupported adaptive terrain format.") }
        let vertices = Int(data.le32(4)), count = Int(data.le32(8)), width = Int(data.le32(12)), bits = Int(data.le32(28))
        guard (4...263169).contains(vertices), (2...524288).contains(count), width == (vertices <= 65536 ? 2 : 4), bits <= 524288,
              data.count == 32 + (bits + 7) / 8 + vertices * 2 else { throw AdaptiveTerrainError(message: "Invalid adaptive topology size.") }
        struct Point { var x: Int32; var y: Int32 }
        struct Triangle { var a: Point; var b: Point; var c: Point }
        var triangles: [Triangle] = []; triangles.reserveCapacity(count)
        var used = 0
        func visit(_ a: Point, _ b: Point, _ c: Point, depth: Int = 0) throws {
            guard depth <= 20 else { throw AdaptiveTerrainError(message: "Invalid adaptive subdivision depth.") }
            if abs(a.x - c.x) + abs(a.y - c.y) > 1 {
                guard used < bits else { throw AdaptiveTerrainError(message: "Truncated adaptive topology.") }
                let split = (data[32 + used / 8] >> (used % 8)) & 1; used += 1
                if split != 0 {
                    let mid = Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    try visit(c, a, mid, depth: depth + 1); try visit(b, c, mid, depth: depth + 1); return
                }
            }
            guard triangles.count < count else { throw AdaptiveTerrainError(message: "Adaptive triangle count mismatch.") }
            triangles.append(Triangle(a: a, b: b, c: c))
        }
        try visit(Point(x: 0, y: 0), Point(x: 512, y: 512), Point(x: 512, y: 0))
        try visit(Point(x: 512, y: 512), Point(x: 0, y: 0), Point(x: 0, y: 512))
        guard used == bits, triangles.count == count else { throw AdaptiveTerrainError(message: "Adaptive topology count mismatch.") }
        var cells = [Int32](repeating: -1, count: 512 * 512)
        for i in triangles.indices {
            if i % 4096 == 0 { try Task.checkCancellation() }
            let t = triangles[i], x = min(t.a.x, t.b.x, t.c.x), y = min(t.a.y, t.b.y, t.c.y)
            guard max(t.a.x, t.b.x, t.c.x) - x == 1, max(t.a.y, t.b.y, t.c.y) - y == 1 else { continue }
            let cell = Int(y * 512 + x), previous = cells[cell]
            if previous < 0 { cells[cell] = Int32(i) }
            else {
                triangles[Int(previous)] = Triangle(a: Point(x: x, y: y), b: Point(x: x, y: y + 1), c: Point(x: x + 1, y: y))
                triangles[i] = Triangle(a: Point(x: x + 1, y: y), b: Point(x: x, y: y + 1), c: Point(x: x + 1, y: y + 1)); cells[cell] = -1
            }
        }
        var lookup = [Int32](repeating: -1, count: 513 * 513), positions: [Point] = [], indices: [UInt32] = []
        positions.reserveCapacity(vertices); indices.reserveCapacity(count * 3)
        for t in triangles { for p in [t.a, t.b, t.c] {
            let slot = Int(p.y * 513 + p.x)
            if lookup[slot] < 0 { lookup[slot] = Int32(positions.count); positions.append(p) }
            indices.append(UInt32(lookup[slot]))
        } }
        guard positions.count == vertices else { throw AdaptiveTerrainError(message: "Adaptive vertex count mismatch.") }
        var result = Data("RME1".utf8); result.append(data[4..<28]); result.reserveCapacity(28 + vertices * 6 + count * 3 * width)
        let heights = 32 + (bits + 7) / 8
        for (i, p) in positions.enumerated() { result.append16(UInt16(p.x)); result.append16(UInt16(p.y)); result.append16(data.le16(heights + i * 2)) }
        for i in indices { if width == 2 { result.append16(UInt16(i)) } else { result.append32(i) } }
        return result
    }
}

/// A full source has an immutable index; saved selections contain only chosen chunks.
/// `coverage` is a compact cell mask for the atlas before the index is fetched.
struct AdaptiveTerrainSource: Codable, Hashable, Sendable {
    var toleranceMetres: Double = 0.5
    var isSource: Bool
    var chunks: [AdaptiveChunk]
    var coverage: [Bool]
    var index: SourceAsset? = nil
    var overview: MapTexture? = nil
    var graphs: [TerrainSourceGraph] = []
    var downloadBytes: Int64 { chunks.reduce(0) { $0 + Int64($1.byteCount) } }

    func validate(bounds: GeoBounds, grid: TerrainGrid?) throws {
        guard toleranceMetres == 0.5, let grid, grid.isValid, coverage.count == grid.columns * grid.rows,
              chunks.count <= 2304, Set(chunks.map(\.id)).count == chunks.count,
              graphs.count <= 16 else { throw AdaptiveTerrainError(message: "Invalid adaptive terrain index.") }
        if let index {
            guard isSource, index.byteCount > 0, index.byteCount < 32_000_000,
                  index.sha256.count == 64, index.file == "index.json", chunks.isEmpty else { throw AdaptiveTerrainError(message: "Invalid adaptive source reference.") }
        } else {
            guard chunks.count == coverage.filter({ $0 }).count else { throw AdaptiveTerrainError(message: "Adaptive coverage does not match its mesh index.") }
            for chunk in chunks {
                try chunk.validate()
                let uv = bounds.uv(chunk.bounds.center)
                let x = Int(floor(uv.u * Double(grid.columns))), y = Int(floor(uv.v * Double(grid.rows)))
                guard x >= 0, x < grid.columns, y >= 0, y < grid.rows, coverage[y * grid.columns + x],
                      abs(chunk.bounds.minLongitude - bounds.point(u: Double(x) / Double(grid.columns), v: 0).longitude) < 1e-9,
                      abs(chunk.bounds.maxLongitude - bounds.point(u: Double(x + 1) / Double(grid.columns), v: 0).longitude) < 1e-9,
                      abs(chunk.bounds.maxLatitude - bounds.point(u: 0, v: Double(y) / Double(grid.rows)).latitude) < 1e-9,
                      abs(chunk.bounds.minLatitude - bounds.point(u: 0, v: Double(y + 1) / Double(grid.rows)).latitude) < 1e-9 else { throw AdaptiveTerrainError(message: "Adaptive cells do not match their geographic grid.") }
            }
            if !isSource && !coverage.allSatisfy({ $0 }) { throw AdaptiveTerrainError(message: "The selected area includes missing terrain.") }
        }
    }
}
