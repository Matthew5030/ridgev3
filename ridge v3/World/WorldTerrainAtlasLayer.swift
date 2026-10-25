import SwiftUI

/// The close 2D atlas is made from native overhead terrain renders, with the
/// existing 3D palette, normals and lighting baked at one reference resolution.
struct WorldTerrainAtlasLayer:View {
    var center:CGPoint
    var scale:CGFloat
    var size:CGSize
    var context:WorldRouteMapContext
    var onReady:(Bool)->Void = { _ in }
    @Environment(\.displayScale) private var displayScale
    @State private var loader=WorldTerrainAtlasLoader()
    private var viewport:TerrainAtlasViewport {
        .init(x:Double(center.x),y:Double(center.y),scale:Double(scale),width:Double(size.width),height:Double(size.height),pixelScale:Double(displayScale),
              contextKey:"\(context.root?.absoluteString ?? "none")|\(context.catalog?.revision ?? "none")|\(context.coverageRevision)")
    }
    var body:some View {
        let visible=viewport.visible,images=loader.images
        let covered=visible.flatMap { loader.coverage[$0] ?? [] }
        let ready = !visible.isEmpty && viewport.bounds.map { WorldMapSurface.covers($0,tiles:covered) } == true
        // Never show a patchwork of completed screenshots over the old map.
        // Publish the complete viewport as one surface when its images are ready.
        Canvas(rendersAsynchronously:true) { canvas,_ in
            if ready {
                for page in visible {
                    guard let image=images[page] else { continue }
                    let rect=CGRect(x:(Double(page.x)/page.divisions-viewport.x)*viewport.scale+viewport.width/2,
                                    y:(Double(page.y)/page.divisions-viewport.y)*viewport.scale+viewport.height/2,
                                    width:viewport.scale/page.divisions,height:viewport.scale/page.divisions)
                    canvas.draw(Image(decorative:image,scale:1),in:rect.insetBy(dx:-0.25,dy:-0.25))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .onChange(of:ready,initial:true) { _,value in onReady(value) }
            .onAppear { loader.request(viewport,context:context) }
            .onChange(of:viewport) { _,value in loader.request(value,context:context) }
            .onDisappear { onReady(false);loader.discard() }
    }
}

private struct TerrainAtlasViewport:Equatable,Sendable {
    var x:Double;var y:Double;var scale:Double;var width:Double;var height:Double;var pixelScale:Double;var contextKey:String
    var bounds:GeoBounds? { WorldTerrainAtlasGrid.viewport(x:x,y:y,scale:scale,width:width,height:height) }
    var visible:[WorldAtlasPage] { WorldTerrainAtlasGrid.visible(x:x,y:y,scale:scale,width:width,height:height) }
    var displayPixels:Int {
        let projected=scale/Double(1<<WorldTerrainAtlasGrid.zoom)*pixelScale
        return min(requested.count>24 ? 512 : 1024,projected>512 ? 1024 : projected>256 ? 512 : 256)
    }
    var requested:[WorldAtlasPage] {
        let pages=visible.isEmpty ? WorldTerrainAtlasGrid.warm(x:x,y:y,scale:scale,height:height) : visible
        return pages.sorted { a,b in
            hypot((Double(a.x)+0.5)/a.divisions-x,(Double(a.y)+0.5)/a.divisions-y)<hypot((Double(b.x)+0.5)/b.divisions-x,(Double(b.y)+0.5)/b.divisions-y)
        }
    }
}

@Observable @MainActor private final class WorldTerrainAtlasLoader {
    var images:[WorldAtlasPage:CGImage]=[:]
    var coverage:[WorldAtlasPage:[GeoBounds]]=[:]
    @ObservationIgnored private let renders=WorldRouteMapPreviewStore()
    @ObservationIgnored private var pending:(TerrainAtlasViewport,WorldRouteMapContext)?
    @ObservationIgnored private var work:Task<Void,Never>?
    @ObservationIgnored private var identity=""
    @ObservationIgnored private var failed=Set<WorldAtlasPage>()
    func request(_ viewport:TerrainAtlasViewport,context:WorldRouteMapContext) {
        if identity != viewport.contextKey { identity=viewport.contextKey;images=[:];coverage=[:];failed=[] }
        pending=(viewport,context)
        guard work == nil else { return }
        work=Task(priority:.utility) { [weak self] in
            guard let self else { return }
            defer {
                work=nil
                if let (view,context)=pending { request(view,context:context) }
            }
            while let (view,context)=pending,!Task.isCancelled {
                pending=nil
                await renders.recordAtlasStatus(status(view))
                let displayPixels=view.displayPixels
                for page in view.requested where images[page]?.width != displayPixels && !failed.contains(page) {
                    guard !Task.isCancelled,identity==view.contextKey else { break }
                    let bounds=WorldTerrainAtlasGrid.bounds(page)
                    let image=await renders.image(viewport:bounds,context:context,width:WorldTerrainAtlasGrid.pixels,height:WorldTerrainAtlasGrid.pixels,fullDetail:true,decodedPixels:displayPixels,allowPartial:true)
                    guard !Task.isCancelled,identity==view.contextKey else { break }
                    if let image {
                        let needed=Set(view.requested)
                        images[page]=image.image;coverage[page]=image.coverage
                        while images.count>WorldTerrainAtlasGrid.maximumPages || images.values.reduce(0,{ $0+$1.width*$1.height*4 })>96*1024*1024 {
                            guard let old=images.keys.first(where:{ !needed.contains($0) }) else { break }
                            images.removeValue(forKey:old);coverage.removeValue(forKey:old)
                        }
                    } else { failed.insert(page) }
                    await renders.recordAtlasStatus(status(view))
                    // A new pan/zoom supersedes the batch after this one page.
                    if pending != nil { break }
                }
                await renders.recordAtlasStatus(status(view))
            }
        }
    }
    private func status(_ view:TerrainAtlasViewport)->WorldTerrainAtlasStatus {
        let visible=view.visible,covered=visible.flatMap { coverage[$0] ?? [] }
        let ready = !visible.isEmpty && view.bounds.map { WorldMapSurface.covers($0,tiles:covered) } == true
        let missing=visible.filter { failed.contains($0) }.count
        return .init(visiblePages:visible.count,loadedPages:visible.filter { images[$0] != nil }.count,
                     partialPages:visible.filter { images[$0] != nil && !WorldMapSurface.covers(WorldTerrainAtlasGrid.bounds($0),tiles:coverage[$0] ?? []) }.count,
                     failedPages:missing,ready:ready,decodedBytes:images.values.reduce(0){$0+$1.width*$1.height*4},
                     state:ready ? "native" : visible.isEmpty ? "country-overview" : missing>0 ? "missing-map-images" : "preparing")
    }
    func discard() { pending=nil;work?.cancel();images=[:];coverage=[:];failed=[] }
}
