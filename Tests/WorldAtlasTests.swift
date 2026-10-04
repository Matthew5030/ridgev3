import Foundation

@main struct WorldAtlasTests {
    static func main() throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) { assertions += 1; precondition(value, message) }
        for invalid in ["../page.jpg", "z20-x0-y0.jpg", "z5-x32-y0.jpg", "z5-x0-y-1.jpg", "x5-y1-z2.jpg"] {
            check(WorldAtlasPage(key: invalid) == nil, "Unsafe or invalid page: \(invalid)")
        }
        check(WorldAtlasPage(key: "z10-x502-y341")?.key == "z10-x502-y341.jpg", "Extension normalization")
        check(WorldAtlasPage(key: "z10-x502-y341.jpg")?.parent == WorldAtlasPage(zoom: 9, x: 251, y: 170), "XYZ parents")
        let pages = (5...10).flatMap { z in
            let n = 1 << z
            return (0..<n).flatMap { y in (0..<n).compactMap { x -> String? in
                let nx = Double(x) / Double(n), ny = Double(y) / Double(n)
                return nx > 0.45 && nx < 0.53 && ny > 0.28 && ny < 0.36 ? WorldAtlasPage(zoom: z, x: x, y: y).key : nil
            } }
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion":1,"tileSize":256,"minZoom":5,"maxZoom":10,"tiles":pages])
        let index = try WorldAtlasIndex(data: data)
        for scale in [7400.0, 32000, 128000, 4000000, 16000000] {
            for x in [0.475, 0.487, 0.502] {
                let selected = index.pages(centerX:x, centerY:0.32, scale:scale, width:1366, height:1024)
                check(!selected.isEmpty, "Covered viewport has images")
                check(selected.count <= 96, "Bounded allocation")
                check(selected == selected.sorted(), "Parent imagery is painted first")
                check(selected.allSatisfy { index.available.contains($0) }, "Only existing files")
                for page in selected where page.zoom > 5 {
                    if let parent = page.parent, index.available.contains(parent) { check(selected.contains(parent), "Parent fallback retained") }
                }
            }
        }
        let sparse = try WorldAtlasIndex(data: JSONSerialization.data(withJSONObject: ["schemaVersion":1,"tileSize":256,"minZoom":5,"maxZoom":10,"tiles":["z5-x15-y10.jpg","z10-x491-y327.jpg"]]))
        let fallback = sparse.pages(centerX:0.48,centerY:0.32,scale:100000,width:1000,height:1000)
        check(fallback == [WorldAtlasPage(zoom:5,x:15,y:10)], "Missing intermediate zoom uses parent without requests for absent files")
        check(index.pages(centerX:0.49,centerY:0.32,scale:.infinity,width:100,height:100).isEmpty, "Nonfinite scale")
        check(index.pages(centerX:0.49,centerY:0.32,scale:100,width:0,height:100).isEmpty, "Empty viewport")
        check(index.pages(centerX:2,centerY:2,scale:100000,width:100,height:100).isEmpty, "Outside world")
        print("World atlas: \(assertions) checks passed")
    }
}
