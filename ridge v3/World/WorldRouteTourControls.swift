import SwiftUI

struct WorldRouteTourControls: View {
    @Bindable var tour: WorldRouteTour
    var returnLabel: String? = nil
    @State private var resumeAfterScrubbing = false

    var body: some View {
        VStack(spacing:12) {
            HStack {
                Label("FPV fly-through",systemImage:"viewfinder").font(.headline)
                Spacer()
                Button { tour.close() } label: {
                    if let returnLabel { Text(returnLabel).font(.caption.weight(.semibold)).frame(minHeight:44) }
                    else { Image(systemName:"xmark").frame(width:44,height:44) }
                }
                    .accessibilityLabel("Close preview and restore map view")
            }
            HStack(spacing:12) {
                Button { tour.togglePlayback() } label: {
                    Image(systemName:tour.isPlaying ? "pause.fill" : tour.progress >= 1 ? "arrow.counterclockwise" : "play.fill")
                        .frame(width:44,height:44).background(RidgeTheme.forest,in:Circle()).foregroundStyle(.white)
                }.accessibilityLabel(tour.isPlaying ? "Pause preview" : tour.progress >= 1 ? "Replay route" : "Play preview")
                Slider(value:Binding(get:{tour.progress},set:{tour.seek(to:$0)}),in:0...1) { editing in
                    if editing { resumeAfterScrubbing=tour.isPlaying;tour.pause() }
                    else if resumeAfterScrubbing { tour.isPlaying=tour.progress<1 }
                }.accessibilityLabel("Route progress")
                    .accessibilityValue("\(Int(tour.progress*100)) percent")
                Text("\(Int(tour.progress*100))%").font(.caption.monospacedDigit()).frame(minWidth:36)
            }
            WorldPreviewSpeedControl(tour: tour)

            HStack {
                Label("Low flight",systemImage:"viewfinder")
                Spacer()
                Text(tour.isEntering ? "Entering route…" : "\(Int(tour.actualHeight.rounded())) m above ground").monospacedDigit()
            }.font(.caption).foregroundStyle(RidgeTheme.muted)
            HStack {
                Text(String(format:"%.2f / %.2f km",tour.progress*tour.length/1000,tour.length/1000)).monospacedDigit()
                Spacer()
                Text(tour.isPlaying ? "Preview" : "Paused")
            }.font(.caption).foregroundStyle(RidgeTheme.muted)
            Text("Drag while flying to steer. Release to rejoin the route.")
                .font(.caption).foregroundStyle(RidgeTheme.muted).fixedSize(horizontal:false,vertical:true)
            if tour.isPreparing {
                HStack(spacing:8) { ProgressView().controlSize(.small);Text("Preparing flight plan…") }
                    .font(.caption).foregroundStyle(RidgeTheme.muted)
            } else if let message=tour.message {
                Text(message).font(.caption).foregroundStyle(RidgeTheme.muted).fixedSize(horizontal:false,vertical:true)
            }
        }.padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
    }
}

struct WorldPreviewSpeedControl: View {
    @Bindable var tour: WorldRouteTour
    var body: some View {
            VStack(spacing:8) {
                HStack {
                    Text("Cruise speed").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(tour.speed)) km/h").font(.subheadline.monospacedDigit().weight(.semibold))
                }
                Slider(value:Binding(get:{tour.speed},set:{tour.speed=$0.rounded()}),in:WorldRouteTour.speedRange,step:10)
                    .accessibilityLabel("Preview cruise speed")
                    .accessibilityValue("\(Int(tour.speed)) kilometres per hour")
                HStack(spacing:6) {
                    ForEach([30.0,90,180,360,600],id:\.self) { speed in
                        Button { tour.speed=speed } label: {
                            Text("\(Int(speed))").font(.caption.monospacedDigit().weight(.semibold))
                                .frame(maxWidth:.infinity,minHeight:36)
                                .background(abs(tour.speed-speed)<1 ? RidgeTheme.forest.opacity(0.16) : Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:7))
                        }.buttonStyle(.plain).accessibilityLabel("Fly at \(Int(speed)) kilometres per hour")
                    }
                }
                Text("Flying \(Int(tour.actualKilometersPerHour.rounded())) km/h · slows gently for turns")
                    .font(.caption2.monospacedDigit()).foregroundStyle(RidgeTheme.muted)
            }.foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
    }
}
