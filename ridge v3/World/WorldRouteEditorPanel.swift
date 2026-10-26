import SwiftUI

enum WorldRouteDetailsSection: String, CaseIterable, Identifiable {
    case waypoints = "Waypoints", elevation = "Elevation"
    var id: Self { self }
}

/// The route stays visible beside the terrain throughout editing and playback.
/// Actions resolve waypoint IDs against the current route in the host.
struct WorldRouteEditorPanel: View {
    enum Action {
        case start, finish, edit, undo, redo, rename, export, reverse, closeLoop, fitRoute, library, cancelPlacement, brief
        case preview(UUID?), select(UUID), move(UUID), delete(UUID), insertAfter(UUID)
    }
    var route: RidgeRoute?
    var editing: Bool
    var busy: Bool
    var pathsReady: Bool
    var canUndo: Bool
    var canRedo: Bool
    var selectedWaypoint: UUID?
    var movingWaypoint: UUID?
    var inserting: Bool
    var summary: String
    @Bindable var tour: WorldRouteTour
    var dismiss: (() -> Void)? = nil
    var onAction: (Action) -> Void
    var section: Binding<WorldRouteDetailsSection> = .constant(.waypoints)
    var elevationSamples: [RouteProfileSample] = []
    var selectedDistance: Double? = nil
    var onScrub: (Double) -> Void = { _ in }
    var compact = false
    private var imported: Bool { route?.segments.contains { $0.mode == "imported" } == true }
    private var previewAvailable: Bool { (route?.points.count ?? 0)>1 && !busy }

    var body: some View {
        VStack(spacing:0) {
            header.padding(compact ? 12 : 18).fixedSize(horizontal:false,vertical:true)
            Divider()
            if let route {
                if elevationSamples.count > 1 {
                    Picker("Route details", selection: section) {
                        ForEach(WorldRouteDetailsSection.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.vertical, 10)
                }
                if tour.isPresented {
                    WorldRouteTourControls(tour:tour,returnLabel:editing ? "Back to editing" : "Back to route")
                        .padding(12).fixedSize(horizontal:false,vertical:true)
                    Divider()
                }
                if section.wrappedValue == .elevation, elevationSamples.count > 1 {
                    ScrollView {
                        WorldRouteElevationStrip(samples: elevationSamples, selectedDistance: selectedDistance,
                            tour: tour, onScrub: onScrub, chartHeight: 140).padding(.vertical, 16)
                        Text("Drag the profile to see that point on the map.")
                            .font(.caption).foregroundStyle(RidgeTheme.muted).padding(.horizontal, 16)
                    }
                } else { waypointList(route) }
                Divider()
                footer(route).padding(16).fixedSize(horizontal:false,vertical:true)
                if compact, editing, !tour.isPresented, section.wrappedValue == .waypoints {
                    WorldRouteToolbar(route: route, editing: editing, busy: busy, pathsReady: pathsReady,
                        canUndo: canUndo, canRedo: canRedo, selectedWaypoint: selectedWaypoint, onAction: onAction)
                }
            } else {
                WorldRoutePlanPrompt(pathsReady:pathsReady,busy:busy,plan:{ onAction(.start) },library:{ onAction(.library) }).padding(16)
                Spacer()
            }
        }
        .frame(maxWidth:.infinity,maxHeight:.infinity)
        .background(RidgeTheme.paper)
        .foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest)
        .accessibilityElement(children:.contain)
        .accessibilityLabel("Route editor")
    }
    @ViewBuilder private var header: some View {
        if compact, let route {
            HStack(spacing:8) {
                VStack(alignment:.leading,spacing:4) {
                    Text(route.name).font(.headline).lineLimit(2)
                    if busy { ProgressView("Updating route…").font(.caption) }
                    else { Text(summary).font(.caption).foregroundStyle(RidgeTheme.muted) }
                }.frame(maxWidth:.infinity,alignment:.leading)
                routeOptions
                if let dismiss {
                    Button(action:dismiss) { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("Hide route details")
                }
            }.buttonStyle(.plain)
        } else { standardHeader }
    }
    private var routeOptions: some View {
        Menu {
            Button("Before you go",systemImage:"figure.walk") { onAction(.brief) }
            Button("Rename route",systemImage:"pencil") { onAction(.rename) }
            Button("Start another route",systemImage:"plus") { onAction(.start) }.disabled(!pathsReady)
            Button("Saved routes",systemImage:"folder") { onAction(.library) }
            Button("Show entire route",systemImage:"arrow.up.left.and.arrow.down.right") { onAction(.fitRoute) }
        } label: { Image(systemName:"ellipsis").frame(width:44,height:44) }.disabled(busy).accessibilityLabel("Route options")
    }
    private var standardHeader: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Label(editing ? "Route editor" : "Your route",systemImage:"point.topleft.down.to.point.bottomright.curvepath")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength:4)
                if let dismiss {
                    Button(action:dismiss) { Image(systemName:compact ? "xmark" : "sidebar.left").frame(width:44,height:44) }.accessibilityLabel("Hide route details")
                }
                if route != nil {
                    routeOptions
                }
            }
            if let route {
                Text(route.name).font(.title3.weight(.semibold)).fixedSize(horizontal:false,vertical:true)
                if busy { ProgressView("Updating route…").font(.caption) }
                else if !compact { Label(editing ? "Changes saved automatically" : "Saved on this device",systemImage:"checkmark.circle").font(.caption).foregroundStyle(RidgeTheme.muted) }
                if !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(RidgeTheme.muted).fixedSize(horizontal:false,vertical:true) }
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func waypointList(_ route: RidgeRoute) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment:.leading,spacing:0) {
                    HStack {
                        Text("WAYPOINTS").font(.caption.weight(.semibold)).tracking(1)
                        Spacer();Text("\(route.waypoints.count)").font(.caption.monospacedDigit())
                    }.foregroundStyle(RidgeTheme.muted).padding(.horizontal,18).padding(.vertical,14)
                    if route.waypoints.isEmpty {
                        Text(imported ? "This GPX track has no planning waypoints. You can preview the track below." : "Tap the map to snap to the nearest walking path or road.")
                            .font(.subheadline).foregroundStyle(RidgeTheme.muted).padding(18)
                    }
                    ForEach(Array(route.waypoints.enumerated()),id:\.element.id) { index, waypoint in
                        waypointRow(waypoint,index:index,count:route.waypoints.count).id(waypoint.id)
                    }
                    if editing && !imported && !route.waypoints.isEmpty {
                        Label("Tap the map to add your next waypoint",systemImage:"plus.circle")
                            .font(.caption).foregroundStyle(RidgeTheme.muted).padding(18)
                    }
                }
            }.scrollBounceBehavior(.basedOnSize)
            .onChange(of:route.waypoints.last?.id) { _, id in
                if editing,let id { withAnimation(.easeOut(duration:0.2)) { proxy.scrollTo(id,anchor:.bottom) } }
            }
            .onChange(of:selectedWaypoint) { _, id in if let id { withAnimation { proxy.scrollTo(id,anchor:.center) } } }
        }
    }
    private func waypointRow(_ waypoint: RouteWaypoint,index: Int,count: Int) -> some View {
        HStack(spacing:4) {
            Button { onAction(.select(waypoint.id)) } label: {
                HStack(spacing:12) {
                    Text("\(index+1)").font(.caption.weight(.bold)).frame(width:30,height:30)
                        .background(index == 0 ? RidgeTheme.forest : RidgeTheme.selection,in:Circle())
                        .foregroundStyle(index == 0 ? RidgeTheme.paper : RidgeTheme.ink)
                    VStack(alignment:.leading,spacing:4) {
                        Text(waypoint.name ?? (index == 0 ? "Start" : index == count-1 ? "Finish" : "Waypoint \(index+1)"))
                            .font(.subheadline.weight(.medium)).lineLimit(2)
                        if movingWaypoint == waypoint.id { Text("Choose a new position on the map").font(.caption).foregroundStyle(RidgeTheme.orange) }
                        else {
                            Text(waypoint.point.elevation.flatMap { $0.isFinite ? "\(Int($0)) m elevation" : nil } ?? "Elevation unavailable")
                                .font(.caption).foregroundStyle(RidgeTheme.muted)
                        }
                    }
                    Spacer(minLength:0)
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,12).padding(.leading,18)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint("Show this waypoint on the map")
            Menu {
                Button("Show on map",systemImage:"scope") { onAction(.select(waypoint.id)) }
                Button("Preview from here",systemImage:"play.rectangle") { onAction(.preview(waypoint.id)) }.disabled(!previewAvailable)
                if !imported {
                    Button("Move waypoint",systemImage:"arrow.up.left.and.arrow.down.right") { onAction(.move(waypoint.id)) }.disabled(!pathsReady)
                    if index<count-1 {
                        Button("Add a via point after this",systemImage:"plus.circle") { onAction(.insertAfter(waypoint.id)) }.disabled(!pathsReady)
                    }
                    Button("Delete waypoint",systemImage:"trash",role:.destructive) { onAction(.delete(waypoint.id)) }.disabled(!pathsReady)
                }
            } label: { Image(systemName:"ellipsis").frame(width:44,height:44) }.padding(.trailing,8)
                .accessibilityLabel("Options for waypoint \(index+1)")
        }.disabled(busy)
            .background(selectedWaypoint == waypoint.id || movingWaypoint == waypoint.id ? RidgeTheme.selection.opacity(0.55) : Color.clear)
    }
    private func footer(_ route: RidgeRoute) -> some View {
        VStack(spacing:12) {
            if movingWaypoint != nil || inserting {
                HStack(alignment:.top) {
                    Text(inserting ? "Tap the map to add your via point." : "Tap the map to move your waypoint.").font(.caption).foregroundStyle(RidgeTheme.orange)
                    Spacer(minLength:4)
                    Button("Cancel") { onAction(.cancelPlacement) }.font(.caption.weight(.semibold))
                }
            } else if editing && !tour.isPresented && !compact {
                Text("Tap the map to extend your route. Preview whenever you like.").font(.caption).foregroundStyle(RidgeTheme.muted).frame(maxWidth:.infinity,alignment:.leading)
            }
            if !tour.isPresented {
                Button { onAction(.preview(nil)) } label: {
                    Label("Preview route",systemImage:"play.fill").frame(maxWidth:.infinity)
                }.buttonStyle(RidgeButtonStyle()).disabled(!previewAvailable)
                if !previewAvailable && !busy { Text("Add two different points to preview your route.").font(.caption).foregroundStyle(RidgeTheme.muted) }
                Button { onAction(.brief) } label: {
                    Label("Before you go",systemImage:"figure.walk").frame(maxWidth:.infinity)
                }.buttonStyle(RidgeButtonStyle(secondary:true)).disabled(busy)
            }
            if !editing {
                HStack(spacing:12) {
                    if !imported { Button("Edit route",systemImage:"pencil") { onAction(.edit) }.disabled(!pathsReady) }
                    Spacer(minLength:0)
                    Button("Export GPX",systemImage:"square.and.arrow.up") { onAction(.export) }
                }.font(.subheadline).frame(minHeight:44).disabled(busy)
                if !compact { Button("Find this route in Routes",systemImage:"folder") { onAction(.library) }.font(.caption) }
            }
        }
    }
}

/// A bottom action for an empty map; planning never claims a sidebar until a
/// route actually exists. Its overlay does not change the map viewport.
struct WorldRoutePlanPrompt:View {
    var pathsReady:Bool
    var busy:Bool
    var plan:()->Void
    var library:()->Void
    var body:some View {
        HStack(spacing:12) {
            Button(action:plan) {
                Label("Plan your route",systemImage:"plus").frame(maxWidth:.infinity)
            }.buttonStyle(RidgeButtonStyle()).disabled(!pathsReady || busy)
            if !pathsReady { ProgressView().controlSize(.small).accessibilityLabel("Preparing walking paths") }
            Button(action:library) {
                Image(systemName:"folder").frame(width:44,height:44)
            }.accessibilityLabel("Open saved routes").disabled(busy)
        }.padding(10).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14))
    }
}
