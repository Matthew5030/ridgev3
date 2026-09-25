// Mac ImageIO compatibility and warm decode study. Not an iPad/GPU benchmark.
import Foundation
import ImageIO
import CoreGraphics

func decode(_ data: Data) -> [UInt8]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ok = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return ok ? pixels : nil
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default
let samples = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    .filter { $0.lastPathComponent.hasPrefix("cartography-") }.sorted { $0.path < $1.path }
var output: [[String: Any]] = []
for sample in samples {
    let referenceData = try Data(contentsOf: sample.appendingPathComponent("original/image.png"))
    guard let reference = decode(referenceData) else { fatalError("Original PNG cannot decode") }
    let names = ["original", "png9", "webp-lossless", "palette256", "palette128", "palette64", "webp90"]
    let files = try names.map { name -> Data in
        try Data(contentsOf: sample.appendingPathComponent(name + (name.hasPrefix("webp") ? "/image.webp" : "/image.png")))
    }
    var times = [[Double]](repeating: [], count: names.count)
    var errors = [Int?](repeating: nil, count: names.count)
    for round in 0..<10 {
        // Rotate order each round, discard the first warm-up; bytes already resident.
        for offset in names.indices {
            let index = (offset + round) % names.count
            let start = DispatchTime.now().uptimeNanoseconds
            let pixels = autoreleasepool { decode(files[index]) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000
            guard let pixels, pixels.count == reference.count else { continue }
            if round > 0 { times[index].append(ms) }
            if round == 0 { errors[index] = zip(reference,pixels).map { abs(Int($0)-Int($1)) }.max() }
        }
    }
    for index in names.indices {
        let sorted = times[index].sorted()
        var row: [String: Any] = ["sample": sample.lastPathComponent, "variant": names[index],
            "supported": !sorted.isEmpty, "measuredRounds": sorted.count]
        if !sorted.isEmpty { row["medianMs"] = sorted[sorted.count/2]; row["maxRGBAError"] = errors[index] }
        output.append(row)
    }
}
let result: [String: Any] = ["environment": ProcessInfo.processInfo.operatingSystemVersionString,
    "scope": "Mac ImageIO decode and draw to sRGB RGBA; warm memory; excludes I/O, network, GPU and mip generation. Not physical iPad.",
    "records": output]
let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
try json.write(to: root.appendingPathComponent("native-decode.json"))
print("Native ImageIO: \(output.count) sample/format combinations recorded")
