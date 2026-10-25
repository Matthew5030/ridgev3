import SwiftUI

struct WorldRouteToolbar: View {
    var route: RidgeRoute
    var editing: Bool
    var busy: Bool
    var pathsReady: Bool
    var canUndo: Bool
    var canRedo: Bool
    var selectedWaypoint: UUID?
    var onAction: (WorldRouteEditorPanel.Action) -> Void
    @State private var availableWidth: CGFloat = 1024
    private var imported: Bool { route.segments.contains { $0.mode == "imported" } }
    var body: some View {
        HStack(spacing:12) {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:8) {
                    shortcut("Undo","arrow.uturn.backward",enabled:canUndo) { onAction(.undo) }
                    shortcut("Redo","arrow.uturn.forward",enabled:canRedo) { onAction(.redo) }
                    if !imported {
                        shortcut("Back to start","arrow.trianglehead.2.clockwise.rotate.90",enabled:pathsReady && route.waypoints.count>1) { onAction(.closeLoop) }
                            .accessibilityHint("Add a route leg back to your first waypoint")
                    }
                    shortcut("Reverse","arrow.left.arrow.right",enabled:pathsReady && route.points.count>1) { onAction(.reverse) }
                    shortcut("Show route","arrow.up.left.and.arrow.down.right",enabled:!route.points.isEmpty) { onAction(.fitRoute) }
                    if !imported,let id=selectedWaypoint,let index=route.waypoints.firstIndex(where:{ $0.id==id }) {
                        Divider().frame(height:32)
                        shortcut("Move point","arrow.up.left.and.arrow.down.right",enabled:pathsReady) { onAction(.move(id)) }
                        shortcut("Add via","plus.circle",enabled:pathsReady && index<route.waypoints.count-1) { onAction(.insertAfter(id)) }
                        shortcut("Delete point","trash",enabled:pathsReady) { onAction(.delete(id)) }
                    }
                }.padding(.horizontal,4)
            }
            if editing {
                Button(availableWidth<700 ? "Finish" : "Finish editing",systemImage:"checkmark") { onAction(.finish) }
                    .font(.subheadline.weight(.semibold)).frame(minHeight:44).fixedSize().accessibilityLabel("Finish editing")
            } else if !imported {
                Button("Edit route",systemImage:"pencil") { onAction(.edit) }.font(.subheadline.weight(.semibold)).disabled(!pathsReady).fixedSize()
            }
        }.padding(.horizontal,16).padding(.vertical,8).background(RidgeTheme.paper).disabled(busy)
            .onGeometryChange(for:CGFloat.self) { $0.size.width } action: { availableWidth=$0 }
    }
    private func shortcut(_ label:String,_ symbol:String,enabled:Bool,action:@escaping()->Void)->some View {
        Button(action:action) {
            VStack(spacing:4) {
                Image(systemName:symbol).font(.system(size:17,weight:.medium))
                Text(label).font(.caption2.weight(.medium)).lineLimit(1)
            }.frame(minWidth:64,minHeight:44).padding(.horizontal,6)
                .background(RidgeTheme.selection.opacity(0.6),in:RoundedRectangle(cornerRadius:9))
        }.buttonStyle(.plain).disabled(!enabled).accessibilityLabel(label)
    }
}
