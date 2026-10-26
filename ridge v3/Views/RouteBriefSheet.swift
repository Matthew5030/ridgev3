import SwiftUI

/// On-demand trip details keep the map and the preview free of extra panels.
struct RouteBriefSheet: View {
    @Bindable var store: AppStore
    let initialRoute: RidgeRoute
    var savedBounds: [GeoBounds]
    var coverageRevision: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage private var planData: Data
    @State private var brief: RouteTripBrief?
    @State private var coverage: RouteOfflineCoverage?
    @State private var newItem = ""
    @State private var notes = ""
    @State private var notesLoaded = false
    @State private var confirmClose = false
    @State private var closeAfterSaving = false
    @State private var notesSaveFailed = false
    @State private var exportDocument: GPXDocument?
    @State private var exporting = false
    @State private var exportError: String?
    private var route: RidgeRoute {
        if let active = store.activeRoute, active.id == initialRoute.id { return active }
        return store.routes.first { $0.id == initialRoute.id } ?? initialRoute
    }
    private var plan: RouteTripPlan { RouteTripPlan.decode(planData) ?? .init() }
    private var calculationID: String { "\(route.id)|\(route.modifiedAt.timeIntervalSince1970)|\(coverageRevision)" }

    init(store: AppStore, route: RidgeRoute, savedBounds: [GeoBounds], coverageRevision: Int) {
        self.store = store; initialRoute = route; self.savedBounds = savedBounds; self.coverageRevision = coverageRevision
        _planData = AppStorage(wrappedValue: Data(), RouteTripPlan.storageKey(for: route.id))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(route.name).font(RidgeTheme.pageTitle).fixedSize(horizontal: false, vertical: true)
                    if RouteTripPlan.decode(planData) == nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("The saved walking preferences couldn’t be read. Your route and notes are still saved.")
                            Button("Reset walking preferences") { planData = Data() }
                        }.font(.subheadline).padding(16).background(RidgeTheme.selection, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if let brief {
                        summary(brief)
                        timing(brief.statistics)
                        maps
                        itinerary(brief)
                    } else { ProgressView("Preparing route details…").frame(maxWidth: .infinity).padding(24) }
                    checklist
                    notesCard
                    Button { exportRoute() } label: {
                        Label("Export route as GPX", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }.buttonStyle(RidgeButtonStyle(secondary: true))
                    if let exportError { Text(exportError).font(.footnote).foregroundStyle(RidgeTheme.orange) }
                    Text("Your timing preferences, checklist and notes stay on this device. GPX exports contain the route and its notes.")
                        .font(.footnote).foregroundStyle(RidgeTheme.muted)
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .background(RidgeTheme.paper).foregroundStyle(RidgeTheme.ink)
            .navigationTitle("Before you go").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { if notes != route.notes { confirmClose = true } else { dismiss() } } } }
            .interactiveDismissDisabled(notes != route.notes || store.isRouting)
            .confirmationDialog("Save your note changes?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Save notes and close") { closeAfterSaving = true; notesSaveFailed = false; store.updateNotes(notes, for: route) }.disabled(store.isRouting)
                Button("Discard note changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) { }
            }
            .task(id: calculationID) {
                let snapshot = route, bounds = savedBounds
                let installed = store.containingEntry(for: snapshot)?.installed == true
                let result = await Task.detached(priority: .userInitiated) {
                    (RouteTripBrief(route: snapshot), RouteEngine.offlineCoverage(for: snapshot, in: bounds))
                }.value
                guard !Task.isCancelled else { return }
                brief = result.0
                coverage = installed ? .init(openingPoint: snapshot.points.first?.coordinate, isComplete: true) : result.1
            }
            .onAppear { if !notesLoaded { notes = route.notes; notesLoaded = true } }
            .onChange(of: route.notes) { _, value in
                if closeAfterSaving, value == notes { dismiss() }
                notes = value
            }
            .onChange(of: store.isRouting) { _, busy in
                if !busy, closeAfterSaving {
                    if notes == route.notes { dismiss() }
                    else { closeAfterSaving = false; notesSaveFailed = true }
                }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .ridgeGPX, defaultFilename: route.name) { result in
                if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { exportError = error.localizedDescription }
            }
        }.tint(RidgeTheme.forest).presentationDetents([.large])
    }
    private func updatePlan(_ change: (inout RouteTripPlan) -> Void) {
        guard var value = RouteTripPlan.decode(planData) else { return }
        change(&value)
        if let data = try? JSONEncoder().encode(value) { planData = data }
    }
    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(RidgeTheme.panel, in: RoundedRectangle(cornerRadius: 14))
    }
    private func summary(_ brief: RouteTripBrief) -> some View {
        card("Your walk", symbol: "figure.walk") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { summaryMetrics(brief) }
                VStack(alignment: .leading, spacing: 16) { summaryMetrics(brief) }
            }
            Text(brief.statistics.distanceMeters <= 1 ? "Add another point to estimate your walk" : brief.returnsToStart ? "Finishes within 25 m of the start" : "Different start and finish")
                .font(.caption).foregroundStyle(RidgeTheme.muted)
            if !brief.statistics.hasCompleteElevation {
                Text("Some elevations are missing. The time estimate includes only known climbing.")
                    .font(.footnote).foregroundStyle(RidgeTheme.muted)
            }
        }
    }
    @ViewBuilder private func summaryMetrics(_ brief: RouteTripBrief) -> some View {
        metric("Distance", value: "\(RidgeTheme.distance(brief.statistics.distanceMeters)) \(brief.statistics.distanceMeters >= 1000 ? "km" : "m")")
        metric("Ascent", value: brief.statistics.hasElevation ? "\(Int(brief.statistics.ascentMeters.rounded())) m" : "Unavailable")
        metric("Time estimate", value: RouteTripPlan.duration(plan.totalMinutes(for: brief.statistics)))
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(RidgeTheme.muted)
            Text(value).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
    private func timing(_ statistics: RouteStatistics) -> some View {
        card("Your timing", symbol: "clock") {
            Stepper(value: Binding(get: { plan.walkingKilometersPerHour }, set: { value in updatePlan { $0.walkingKilometersPerHour = value } }), in: 2...6, step: 0.5) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Walking pace")
                    Text(String(format: "%.1f km/h", plan.walkingKilometersPerHour)).font(.subheadline.monospacedDigit()).foregroundStyle(RidgeTheme.muted)
                }
            }.accessibilityIdentifier("trip.walkingPace")
            Stepper(value: Binding(get: { plan.breakMinutes }, set: { value in updatePlan { $0.breakMinutes = value } }), in: 0...180, step: 5) {
                Text("Breaks: \(plan.breakMinutes) min").monospacedDigit()
            }.accessibilityIdentifier("trip.breaks")
            Toggle("Set a start time", isOn: Binding(get: { plan.departure != nil }, set: { enabled in updatePlan { $0.departure = enabled ? Date() : nil } }))
            if let departure = plan.departure {
                DatePicker("Start", selection: Binding(get: { plan.departure ?? departure }, set: { value in updatePlan { $0.departure = value } }), displayedComponents: [.date, .hourAndMinute])
                if let finish = plan.finish(for: statistics) {
                    LabeledContent("Estimated finish") { Text(finish, format: .dateTime.day().month(.abbreviated).hour().minute()).monospacedDigit() }
                }
            }
            Text("Walking time uses your pace plus 1 hour per 600 m of ascent, then adds your breaks. Terrain, weather and stops can change it. This doesn’t change the fly-through speed.")
                .font(.footnote).foregroundStyle(RidgeTheme.muted)
        }.disabled(RouteTripPlan.decode(planData) == nil)
    }
    private var maps: some View {
        card("Saved maps", symbol: "map") {
            if let coverage {
                Label(coverage.isComplete ? "Maps saved along this route" : coverage.openingPoint != nil ? "Only part of this route has saved maps" : "This route needs map downloads",
                      systemImage: coverage.isComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(coverage.isComplete ? RidgeTheme.forest : RidgeTheme.orange)
                Text(coverage.isComplete ? "The saved terrain is available without a connection." : "Download the missing area in Explore before going offline.")
                    .font(.subheadline).foregroundStyle(RidgeTheme.muted)
            } else { ProgressView("Checking route coverage…") }
        }
    }
    private func itinerary(_ brief: RouteTripBrief) -> some View {
        card("Itinerary", symbol: "point.topleft.down.to.point.bottomright.curvepath") {
            ForEach(brief.legs) { leg in
                VStack(alignment: .leading, spacing: 8) {
                    if leg.id != brief.legs.first?.id { Divider() }
                    Text("\(leg.from) → \(leg.to)").font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("\(RidgeTheme.distance(leg.statistics.distanceMeters)) \(leg.statistics.distanceMeters >= 1000 ? "km" : "m") · \(RouteTripPlan.duration(plan.walkingMinutes(for: leg.statistics))) walking")
                        .font(.subheadline).monospacedDigit().foregroundStyle(RidgeTheme.muted)
                    if leg.statistics.hasElevation {
                        Text("↑ \(Int(leg.statistics.ascentMeters.rounded())) m  ↓ \(Int(leg.statistics.descentMeters.rounded())) m")
                            .font(.caption).foregroundStyle(RidgeTheme.muted)
                    }
                    if leg.startsNewTrack {
                        Text("Separate GPX section. The gap isn’t included in distance or time.").font(.caption).foregroundStyle(RidgeTheme.muted)
                    }
                }.accessibilityElement(children: .combine)
            }
            if brief.legs.isEmpty { Text("Add another point to build your itinerary.").font(.subheadline).foregroundStyle(RidgeTheme.muted) }
            Text("Leg times exclude your planned breaks.").font(.footnote).foregroundStyle(RidgeTheme.muted)
        }
    }
    private var checklist: some View {
        card("Your checklist", symbol: "checklist") {
            Text("\(plan.checklist.filter(\.completed).count) of \(plan.checklist.count) checked")
                .font(.caption).foregroundStyle(RidgeTheme.muted)
            ForEach(plan.checklist) { item in
                HStack(alignment: .top, spacing: 8) {
                    Button {
                        updatePlan { value in if let i = value.checklist.firstIndex(where: { $0.id == item.id }) { value.checklist[i].completed.toggle() } }
                    } label: {
                        Label(item.title, systemImage: item.completed ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.completed ? RidgeTheme.forest : RidgeTheme.ink)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityValue(item.completed ? "Checked" : "Not checked")
                    Button(role: .destructive) { updatePlan { $0.checklist.removeAll { $0.id == item.id } } } label: {
                        Image(systemName: "minus.circle").foregroundStyle(RidgeTheme.muted).frame(width: 44, height: 44)
                    }.accessibilityLabel("Remove \(item.title)")
                }
            }
            if plan.checklist.count < 40 {
                HStack {
                    TextField("Add your own item", text: $newItem).onSubmit(addItem).submitLabel(.done)
                    Button(action: addItem) { Image(systemName: "plus.circle.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel("Add checklist item").disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if plan.checklist.contains(where: \.completed) {
                Button("Uncheck all for another walk") { updatePlan { value in for i in value.checklist.indices { value.checklist[i].completed = false } } }
                    .font(.subheadline).frame(minHeight: 44)
            }
        }.disabled(RouteTripPlan.decode(planData) == nil)
    }
    private func addItem() { updatePlan { $0.addItem(newItem) }; newItem = "" }
    private var notesCard: some View {
        card("Route notes", symbol: "note.text") {
            Text("Parking, meeting point, places to stop—anything you want to remember.").font(.subheadline).foregroundStyle(RidgeTheme.muted)
            TextEditor(text: $notes).frame(minHeight: typeSize.isAccessibilitySize ? 220 : 120)
                .scrollContentBackground(.hidden).padding(8).background(RidgeTheme.paper, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Route notes").onChange(of: notes) { _, value in if value.count > 20_000 { notes = String(value.prefix(20_000)) } }
            Button { store.updateNotes(notes, for: route) } label: {
                Text(store.isRouting ? "Saving…" : notes == route.notes ? "Notes saved" : "Save notes").frame(minHeight: 44)
            }.disabled(store.isRouting || notes == route.notes)
            if notes != route.notes { Text("Tap Save notes to keep your changes.").font(.caption).foregroundStyle(RidgeTheme.muted) }
            if notesSaveFailed { Text("The notes haven’t saved. Try again before closing.").font(.caption).foregroundStyle(RidgeTheme.orange) }
        }
    }
    private func exportRoute() {
        do { exportDocument = try GPXDocument(route: route); exportError = nil; exporting = true }
        catch { exportError = error.localizedDescription }
    }
}
