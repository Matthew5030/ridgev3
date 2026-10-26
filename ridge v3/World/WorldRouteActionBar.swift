import SwiftUI

/// The map keeps its space until the user asks for route details.
struct WorldRouteActionBar: View {
    var route: RidgeRoute
    var editing: Bool
    var busy: Bool
    var pathsReady: Bool
    var canUndo: Bool
    var details: () -> Void
    var onAction: (WorldRouteEditorPanel.Action) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: details) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Route details").font(.subheadline.weight(.semibold))
                        Text(String(format: "%.1f km · %d points", RouteEngine.statistics(for: route).distanceMeters / 1000, route.waypoints.count))
                            .font(.caption).foregroundStyle(RidgeTheme.muted)
                    }
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold))
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Open waypoints, elevation and walking plans")
            if editing {
                Button { onAction(.undo) } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                }.disabled(!canUndo).accessibilityLabel("Undo route change")
            }
            Button { onAction(.preview(nil)) } label: {
                Image(systemName: "play.fill").frame(width: 44, height: 44)
                    .background(RidgeTheme.forest, in: Circle()).foregroundStyle(.white)
            }.disabled(route.points.count < 2).accessibilityLabel("Preview route")
            if editing {
                Button("Done") { onAction(.finish) }.font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
            } else if !route.segments.contains(where: { $0.mode == "imported" }) {
                Button { onAction(.edit) } label: {
                    Image(systemName: "pencil").frame(width: 44, height: 44)
                }.disabled(!pathsReady).accessibilityLabel("Edit route")
            }
        }.padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial)
            .disabled(busy).buttonStyle(.plain)
    }
}

/// Playback keeps one scrubber and an optional elevation plot.
struct WorldRoutePlaybackBar: View {
    @Bindable var tour: WorldRouteTour
    @Binding var showsElevation: Bool
    var hasElevation: Bool
    @State private var resumeAfterScrubbing = false

    var body: some View {
        VStack(spacing: 0) {
            if let message = tour.message, !tour.isPreparing {
                Text(message).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            HStack(spacing: 4) {
                Button { tour.togglePlayback() } label: {
                    Image(systemName: tour.isPlaying ? "pause.fill" : tour.progress >= 1 ? "arrow.counterclockwise" : "play.fill")
                        .frame(width: 44, height: 44)
                }.accessibilityLabel(tour.isPlaying ? "Pause preview" : "Play preview")
                Slider(value: Binding(get: { tour.progress }, set: { tour.seek(to: $0) }), in: 0...1) { editing in
                    if editing { resumeAfterScrubbing = tour.isPlaying; tour.pause() }
                    else if resumeAfterScrubbing { tour.isPlaying = tour.progress < 1; resumeAfterScrubbing = false }
                }.accessibilityLabel("Route progress").accessibilityValue("\(Int(tour.progress * 100)) percent")
                if hasElevation {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { showsElevation.toggle() } } label: {
                        Image(systemName: "chart.xyaxis.line").frame(width: 44, height: 44)
                            .background(showsElevation ? RidgeTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.accessibilityLabel(showsElevation ? "Hide elevation" : "Show elevation")
                }
                Button { tour.close() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.accessibilityLabel("End preview and return to route")
            }.padding(.horizontal, 8).padding(.vertical, 6)
        }.background(.regularMaterial).buttonStyle(.plain)
    }
}
