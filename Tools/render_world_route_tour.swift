import AppKit
import SwiftUI
import SceneKit
import simd

/// Local visual QA: the production controls and camera against a synthetic
/// valley. This fixture does not represent a downloaded area or device timing.
@main struct RenderWorldRouteTour {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let frame=GeoBounds(minLatitude:52.99,minLongitude:-4.02,maxLatitude:53.02,maxLongitude:-3.98)
        let route=(0...100).map { i in RoutePoint(coordinate:GeoPoint(latitude:53+Double(i)*0.00008,longitude:-4+sin(Double(i)*0.02)*0.0004),elevation:nil) }
        let path=WorldRouteTourPath(segments:[route])!
        let tour=WorldRouteTour()
        tour.open(route:RidgeRoute(name:"Synthetic valley",regionID:"qa",segments:[RouteSegment(points:route,mode:"track")]))
        tour.seek(to:0.35);tour.pause();tour.finishEntry()
        for (width,preparing,playing):(CGFloat,Bool,Bool) in [(360,false,false),(768,false,false),(360,true,false),(360,false,true)] {
                tour.isPreparing=preparing;tour.isPlaying=playing;tour.reportSpeed(tour.metersPerSecond);tour.reportHeight(15)
                let panel=WorldRouteTourControls(tour:tour).buttonStyle(.plain)
                    .foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
                    .padding(16).frame(width:width).background(RidgeTheme.paper)
                    .environment(\.colorScheme,.light)
                let hosting=NSHostingView(rootView:panel)
                let size=CGSize(width:width,height:hosting.fittingSize.height)
                let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
                window.contentView=hosting;hosting.frame=CGRect(origin:.zero,size:size)
                hosting.layoutSubtreeIfNeeded();hosting.displayIfNeeded()
                RunLoop.current.run(until:Date().addingTimeInterval(0.05));hosting.layoutSubtreeIfNeeded();window.displayIfNeeded()
                guard let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) else { fatalError("Cannot render controls") }
                hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
                guard let png=bitmap.representation(using:.png,properties:[:]) else { fatalError("Cannot encode controls") }
                try png.write(to:output.appendingPathComponent("controls-\(preparing ? "preparing" : playing ? "playing" : "fly-through")-\(Int(width)).png"))
        }
        for width:CGFloat in [340,480] {
            let prompt=WorldRoutePlanPrompt(pathsReady:true,busy:false,plan:{},library:{})
                .foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
                .padding(12).frame(width:width).background(RidgeTheme.paper).environment(\.colorScheme,.light)
            let hosting=NSHostingView(rootView:prompt),size=CGSize(width:width,height:92)
            let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.contentView=hosting;hosting.frame=CGRect(origin:.zero,size:size);hosting.layoutSubtreeIfNeeded();window.displayIfNeeded()
            let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds)!
            hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("plan-bottom-\(Int(width)).png"))
        }
        let labels=["Car park", "Lake viewpoint", "Ridge junction", "Summit", "Finish"]
        let waypoints=[0,25,50,75,100].enumerated().map { index, sample in
            RouteWaypoint(point:RoutePoint(coordinate:route[sample].coordinate,elevation:Double(120+sample*4)),name:labels[index])
        }
        let example=RidgeRoute(name:"An afternoon in the hills",regionID:"qa",waypoints:waypoints,
            segments:[RouteSegment(points:route,mode:"track")])
        for (name,width,height,editing,preview,empty) in [
            ("editing",340.0,820.0,true,false,false),
            ("saved",340,820,false,false,false),
            ("preview",340,820,true,true,false),
            ("compact",300,540,true,false,false),
            ("empty",340,820,false,false,true)
        ] {
            let previewState=WorldRouteTour()
            if preview { previewState.open(route:example);previewState.pause();previewState.isPreparing=false;previewState.reportHeight(15);previewState.finishEntry() }
            let panel=WorldRouteEditorPanel(route:empty ? nil : example,editing:editing,busy:false,pathsReady:true,
                canUndo:true,canRedo:false,selectedWaypoint:waypoints[2].id,movingWaypoint:nil,inserting:false,
                summary:empty ? "" : "0.9 km · 5 waypoints",tour:previewState,dismiss:nil,onAction:{ _ in })
                .buttonStyle(.plain).frame(width:width,height:height).environment(\.colorScheme,.light)
            let hosting=NSHostingView(rootView:panel)
            let size=CGSize(width:width,height:height)
            let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.contentView=hosting;hosting.frame=CGRect(origin:.zero,size:size)
            hosting.layoutSubtreeIfNeeded();hosting.displayIfNeeded()
                RunLoop.current.run(until:Date().addingTimeInterval(0.05));hosting.layoutSubtreeIfNeeded();window.displayIfNeeded()
            let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds)!
            hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("sidebar-\(name).png"))
        }
        let plotRoute=RidgeRoute(name:"Profile sample",regionID:"qa",segments:[RouteSegment(points:(0...100).map { index in
            RoutePoint(coordinate:route[index].coordinate,elevation:250+100*sin(Double(index)/18)+Double(index)*2)
        },mode:"track")])
        let profile=RouteEngine.elevationProfile(plotRoute.segments)
        func render<V:View>(_ view:V,width:CGFloat,height:CGFloat,name:String) throws {
            let hosting=NSHostingView(rootView:view.frame(width:width,height:height).environment(\.colorScheme,.light))
            let size=CGSize(width:width,height:height)
            let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.contentView=hosting;hosting.frame=CGRect(origin:.zero,size:size);hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.05));window.displayIfNeeded()
            let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds)!
            hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name+".png"))
        }
        for width:CGFloat in [320,390,844] {
            for editing in [false,true] {
                try render(WorldRouteActionBar(route:example,editing:editing,busy:false,pathsReady:true,canUndo:true,details:{},onAction:{ _ in }),
                    width:width,height:64,name:"quiet-route-\(editing ? "editing" : "saved")-\(Int(width))")
            }
            let player=WorldRouteTour();player.open(route:plotRoute);player.finishEntry();player.isPreparing=false;player.seek(to:0.35)
            try render(WorldRoutePlaybackBar(tour:player,showsElevation:.constant(false),hasElevation:true),
                width:width,height:56,name:"quiet-player-\(Int(width))")
        }
        for section in WorldRouteDetailsSection.allCases {
            let panel=WorldRouteEditorPanel(route:example,editing:true,busy:false,pathsReady:true,canUndo:true,canRedo:false,
                selectedWaypoint:nil,movingWaypoint:nil,inserting:false,summary:"0.9 km · 5 waypoints",tour:WorldRouteTour(),dismiss:{},onAction:{ _ in },
                section:.constant(section),elevationSamples:profile,compact:true)
            try render(panel,width:390,height:440,name:"phone-details-\(section.id.rawValue.lowercased())")
        }
        for width: CGFloat in [390,1024] {
            for fraction in [0.2,0.75] {
                let preview=WorldRouteTour();preview.open(route:plotRoute);preview.seek(to:fraction);preview.pause()
                let strip=VStack(spacing:0) {
                    WorldRouteElevationStrip(samples:profile,selectedDistance:nil,tour:preview,onScrub:{ _ in })
                    Divider()
                    WorldRouteToolbar(route:example,editing:true,busy:false,pathsReady:true,canUndo:true,canRedo:false,selectedWaypoint:waypoints[2].id,onAction:{ _ in })
                }.foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest).frame(width:width).environment(\.colorScheme,.light)
                let hosting=NSHostingView(rootView:strip),size=CGSize(width:width,height:150)
                let window=NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
                window.contentView=hosting;hosting.frame=CGRect(origin:.zero,size:size);hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until:Date().addingTimeInterval(0.05));window.displayIfNeeded()
                let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds)!
                hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("bottom-\(Int(width))-\(Int(fraction*100)).png"))
            }
        }
        func ground(_ point:GeoPoint)->Float {
            let uv=frame.uv(point),x=Float((uv.u-0.5)*frame.widthMeters),z=Float((uv.v-0.5)*frame.depthMeters)
            return 50+0.00012*x*x+12*sin(z/500)
        }
        let scene=SCNScene();scene.background.contents=NSColor(red:0.76,green:0.86,blue:0.91,alpha:1)
        var vertices:[SCNVector3]=[],indices:[Int32]=[]
        let divisions=160
        for y in 0...divisions { for x in 0...divisions {
            let uv=(Double(x)/Double(divisions),Double(y)/Double(divisions))
            vertices.append(SCNVector3(Float((uv.0-0.5)*frame.widthMeters),ground(frame.point(u:uv.0,v:uv.1)),Float((uv.1-0.5)*frame.depthMeters)))
        } }
        for y in 0..<divisions { for x in 0..<divisions {
            let a=Int32(y*(divisions+1)+x),side=Int32(divisions+1)
            indices += [a,a+side,a+1,a+1,a+side,a+side+1]
        } }
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        let material=SCNMaterial();material.diffuse.contents=NSColor(red:0.43,green:0.57,blue:0.31,alpha:1);material.isDoubleSided=true;material.lightingModel = .lambert
        geometry.materials=[material];scene.rootNode.addChildNode(SCNNode(geometry:geometry))
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=600;scene.rootNode.addChildNode(ambient)
        // Route markers help assess heading and eye height in the fixture.
        for sample in route {
            let uv=frame.uv(sample.coordinate)
            let dot=SCNNode(geometry:SCNSphere(radius:0.3));dot.position=SCNVector3(Float((uv.u-0.5)*frame.widthMeters),ground(sample.coordinate)+0.35,Float((uv.v-0.5)*frame.depthMeters))
            dot.geometry!.firstMaterial!.diffuse.contents=NSColor.orange;scene.rootNode.addChildNode(dot)
        }
        let camera=SCNNode();camera.camera=SCNCamera();camera.camera!.fieldOfView=WorldRouteTour.fieldOfView;camera.camera!.zNear=0.1;camera.camera!.zFar=20000;scene.rootNode.addChildNode(camera)
        let renderer=SCNRenderer(device:nil,options:nil);renderer.scene=scene;renderer.pointOfView=camera
        for (name,dx) in [("forward",0.0),("look-around",-140.0)] {
            let rail=WorldFlightCorridor(path:path,tolerance:160)
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:WorldFlightTerrain.distances(length:rail.length).map { Float?(ground(rail.sample(flightDistance:$0).point)) })
            let flight=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:WorldRouteTour.flightClearance,cornerLift:WorldRouteTour.fpvCornerLift)
            let pose=flight.sample(time:flight.time(at:path.length*0.35)).pose
            var look=WorldCinematicLook();look.begin();look.drag(dx:dx,dy:0)
            let direction=look.direction(from:simd_normalize(pose.look-pose.eye))
            camera.simdPosition=pose.eye;WorldCameraOrientation.aim(camera,at:pose.eye+direction*80)
            camera.camera!.fieldOfView=WorldRouteTour.fieldOfView
            let image=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:700),antialiasingMode:.multisampling4X)
            let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("camera-\(name).png"))
        }
        func flightPoint(_ x:Double,_ north:Double)->RoutePoint {
            RoutePoint(coordinate:GeoPoint(latitude:frame.center.latitude+north/111195,longitude:frame.center.longitude+x/(111195*cos(frame.center.latitude * .pi/180))),elevation:nil)
        }
        let flightFixtures:[(String,[RoutePoint])]=[
            ("banked-turn",[flightPoint(0,-250),flightPoint(0,0),flightPoint(250,0)]),
            ("switchback-pass",[flightPoint(0,-160),flightPoint(0,0),flightPoint(80,0),flightPoint(80,80),flightPoint(0,80),flightPoint(0,160),flightPoint(80,160),flightPoint(80,340)])]
        for (name,points) in flightFixtures {
            let path=WorldRouteTourPath(segments:[points])!,rail=WorldFlightCorridor(path:path,tolerance:160)
            let heights=WorldFlightTerrain.distances(length:rail.length).map { Float?(ground(rail.sample(flightDistance:$0).point)) }
            let terrain=WorldFlightTerrain(path:path,corridor:rail,heights:heights)
            let plan=try WorldFlightPlan(path:path,corridor:rail,terrain:terrain,frame:frame,cruiseSpeed:25,reduceMotion:false,clearance:WorldRouteTour.flightClearance,cornerLift:WorldRouteTour.fpvCornerLift)
            let times=Array(stride(from:0.0,through:plan.duration,by:0.1))
            let time=times.max { a,b in
                let x=plan.sample(time:a).pose,y=plan.sample(time:b).pose
                return name=="banked-turn" ? abs(x.bank)<abs(y.bank) : x.eye.y-ground(x.focus)<y.eye.y-ground(y.focus)
            }!
            let markers=SCNNode();scene.rootNode.addChildNode(markers)
            for distance in stride(from:0.0,through:path.length,by:5) {
                let p=path.sample(at:distance).coordinate,position=WorldRouteTourCamera.local(p,frame:frame,elevation:ground)
                let dot=SCNNode(geometry:SCNSphere(radius:0.6));dot.simdPosition=position+SIMD3(0,0.6,0)
                dot.geometry!.firstMaterial!.diffuse.contents=NSColor.orange;markers.addChildNode(dot)
            }
            let sample=plan.sample(time:time).pose
            camera.simdPosition=sample.eye;WorldCameraOrientation.aim(camera,at:sample.look,bank:sample.bank)
            let snapshot=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:700),antialiasingMode:.multisampling4X)
            let bitmap=NSBitmapImageRep(data:snapshot.tiffRepresentation!)!
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("camera-\(name).png"))
            if name=="banked-turn" {
                var entry=plan.sample(time:0);entry.velocity *= Float(150.0/3.6/plan.cruiseSpeed)
                let opening=WorldRouteTourCamera.Pose(eye:entry.pose.eye+SIMD3<Float>(240,600,300),look:entry.pose.eye,focus:entry.pose.focus)
                let arrival=WorldFlightArrival(path:path,flight:entry,frame:frame,aspect:1000.0/700,from:opening,fieldOfView:43)
                for fraction in [0.0,0.45,0.80,1.0] {
                    let pose=arrival.sample(elapsed:arrival.hold+(arrival.duration-arrival.hold)*fraction)
                    camera.camera!.fieldOfView=CGFloat(arrival.fieldOfView(elapsed:arrival.duration*fraction))
                    camera.simdPosition=pose.eye;WorldCameraOrientation.aim(camera,at:pose.look,bank:pose.bank,up:pose.up)
                    let image=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:700),antialiasingMode:.multisampling4X)
                    let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
                    try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("arrival-\(Int(fraction*100)).png"))
                }
            }
            if name=="banked-turn" {
                var entry=plan.sample(time:0);entry.velocity *= Float(150.0/3.6/plan.cruiseSpeed)
                let arrival=WorldFlightArrival(path:path,flight:entry,frame:frame,aspect:1000.0/700)
                for jump in [0.0,0.45,1.0] {
                    let pose=arrival.sample(elapsed:arrival.duration*jump)
                    camera.simdPosition=pose.eye;WorldCameraOrientation.aim(camera,at:pose.look,bank:pose.bank,up:pose.up)
                    let terrain=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:700),antialiasingMode:.multisampling4X)
                    let art=ZStack {
                        Image(nsImage:terrain).resizable()
                        WorldFlightCloudArtwork(progress:jump*0.6)
                    }.frame(width:1000,height:700)
                    let hosting=NSHostingView(rootView:art),window=NSWindow(contentRect:CGRect(x:0,y:0,width:1000,height:700),styleMask:.borderless,backing:.buffered,defer:false)
                    window.contentView=hosting;hosting.frame=CGRect(x:0,y:0,width:1000,height:700);hosting.layoutSubtreeIfNeeded();window.displayIfNeeded()
                    RunLoop.current.run(until:Date().addingTimeInterval(0.05))
                    let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds)!;hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
                    try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("generated-entry-\(Int(jump*100)).png"))
                }
                let pose=plan.sample(time:0).pose
                camera.simdPosition=pose.eye;WorldCameraOrientation.aim(camera,at:pose.look,bank:pose.bank,up:pose.up)
                let terrain=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:700),antialiasingMode:.multisampling4X)
                let art=ZStack { Image(nsImage:terrain).resizable() }.frame(width:1000,height:700)
                let hosting=NSHostingView(rootView:art),window=NSWindow(contentRect:CGRect(x:0,y:0,width:1000,height:700),styleMask:.borderless,backing:.buffered,defer:false)
                window.contentView=hosting;hosting.frame=CGRect(x:0,y:0,width:1000,height:700);hosting.layoutSubtreeIfNeeded();window.displayIfNeeded()
                RunLoop.current.run(until:Date().addingTimeInterval(0.05))
                let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds)!;hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("fpv-preview.png"))
            }
            markers.removeFromParentNode()
        }
        // Main-map camera handoff: synthetic top-down landscape dissolves
        // into the production descent. No cloud artwork or screen mask.
        let mapTarget=WorldRouteTourCamera.local(frame.center,frame:frame,elevation:ground)
        var atlasImage:NSImage?
        for (name,elapsed) in [("start",0.0),("blend",0.325),("finish",1.8)] {
            let pose=WorldCameraTransition.entry(span:WorldCameraTransition.minimumAtlasSpan,progress:elapsed/WorldCameraTransition.entryDuration)
            camera.camera?.fieldOfView=CGFloat(pose.fieldOfView)
            camera.camera?.zFar=500000
            camera.simdPosition=mapTarget+Float(pose.distance)*SIMD3(0,Float(sin(pose.pitch)),Float(cos(pose.pitch)))
            WorldCameraOrientation.aim(camera,at:mapTarget)
            let terrain=renderer.snapshot(atTime:0,with:CGSize(width:1000,height:700),antialiasingMode:.multisampling4X)
            if atlasImage == nil { atlasImage=terrain }
            let art=ZStack {
                Image(nsImage:terrain).resizable()
                Image(nsImage:atlasImage!).resizable()
                    .scaleEffect(WorldCameraTransition.entryOverlayScale(span:WorldCameraTransition.minimumAtlasSpan,progress:elapsed/WorldCameraTransition.entryDuration))
                    .opacity(max(0,1-elapsed/WorldCameraTransition.mapBlendDuration))
            }.frame(width:1000,height:700)
            let hosting=NSHostingView(rootView:art),window=NSWindow(contentRect:CGRect(x:0,y:0,width:1000,height:700),styleMask:.borderless,backing:.buffered,defer:false)
            window.contentView=hosting;hosting.frame=CGRect(x:0,y:0,width:1000,height:700);hosting.layoutSubtreeIfNeeded();window.displayIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.05))
            let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds)!;hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("map-entry-\(name).png"))
        }
        // Top-down rail QA: real flight geometry, deliberately synthetic routes.
        let cases:[(String,[(Double,Double)])]=[
            ("Rounded bend",[(0,0),(0,300),(300,300)]),
            ("Close turnaround",[(0,0),(0,300),(0,0)]),
            ("Route bend: smooth it out",[(0,0),(0,100),(75,180),(0,260),(0,400)]),
            ("Switchbacks: one forward pass",[(0,0),(0,100),(80,100),(80,180),(0,180),(0,260),(80,260),(80,400)]),
            ("Overlapping switchbacks: keep order",[(0,0),(0,350),(20,40),(40,320),(10,0)])]
        let diagram=NSImage(size:NSSize(width:1200,height:1410))
        diagram.lockFocus()
        NSColor.white.setFill();NSRect(x:0,y:0,width:1200,height:1410).fill()
        for (index,item) in cases.enumerated() {
            let rect=NSRect(x:Double(index%2)*600+45,y:Double(2-index/2)*460+45,width:510,height:400)
            let title=item.0,points=item.1.map { xy in RoutePoint(coordinate:GeoPoint(latitude:53+xy.1/111_195,longitude:-4+xy.0/(111_195*cos(53 * .pi/180))),elevation:100) }
            let path=WorldRouteTourPath(segments:[points])!,rail=WorldFlightCorridor(path:path,tolerance:160)
            let scale=0.6
            func xy(_ point:GeoPoint)->NSPoint {
                NSPoint(x:rect.minX+90+(point.longitude+4)*111_195*cos(53 * .pi/180)*scale,
                        y:rect.minY+30+(point.latitude-53)*111_195*scale)
            }
            (title as NSString).draw(at:NSPoint(x:rect.minX,y:rect.maxY-10),withAttributes:[.font:NSFont.systemFont(ofSize:22,weight:.semibold),.foregroundColor:NSColor.darkGray])
            let original=NSBezierPath();original.move(to:xy(points[0].coordinate))
            for point in points.dropFirst() { original.line(to:xy(point.coordinate)) }
            NSColor.systemOrange.setStroke();original.lineWidth=3;original.stroke()
            let flight=NSBezierPath();flight.move(to:xy(rail.sample(flightDistance:0).point))
            for distance in stride(from:2.0,through:rail.length,by:2) { flight.line(to:xy(rail.sample(flightDistance:distance).point)) }
            NSColor(red:0.12,green:0.38,blue:0.31,alpha:1).setStroke();flight.lineWidth=3;flight.stroke()
            for distance in stride(from:35.0,through:rail.length,by:55) {
                let sample=rail.sample(flightDistance:distance),p=xy(sample.point),dx=sample.direction.x,dy = -sample.direction.y
                let arrow=NSBezierPath();arrow.move(to:NSPoint(x:p.x-dx*8-dy*4,y:p.y-dy*8+dx*4));arrow.line(to:p)
                arrow.line(to:NSPoint(x:p.x-dx*8+dy*4,y:p.y-dy*8-dx*4));arrow.lineWidth=2;arrow.stroke()
            }
        }
        ("Orange: planned route    Green: smooth flight path" as NSString).draw(at:NSPoint(x:45,y:20),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.darkGray])
        diagram.unlockFocus()
        let railBitmap=NSBitmapImageRep(data:diagram.tiffRepresentation!)!
        try railBitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("flight-corridor.png"))
        print("Rendered controls, synthetic valley cameras and production flight rails: \(output.path)")
    }
}
