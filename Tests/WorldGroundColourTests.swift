import Foundation
import CoreGraphics

/// Behavioural checks: old data, cloudy pixels, geographic orientation, protected
/// features, line readability, gutters and hostile asset lengths.
func testGroundColour() throws {
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw RidgeError.message("Ground colour: " + message) }
    }
    func bytes(_ image: CGImage) -> [UInt8] { [UInt8](image.dataProvider!.data! as Data) }
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = bytes(image), i = y * image.bytesPerRow + x * 4
        return Array(data[i..<i+4])
    }
    let legacy = Data(#"{"width":32,"height":32,"paths":[]}"#.utf8)
    var map = try JSONDecoder().decode(WorldVectorMap.self, from: legacy)
    try require(map.groundColour == nil, "legacy maps decode without imagery")
    map.paths = [
        .init(kind:"water", closed:true, rings:[[[0,0],[12,0],[12,12],[0,12]]]),
        .init(kind:"footpath", closed:false, rings:[[[0,24],[32,24]]])
    ]
    let original = try WorldCartography.draw(map, pixels:128)
    // RGBA rows and native map coordinates must agree about which way is north.
    try require(pixel(original, 20, 20) == [168,203,209,255], "native bitmap rows are north-up")
    var rgba = [UInt8]()
    for y in 0..<12 { for _ in 0..<12 { rgba += y < 6 ? [255,0,0,255] : [0,0,255,255] } }
    let samples = WorldVectorMap.GroundColour(version:1, width:12, height:12, border:2, rgba:Data(rgba))
    map.groundColour = samples
    let coloured = try WorldCartography.draw(map, pixels:128)
    let north = pixel(coloured,100,20), south = pixel(coloured,100,116)
    try require(north[0] > north[2] && south[2] > south[0], "north/south samples align with geography")
    try require(pixel(coloured,20,20) == pixel(original,20,20), "water fill stays unchanged")
    // The centre of an opaque path stroke is exactly the original ink colour.
    try require(pixel(coloured,12,100) == pixel(original,12,100), "paths are drawn over ground")
    for i in stride(from:3, to:rgba.count, by:4) { rgba[i] = 0 }
    map.groundColour!.rgba = Data(rgba)
    try require(bytes(try WorldCartography.draw(map,pixels:128)) == bytes(original), "cloudy/no-data pixels retain original cartography exactly")
    map.paths = []; map.groundColour = samples
    let start = Date()
    _ = try WorldCartography.draw(map,pixels:1024)
    print("Ground colour 1024px render: \(Date().timeIntervalSince(start)) seconds (Mac)")
    for resolution in [32,64,128,256,512,1024] {
        let image = try WorldCartography.draw(map,pixels:resolution)
        try require(pixel(image,0,0)[0] > pixel(image,0,0)[2], "north gutter retained at every LOD")
        try require(pixel(image,0,resolution+7)[2] > pixel(image,0,resolution+7)[0], "south gutter retained at every LOD")
    }
    var invalid = samples
    invalid.rgba = Data([0,1,2])
    do { try invalid.validate(); throw RidgeError.message("Accepted invalid byte length") }
    catch { try require(error.localizedDescription != "Accepted invalid byte length", "reject malformed samples") }
    invalid = samples; invalid.border = 1
    do { try invalid.validate(); throw RidgeError.message("Accepted insufficient gutter") }
    catch { try require(error.localizedDescription != "Accepted insufficient gutter", "reject insufficient gutter") }
    // Only the offline atlas build can use a whole-section colour raster.
    let overview=WorldVectorMap.GroundColour(version:1,width:264,height:264,border:4,rgba:Data(repeating:255,count:264*264*4))
    do { try overview.validate();throw RidgeError.message("Accepted overview as a runtime tile") }
    catch { try require(error.localizedDescription != "Accepted overview as a runtime tile", "runtime colour allocation stays bounded") }
    var overviewMap=map;overviewMap.groundColour=overview
    let capture=try WorldCartography.draw(overviewMap,pixels:256,overview:true)
    try require(capture.width==264 && capture.height==264,"atlas captures use the native ground-colour blend")
    overviewMap.groundColour!.rgba=Data([0])
    do { _=try WorldCartography.draw(overviewMap,pixels:256,overview:true);throw RidgeError.message("Accepted damaged overview") }
    catch { try require(error.localizedDescription != "Accepted damaged overview", "overview validates its sample bytes") }
    print("Ground colour: legacy fallback, orientation, masking, ink, gutters and validation passed")
}
