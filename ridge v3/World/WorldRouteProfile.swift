import Foundation

/// Interpolate the chart and map marker using travelled distance, preserving
/// missing heights and disconnected track boundaries.
enum WorldRouteProfile {
    struct Position {
        var coordinate: GeoPoint
        var elevation: Double?
    }
    static func distance(nearest point: GeoPoint, in samples: [RouteProfileSample]) -> Double? {
        guard point.isValid,!samples.isEmpty else { return nil }
        let scale=cos(point.latitude * .pi/180)
        var best=Double.infinity,result=samples[0].distance
        for index in 1..<samples.count where !samples[index].breakBefore {
            let a=samples[index-1],b=samples[index]
            let ax=(a.point.coordinate.longitude-point.longitude)*scale,ay=a.point.coordinate.latitude-point.latitude
            let dx=(b.point.coordinate.longitude-a.point.coordinate.longitude)*scale,dy=b.point.coordinate.latitude-a.point.coordinate.latitude
            let square=dx*dx+dy*dy,t=square>0 ? min(1,max(0,-(ax*dx+ay*dy)/square)) : 0
            let error=pow(ax+dx*t,2)+pow(ay+dy*t,2)
            if error<best { best=error;result=a.distance+(b.distance-a.distance)*t }
        }
        return result
    }
    static func position(in samples: [RouteProfileSample], at distance: Double) -> Position? {
        guard let first=samples.first else { return nil }
        let distance=distance.isFinite ? min(samples.last!.distance,max(0,distance)) : 0
        var low=0,high=samples.count-1
        while low+1<high {
            let middle=(low+high)/2
            if samples[middle].distance<=distance { low=middle } else { high=middle }
        }
        let a=samples[low],b=samples[high]
        guard b.distance>a.distance else { return Position(coordinate:first.point.coordinate,elevation:first.point.elevation.flatMap { $0.isFinite ? $0 : nil }) }
        let t=max(0,min(1,(distance-a.distance)/(b.distance-a.distance)))
        if b.breakBefore && t>0 && t<1 { return nil }
        let elevation: Double?
        if t==0 { elevation=a.point.elevation }
        else if t==1 { elevation=b.point.elevation }
        else if let x=a.point.elevation,let y=b.point.elevation,x.isFinite,y.isFinite,!b.unknownBefore { elevation=x+(y-x)*t }
        else { elevation=nil }
        return Position(coordinate:GeoPoint(latitude:a.point.coordinate.latitude+(b.point.coordinate.latitude-a.point.coordinate.latitude)*t,
                                            longitude:a.point.coordinate.longitude+(b.point.coordinate.longitude-a.point.coordinate.longitude)*t),
                        elevation:elevation.flatMap { $0.isFinite ? $0 : nil })
    }
}
