import SwiftUI

struct WorldRegionPacksView: View {
    @Bindable var world:WorldModel
    let chooseCustom:() -> Void
    let explore:(WorldRegionPack) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var packs:[WorldRegionPack]=[]
    @State private var sourcesByPack:[String:[WorldCatalog.Region]]=[:]
    @State private var selected:String?
    @State private var error:String?

    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    Text("Save a region for the next trip. Explore anywhere in it once the maps are on your device.")
                        .font(.subheadline).foregroundStyle(RidgeTheme.muted)
                    Button { chooseCustom() } label: {
                        HStack(spacing:12) {
                            Image(systemName:"crop").font(.title2)
                            VStack(alignment:.leading,spacing:4) {
                                Text("Choose a smaller area").font(.headline)
                                Text("Around a place, or draw your own boundary").font(.caption).foregroundStyle(RidgeTheme.muted)
                            }
                            Spacer();Image(systemName:"chevron.right")
                        }.padding(16).background(RidgeTheme.panel,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).disabled(world.isSavingOffline)
                    if let active=world.downloadRegion,world.isSavingOffline {
                        Button { selected=active.id } label: {
                            HStack { ProgressView();Text("Downloading \(active.name)");Spacer();Image(systemName:"chevron.right") }
                        }.buttonStyle(.plain)
                    }
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:280),spacing:16)],spacing:18) {
                        ForEach(packs) { pack in
                            let count=sourcesByPack[pack.id]?.count ?? 0
                            Button {
                                if world.downloadRegion?.id != pack.id || world.regionPlan == nil && !world.checkingDownload && !world.isSavingOffline {
                                    world.offerRegionDownload(pack)
                                }
                                selected=pack.id
                            } label: {
                                VStack(alignment:.leading,spacing:0) {
                                    RegionLandscape(pack:pack).frame(height:140).clipped()
                                    VStack(alignment:.leading,spacing:7) {
                                        Text(pack.name).font(.headline)
                                        Text(pack.subtitle).font(.caption).foregroundStyle(RidgeTheme.muted).fixedSize(horizontal:false,vertical:true)
                                        HStack {
                                            Text(count==0 ? "Not available yet" : "View pack")
                                            Spacer();Image(systemName:count==0 ? "clock" : "arrow.down.circle")
                                        }.font(.subheadline.weight(.medium)).padding(.top,5)
                                    }.padding(16)
                                }.frame(maxWidth:.infinity,alignment:.leading).background(RidgeTheme.panel)
                                    .clipShape(RoundedRectangle(cornerRadius:14))
                            }.buttonStyle(.plain).disabled(world.isSavingOffline && world.downloadRegion?.id != pack.id)
                        }
                    }
                    Text("Packs follow the map grid, so their edges are approximate. Some regions have partial coverage; check the shaded map before downloading.")
                        .font(.caption).foregroundStyle(RidgeTheme.muted)
                    if let error { Text(error).foregroundStyle(RidgeTheme.orange) }
                }.padding(20).frame(maxWidth:900).frame(maxWidth:.infinity)
            }.background(RidgeTheme.paper).navigationTitle("Download maps")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
                .navigationDestination(item:$selected) { id in
                    if let pack=packs.first(where: { $0.id==id }) { detail(pack) }
                }
        }.foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
            .task(id:world.catalog?.revision) {
                do {
                    packs=try WorldRegionPack.load()
                    if let catalog=world.catalog { sourcesByPack=Dictionary(uniqueKeysWithValues:packs.map { ($0.id,$0.sources(in:catalog)) }) }
                    selected=world.downloadRegion?.id
                } catch { self.error=error.localizedDescription }
            }
    }
    private func detail(_ pack:WorldRegionPack) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                RegionLandscape(pack:pack).frame(height:190).clipShape(RoundedRectangle(cornerRadius:14))
                VStack(alignment:.leading,spacing:7) {
                    Text(pack.name).font(.title2.weight(.semibold))
                    Text(pack.subtitle).foregroundStyle(RidgeTheme.muted)
                }
                if let sources=sourcesByPack[pack.id] {
                    RegionCoverageMap(pack:pack,sources:sources).frame(height:190)
                        .background(RidgeTheme.panel,in:RoundedRectangle(cornerRadius:12))
                    Text("Green: maps available from your source. Pale: not available yet. The pack saves all available maps in this region.")
                        .font(.caption).foregroundStyle(RidgeTheme.muted)
                }
                if world.regionComplete {
                    Label("Available maps saved",systemImage:"checkmark.circle.fill").font(.headline)
                    Text("Choose a place to explore. Ridge only prepares the terrain around you.").font(.subheadline)
                    Button("Explore region") { explore(pack) }.buttonStyle(.borderedProminent)
                } else if world.checkingDownload {
                    ProgressView(value:Double(world.regionChecked),total:Double(max(1,world.regionTotal)))
                    Text("Checking saved maps · \(world.regionChecked) of \(world.regionTotal) sections").font(.subheadline.monospacedDigit())
                    Button("Cancel check") { world.pauseRegionDownload() }
                } else if world.isSavingOffline,let plan=world.regionPlan {
                    if world.isConnectingDownload { ProgressView("Connecting to map server…") }
                    else {
                        ProgressView(value:Double(world.downloadedBytes),total:Double(max(1,plan.bytes)))
                        Text("\(RidgeTheme.bytes(world.downloadedBytes)) of \(RidgeTheme.bytes(plan.bytes))").font(.headline.monospacedDigit())
                    }
                    Text("\(world.regionSaved) of \(plan.parts.count) sections saved").font(.subheadline.monospacedDigit())
                    Text("Keep Ridge open. The screen will stay awake while downloading. You can pause and continue later.").font(.caption).foregroundStyle(RidgeTheme.muted)
                    Button("Pause download") { world.pauseRegionDownload() }.buttonStyle(.bordered)
                } else if let plan=world.regionPlan {
                    VStack(alignment:.leading,spacing:8) {
                        Text(plan.bytes==0 ? "Maps already on your device" : "\(RidgeTheme.bytes(plan.bytes)) to download").font(.title3.weight(.semibold))
                        Text("\(RidgeTheme.bytes(plan.totalBytes)) in total · terrain, maps & walking paths").font(.subheadline).foregroundStyle(RidgeTheme.muted)
                        if plan.bytes>0,plan.totalBytes>plan.bytes {
                            Text("\(RidgeTheme.bytes(plan.totalBytes-plan.bytes)) already saved and reused").font(.caption)
                        }
                    }
                    Button(plan.bytes==0 ? "Use saved maps" : "Download region") { world.downloadRegionPack() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Saves to storage. It won’t load the whole region into 3D.").font(.caption).foregroundStyle(RidgeTheme.muted)
                }
                if let error=world.downloadError {
                    Text(error).font(.subheadline)
                    if world.regionTotal>0 && !world.isSavingOffline && !world.checkingDownload {
                        Button("Check remaining download") { world.offerRegionDownload(pack) }.buttonStyle(.bordered)
                    }
                }
            }.padding(20).frame(maxWidth:600).frame(maxWidth:.infinity)
        }.background(RidgeTheme.paper).navigationTitle("Region pack").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { dismiss() } } }
    }
}

/// Geographic preview of the real manifest coverage, not a decorative outline.
private struct RegionCoverageMap:View {
    let pack:WorldRegionPack
    let sources:[WorldCatalog.Region]
    var body:some View {
        Canvas { context,size in
            let bounds=pack.bounds
            let scale=min((size.width-30)/bounds.widthMeters,(size.height-30)/bounds.depthMeters)
            let width=bounds.widthMeters*scale,height=bounds.depthMeters*scale
            func rect(_ b:GeoBounds)->CGRect {
                let a=bounds.uv(.init(latitude:b.maxLatitude,longitude:b.minLongitude))
                let z=bounds.uv(.init(latitude:b.minLatitude,longitude:b.maxLongitude))
                return CGRect(x:(size.width-width)/2+a.u*width,y:(size.height-height)/2+a.v*height,width:(z.u-a.u)*width,height:(z.v-a.v)*height)
            }
            for cell in pack.cells { context.fill(Path(rect(cell.bounds)),with:.color(RidgeTheme.forest.opacity(0.1))) }
            for source in sources { context.fill(Path(rect(source.bounds)),with:.color(RidgeTheme.forest.opacity(0.8))) }
        }.accessibilityLabel("Map showing available coverage in \(pack.name)")
    }
}

/// Small, explicitly illustrated landmark postcards. Native vector paths keep
/// the download picker sharp at any device size and add no photo dependency.
struct RegionLandscape:View {
    let pack:WorldRegionPack
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
            let coastal=["east-anglia","south-east","south-west"].contains(pack.id)
            if coastal {
                polygon([(0,0.59),(0.2,0.57),(0.43,0.62),(0.7,0.55),(1,0.59),(1,1),(0,1)],far)
            } else {
                polygon([(0,0.62),(0.14,0.43),(0.26,0.54),(0.40,0.30),(0.53,0.50),(0.7,0.36),(0.88,0.54),(1,0.43),(1,1),(0,1)],far)
            }
            let profile:[(Double,Double)]
            switch pack.id {
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
                if pack.id=="east-anglia" {
                    polygon([(0,0.7),(0.62,0.68),(0.35,0.86),(0,0.88)],grass)
                    polygon([(0.66,0.49),(0.79,0.49),(0.82,0.77),(0.64,0.77)],Color(red:0.87,green:0.83,blue:0.69))
                    polygon([(0.64,0.5),(0.73,0.38),(0.81,0.5)],rock)
                    var sails=Path();sails.move(to:point(0.58,0.31));sails.addLine(to:point(0.86,0.68));sails.move(to:point(0.86,0.31));sails.addLine(to:point(0.58,0.68))
                    context.stroke(sails,with:.color(.white.opacity(0.85)),lineWidth:3)
                } else if pack.id=="south-east" {
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
            Text("Illustration · \(pack.landmark)").font(.system(size:10,weight:.medium))
                .padding(.horizontal,8).padding(.vertical,5).background(RidgeTheme.paper.opacity(0.90),in:Capsule()).padding(10)
        }.accessibilityLabel("Illustration of \(pack.landmark)")
    }
}
