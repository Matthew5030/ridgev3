import Foundation
import CoreGraphics
import ImageIO
import zlib

@main struct WorldRouteMapPreviewTests {
    static func main() async throws {
        var checks=0
        func check(_ condition:Bool,_ message:String) throws { checks+=1;if !condition { throw RidgeError.message(message) } }
        let resources=URL(fileURLWithPath:CommandLine.arguments[1]),bundle=resources.appendingPathComponent("WorldData.bundle")
        let cache=FileManager.default.temporaryDirectory.appendingPathComponent("ridge-route-maps-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:cache) }
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        var source=try JSONDecoder().decode(WorldSource.self,from:Data(contentsOf:bundle.appendingPathComponent("world.json")))
        var tile=source.tiles[0]
        let bundledSource=source
        let raw=Data(#"{"width":32,"height":32,"paths":[{"kind":"water","closed":true,"rings":[[[0,0],[32,0],[32,16],[0,16]]]},{"kind":"woodland","closed":true,"rings":[[[0,16],[32,16],[32,32],[0,32]]]}]}"#.utf8)
        var compressed=Data(count:Int(compressBound(uLong(raw.count)))),size=uLongf(compressed.count)
        let status=compressed.withUnsafeMutableBytes { out in raw.withUnsafeBytes { input in
            compress2(out.bindMemory(to:Bytef.self).baseAddress!,&size,input.bindMemory(to:Bytef.self).baseAddress!,uLong(raw.count),9)
        } }
        try check(status==Z_OK,"Synthetic vector fixture compresses")
        compressed.count=Int(size)
        tile.map = .init(file:"thumbnail.map",byteCount:compressed.count,sha256:AdaptiveTerrainCodec.hash(compressed),decodedByteCount:raw.count)
        source.tiles=[tile]
        let overview=try JSONEncoder().encode(WorldOverview(width:2,height:2,heights:[100,100,100,100]))
        source.overview = .init(file:"overview.json",byteCount:overview.count,sha256:AdaptiveTerrainCodec.hash(overview))
        try overview.write(to:cache.appendingPathComponent(source.overview.sha256))
        let root=URL(string:"http://offline.invalid/world/")!,address=root.appendingPathComponent("fixture/world.json").absoluteString
        try JSONEncoder().encode(source).write(to:cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8))+".index"))
        let loose=cache.appendingPathComponent(tile.map.sha256)
        try compressed.write(to:loose)
        let region=WorldCatalog.Region(id:source.id,path:"fixture/world.json",bounds:source.bounds,tileCount:1)
        let catalog=WorldCatalog(schemaVersion:1,revision:"thumbnail-test",sources:[region])
        let context=WorldRouteMapContext(catalog:catalog,root:root,savedBounds:[tile.mesh.bounds],coverageRevision:1)
        let maps=WorldRouteMapPreviewStore(atlasURL:resources.appendingPathComponent("WorldAtlas.bundle"),cacheURL:cache,terrainURL:resources.appendingPathComponent("WorldContext.bundle"))
        guard let detailed=await maps.image(viewport:tile.mesh.bounds,context:context) else { throw RidgeError.message("Missing route thumbnail") }
        try check(detailed.hasMap && detailed.detailTiles==1,"World route thumbnail renders saved terrain without a legacy PackEntry or resident scene")
        try check(detailed.image.width==720 && detailed.image.height==480,"Thumbnail size is bounded")
        func rgb(_ image:CGImage,x:Int,y:Int)->[UInt8] {
            let space=CGColorSpace(name:CGColorSpace.sRGB)!
            let canvas=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            canvas.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            let bytes=canvas.data!.assumingMemoryBound(to:UInt8.self),i=(y*image.width+x)*4
            return [bytes[i],bytes[i+1],bytes[i+2]]
        }
        let north=rgb(detailed.image,x:360,y:100),south=rgb(detailed.image,x:360,y:380)
        try check(north[2]>north[0] && north[1]>north[0],"Northern water stays at the top of the lit terrain thumbnail: \(north)")
        try check(south[1]>south[2] && south[0]>south[2],"Southern woodland stays below the route: \(south)")
        try check(!FileManager.default.fileExists(atPath:cache.appendingPathComponent(tile.mesh.path).path),"Thumbnail uses coarse overview heights without fine terrain or routing graphs")
        let reused=await maps.image(viewport:tile.mesh.bounds,context:context)
        try check(reused?.cached==true,"An unchanged viewport reuses its native terrain screenshot")
        // A downloaded source may stop partway through a reference image.
        // Its unavailable offscreen margin must not hide an otherwise covered
        // viewport, and the PNG must remember its actual coverage on reuse.
        let boundary=GeoBounds(minLatitude:tile.mesh.bounds.minLatitude,minLongitude:tile.mesh.bounds.minLongitude-(tile.mesh.bounds.maxLongitude-tile.mesh.bounds.minLongitude)/2,
                               maxLatitude:tile.mesh.bounds.maxLatitude,maxLongitude:tile.mesh.bounds.maxLongitude)
        guard let partial=await maps.image(viewport:boundary,context:context,fullDetail:true,allowPartial:true) else { throw RidgeError.message("Missing boundary fixture") }
        try check(WorldMapSurface.covers(tile.mesh.bounds,tiles:partial.coverage),"Downloaded visible terrain can use a partially covered image tile")
        try check(!WorldMapSurface.covers(boundary,tiles:partial.coverage),"Image coverage does not claim its unavailable margin")
        let partialHit=await maps.image(viewport:boundary,context:context,fullDetail:true,allowPartial:true)
        try check(partialHit?.cached==true && partialHit?.coverage==partial.coverage,"PNG coverage metadata survives a cache read")
        let strictBoundary=await maps.image(viewport:boundary,context:context,fullDetail:true)
        try check(strictBoundary==nil,"A cached boundary image cannot masquerade as a full native page")
        let space=CGColorSpace(name:CGColorSpace.sRGB)!
        let alphaCanvas=CGContext(data:nil,width:720,height:480,bitsPerComponent:8,bytesPerRow:720*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        alphaCanvas.draw(partial.image,in:CGRect(x:0,y:0,width:720,height:480))
        let alpha=alphaCanvas.data!.assumingMemoryBound(to:UInt8.self)
        try check(alpha[(240*720+30)*4+3]==0,"Unavailable page margins stay transparent")
        try check(alpha[(240*720+500)*4+3]>250,"Available native terrain remains opaque")
        var packedContext=context;packedContext.coverageRevision+=1
        // Install the same vector as an indexed section pack, with no loose file.
        let entry=WorldSectionPack.Entry(sha256:tile.map.sha256,byteCount:compressed.count,offset:0,storedByteCount:compressed.count,compressed:false)
        let index=try JSONEncoder().encode(WorldSectionPack.Index(schemaVersion:1,sourceID:source.id,entries:[entry]))
        var packed=Data("RIDGEPK1".utf8),length=UInt32(index.count).littleEndian
        withUnsafeBytes(of:&length) { packed.append(contentsOf:$0) };packed.append(index);packed.append(compressed)
        let hash=AdaptiveTerrainCodec.hash(packed),asset=WorldMapAsset(file:"section-\(hash).ridgepack",byteCount:packed.count,sha256:hash)
        try FileManager.default.createDirectory(at:WorldSectionPack.directory(cache),withIntermediateDirectories:true)
        try packed.write(to:WorldSectionPack.file(asset,cache:cache));try WorldSectionPack.install(asset,sourceID:source.id,cache:cache)
        try FileManager.default.removeItem(at:loose)
        let fromPack=await maps.image(viewport:tile.mesh.bounds,context:packedContext)
        try check(fromPack?.detailTiles==1 && fromPack?.hasMap==true,"Packed regional downloads supply route thumbnails too")
        var unsaved=context;unsaved.savedBounds=[]
        let atlasOnly=await maps.image(viewport:tile.mesh.bounds,context:unsaved)
        try check(atlasOnly?.hasMap==true && atlasOnly?.detailTiles==0,"An unsaved area still has a local terrain background without claiming saved detail")
        let cold=await maps.image(viewport:tile.mesh.bounds,context:nil)
        try check(cold?.hasMap==true && cold?.detailTiles==0,"The map background works before World catalogue configuration")
        try FileManager.default.removeItem(at:WorldSectionPack.file(asset,cache:cache))
        var missingContext=context;missingContext.coverageRevision+=2
        let missing=await maps.image(viewport:tile.mesh.bounds,context:missingContext)
        try check(missing?.hasMap==true && missing?.detailTiles==0,"Missing saved detail falls back to the bundled map without network access")
        // Fixed reference-resolution pages use the actual terrain renderer,
        // rather than magnifying the country atlas or generating zoom levels.
        let centre=bundledSource.bounds.center,n=Double(1<<WorldTerrainAtlasGrid.zoom)
        let px=Int((centre.longitude+180)/360*n),py=Int((1-asinh(tan(centre.latitude * .pi/180)) / .pi)/2*n)
        let page=WorldAtlasPage(zoom:WorldTerrainAtlasGrid.zoom,x:px,y:py)
        let pageBounds=WorldTerrainAtlasGrid.bounds(page)
        try check(WorldTerrainAtlasGrid.bounds(.init(zoom:page.zoom,x:px+1,y:py)).minLongitude==pageBounds.maxLongitude,"Native pages meet without longitude gaps")
        try check(WorldTerrainAtlasGrid.bounds(.init(zoom:page.zoom,x:px,y:py+1)).maxLatitude==pageBounds.minLatitude,"Native pages meet without latitude gaps")
        let xc=(Double(px)+0.5)/n,yc=(Double(py)+0.5)/n
        for scale in [1_000_000.0,2_000_000,4_000_000,8_000_000] {
            let selected=WorldTerrainAtlasGrid.visible(x:xc,y:yc,scale:scale,width:1024,height:768)
            try check(!selected.isEmpty && selected.count<=WorldTerrainAtlasGrid.maximumPages && selected.allSatisfy { $0.zoom==WorldTerrainAtlasGrid.zoom },"Every close-map zoom reuses the same fixed-resolution pages")
        }
        try check(WorldTerrainAtlasGrid.visible(x:xc,y:yc,scale:7400,width:1024,height:768).isEmpty,"Country browsing cannot allocate an unbounded terrain screenshot grid")
        try check(WorldTerrainAtlasGrid.visible(x:Double.nan,y:yc,scale:1,width:1024,height:768).isEmpty,"Invalid viewport cannot allocate pages")
        try check(WorldTerrainAtlasGrid.warm(x:xc,y:yc,scale:2_000_000,height:768).count==9,"Background warmup is bounded to nine nearby reference pages")
        try check(await maps.image(viewport:pageBounds,context:context,width:1024,height:1024,fullDetail:true)==nil,"A partial terrain island cannot become a close-atlas page")
        try JSONEncoder().encode(bundledSource).write(to:cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8))+".index"))
        try Data(contentsOf:bundle.appendingPathComponent(bundledSource.overview.file)).write(to:cache.appendingPathComponent(bundledSource.overview.sha256))
        let pageTiles=bundledSource.tiles.filter { $0.mesh.bounds.intersects(pageBounds) }
        for tile in pageTiles {
            try Data(contentsOf:bundle.appendingPathComponent(tile.map.file)).write(to:cache.appendingPathComponent(tile.map.sha256))
            if let background=tile.background { try Data(contentsOf:bundle.appendingPathComponent(background.path)).write(to:cache.appendingPathComponent(background.sha256)) }
        }
        var nativeContext=context;nativeContext.coverageRevision+=10;nativeContext.savedBounds=pageTiles.map { $0.mesh.bounds }
        guard let native=await maps.image(viewport:pageBounds,context:nativeContext,width:1024,height:1024,fullDetail:true) else { throw RidgeError.message("Missing complete native terrain atlas fixture") }
        try check(native.image.width==1024 && native.image.height==1024 && native.detailTiles>0,"A 2D atlas page captures actual lit terrain at reference quality")
        var sparseContext=nativeContext;sparseContext.savedBounds=[pageTiles[0].mesh.bounds]
        let sparse=await maps.image(viewport:pageBounds,context:sparseContext,width:1024,height:1024,fullDetail:true)
        try check(sparse?.hasMap==true && sparseContext.savedBounds.count==1,"The 2D map can reuse locally cached overview assets beyond fine-terrain coverage without changing download receipts")
        let wideScale=WorldCameraTransition.maximumAtlasScale(latitude:centre.latitude,viewportHeight:768,minimumSpan:14000)
        try check(!WorldTerrainAtlasGrid.visible(x:xc,y:yc,scale:wideScale,width:1024,height:768).isEmpty,"The wide view from the reported screenshot can use the native 2D surface")
        let smaller=await maps.image(viewport:pageBounds,context:nativeContext,width:1024,height:1024,fullDetail:true,decodedPixels:256)
        try check(smaller?.image.width==256 && smaller?.cached==true,"Wide views decode a smaller display bitmap from the same reference capture")
        let nativeHit=await maps.image(viewport:pageBounds,context:nativeContext,width:1024,height:1024,fullDetail:true)
        try check(nativeHit?.cached==true,"The native 2D surface reuses its cached screenshot")
        if let path=ProcessInfo.processInfo.environment["RIDGE_TERRAIN_ATLAS_OUTPUT"],let destination=CGImageDestinationCreateWithURL(URL(fileURLWithPath:path) as CFURL,"public.png" as CFString,1,nil) {
            CGImageDestinationAddImage(destination,native.image,nil)
            try check(CGImageDestinationFinalize(destination),"Native 2D reference page exports")
        }
        if let path=ProcessInfo.processInfo.environment["RIDGE_THUMBNAIL_OUTPUT"] {
            // Native visual QA uses the real bundled cartography underneath a
            // deliberately synthetic route; no private saved geometry is used.
            try JSONEncoder().encode(bundledSource).write(to:cache.appendingPathComponent(AdaptiveTerrainCodec.hash(Data(address.utf8))+".index"))
            let exportTile=bundledSource.tiles[(bundledSource.rows/2)*bundledSource.columns+bundledSource.columns/2]
            let center=exportTile.mesh.bounds.center,halfLatitude=(exportTile.mesh.bounds.maxLatitude-exportTile.mesh.bounds.minLatitude)/2
            let halfLongitude=halfLatitude*1.5/cos(center.latitude * .pi/180)
            let exportViewport=GeoBounds(minLatitude:center.latitude-halfLatitude,minLongitude:center.longitude-halfLongitude,maxLatitude:center.latitude+halfLatitude,maxLongitude:center.longitude+halfLongitude)
            let visible=bundledSource.tiles.filter { $0.mesh.bounds.intersects(exportViewport) }
            for tile in visible { try Data(contentsOf:bundle.appendingPathComponent(tile.map.file)).write(to:cache.appendingPathComponent(tile.map.sha256)) }
            try Data(contentsOf:bundle.appendingPathComponent(bundledSource.overview.file)).write(to:cache.appendingPathComponent(bundledSource.overview.sha256))
            var realContext=context;realContext.coverageRevision+=3;realContext.savedBounds=visible.map { $0.mesh.bounds }
            guard let real=await maps.image(viewport:exportViewport,context:realContext),real.detailTiles==visible.count else { throw RidgeError.message("Missing real map fixture") }
            try check(real.hasMap,"Real saved cartography supplies a map backdrop")
            let color=CGColorSpace(name:CGColorSpace.sRGB)!
            let canvas=CGContext(data:nil,width:720,height:480,bitsPerComponent:8,bytesPerRow:720*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            canvas.draw(real.image,in:CGRect(x:0,y:0,width:720,height:480))
            let route=CGMutablePath();route.move(to:CGPoint(x:130,y:330));route.addLines(between:[CGPoint(x:230,y:300),CGPoint(x:350,y:175),CGPoint(x:500,y:135),CGPoint(x:600,y:240)])
            canvas.setLineCap(.round);canvas.setLineJoin(.round)
            canvas.addPath(route);canvas.setStrokeColor(CGColor(gray:1,alpha:0.95));canvas.setLineWidth(8);canvas.strokePath()
            canvas.addPath(route);canvas.setStrokeColor(CGColor(srgbRed:0.86,green:0.27,blue:0.12,alpha:1));canvas.setLineWidth(4);canvas.strokePath()
            let rendered=canvas.makeImage()!
            let url=URL(fileURLWithPath:path)
            if let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) {
                CGImageDestinationAddImage(destination,rendered,nil);try check(CGImageDestinationFinalize(destination),"Native thumbnail fixture exports")
            }
        }
        try check(context.identity != unsaved.identity,"Cache identity includes saved coverage across launches")
        let disposable=cache.appendingPathComponent("budget-test",isDirectory:true)
        try FileManager.default.createDirectory(at:disposable,withIntermediateDirectories:true)
        for index in 0..<260 { try Data([0]).write(to:disposable.appendingPathComponent("\(index).png")) }
        WorldRouteMapPreviewStore.prune(directory:disposable)
        try check(try FileManager.default.contentsOfDirectory(atPath:disposable.path).count==256,"Screenshot cache has a fixed file-count limit")
        let oversized=disposable.appendingPathComponent("oversized.png")
        FileManager.default.createFile(atPath:oversized.path,contents:nil)
        let handle=try FileHandle(forWritingTo:oversized);try handle.truncate(atOffset:UInt64(WorldRouteMapPreviewStore.diskBudget+1));try handle.close()
        WorldRouteMapPreviewStore.prune(directory:disposable)
        let bytes=try FileManager.default.contentsOfDirectory(at:disposable,includingPropertiesForKeys:[.fileSizeKey]).reduce(0) { $0+((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
        try check(bytes<=WorldRouteMapPreviewStore.diskBudget,"Disposable screenshots stay inside the 64 MiB budget")
        try check(FileManager.default.fileExists(atPath:cache.appendingPathComponent(source.overview.sha256).path),"Evicting screenshots preserves downloaded source assets")
        print("PASS \(checks) offline route-map thumbnail, orientation and packed-source checks")
    }
}
