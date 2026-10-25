import Foundation

enum WorldCameraTransition {
    static let minimumAtlasSpan = 3500.0
    static let entrySpanLimit = 8000.0
    static let preparationSpanLimit = 24000.0
    static let overheadSpanLimit = 12000.0
    static let entryDuration = 1.2
    static let exitDuration = 0.95
    static let exitSpan = 6000.0
    static let mapBlendDuration = 0.3

    /// Match a physical zoom floor at every latitude and screen height. A fixed
    /// Mercator scale allows far closer zoom on a small or northern viewport.
    static func maximumAtlasScale(latitude:Double,viewportHeight:Double,minimumSpan:Double = minimumAtlasSpan)->Double {
        let latitude=min(80,max(-80,latitude)),half=minimumSpan/111_195/2
        func projected(_ latitude:Double)->Double {
            let angle=latitude * .pi/180
            return (1-log(tan(angle)+1/cos(angle)) / .pi)/2
        }
        return max(350,max(1,viewportHeight)/(projected(latitude-half)-projected(latitude+half)))
    }
    static let skyPitch = Double.pi/2 // Exact overhead; the camera basis is explicitly north-up.
    struct Pose {
        var distance: Double
        var pitch: Double
        var yaw: Double
        var fieldOfView: Double
        var span: Double { 2*distance*tan(fieldOfView * .pi/360) }
    }
    static func entry(span: Double, progress: Double) -> Pose {
        let t=ease(progress),field=5+38*t,footprint=span+(min(8000,span*0.82)-span)*t
        // Match the atlas's overhead projection for the entire dissolve.
        // Only the fully visible terrain camera pitches into the glide.
        let tilt=ease((max(0,min(1,progress))*entryDuration-mapBlendDuration)/(entryDuration-mapBlendDuration))
        return Pose(distance:footprint/(2*tan(field * .pi/360)),pitch:skyPitch+(0.85-skyPitch)*tilt,yaw:0,fieldOfView:field)
    }
    static func entryOverlayScale(span:Double,progress:Double)->Double {
        span/max(1,entry(span:span,progress:progress).span)
    }
    static func exit(from start: Pose, progress: Double) -> Pose {
        let t=ease(progress),field=start.fieldOfView+(5-start.fieldOfView)*t
        let span=start.span+(max(exitSpan,start.span)-start.span)*t
        let heading=atan2(sin(start.yaw),cos(start.yaw))
        return Pose(distance:span/(2*tan(field * .pi/360)),pitch:start.pitch+(skyPitch-start.pitch)*t,yaw:heading*(1-t),fieldOfView:field)
    }
    static func viewport(center: GeoPoint, span: Double, aspect: Double) -> GeoBounds {
        let latitude=span/111_195,longitude=span*aspect/(111_195*max(0.01,cos(center.latitude * .pi/180)))
        return GeoBounds(minLatitude:center.latitude-latitude/2,minLongitude:center.longitude-longitude/2,maxLatitude:center.latitude+latitude/2,maxLongitude:center.longitude+longitude/2)
    }
    private static func ease(_ progress: Double) -> Double { let t=max(0,min(1,progress));return t*t*(3-2*t) }
}

/// Atmosphere depends on viewing distance, never on the state of tile loading.
/// Use the same curve during flight and ordinary gestures so entry cannot flash.
enum WorldAtmosphere {
    static func range(cameraDistance: Double) -> (start: Double, end: Double) {
        let start = max(20000,cameraDistance+16000)
        return (start,start+60000)
    }
}

/// A terrain window is usable as a 2D surface only when its textured tiles fill
/// the whole viewport. Centre/corner checks miss holes and circular load edges.
enum WorldMapSurface {
    static let minimumPixels=64
    static func intersection(_ a:GeoBounds,_ b:GeoBounds)->GeoBounds? {
        let box=GeoBounds(minLatitude:max(a.minLatitude,b.minLatitude),minLongitude:max(a.minLongitude,b.minLongitude),
                          maxLatitude:min(a.maxLatitude,b.maxLatitude),maxLongitude:min(a.maxLongitude,b.maxLongitude))
        return box.isValid ? box : nil
    }
    static func preparationRadius(_ viewport:GeoBounds)->Double {
        min(10000,max(4500,hypot(viewport.widthMeters,viewport.depthMeters)/2+1000))
    }
    static func coversDownloaded(_ viewport:GeoBounds,downloaded:[GeoBounds],rendered:[GeoBounds])->Bool {
        let needed=downloaded.compactMap { tile -> GeoBounds? in
            let box=GeoBounds(minLatitude:max(viewport.minLatitude,tile.minLatitude),minLongitude:max(viewport.minLongitude,tile.minLongitude),
                              maxLatitude:min(viewport.maxLatitude,tile.maxLatitude),maxLongitude:min(viewport.maxLongitude,tile.maxLongitude))
            return box.isValid ? box : nil
        }
        return !needed.isEmpty && needed.allSatisfy { covers($0,tiles:rendered) }
    }
    static func covers(_ viewport:GeoBounds,tiles:[GeoBounds])->Bool {
        guard viewport.isValid else { return false }
        let tiles=tiles.filter { $0.isValid && $0.intersects(viewport) }
        guard !tiles.isEmpty else { return false }
        let epsilon=1e-9
        let edges=Set([viewport.minLatitude,viewport.maxLatitude]+tiles.flatMap { [max(viewport.minLatitude,$0.minLatitude),min(viewport.maxLatitude,$0.maxLatitude)] }).sorted()
        for (south,north) in zip(edges,edges.dropFirst()) where north-south>epsilon {
            let latitude=(south+north)/2
            let ranges=tiles.filter { $0.minLatitude<=latitude && $0.maxLatitude>=latitude }.sorted { $0.minLongitude<$1.minLongitude }
            var covered=viewport.minLongitude
            for tile in ranges {
                if tile.minLongitude>covered+epsilon { return false }
                covered=max(covered,tile.maxLongitude)
                if covered>=viewport.maxLongitude-epsilon { break }
            }
            if covered<viewport.maxLongitude-epsilon { return false }
        }
        return true
    }
}
