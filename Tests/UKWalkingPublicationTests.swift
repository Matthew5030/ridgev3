import Foundation

@main struct UKWalkingPublicationTests {
    struct Case:Decodable {
        var name:String;var sourceID:String;var graphFile:String;var packFile:String
        var graphAsset:WorldMapAsset;var packAsset:WorldMapAsset
        var start:GeoPoint;var finish:GeoPoint
    }
    static func main() throws {
        var checks=0
        func check(_ condition:Bool,_ message:String) throws {
            guard condition else { throw RidgeError.message(message) };checks+=1
        }
        let cases=try JSONDecoder().decode([Case].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        for item in cases {
            let pack=try WorldSectionPack.Reader(url:URL(fileURLWithPath:item.packFile).resolvingSymlinksInPath(),asset:item.packAsset,sourceID:item.sourceID)
            try pack.verify()
            let packed=try pack.read(item.graphAsset)
            try check(packed == Data(contentsOf:URL(fileURLWithPath:item.graphFile)),"Loose and packaged routing differ")
            var graph=try JSONDecoder().decode(WalkingGraph.self,from:packed)
            try check(!graph.edges.contains { ["motorway","motorway_link","majorRoad","minorRoad"].contains($0.kind) },"Unresolved road class or motorway in publication")
            for (start,finish) in [(item.start,item.finish),(item.finish,item.start)] {
                let route=try RouteEngine.walkingSegment(from:start,to:finish,graph:graph,snapDistance:1)
                try check(route.points.first!.coordinate.distance(to:start)<0.02 && route.points.last!.coordinate.distance(to:finish)<0.02,"Connection moved its endpoints")
                try check(route.points.count>=2,"Connection has no network geometry")
            }
            graph.edges.removeAll { !["path","footway","footpath","bridleway","steps","pedestrian","track"].contains($0.kind) }
            do {
                _=try RouteEngine.walkingSegment(from:item.start,to:item.finish,graph:graph,snapDistance:1)
                throw RidgeError.message("Old blanket road exclusion unexpectedly connects this fixture")
            } catch RouteError.disconnectedPaths { checks+=1 }
            print("PASS \(item.name): verified download; real A-road connection routes in both directions")
        }
        if CommandLine.arguments.count > 2, let london = cases.first(where: { $0.name == "London" }) {
            let root=URL(fileURLWithPath:CommandLine.arguments[2])
            let catalog=try JSONDecoder().decode(WorldCatalog.self,from:Data(contentsOf:root.appendingPathComponent("catalog.json")))
            let center=GeoPoint(latitude:51.5,longitude:-0.06)
            let cache=FileManager.default.temporaryDirectory.appendingPathComponent("ridge-dense-check-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:cache) }
            var parts:[WorldLandscapeStore.Part]=[]
            for region in catalog.sources where WorldWindow.distance(center,to:region.bounds)<=WorldWindow.routingRadius {
                var source=try JSONDecoder().decode(WorldSource.self,from:Data(contentsOf:root.appendingPathComponent(region.path)))
                if let routing=region.routing { source.graph=routing }
                let url=root.appendingPathComponent(region.path).deletingLastPathComponent().appendingPathComponent(source.graph.file)
                let graph=try JSONDecoder().decode(WalkingGraph.self,from:Data(contentsOf:url))
                parts.append(.init(source:source,overview:.init(width:2,height:2,heights:[0,0,0,0]),graph:graph,
                                   files:WorldSourceStore(cacheURL:cache,allowsNetwork:false),connected:true))
            }
            let joined=try WorldLandscapeStore.joinGraphs(parts,center:center,radius:WorldWindow.routingRadius)
            try check(joined.nodes.count>250_000,"Dense fixture exercises the previous admission failure")
            try check(joined.nodes.count<=RouteEngine.maximumGraphNodes,"Joined city network stays within its device allowance")
            let route=try RouteEngine.walkingSegment(from:london.start,to:london.finish,graph:joined,snapDistance:1)
            try check(route.points.count>=2,"The real dense city window can plan a road connection")
            print("PASS dense London neighbourhood: \(joined.nodes.count) junctions, \(joined.edges.count) edges, real road route")
        }
        print("PASS \(checks) checks across \(cases.count) UK locations")
    }
}
