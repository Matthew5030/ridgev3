import SwiftUI

/// One compact, shared position control for editing and playback.
struct WorldRouteElevationStrip: View {
    var samples: [RouteProfileSample]
    var selectedDistance: Double?
    @Bindable var tour: WorldRouteTour
    var onScrub: (Double) -> Void
    @State private var scrubbing=false
    @State private var resumeAfterScrub=false
    private var length: Double { samples.last?.distance ?? 0 }
    private var fraction: Double {
        tour.isPresented ? tour.progress : min(1,max(0,(selectedDistance ?? length)/max(1,length)))
    }
    var body: some View {
        let position=WorldRouteProfile.position(in:samples,at:length*fraction)
        VStack(spacing:4) {
            HStack {
                Label("Elevation",systemImage:"mountain.2").font(.caption.weight(.semibold))
                Spacer()
                Text((position?.elevation.map { "\(Int($0.rounded())) m · " } ?? "Elevation unavailable · ")
                     + String(format:"%.2f / %.2f km",length*fraction/1000,length/1000))
            }.font(.caption.monospacedDigit()).foregroundStyle(RidgeTheme.muted)
            GeometryReader { geometry in
                Canvas { context,size in
                    let heights=samples.compactMap { $0.point.elevation }.filter(\.isFinite)
                    let low=heights.min() ?? 0, high=heights.max() ?? 1
                    let span=max(10,high-low),floor=low-max(0,(10-(high-low))/2)
                    func y(_ elevation: Double)->CGFloat { 4+(1-(elevation-floor)/span)*(size.height-8) }
                    var grid=Path()
                    for fraction in [0.0,0.5,1] { let py=4+fraction*(size.height-8);grid.move(to:CGPoint(x:0,y:py));grid.addLine(to:CGPoint(x:size.width,y:py)) }
                    context.stroke(grid,with:.color(RidgeTheme.line.opacity(0.65)),lineWidth:0.5)
                    var runs:[[CGPoint]]=[],run:[CGPoint]=[]
                    for sample in samples {
                        if sample.breakBefore || sample.unknownBefore || sample.point.elevation?.isFinite != true {
                            if !run.isEmpty { runs.append(run);run=[] }
                        }
                        if let elevation=sample.point.elevation,elevation.isFinite {
                            run.append(CGPoint(x:sample.distance/max(1,length)*size.width,y:y(elevation)))
                        }
                    }
                    if !run.isEmpty { runs.append(run) }
                    for run in runs where run.count>1 {
                        var line=Path();line.addLines(run)
                        var fill=line;fill.addLine(to:CGPoint(x:run.last!.x,y:size.height));fill.addLine(to:CGPoint(x:run.first!.x,y:size.height));fill.closeSubpath()
                        context.fill(fill,with:.color(RidgeTheme.forest.opacity(0.12)))
                        context.stroke(line,with:.color(RidgeTheme.forest),style:StrokeStyle(lineWidth:1.5,lineJoin:.round))
                    }
                    let x=fraction*size.width
                    var marker=Path();marker.move(to:CGPoint(x:x,y:0));marker.addLine(to:CGPoint(x:x,y:size.height))
                    context.stroke(marker,with:.color(RidgeTheme.orange),lineWidth:1.5)
                    if let elevation=position?.elevation {
                        let dot=CGRect(x:x-3.5,y:y(elevation)-3.5,width:7,height:7)
                        context.fill(Path(ellipseIn:dot),with:.color(RidgeTheme.orange))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { value in
                    if !scrubbing { scrubbing=true;resumeAfterScrub=tour.isPlaying;tour.pause() }
                    onScrub(min(1,max(0,value.location.x/max(1,geometry.size.width))))
                }.onEnded { _ in
                    scrubbing=false
                    if resumeAfterScrub && tour.isPresented { tour.isPlaying=tour.progress<1 }
                    resumeAfterScrub=false
                })
            }.frame(height:44)
        }.padding(.horizontal,16).padding(.vertical,8).background(RidgeTheme.paper)
            .accessibilityElement(children:.ignore).accessibilityLabel("Route elevation and position")
            .accessibilityValue("\(Int(fraction*100)) percent" + (position?.elevation.map { ", \(Int($0)) metres elevation" } ?? ", elevation unavailable"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onScrub(min(1,fraction+0.01))
                case .decrement: onScrub(max(0,fraction-0.01))
                @unknown default: break
                }
            }
    }
}
