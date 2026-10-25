import Foundation
import CoreGraphics
import ImageIO

struct WorldRouteMapContext:Sendable {
    var catalog:WorldCatalog?
    var root:URL?
    var savedBounds:[GeoBounds]
    var coverageRevision:Int
    var identity:String {
        // Coverage revision is process-local; include the actual saved footprint
        // so a different set of downloads cannot reuse an old screenshot.
        let footprint=savedBounds.map { "\($0.minLatitude),\($0.minLongitude),\($0.maxLatitude),\($0.maxLongitude)" }.sorted().joined(separator:";")
        return "terrain-v3|\(root?.absoluteString ?? "none")|\(catalog?.revision ?? "none")|\(coverageRevision)|\(AdaptiveTerrainCodec.hash(Data(footprint.utf8)))"
    }
}
struct WorldRouteMapImage:@unchecked Sendable {
    var image:CGImage
    var hasMap:Bool
    var detailTiles:Int
    var cached=false
    var coverage:[GeoBounds]=[]
}

/// Serial offscreen views of the real terrain, using the same materials,
/// lighting, background geometry and saved map assets as the live world.
actor WorldRouteMapPreviewStore {
    private let distant:WorldDistantTerrainStore
    private let cache:URL
    static let diskBudget=64*1024*1024
    private var busy=false
    private var waiting:[CheckedContinuation<Void,Never>]=[]
    init(atlasURL:URL? = Bundle.main.url(forResource:"WorldAtlas",withExtension:"bundle"),cacheURL:URL? = nil,
         terrainURL:URL? = Bundle.main.url(forResource:"WorldContext",withExtension:"bundle")) {
        distant=WorldDistantTerrainStore(root:terrainURL,atlas:atlasURL);cache=WorldOfflineCoverage.cache(cacheURL)
    }
    private func acquire() async {
        if busy { await withCheckedContinuation { waiting.append($0) } } else { busy=true }
    }
    private func release() {
        if waiting.isEmpty { busy=false } else { waiting.removeFirst().resume() }
    }
    func image(viewport:GeoBounds,context:WorldRouteMapContext?,width:Int=720,height:Int=480,fullDetail:Bool=false,decodedPixels:Int?=nil,allowPartial:Bool=false) async -> WorldRouteMapImage? {
        await acquire();defer { release() }
        guard viewport.isValid,(1...1440).contains(width),(1...1440).contains(height),!Task.isCancelled else { return nil }
        // Thumbnails captured against the previous bundled atlas must not
        // survive the replacement of that base map with native UK imagery.
        let key="\(WorldPreview.cacheRevision)|bundled-native-v1|\(context?.identity ?? "overview")|\(viewport)|\(width)x\(height)|full:\(fullDetail)"
        let directory=cache.appendingPathComponent("overhead-previews",isDirectory:true)
        let file=directory.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(key.utf8))+".png")
        if let source=CGImageSourceCreateWithURL(file as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),image.width==width,image.height==height {
            let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any]
            let png=properties?[kCGImagePropertyPNGDictionary as String] as? [String:Any]
            let description=png?[kCGImagePropertyPNGDescription as String] as? String
            let coverage=description.flatMap { $0.data(using:.utf8) }.flatMap { try? JSONDecoder().decode([GeoBounds].self,from:$0) } ?? [viewport]
            if !fullDetail || allowPartial || WorldMapSurface.covers(viewport,tiles:coverage) {
                try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:file.path)
                return WorldRouteMapImage(image:Self.displayImage(image,pixels:decodedPixels),hasMap:true,detailTiles:0,cached:true,coverage:coverage)
            }
        }
        let frame=viewport
        var surfaces:[WorldPreview.Surface]=[]
        var complete=true
        if let context,let catalog=context.catalog,let root=context.root,!context.savedBounds.isEmpty {
            let saved=Set(context.savedBounds)
            let regions=catalog.sources.filter { region in region.bounds.intersects(viewport) && context.savedBounds.contains(where: { $0.intersects(region.bounds) }) }
                .sorted { $0.bounds.center.distance(to:viewport.center)<$1.bounds.center.distance(to:viewport.center) }.prefix(24)
            var seen=Set<GeoBounds>()
            for region in regions where surfaces.count<64 {
                guard !Task.isCancelled else { return nil }
                let files=WorldSourceStore(cacheURL:cache,allowsNetwork:false)
                guard var source=try? await files.manifest(address:root.appendingPathComponent(region.path).absoluteString,preferCached:true,recoverCoverage:false),
                      let (_,overview,_)=try? await files.contents(of:source,includeGraph:false) else { complete=false;continue }
                source.tiles=source.tiles.filter { (fullDetail || saved.contains($0.mesh.bounds)) && $0.mesh.bounds.minLongitude<viewport.maxLongitude && $0.mesh.bounds.maxLongitude>viewport.minLongitude && $0.mesh.bounds.minLatitude<viewport.maxLatitude && $0.mesh.bounds.maxLatitude>viewport.minLatitude && !seen.contains($0.mesh.bounds) }
                if source.tiles.count>64-surfaces.count { complete=false }
                source.tiles=Array(source.tiles.prefix(64-surfaces.count))
                for tile in source.tiles {
                    guard !Task.isCancelled else { return nil }
                    let fraction=tile.mesh.bounds.widthMeters/max(1,viewport.widthMeters)*Double(width)
                    let pixels=fraction>512 ? 1024 : fraction>256 ? 512 : fraction>128 ? 256 : fraction>64 ? 128 : 64
                    // A missing background chunk must not downgrade the other
                    // cached tiles in this page. Use each tile's best local mesh.
                    var geometrySource=source;geometrySource.tiles=[tile]
                    let backdrop=try? await files.backdrop(source:geometrySource,overview:overview,frame:frame)
                    let geometry=backdrop?.geometries[tile.id] ?? WorldGeometry.coarse(tile:tile,source:source,overview:overview,maximumDivisions:32,frame:frame)
                    guard let prepared=try? await files.prepare(tile,request:.init(id:tile.id,pixels:pixels,fine:false),sourceBounds:frame) else { complete=false;continue }
                    surfaces.append(.init(geometry:geometry,image:prepared.image,bounds:tile.mesh.bounds));seen.insert(tile.mesh.bounds)
                }
            }
        }
        if fullDetail && !allowPartial && (!complete || !WorldMapSurface.covers(viewport,tiles:surfaces.map(\.bounds))) { return nil }
        let background:WorldDistantTerrain?
        if fullDetail { background=nil } else { background=try? await distant.build(center:viewport.center,frame:frame) }
        var contextSurface:WorldPreview.Surface?
        if let background {
            let covered=Set(surfaces.compactMap { WorldDistantTerrain.key(for:$0.bounds) })
            contextSurface = .init(geometry:background.geometry(excluding:covered),image:background.image,bounds:viewport)
        }
        guard !Task.isCancelled,!surfaces.isEmpty || background != nil,
              let image=try? WorldPreview.overhead(viewport:viewport,frame:frame,surfaces:surfaces,background:contextSurface,width:width,height:height,transparentBackground:fullDetail && allowPartial) else { return nil }
        // Reusable screenshots are disposable, bounded cache entries, never
        // downloads. Only complete saved-map renders are kept between launches.
        let coverage=surfaces.compactMap { WorldMapSurface.intersection($0.bounds,viewport) }
        if context?.catalog != nil,(complete || (fullDetail && allowPartial)),!Task.isCancelled {
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let temporary=file.appendingPathExtension("tmp")
            if let destination=CGImageDestinationCreateWithURL(temporary as CFURL,"public.png" as CFString,1,nil) {
                let text=(try? JSONEncoder().encode(coverage)).flatMap { String(data:$0,encoding:.utf8) } ?? "[]"
                let properties=[kCGImagePropertyPNGDictionary:[kCGImagePropertyPNGDescription:text]] as CFDictionary
                CGImageDestinationAddImage(destination,image,properties)
                if CGImageDestinationFinalize(destination) {
                    try? FileManager.default.removeItem(at:file);try? FileManager.default.moveItem(at:temporary,to:file)
                }
            }
            Self.prune(directory:directory)
        }
        return WorldRouteMapImage(image:Self.displayImage(image,pixels:decodedPixels),hasMap:true,detailTiles:surfaces.count,coverage:coverage)
    }
    func recordAtlasStatus(_ status:WorldTerrainAtlasStatus) {
        guard let data=try? JSONEncoder().encode(status) else { return }
        try? data.write(to:cache.appendingPathComponent("terrain-atlas-status.json"),options:.atomic)
    }
    /// Downsample only the disposable display bitmap. The cached capture stays
    /// at its one reference resolution, regardless of current atlas zoom.
    private static func displayImage(_ image:CGImage,pixels:Int?)->CGImage {
        guard let pixels,pixels>=32,pixels<max(image.width,image.height),let space=image.colorSpace ?? CGColorSpace(name:CGColorSpace.sRGB) else { return image }
        let factor=Double(pixels)/Double(max(image.width,image.height))
        let width=max(1,Int(Double(image.width)*factor)),height=max(1,Int(Double(image.height)*factor))
        guard let canvas=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        canvas.interpolationQuality = .high;canvas.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        return canvas.makeImage() ?? image
    }
    static func prune(directory:URL) {
        let files=((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])) ?? [])
            .compactMap { url -> (URL,Int,Date)? in
                guard let values=try? url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) else { return nil }
                return (url,values.fileSize ?? 0,values.contentModificationDate ?? .distantPast)
            }.sorted { $0.2>$1.2 }
        var bytes=0
        for (index,item) in files.enumerated() {
            bytes+=item.1
            if bytes>diskBudget || index>=256 { try? FileManager.default.removeItem(at:item.0) }
        }
    }

}
