import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A light cloud veil over the live route overview; no first-person framing.
struct WorldFlightEntryView: View {
    @Bindable var tour:WorldRouteTour
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        TimelineView(.animation(minimumInterval:1.0/30,paused:reduceMotion)) { clock in
            let waiting=clock.date.timeIntervalSince(tour.entryStartedAt)
            ZStack {
                if !reduceMotion {
                    WorldFlightCloudArtwork(progress:tour.isRevealing ? min(1,tour.entryElapsed/3.2) : 0,drift:waiting*0.8)
                }
                VStack {
                        HStack {
                            VStack(alignment:.leading,spacing:5) {
                                Text("FPV FLY-THROUGH").font(.caption2.weight(.semibold)).tracking(2)
                                HStack(spacing:8) {
                                    if !tour.isTerrainReady { ProgressView().tint(.white).controlSize(.small) }
                                    Text(tour.isPreparing ? "Preparing your preview…" : tour.isTerrainReady ? "Joining the route…" : "Preparing the scenery…").font(.caption)
                                }.opacity(0.85)
                            }
                            Spacer()
                            Button { tour.close() } label: { Image(systemName:"xmark").frame(width:44,height:44).background(.black.opacity(0.30),in:Circle()) }
                                .accessibilityLabel("Close preview and return to route")
                        }.padding(18).background(LinearGradient(colors:[.black.opacity(0.45),.clear],startPoint:.top,endPoint:.bottom))
                        Spacer()
                        if tour.isTerrainReady { Button("Skip intro") { tour.finishEntry() }.font(.caption.weight(.semibold)).padding(.horizontal,18).frame(minHeight:44).background(.black.opacity(0.35),in:Capsule()).padding(20) }
                }.foregroundStyle(.white)
            }
        }
        .task(id:tour.sessionID) {
            while !Task.isCancelled,tour.isPresented,tour.isEntering,!tour.isRevealing {
                if tour.isTerrainReady && !tour.isPreparing {
                    tour.revealEntry();break
                }
                do { try await Task.sleep(for:.milliseconds(100)) } catch { break }
            }
        }
    }
}

struct WorldFlightCloudArtwork:View {
    var progress:Double
    var drift:Double=0
    var body:some View {
        GeometryReader { geometry in
            WorldFlightArt.image("FlightClouds").resizable().interpolation(.high)
                .frame(width:geometry.size.width,height:geometry.size.height)
                .scaleEffect(1.12+progress*0.7).offset(x:min(60,drift))
                .opacity(max(0,1-progress)*0.28)
        }.clipped().accessibilityHidden(true).allowsHitTesting(false)
    }
}

enum WorldFlightArt {
    static func image(_ name:String)->Image {
        #if os(macOS)
        if let root=ProcessInfo.processInfo.environment["RIDGE_FLIGHT_ASSETS"],
           let image=NSImage(contentsOfFile:root+"/"+name+".imageset/"+name+".png") { return Image(nsImage:image) }
        #endif
        return Image(name)
    }
}
