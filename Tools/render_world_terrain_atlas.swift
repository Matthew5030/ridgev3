import Foundation
import CoreGraphics
import ImageIO
import SceneKit

/// Publish the single reference level of the 2D map from the actual 3D assets.
/// This runs on the map server, independently of a phone's terrain downloads.
@main struct RenderWorldTerrainAtlas {
    static func main() async throws {
        let args=CommandLine.arguments
        if args.count==4,args[1]=="--surface" { try captureSurface(input:URL(fileURLWithPath:args[2]),output:URL(fileURLWithPath:args[3]));return }
        guard args.count>=5 else { throw RidgeError.message("Usage: render-atlas WORLD_ROOT OUTPUT X Y [X Y …]") }
        let root=URL(fileURLWithPath:args[1],isDirectory:true),output=URL(fileURLWithPath:args[2],isDirectory:true)
        let raw=try Data(contentsOf:root.appendingPathComponent("catalog.json"))
        let catalog=try JSONDecoder().decode(WorldCatalog.self,from:raw);try catalog.validate()
        let directory=output.appendingPathComponent(WorldTerrainAtlasGrid.captureDirectory(revision:catalog.revision))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for i in stride(from:3,to:args.count-1,by:2) {
            guard let x=Int(args[i]),let y=Int(args[i+1]),(0..<8192).contains(x),(0..<8192).contains(y) else { continue }
            let page=WorldAtlasPage(zoom:13,x:x,y:y),bounds=WorldTerrainAtlasGrid.bounds(page)
            let file=directory.appendingPathComponent(WorldTerrainAtlasGrid.filename(page))
            if FileManager.default.fileExists(atPath:file.path) { continue }
            var surfaces:[WorldPreview.Surface]=[]
            for region in catalog.sources where overlaps(region.bounds,bounds) {
                let sourceRoot=root.appendingPathComponent(region.path).deletingLastPathComponent()
                let files=WorldSourceStore(bundledURL:sourceRoot,allowsNetwork:false)
                guard let source=try? await files.manifest(address:"",recoverCoverage:false),
                      let (_,overview,_)=try? await files.contents(of:source,includeGraph:false) else { continue }
                for tile in source.tiles where overlaps(tile.mesh.bounds,bounds) {
                    var local=source;local.tiles=[tile]
                    let background=try? await files.backdrop(source:local,overview:overview,frame:bounds)
                    let geometry=background?.geometries[tile.id] ?? WorldGeometry.coarse(tile:tile,source:source,overview:overview,maximumDivisions:32,frame:bounds)
                    let fraction=tile.mesh.bounds.widthMeters/bounds.widthMeters*1024
                    let pixels=fraction>256 ? 512 : fraction>128 ? 256 : 128
                    guard let prepared=try? await files.prepare(tile,request:.init(id:tile.id,pixels:pixels,fine:false),sourceBounds:bounds) else { continue }
                    surfaces.append(.init(geometry:geometry,image:prepared.image,bounds:tile.mesh.bounds))
                }
            }
            let coverage=surfaces.compactMap { WorldMapSurface.intersection($0.bounds,bounds) }
            // Never publish a page with an atlas-style hole or missing strip.
            guard WorldMapSurface.covers(bounds,tiles:coverage) else { print("Unavailable \(x) \(y)");continue }
            let image=try WorldPreview.overhead(viewport:bounds,frame:bounds,surfaces:surfaces,background:nil,width:1024,height:1024)
            let temporary=file.appendingPathExtension("tmp")
            guard let destination=CGImageDestinationCreateWithURL(temporary as CFURL,"public.png" as CFString,1,nil) else { continue }
            let text=String(data:try JSONEncoder().encode(coverage),encoding:.utf8)!
            CGImageDestinationAddImage(destination,image,[kCGImagePropertyPNGDictionary:[kCGImagePropertyPNGDescription:text]] as CFDictionary)
            if CGImageDestinationFinalize(destination) { try FileManager.default.moveItem(at:temporary,to:file);print("Rendered \(x) \(y)") }
        }
    }
    static func overlaps(_ a:GeoBounds,_ b:GeoBounds)->Bool {
        a.minLongitude<b.maxLongitude && a.maxLongitude>b.minLongitude && a.minLatitude<b.maxLatitude && a.maxLatitude>b.minLatitude
    }
    static func captureSurface(input:URL,output:URL) throws {
        struct Metadata:Decodable { var bounds:GeoBounds;var side:Int;var pixels:Int }
        let metadata=try JSONDecoder().decode(Metadata.self,from:Data(contentsOf:input.appendingPathComponent("surface.json")))
        let data=try Data(contentsOf:input.appendingPathComponent("heights.bin")),n=metadata.side,bounds=metadata.bounds
        guard n>=2,n<=1025,data.count==n*n*4,metadata.pixels==2048 else { throw RidgeError.message("Invalid atlas surface") }
        let colour:CGImage
        let vector=input.appendingPathComponent("map.json")
        if FileManager.default.fileExists(atPath:vector.path) {
            colour=try WorldCartography.draw(JSONDecoder().decode(WorldVectorMap.self,from:Data(contentsOf:vector)),pixels:2048,overview:true,overviewBackground:try? Data(contentsOf:input.appendingPathComponent("base.bin")))
        } else if let imageSource=CGImageSourceCreateWithURL(input.appendingPathComponent("colour.png") as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(imageSource,0,nil) { colour=image }
        else { throw RidgeError.message("Missing atlas cartography") }
        var positions:[SCNVector3]=[],uv:[CGPoint]=[],indices:[Int32]=[]
        data.withUnsafeBytes { bytes in
            for row in 0..<n { for column in 0..<n {
                let u=Double(column)/Double(n-1),v=Double(row)/Double(n-1)
                positions.append(SCNVector3(Float((u-0.5)*bounds.widthMeters),bytes.loadUnaligned(fromByteOffset:(row*n+column)*4,as:Float.self),Float((v-0.5)*bounds.depthMeters)))
                uv.append(CGPoint(x:u,y:v))
            } }
        }
        for row in 0..<n-1 { for column in 0..<n-1 { let i=Int32(row*n+column),s=Int32(n);indices += [i,i+s,i+1,i+1,i+s,i+s+1] } }
        let geometry=WorldGeometry.build(positions:positions,uv:uv,indices:indices)
        let image=try WorldPreview.overhead(viewport:bounds,frame:bounds,surfaces:[.init(geometry:geometry,image:colour,bounds:bounds)],background:nil,width:2048,height:2048)
        guard let destination=CGImageDestinationCreateWithURL(output as CFURL,"public.png" as CFString,1,nil) else { throw RidgeError.message("Cannot save atlas capture") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw RidgeError.message("Cannot finish atlas capture") }
    }
}
