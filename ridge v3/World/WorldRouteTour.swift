import Foundation
import Observation

/// Distance-based traversal keeps speed independent of GPX sample density.
/// Disconnected tracks are rejected rather than inventing a walk between them.
struct WorldRouteTourPath {
    let points: [RoutePoint]
    let distances: [Double]
    var length: Double { distances.last ?? 0 }

    init?(segments: [[RoutePoint]]) {
        var points: [RoutePoint] = [], distances: [Double] = []
        for segment in segments where !segment.isEmpty {
            if let last = points.last, let first = segment.first,
               last.coordinate.distance(to:first.coordinate) > 2 { return nil }
            for point in segment {
                guard point.coordinate.isValid else { return nil }
                if let last = points.last {
                    let step = last.coordinate.distance(to:point.coordinate)
                    guard step.isFinite else { return nil }
                    if step < 0.01 { continue }
                    distances.append((distances.last ?? 0)+step)
                } else { distances.append(0) }
                points.append(point)
            }
        }
        guard points.count > 1, (distances.last ?? 0) > 1 else { return nil }
        self.points=points; self.distances=distances
    }

    func sample(at distance: Double) -> RoutePoint {
        let distance = distance.isFinite ? min(length,max(0,distance)) : 0
        var low=0, high=distances.count-1
        while low+1 < high {
            let middle=(low+high)/2
            if distances[middle] <= distance { low=middle } else { high=middle }
        }
        let a=points[low], b=points[high]
        let fraction=(distance-distances[low])/(distances[high]-distances[low])
        let elevation: Double?
        if let x=a.elevation, let y=b.elevation, x.isFinite, y.isFinite { elevation=x+(y-x)*fraction }
        else { elevation=nil }
        return RoutePoint(coordinate:GeoPoint(latitude:a.coordinate.latitude+(b.coordinate.latitude-a.coordinate.latitude)*fraction,
                                              longitude:a.coordinate.longitude+(b.coordinate.longitude-a.coordinate.longitude)*fraction),elevation:elevation)
    }

    /// Project onto each leg so a waypoint can start between sparse GPX samples.
    func distance(nearest point: GeoPoint) -> Double {
        guard point.isValid else { return 0 }
        let scale=cos(point.latitude * .pi/180)
        var best=Double.infinity, result=0.0
        for index in 1..<points.count {
            let a=points[index-1].coordinate,b=points[index].coordinate
            let ax=(a.longitude-point.longitude)*scale,ay=a.latitude-point.latitude
            let dx=(b.longitude-a.longitude)*scale,dy=b.latitude-a.latitude
            let square=dx*dx+dy*dy
            let t=square>0 ? max(0,min(1,-(ax*dx+ay*dy)/square)) : 0
            let error=pow(ax+t*dx,2)+pow(ay+t*dy,2)
            if error<best { best=error;result=distances[index-1]+t*(distances[index]-distances[index-1]) }
        }
        return result
    }
    func distance(toWaypoint id: UUID, in route: RidgeRoute) -> Double {
        guard let index=route.waypoints.firstIndex(where:{ $0.id==id }) else { return 0 }
        if route.segments.count == route.waypoints.count-1 {
            // Use the occurrence in the ordered legs, including loops which
            // return to an earlier coordinate, rather than its nearest match.
            var previous: GeoPoint?, distance=0.0
            for segment in route.segments.prefix(index) {
                for point in segment.points {
                    if let previous {
                        let step=previous.distance(to:point.coordinate)
                        if step>=0.01 { distance+=step }
                    }
                    previous=point.coordinate
                }
            }
            return min(length,distance)
        }
        if index==route.waypoints.count-1,route.waypoints[index].point.coordinate == points.last?.coordinate { return length }
        return distance(nearest:route.waypoints[index].point.coordinate)
    }

    /// Use a short chord around the camera to soften sharp vertices. At the
    /// finish the chord still points forwards, never back along the route.
    func heading(at distance: Double, lookAhead: Double) -> (from: RoutePoint, to: RoutePoint) {
        (sample(at:max(0,distance-4)),sample(at:min(length,max(lookAhead,distance+lookAhead))))
    }
}

@MainActor @Observable final class WorldRouteTour {
    struct Configuration: Equatable {
        var revealing: Bool
        var entering: Bool
        var presented: Bool
        var playing: Bool
        var speed: Double
        var seekRevision: Int
    }
    /// Read by the SwiftUI host so every camera setting explicitly refreshes
    /// the representable, even when only its controls observe the change.
    var configuration: Configuration {
        Configuration(revealing:isRevealing,entering:isEntering,presented:isPresented,playing:isPlaying,speed:speed,seekRevision:seekRevision)
    }
    @ObservationIgnored private(set) var path: WorldRouteTourPath?
    @ObservationIgnored private(set) var corridor: WorldFlightCorridor?
    private(set) var isPresented = false
    private(set) var isEntering = false
    private(set) var isRevealing = false
    private(set) var entryElapsed = 0.0
    var isTerrainReady = false
    @ObservationIgnored private(set) var entryStartedAt = Date()
    var isPlaying = false
    /// Cruise speed in km/h; the previous multiplier hid an absolute turn cap.
    static let speedRange = 10.0...600.0
    var speed = 150.0
    static let flightClearance = 15.0
    nonisolated static let fieldOfView = 68.0
    static let fpvCornerLift = 90.0
    static let preparedSpeed = 25.0
    var clearance:Double { Self.flightClearance }
    private(set) var actualHeight = 0.0
    private(set) var actualMetersPerSecond=0.0
    private(set) var progress = 0.0
    private(set) var seekRevision = 0
    var message: String?
    var isPreparing=false
    private(set) var sessionID=UUID()
    var canAdvance: Bool { isPresented && isPlaying && !isEntering }
    var length: Double { path?.length ?? 0 }
    var metersPerSecond: Double { min(Self.speedRange.upperBound,max(Self.speedRange.lowerBound,speed))/3.6 }
    var actualKilometersPerHour:Double { isPlaying ? actualMetersPerSecond*3.6 : 0 }

    @discardableResult func open(route: RidgeRoute, startingAtWaypoint waypoint: UUID? = nil) -> Bool {
        guard let path=WorldRouteTourPath(segments:route.segments.isEmpty ? [route.points] : route.segments.map(\.points)) else { return false }
        self.path=path;corridor=WorldFlightCorridor(path:path,tolerance:160)
        sessionID=UUID();isPreparing=true;isEntering=true;isRevealing=false;entryElapsed=0;isTerrainReady=false;entryStartedAt=Date();actualMetersPerSecond=0;actualHeight=0
        progress=waypoint.map { path.distance(toWaypoint:$0,in:route)/path.length } ?? 0
        seekRevision+=1; message=nil
        isPresented=true; isPlaying=progress<1
        return true
    }
    func revealEntry() { entryElapsed=0;isRevealing=true }
    func reportEntry(elapsed:Double) { entryElapsed=elapsed }
    func finishEntry() { isEntering=false;isRevealing=false;entryElapsed=0 }
    func close() { finishEntry();isTerrainReady=false;isPlaying=false; isPresented=false; isPreparing=false;actualMetersPerSecond=0;actualHeight=0;message=nil }
    func pause() { if isPlaying { isPlaying=false };actualMetersPerSecond=0 }
    func reportHeight(_ metres:Double) { actualHeight=max(0,metres) }
    func reportSpeed(_ metresPerSecond:Double) { actualMetersPerSecond=max(0,metresPerSecond) }
    func togglePlayback() {
        if progress >= 1 { seek(to:0) }
        message=nil; isPlaying.toggle()
    }
    func seek(to fraction: Double) {
        progress=fraction.isFinite ? min(1,max(0,fraction)) : 0
        seekRevision+=1; message=nil
    }
    func report(distance: Double) {
        progress=length > 0 ? min(1,max(0,distance/length)) : 0
        if progress >= 1 { isPlaying=false }
    }
}
