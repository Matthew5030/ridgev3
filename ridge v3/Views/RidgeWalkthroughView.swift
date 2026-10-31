import SwiftUI

/// Versioned independently of app releases, so routine updates do not repeat the guide.
enum RidgeWalkthrough {
    static let version = 1
    static let completedVersionKey = "ridge.walkthrough.completedVersion"
}

struct RidgeWalkthroughView: View {
    var isReplay = false
    var onFinish: () -> Void
    @State private var page = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    private let steps = WalkthroughStep.allCases

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "mountain.2").font(.title3.weight(.semibold))
                    Text("Ridge").font(.title3.weight(.semibold))
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityElement(children: .ignore).accessibilityLabel("Ridge")
                Spacer()
                Button(isReplay ? "Close" : "Skip", action: onFinish)
                    .font(.body.weight(.medium)).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(isReplay ? "Close walkthrough" : "Skip walkthrough and explore the map")
            }
            .padding(.horizontal, 24).padding(.top, 8)

            TabView(selection: $page) {
                ForEach(steps) { step in
                    GeometryReader { geometry in
                        let wide = geometry.size.width >= 740 && !dynamicType.isAccessibilitySize
                        ScrollView {
                            Group {
                                if wide {
                                    HStack(spacing: 40) {
                                        WalkthroughMap(step: step)
                                            .frame(width: min(480, geometry.size.width * 0.47), height: min(440, max(200, geometry.size.height - 48)))
                                        explanation(step).frame(maxWidth: 380)
                                    }
                                } else {
                                    VStack(alignment: .leading, spacing: 26) {
                                        if !dynamicType.isAccessibilitySize {
                                            WalkthroughMap(step: step)
                                                .frame(height: min(310, max(180, geometry.size.height * 0.48)))
                                        }
                                        explanation(step)
                                    }
                                    .frame(maxWidth: 480)
                                }
                            }
                            .padding(.horizontal, 24).padding(.vertical, 20)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                    .tag(step.rawValue)
                    .accessibilityIdentifier("walkthrough.page.\(step.rawValue)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 16) {
                HStack(spacing: 7) {
                    ForEach(steps) { step in
                        Capsule().fill(step.rawValue == page ? RidgeTheme.forest : RidgeTheme.line)
                            .frame(width: step.rawValue == page ? 22 : 7, height: 7)
                    }
                    Spacer()
                    Text("\(page + 1) of \(steps.count)").font(.caption.monospacedDigit()).foregroundStyle(RidgeTheme.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(page + 1) of \(steps.count)")
                HStack(spacing: 16) {
                    if page > 0 {
                        Button("Back") { select(page - 1) }
                            .font(.body.weight(.medium)).frame(minWidth: 54, minHeight: 52)
                            .accessibilityIdentifier("walkthrough.back")
                    }
                    Button {
                        if page == steps.count - 1 { onFinish() } else { select(page + 1) }
                    } label: {
                        Text(page == steps.count - 1 ? (isReplay ? "Done" : "Start exploring") : page == 0 ? "Show me around" : "Continue")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(RidgeTheme.panel).background(RidgeTheme.forest, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityIdentifier("walkthrough.continue")
                }
            }
            .frame(maxWidth: 480).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)
        }
        .background(RidgeTheme.paper.ignoresSafeArea())
        .foregroundStyle(RidgeTheme.ink).tint(RidgeTheme.forest).preferredColorScheme(.light)
    }

    private func explanation(_ step: WalkthroughStep) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if step == .explore && !dynamicType.isAccessibilitySize {
                Text("FREE DURING EARLY ACCESS")
                    .font(.caption.weight(.semibold)).tracking(1)
                    .foregroundStyle(RidgeTheme.forest)
            }
            Text(step.title).font(.largeTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(step.detail).font(.body).foregroundStyle(RidgeTheme.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            Label(step.tip, systemImage: step.symbol)
                .font(.subheadline).foregroundStyle(RidgeTheme.forest)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            if step == .explore && dynamicType.isAccessibilitySize {
                Text("Free during early access.").font(.body).foregroundStyle(RidgeTheme.forest)
            }
        }
    }
    private func select(_ next: Int) {
        if reduceMotion { page = next }
        else { withAnimation(.easeInOut(duration: 0.24)) { page = next } }
    }
}

private enum WalkthroughStep: Int, CaseIterable, Identifiable {
    case explore, offline, plan, preview
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .explore: return "Find your next walk."
        case .offline: return "Take the map with you."
        case .plan: return "Make it your route."
        case .preview: return "See the journey ahead."
        }
    }
    var detail: String {
        switch self {
        case .explore: return "Search for a place, then pinch to zoom. In a saved area, keep zooming to glide into 3D."
        case .offline: return WorldBundledMaps.downloadsEnabled ? "Choose an area and download its terrain and walking paths before heading out. Saved maps work without a signal." : "Eryri, the Lake District, Peak District and Chilterns & Thames Valley are included. Their terrain and walking paths are ready without a download or a signal."
        case .plan: return "Tap Plan your route, then tap the map to add waypoints. Open route details to edit your stops and see the elevation."
        case .preview: return "Tap Preview route for a fly-through of your walk. Scrub along the elevation profile to explore a section, then return to editing."
        }
    }
    var tip: String {
        switch self {
        case .explore: return "One finger to move. Two fingers to tilt or turn."
        case .offline: return WorldBundledMaps.downloadsEnabled ? "See the download size before you start." : "Zoom into an included area and start planning."
        case .plan: return "Find your saved walks in Routes."
        case .preview: return "Drag to look around. Let go to rejoin the glide."
        }
    }
    var symbol: String {
        switch self {
        case .explore: return "hand.draw"
        case .offline: return "arrow.down.circle"
        case .plan: return "folder"
        case .preview: return "play.circle"
        }
    }
}

/// Small instructional overlays on the real bundled map. No network, 3D scene,
/// downloads, location prompts or saved-route changes are needed for this guide.
private struct WalkthroughMap: View {
    let step: WalkthroughStep
    private let center = CGPoint(x: (180 - 4.08) / 360, y: (1 - asinh(tan(53.07 * Double.pi / 180)) / Double.pi) / 2)
    private let stops = [CGPoint(x: 0.17, y: 0.75), CGPoint(x: 0.43, y: 0.47), CGPoint(x: 0.78, y: 0.24)]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                RidgeTheme.selection
                WorldAtlasLayer(center: center, scale: max(size.width, size.height) * 1600, size: size)
                if step == .offline {
                    RoundedRectangle(cornerRadius: 20).fill(RidgeTheme.forest.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(RidgeTheme.forest, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
                        .frame(width: size.width * 0.68, height: size.height * 0.62)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48, weight: .medium)).foregroundStyle(RidgeTheme.forest, RidgeTheme.panel)
                }
                if step == .plan || step == .preview {
                    route(in: size)
                    ForEach(stops.indices, id: \.self) { index in
                        Text("\(index + 1)").font(.caption.weight(.bold))
                            .frame(width: 29, height: 29).background(RidgeTheme.panel, in: Circle())
                            .overlay(Circle().strokeBorder(RidgeTheme.orange, lineWidth: 2))
                            .position(x: stops[index].x * size.width, y: stops[index].y * size.height)
                    }
                }
                VStack {
                    HStack {
                        Label(step == .plan || step == .preview ? "Example route" : "Eryri / Snowdonia", systemImage: "map")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RidgeTheme.panel.opacity(0.96), in: Capsule())
                        Spacer(minLength: 0)
                    }
                    Spacer()
                    if step == .preview {
                        Image(systemName: "play.fill").font(.title2)
                            .foregroundStyle(RidgeTheme.panel).frame(width: 62, height: 62)
                            .background(RidgeTheme.forest, in: Circle())
                        Spacer()
                    }
                    Label(step == .explore ? "Pinch to explore" : step == .offline ? "Saved on this device" : step == .plan ? "Plan your route" : "Preview your walk",
                          systemImage: step == .explore ? "plus.magnifyingglass" : step == .offline ? "checkmark.circle.fill" : step == .plan ? "plus" : "play.fill")
                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 12)
                        .background(RidgeTheme.panel.opacity(0.96), in: Capsule())
                    Text("© OpenStreetMap contributors · Welsh Government OGL v3\nNatural Earth · Mapzen · Copernicus Sentinel 2025")
                        .font(.system(size: 8)).multilineTextAlignment(.center)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(RidgeTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
                }.padding(14)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(RidgeTheme.ink.opacity(0.06)))
        .dynamicTypeSize(.large)
        .accessibilityHidden(true)
    }
    private func route(in size: CGSize) -> some View {
        let path = Path { path in
            path.move(to: CGPoint(x: size.width * 0.17, y: size.height * 0.75))
            path.addCurve(to: CGPoint(x: size.width * 0.43, y: size.height * 0.47),
                          control1: CGPoint(x: size.width * 0.36, y: size.height * 0.74), control2: CGPoint(x: size.width * 0.25, y: size.height * 0.50))
            path.addCurve(to: CGPoint(x: size.width * 0.78, y: size.height * 0.24),
                          control1: CGPoint(x: size.width * 0.66, y: size.height * 0.43), control2: CGPoint(x: size.width * 0.56, y: size.height * 0.20))
        }
        return path.stroke(RidgeTheme.panel, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            .overlay(path.stroke(RidgeTheme.orange, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round)))
    }
}

#Preview { RidgeWalkthroughView {} }
