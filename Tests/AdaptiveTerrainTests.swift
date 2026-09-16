import Foundation
import zlib

@MainActor @main struct AdaptiveTerrainTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1; if !condition() { fatalError(message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Accepted: " + message) } catch { checks += 1 }
    }
    static func main() throws {
        // Two unsplit RTIN roots; heights form an independently known plane.
        var raw = Data("RAT1".utf8)
        func put(_ n: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { raw.append(UInt8(truncatingIfNeeded: n >> shift)) } }
        [4,2,2,513,Float(0.1).bitPattern,Float(0).bitPattern,2].forEach(put)
        raw.append(0)
        for n: Int16 in [100,400,200,300] { raw.append(UInt8(truncatingIfNeeded:n));raw.append(UInt8(truncatingIfNeeded:n >> 8)) }
        let decoded = try AdaptiveTerrainCodec.reconstruct(raw)
        expect(decoded.count == 64, "Flat mesh size")
        let first = decoded[28..<34]
        expect(Array(first) == [0,0,0,0,100,0], "First vertex")
        var size = compressBound(uLong(raw.count)), compressed = Data(count: Int(compressBound(uLong(raw.count))))
        let result = compressed.withUnsafeMutableBytes { out in raw.withUnsafeBytes { input in compress2(out.bindMemory(to: Bytef.self).baseAddress!, &size, input.bindMemory(to: Bytef.self).baseAddress!, uLong(raw.count), 9) } }
        expect(result == Z_OK, "Fixture compression"); compressed.count = Int(size)
        let bounds = GeoBounds(minLatitude:53,minLongitude:-4,maxLatitude:53.01,maxLongitude:-3.99)
        let chunk = AdaptiveChunk(id:"plane",bounds:bounds,path:"plane.rat.zlib",byteCount:compressed.count,sha256:AdaptiveTerrainCodec.hash(compressed),decodedByteCount:decoded.count,decodedSHA256:AdaptiveTerrainCodec.hash(decoded),vertices:4,triangles:2,indexWidth:2,topologyByteCount:raw.count,topologySHA256:AdaptiveTerrainCodec.hash(raw),maxErrorMetres:0)
        let mesh = try AdaptiveTerrainCodec.decode(compressed,chunk:chunk)
        for y in stride(from:0,through:512,by:32) { for x in stride(from:0,through:512,by:32) {
            expect(abs((mesh.height(x:Float(x),y:Float(y)) ?? -999) - (10 + Float(x)/512*10 + Float(y)/512*20)) < 0.001,"Barycentric plane")
        } }
        expect(mesh.height(x:-1,y:0) == nil,"Outside sample")
        for n in 0..<raw.count { rejects("truncated topology") { _ = try AdaptiveTerrainCodec.reconstruct(Data(raw.prefix(n))) } }
        var bad = compressed;bad[0] ^= 1
        rejects("damaged download") { _ = try AdaptiveTerrainCodec.decode(bad,chunk:chunk) }
        var invalid = chunk; invalid.path = "../escape"
        rejects("unsafe path") { try invalid.validate() }
        invalid = chunk;invalid.byteOffset = Int64.max
        rejects("overflowing range") { try invalid.validate() }
        invalid = chunk; invalid.decodedByteCount = Int.max
        rejects("unbounded allocation") { try invalid.validate() }
        rejects("inflate over limit") { _ = try AdaptiveTerrainCodec.inflate(compressed,byteCount:Int.max) }
        rejects("inflate wrong output size") { _ = try AdaptiveTerrainCodec.inflate(compressed,byteCount:raw.count+1) }
        var extra = raw;extra.append(0)
        rejects("trailing topology") { _ = try AdaptiveTerrainCodec.reconstruct(extra) }
        var malformed = raw;malformed[32] = 3
        rejects("invalid topology decisions") { _ = try AdaptiveTerrainCodec.reconstruct(malformed) }
        if CommandLine.arguments.count > 1 {
            let root=URL(fileURLWithPath:CommandLine.arguments[1])
            let descriptor=try JSONDecoder().decode(AdaptiveChunk.self,from:Data(contentsOf:root.appendingPathComponent("chunk.json")))
            let start=Date(), real=try AdaptiveTerrainCodec.decode(Data(contentsOf:root.appendingPathComponent("chunk.zlib")),chunk:descriptor)
            for i in stride(from:0,to:descriptor.vertices,by:101) { let p=real.vertex(i);expect(abs((real.height(x:p.x,y:p.z) ?? -9999)-p.y)<0.02,"Real native vertex") }
            print("Real chunk: \(descriptor.vertices) vertices, \(descriptor.triangles) triangles, \(Date().timeIntervalSince(start)) seconds")
        }
        let nativeBounds = GeoBounds(minLatitude: 53, minLongitude: -4, maxLatitude: 55, maxLongitude: -2)
        let grid = TerrainGrid(gridID: "ridge-native-adaptive-v1", worldTileID: "test-native", originColumn: 0, originRow: 0, columns: 2, rows: 2, longitudeEdges: [-4,-3,-2], latitudeEdges: [55,54.2,53])
        expect(grid.isValid, "Native grid accepts exact nonuniform latitude edges")
        expect(grid.point(u: 0.5, v: 0.5, in: nativeBounds).latitude == 54.2, "No latitude resampling")
        for row in 0..<2 { for column in 0..<2 {
            let p = grid.point(u: (Double(column)+0.5)/2, v: (Double(row)+0.5)/2, in: nativeBounds)
            let uv = grid.uv(p, in: nativeBounds)
            expect(abs(uv.u - (Double(column)+0.5)/2) < 1e-10 && abs(uv.v - (Double(row)+0.5)/2) < 1e-10, "Native grid round trip")
        } }
        let crop = grid.cropped(to: AreaSelection(minU: 0, minV: 0.5, maxU: 0.5, maxV: 1))!
        expect(crop.latitudeEdges == [54.2,53] && crop.longitudeEdges == [-4,-3], "Crop retains exact axes")
        print("Adaptive terrain: \(checks) checks passed")
    }
}
