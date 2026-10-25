import Foundation

/// One fixed resolution of overhead terrain captures. Zooming scales these
/// pages; it never asks for another image pyramid or downloads map assets.
enum WorldTerrainAtlasGrid {
    static let zoom=13
    static let pixels=1024
    static let maximumPages=96
    static func captureDirectory(revision:String)->String {
        "terrain-atlas/\(WorldPreview.cacheRevision)-\(AdaptiveTerrainCodec.hash(Data(revision.utf8)))"
    }
    static func filename(_ page:WorldAtlasPage)->String { "z\(page.zoom)-x\(page.x)-y\(page.y).png" }
    static func bounds(_ page:WorldAtlasPage)->GeoBounds {
        func latitude(_ y:Int)->Double { atan(sinh(.pi*(1-2*Double(y)/page.divisions)))*180 / .pi }
        return GeoBounds(minLatitude:latitude(page.y+1),minLongitude:Double(page.x)/page.divisions*360-180,
                         maxLatitude:latitude(page.y),maxLongitude:Double(page.x+1)/page.divisions*360-180)
    }
    static func viewport(x:Double,y:Double,scale:Double,width:Double,height:Double)->GeoBounds? {
        guard x.isFinite,y.isFinite,scale.isFinite,width.isFinite,height.isFinite,scale>=1,width>0,height>0 else { return nil }
        func latitude(_ y:Double)->Double { atan(sinh(.pi*(1-2*y)))*180 / .pi }
        let box=GeoBounds(minLatitude:latitude(min(1,y+height/2/scale)),minLongitude:max(-180,(x-width/2/scale)*360-180),
                          maxLatitude:latitude(max(0,y-height/2/scale)),maxLongitude:min(180,(x+width/2/scale)*360-180))
        return box.isValid ? box : nil
    }
    static func visible(x:Double,y:Double,scale:Double,width:Double,height:Double)->[WorldAtlasPage] {
        guard x.isFinite,y.isFinite,scale.isFinite,width.isFinite,height.isFinite,scale>=1,width>0,height>0,(0...1).contains(x),(0...1).contains(y) else { return [] }
        let n=1<<zoom
        let left=max(0,min(n-1,Int(floor((x-width/2/scale)*Double(n))))),right=max(0,min(n-1,Int(ceil((x+width/2/scale)*Double(n)))-1))
        let top=max(0,min(n-1,Int(floor((y-height/2/scale)*Double(n))))),bottom=max(0,min(n-1,Int(ceil((y+height/2/scale)*Double(n)))-1))
        guard right>=left,bottom>=top,(right-left+1)*(bottom-top+1)<=maximumPages else { return [] }
        return (top...bottom).flatMap { row in (left...right).map { WorldAtlasPage(zoom:zoom,x:$0,y:row) } }
    }
    static func warm(x:Double,y:Double,scale:Double,height:Double)->[WorldAtlasPage] {
        guard x.isFinite,y.isFinite,scale.isFinite,height.isFinite,scale>=1,height>0,(0...1).contains(x),(0...1).contains(y) else { return [] }
        func latitude(_ y:Double)->Double { atan(sinh(.pi*(1-2*y)))*180 / .pi }
        let span=abs(latitude(y-height/2/scale)-latitude(y+height/2/scale))*111195
        guard span<WorldCameraTransition.preparationSpanLimit else { return [] }
        let n=1<<zoom,cx=min(n-2,max(1,Int(floor(x*Double(n))))),cy=min(n-2,max(1,Int(floor(y*Double(n)))))
        return ((cy-1)...(cy+1)).flatMap { row in ((cx-1)...(cx+1)).map { WorldAtlasPage(zoom:zoom,x:$0,y:row) } }
    }
}

/// Small local diagnostic: no route geometry, coordinates or server addresses.
struct WorldTerrainAtlasStatus:Codable,Sendable {
    var renderer="visible-boundaries-v2"
    var visiblePages:Int
    var loadedPages:Int
    var partialPages:Int
    var failedPages:Int
    var ready:Bool
    var decodedBytes:Int
    var state:String
}
