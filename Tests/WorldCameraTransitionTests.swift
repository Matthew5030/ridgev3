import Foundation
import AppKit
import SceneKit
import simd
@main struct WorldCameraTransitionTests {
    @MainActor static func main() {
        var checks=0
        func check(_ pass:Bool) { precondition(pass);checks+=1 }
        for span in [2000.0,3500,6900,9900,14000,17999] {
            var previous=Double.infinity
            for i in 0...100 {
                let p=WorldCameraTransition.entry(span:span,progress:Double(i)/100)
                check(p.distance.isFinite && p.distance>170 && p.distance<300000)
                check(p.span<=previous+0.00001);previous=p.span
                check(p.pitch>=0.85-1e-9 && p.pitch<=WorldCameraTransition.skyPitch)
            }
            let start=WorldCameraTransition.entry(span:span,progress:0),end=WorldCameraTransition.entry(span:span,progress:1)
            check(abs(start.span-span)<0.00001);check(end.fieldOfView==43)
            check(end.distance<12000) // Final frame must not trigger automatic atlas exit.
            for yaw in [-6.0,-2,0,2,6] {
                let pose=WorldCameraTransition.Pose(distance:end.distance,pitch:0.5,yaw:yaw,fieldOfView:43)
                let first=WorldCameraTransition.exit(from:pose,progress:0),last=WorldCameraTransition.exit(from:pose,progress:1)
                check(abs(first.distance-pose.distance)<0.00001 && first.pitch==pose.pitch)
                check(abs(sin(first.yaw)-sin(yaw))<1e-8)
                check(abs(last.span-max(WorldCameraTransition.exitSpan,pose.span))<0.00001 && last.yaw==0)
                for aspect in [0.46,0.75,1.33,2.0] {
                    let bounds=WorldCameraTransition.viewport(center:GeoPoint(latitude:53.0763,longitude:-4.0546),span:last.span,aspect:aspect)
                    check(bounds.isValid && abs(bounds.depthMeters-last.span)<1)
                    check(abs(bounds.widthMeters/bounds.depthMeters-aspect)<0.001)
                }
            }
        }
        // Focused ground and its nearby route remain outside the haze at every
        // stage of the sky/terrain transition, including its final frame.
        for span in [2000.0,3500,6900,9900,14000,17999] {
            for i in 0...100 {
                let pose = WorldCameraTransition.entry(span:span,progress:Double(i)/100)
                let fog = WorldAtmosphere.range(cameraDistance:pose.distance)
                check(fog.start > pose.distance+10000)
                check(fog.end-fog.start >= 50000)
                if i < 100 {
                    let next = WorldCameraTransition.entry(span:span,progress:Double(i+1)/100)
                    let nextFog = WorldAtmosphere.range(cameraDistance:next.distance)
                    check(abs(nextFog.start-fog.start) <= abs(next.distance-pose.distance)+0.001)
                }
            }
        }
        for distance in [170.0,2000,6000,12000,26000,300000] {
            let fog = WorldAtmosphere.range(cameraDistance:distance)
            check(fog.start >= 20000 && fog.start > distance && fog.end > fog.start)
        }
        check(WorldCameraTransition.minimumAtlasSpan<WorldCameraTransition.entrySpanLimit)
        check(WorldCameraTransition.entrySpanLimit<WorldCameraTransition.preparationSpanLimit)
        check(WorldCameraTransition.minimumAtlasSpan<=3500)
        check(WorldCameraTransition.entrySpanLimit<=8000)
        check(WorldCameraTransition.entrySpanLimit<WorldCameraTransition.overheadSpanLimit)
        check(WorldCameraTransition.overheadSpanLimit<WorldCameraTransition.preparationSpanLimit)
        check(WorldCameraTransition.entryDuration<=1.2)
        // Regression: a textured centre or four corners cannot expose a circular
        // island/holes against the coarse horizon. Certify every visible strip.
        let viewport=GeoBounds(minLatitude:53,minLongitude:-4,maxLatitude:53.04,maxLongitude:-3.96)
        func box(_ x:Int,_ y:Int)->GeoBounds {
            GeoBounds(minLatitude:53+Double(y)*0.01,minLongitude:-4+Double(x)*0.01,maxLatitude:53+Double(y+1)*0.01,maxLongitude:-4+Double(x+1)*0.01)
        }
        let grid=(0..<4).flatMap { y in (0..<4).map { box($0,y) } }
        check(WorldMapSurface.covers(viewport,tiles:grid))
        check(WorldMapSurface.covers(viewport,tiles:[viewport]))
        check(!WorldMapSurface.covers(viewport,tiles:[]))
        check(!WorldMapSurface.covers(viewport,tiles:[box(1,1)]))
        check(!WorldMapSurface.covers(viewport,tiles:[box(0,0),box(3,0),box(0,3),box(3,3)]))
        check(!WorldMapSurface.covers(viewport,tiles:grid.filter { $0 != box(1,1) }))
        check(!WorldMapSurface.covers(viewport,tiles:grid.filter { $0.maxLongitude < -3.965 }))
        check(WorldMapSurface.coversDownloaded(viewport,downloaded:[box(1,1)],rendered:[box(1,1)]))
        check(!WorldMapSurface.coversDownloaded(viewport,downloaded:grid,rendered:[box(1,1)]))
        check(!WorldMapSurface.coversDownloaded(viewport,downloaded:[],rendered:grid))
        check(WorldMapSurface.coversDownloaded(viewport,downloaded:grid,rendered:grid))
        check(WorldMapSurface.minimumPixels>=64)
        check(WorldMapSurface.preparationRadius(viewport)>=hypot(viewport.widthMeters,viewport.depthMeters)/2)
        // Invert the atlas's actual Mercator camera at phone/tablet heights and
        // UK latitudes. The zoom floor must describe ground span, not pixels.
        for latitude in [49.8,53,55.9,59.4] {
            let angle=latitude * .pi/180
            let center=(1-log(tan(angle)+1/cos(angle)) / .pi)/2
            for height in [320.0,540,844,1024,1366] {
                let scale=WorldCameraTransition.maximumAtlasScale(latitude:latitude,viewportHeight:height)
                func unproject(_ y:Double)->Double { atan(sinh(.pi*(1-2*y)))*180 / .pi }
                let north=unproject(center-height/2/scale),south=unproject(center+height/2/scale)
                let span=GeoPoint(latitude:north,longitude:0).distance(to:GeoPoint(latitude:south,longitude:0))
                check(abs(span-WorldCameraTransition.minimumAtlasSpan)<1)
                check(span<WorldCameraTransition.entrySpanLimit)
                check(scale<16_000_000)
            }
        }
        // Project real SceneKit camera landmarks into the full viewport. While
        // the atlas is visible, its scaled pixels must overlay the 3D plane.
        _ = NSApplication.shared
        for size in [CGSize(width:390,height:844),CGSize(width:1024,height:768)] {
            let scene=SCNScene(),camera=SCNNode()
            camera.camera=SCNCamera();camera.camera?.projectionDirection = .vertical
            camera.camera?.zNear=2;camera.camera?.zFar=500000
            scene.rootNode.addChildNode(camera)
            let view=SCNView(frame:CGRect(origin:.zero,size:size));view.scene=scene;view.pointOfView=camera
            let span=WorldCameraTransition.minimumAtlasSpan,aspect=Double(size.width/size.height)
            let target=SIMD3<Float>(700,300,-400)
            for fraction in [0.0,0.25,0.5,1.0] {
                let progress=fraction*WorldCameraTransition.mapBlendDuration/WorldCameraTransition.entryDuration
                let pose=WorldCameraTransition.entry(span:span,progress:progress)
                check(abs(pose.pitch-Double.pi/2)<1e-12)
                camera.camera?.fieldOfView=CGFloat(pose.fieldOfView)
                camera.simdPosition=target+Float(pose.distance)*SIMD3(0,Float(sin(pose.pitch)),Float(cos(pose.pitch)))
                WorldCameraOrientation.aim(camera,at:target)
                _ = view.snapshot()
                let scale=WorldCameraTransition.entryOverlayScale(span:span,progress:progress)
                check(simd_dot(camera.simdWorldRight,SIMD3<Float>(1,0,0))>0.9999)
                check(simd_dot(camera.simdWorldUp,SIMD3<Float>(0,0,-1))>0.9999)
                for (x,z) in [(0.0,0.0),(1800,0),(-1800,0),(0,1800),(0,-1800)] {
                    let projected=view.projectPoint(SCNVector3(target+SIMD3(Float(x),0,Float(z))))
                    let atlasX=Double(size.width)/2+x/(span*aspect)*Double(size.width)*scale
                    let atlasY=abs(z)/span*Double(size.height)*scale
                    check(abs(Double(projected.x)-atlasX)<0.5)
                    check(abs(abs(Double(projected.y)-Double(size.height)/2)-atlasY)<0.5)
                }
            }
        }
        print("PASS \(checks) camera transition checks")
    }
}
