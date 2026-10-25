import SwiftUI

/// Inline inspector: the map stays visible and interactive while a region is
/// checked, downloaded or paused. There is no second region browser.
struct WorldRegionDownloadCard: View {
    @Bindable var world:WorldModel
    let pack:WorldRegionPack
    var saved:WorldRegionMapOverlay? = nil
    let explore:() -> Void
    var selectWholePark:(() -> Void)? = nil
    var retryConnection:(() -> Void)? = nil
    @State private var confirmRemoval = false
    private var availability:WorldRegionPack.TerrainAvailability {
        saved?.terrainAvailability ?? pack.terrainAvailability(in:world.catalog)
    }
    private var blocked:Bool { availability == .unavailable }
    private var partialCoverage:Bool { availability == .incomplete }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:12) {
                RegionLandscape(pack:pack,showCaption:false).frame(width:92,height:64).clipShape(RoundedRectangle(cornerRadius:8)).accessibilityHidden(true)
                VStack(alignment:.leading,spacing:4) {
                    Text(pack.name).font(.headline)
                    Text(saved?.statusText ?? pack.subtitle).font(.caption).foregroundStyle(RidgeTheme.muted)
                    Text(pack.terrainQualityText(in:world.catalog)).font(.caption).foregroundStyle(RidgeTheme.muted)
                }
            }
            if pack.parkID != nil {
                Text(pack.subtitle).font(.caption).foregroundStyle(RidgeTheme.muted)
            }
            if partialCoverage {
                Label("Partial terrain coverage",systemImage:"exclamationmark.triangle")
                    .font(.subheadline.weight(.medium))
                Text("Red patches have no terrain and aren’t included in the download. You can explore the available terrain around them.")
                    .font(.caption).foregroundStyle(RidgeTheme.muted)
            }
            if !pack.standardTerrain(in:world.catalog).isEmpty {
                Text("Blue areas use standard terrain from 30 m elevation data. LiDAR detail is retained wherever available.")
                    .font(.caption).foregroundStyle(RidgeTheme.muted)
            }
            if let selectWholePark,!world.isSavingOffline,!world.checkingDownload {
                Button("Select whole park",systemImage:"map",action:selectWholePark).font(.subheadline)
            }
            if let saved,saved.savedTileCount>0,!world.isSavingOffline {
                Button(blocked || partialCoverage ? "Explore saved terrain" : "Explore in 3D",systemImage:"mountain.2") { explore() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if saved.downloadState == .partial {
                    Text("Opens the saved part. Download the rest to explore the whole available region.").font(.caption).foregroundStyle(RidgeTheme.muted)
                }
            }
                if world.catalog == nil {
                    if world.isLoading { ProgressView("Connecting to map server…") }
                    else if let retryConnection {
                        Button("Retry connection",systemImage:"arrow.clockwise",action:retryConnection)
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                } else if blocked {
                    Label("Terrain unavailable",systemImage:"exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(Color(red:0.70,green:0.19,blue:0.16))
                    Text("Red means this map source has no terrain here. It doesn’t mean you need to download it. You can still browse the overview.")
                        .font(.subheadline)
                } else if world.regionComplete {
                    Label(partialCoverage ? "Available terrain saved" : "Maps saved",systemImage:"checkmark.circle.fill").font(.headline)
                    Text("Choose a place to explore. Ridge only prepares the terrain around you.").font(.subheadline)
                    if saved?.savedTileCount ?? 0 == 0 { Button("Explore in 3D") { explore() }.buttonStyle(.borderedProminent) }
                } else if world.checkingDownload {
                    ProgressView(value:Double(world.regionChecked),total:Double(max(1,world.regionTotal)))
                    Text("Checking saved maps · \(world.regionChecked) of \(world.regionTotal) sections").font(.subheadline.monospacedDigit())
                    Button("Cancel check") { world.pauseRegionDownload() }
                } else if world.isSavingOffline,let plan=world.regionPlan {
                    if world.isConnectingDownload { ProgressView("Connecting to map server…") }
                    else {
                        if plan.isEstimate {
                            ProgressView(value:Double(world.regionTileProgress.savedTileCount+world.regionTileProgress.completed.count),total:Double(max(1,plan.tileCount)))
                                .animation(.linear(duration:0.25),value:world.regionTileProgress.savedTileCount+world.regionTileProgress.completed.count)
                            Text("\(RidgeTheme.bytes(world.downloadedBytes)) downloaded").font(.headline.monospacedDigit())
                        } else {
                            ProgressView(value:Double(world.downloadedBytes),total:Double(max(1,plan.bytes)))
                                .animation(.linear(duration:0.25),value:world.downloadedBytes)
                            Text("\(RidgeTheme.bytes(world.downloadedBytes)) of \(RidgeTheme.bytes(plan.bytes))").font(.headline.monospacedDigit())
                        }
                    }
                    WorldDownloadSpeed(rate:world.downloadRate)
                    Text("\(world.regionSaved) of \(plan.parts.count) sections saved").font(.subheadline.monospacedDigit())
                    Text("Amber tiles are downloading. Green tiles are saved.").font(.caption).foregroundStyle(RidgeTheme.muted)
                    Text("Keep Ridge open. The screen will stay awake while downloading. You can pause and continue later.").font(.caption).foregroundStyle(RidgeTheme.muted)
                    Button("Pause download") { world.pauseRegionDownload() }.buttonStyle(.bordered)
                } else if let plan=world.regionPlan,saved?.downloadState != .saved {
                    VStack(alignment:.leading,spacing:8) {
                        Text(plan.isEstimate ? "Up to \(RidgeTheme.bytes(plan.totalBytes))" : plan.bytes==0 ? "Maps already on your device" : "\(RidgeTheme.bytes(plan.bytes)) to download").font(.title3.weight(.semibold))
                        Text(plan.isEstimate ? "Terrain, maps & walking paths. Files already saved are reused as the download runs." : "\(RidgeTheme.bytes(plan.totalBytes)) in total · terrain, maps & walking paths").font(.subheadline).foregroundStyle(RidgeTheme.muted)
                        if plan.bytes>0,plan.totalBytes>plan.bytes {
                            Text("\(RidgeTheme.bytes(plan.totalBytes-plan.bytes)) already saved and reused").font(.caption)
                        }
                    }
                    if plan.bytes>0 {
                        Button(partialCoverage ? "Download available terrain" : "Download region") { world.downloadRegionPack() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    } else if saved?.savedTileCount ?? 0 == 0 {
                        Button("Use saved maps") { world.downloadRegionPack() }.buttonStyle(.borderedProminent)
                    }
                    Text("Saves to storage. It won’t load the whole region into 3D.").font(.caption).foregroundStyle(RidgeTheme.muted)
                }
                if let error=world.downloadError,!blocked {
                    Text(error).font(.subheadline)
                    if world.regionTotal>0 && !world.isSavingOffline && !world.checkingDownload {
                        Button("Check remaining download") { world.offerRegionDownload(pack) }.buttonStyle(.bordered)
                    }
                }
                if saved?.savedTileCount ?? 0 > 0 {
                    Button("Remove downloaded maps",role:.destructive) { confirmRemoval=true }
                        .disabled(world.isRemovingDownloads)
                }
        }.padding(16).frame(maxWidth:500,alignment:.leading)
            .confirmationDialog("Remove downloaded maps in \(pack.name)?",isPresented:$confirmRemoval,titleVisibility:.visible) {
                Button("Remove maps",role:.destructive) { Task { await world.removeDownloadedMaps(in:pack) } }
            } message: { Text("You can download them again. Saved routes and map files still used by other areas are kept.") }
    }
}

private struct WorldDownloadSpeed:View {
    let rate:WorldDownloadRate
    var body:some View {
        TimelineView(.periodic(from:.now,by:1)) { timeline in
            let value=rate.bytesPerSecond(at:timeline.date)
            Label(value.map { RidgeTheme.bytes(Int64($0))+"/s" } ?? "Measuring speed…",systemImage:"arrow.down")
                .font(.subheadline.monospacedDigit()).foregroundStyle(RidgeTheme.muted)
                .accessibilityLabel(value.map { "Download speed, "+RidgeTheme.bytes(Int64($0))+" per second" } ?? "Measuring download speed")
        }
    }
}

/// Small, explicitly illustrated landmark postcards. Native vector paths keep
/// the download picker sharp at any device size and add no photo dependency.
struct RegionLandscape:View {
    let pack:WorldRegionPack
    var showCaption=true
    var body:some View {
        Canvas { context,size in
            let w=size.width,h=size.height
            func point(_ x:Double,_ y:Double)->CGPoint { CGPoint(x:x*w,y:y*h) }
            func polygon(_ points:[(Double,Double)],_ color:Color) {
                var path=Path();path.move(to:point(points[0].0,points[0].1))
                for p in points.dropFirst() { path.addLine(to:point(p.0,p.1)) }
                path.closeSubpath();context.fill(path,with:.color(color))
            }
            let sky=Color(red:0.81,green:0.87,blue:0.85),far=Color(red:0.55,green:0.67,blue:0.63)
            let rock=Color(red:0.34,green:0.48,blue:0.43),grass=Color(red:0.66,green:0.72,blue:0.54)
            context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(sky))
            context.fill(Path(ellipseIn:CGRect(x:w*0.77,y:h*0.13,width:h*0.23,height:h*0.23)),with:.color(Color(red:0.96,green:0.90,blue:0.69)))
            let coastal=["east-anglia","south-east","south-west"].contains(pack.artworkID)
            if coastal {
                polygon([(0,0.59),(0.2,0.57),(0.43,0.62),(0.7,0.55),(1,0.59),(1,1),(0,1)],far)
            } else {
                polygon([(0,0.62),(0.14,0.43),(0.26,0.54),(0.40,0.30),(0.53,0.50),(0.7,0.36),(0.88,0.54),(1,0.43),(1,1),(0,1)],far)
            }
            let profile:[(Double,Double)]
            switch pack.artworkID {
            case "north-scotland": profile=[(0,0.83),(0.22,0.65),(0.34,0.63),(0.4,0.3),(0.44,0.16),(0.48,0.35),(0.5,0.63),(0.63,0.55),(0.7,0.38),(0.74,0.68),(1,0.89)]
            case "west-highlands": profile=[(0,0.85),(0.17,0.64),(0.36,0.27),(0.57,0.24),(0.61,0.35),(0.70,0.41),(0.74,0.63),(1,0.85)]
            case "lowlands": profile=[(0,0.91),(0.2,0.6),(0.3,0.36),(0.43,0.68),(0.54,0.42),(0.65,0.71),(0.79,0.48),(1,0.85)]
            case "northern-ireland": profile=[(0,0.83),(0.20,0.65),(0.36,0.32),(0.45,0.49),(0.55,0.67),(0.71,0.4),(0.81,0.66),(1,0.86)]
            case "lakes-dales": profile=[(0,0.81),(0.18,0.59),(0.35,0.4),(0.43,0.44),(0.53,0.29),(0.61,0.31),(0.68,0.45),(0.82,0.59),(1,0.78)]
            case "north-east": profile=[(0,0.83),(0.28,0.7),(0.45,0.4),(0.5,0.32),(0.59,0.33),(0.59,0.48),(0.70,0.7),(1,0.85)]
            case "midlands": profile=[(0,0.7),(0.2,0.65),(0.3,0.44),(0.48,0.43),(0.49,0.50),(0.69,0.49),(0.71,0.54),(0.87,0.54),(1,0.59)]
            case "wales": profile=[(0,0.91),(0.2,0.74),(0.32,0.52),(0.41,0.48),(0.51,0.22),(0.54,0.29),(0.68,0.6),(0.78,0.52),(1,0.86)]
            default: profile=[(0,0.55),(0.18,0.52),(0.35,0.56),(0.56,0.49),(0.8,0.55),(1,0.52)]
            }
            polygon(profile+[(1,1),(0,1)],rock)
            polygon([(0,0.85),(0.25,0.80),(0.55,0.94),(0.8,0.77),(1,0.85),(1,1),(0,1)],grass)
            if coastal {
                let sea=Color(red:0.48,green:0.68,blue:0.71)
                polygon([(0,0.72),(0.25,0.69),(0.5,0.74),(0.8,0.66),(1,0.7),(1,1),(0,1)],sea)
                if pack.artworkID=="east-anglia" {
                    polygon([(0,0.7),(0.62,0.68),(0.35,0.86),(0,0.88)],grass)
                    polygon([(0.66,0.49),(0.79,0.49),(0.82,0.77),(0.64,0.77)],Color(red:0.87,green:0.83,blue:0.69))
                    polygon([(0.64,0.5),(0.73,0.38),(0.81,0.5)],rock)
                    var sails=Path();sails.move(to:point(0.58,0.31));sails.addLine(to:point(0.86,0.68));sails.move(to:point(0.86,0.31));sails.addLine(to:point(0.58,0.68))
                    context.stroke(sails,with:.color(.white.opacity(0.85)),lineWidth:3)
                } else if pack.artworkID=="south-east" {
                    polygon([(0,0.38),(0.18,0.43),(0.29,0.36),(0.43,0.43),(0.53,0.38),(0.64,0.46),(0.71,0.42),(0.83,0.51),(0.82,0.63),(0.68,0.66),(0.49,0.75),(0.28,0.83),(0,0.92)],Color(red:0.94,green:0.92,blue:0.82))
                    polygon([(0,0.36),(0.18,0.41),(0.29,0.34),(0.43,0.41),(0.53,0.36),(0.64,0.44),(0.71,0.40),(0.83,0.49),(0.71,0.46),(0.52,0.40),(0.27,0.40),(0,0.40)],grass)
                } else {
                    polygon([(0,0.44),(0.25,0.5),(0.41,0.60),(0.52,0.50),(0.64,0.52),(0.72,0.66),(0.69,0.83),(0.57,0.85),(0.40,0.8),(0.21,0.74),(0,0.79)],Color(red:0.69,green:0.65,blue:0.49))
                    var arch=Path();arch.move(to:point(0.46,0.82));arch.addQuadCurve(to:point(0.63,0.81),control:point(0.54,0.45));arch.closeSubpath()
                    context.fill(arch,with:.color(sea))
                }
            } else {
                var ridge=Path();ridge.move(to:point(0.51,0.43));ridge.addLine(to:point(0.61,0.64));ridge.addLine(to:point(0.54,0.74))
                context.stroke(ridge,with:.color(.white.opacity(0.16)),lineWidth:1.5)
            }
        }.overlay(alignment:.bottomLeading) {
            if showCaption { Text("Illustration · \(pack.landmark)").font(.system(size:10,weight:.medium))
                .padding(.horizontal,8).padding(.vertical,5).background(RidgeTheme.paper.opacity(0.90),in:Capsule()).padding(10) }
        }.accessibilityLabel("Illustration of \(pack.landmark)")
    }
}
