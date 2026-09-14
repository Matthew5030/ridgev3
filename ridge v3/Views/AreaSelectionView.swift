import SwiftUI

/// This is only the download selector. Routes are always edited in the 3D scene.
struct AreaSelectionView: View {
    var manifest: RegionManifest
    var directory: URL
    @Binding var selection: AreaSelection
    @State private var origin: CGPoint?
    @State private var firstCorner: CGPoint?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AreaPreview(manifest: manifest, directory: directory)
                Canvas { context, size in
                    let rect = CGRect(x: selection.minU * size.width, y: selection.minV * size.height,
                                      width: (selection.maxU - selection.minU) * size.width, height: (selection.maxV - selection.minV) * size.height)
                    var shade = Path(CGRect(origin: .zero, size: size)); shade.addRect(rect)
                    context.fill(shade, with: .color(RidgeTheme.ink.opacity(0.35)), style: FillStyle(eoFill: true))
                    context.stroke(Path(rect), with: .color(RidgeTheme.paper), lineWidth: 4)
                    context.stroke(Path(rect), with: .color(RidgeTheme.forest), style: StrokeStyle(lineWidth: 1.7, dash: [6, 3]))
                    for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                        context.fill(Path(ellipseIn: CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)), with: .color(RidgeTheme.forest))
                    }
                    let preview = AreaCropper.preview(manifest: manifest, selection: selection)
                    let label = Text(String(format: "%.1f × %.1f km", preview.bounds.widthMeters / 1000, preview.bounds.depthMeters / 1000)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(RidgeTheme.paper)
                    let box = CGRect(x: max(8, min(size.width - 150, rect.midX - 72)), y: min(size.height - 38, max(8, rect.minY + 10)), width: 144, height: 28)
                    context.fill(Path(roundedRect: box, cornerRadius: 9), with: .color(RidgeTheme.forest.opacity(0.93)))
                    context.draw(label, at: CGPoint(x: box.midX, y: box.midY))
                    if let corner = firstCorner {
                        let point = CGPoint(x: corner.x * size.width, y: corner.y * size.height)
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)), with: .color(RidgeTheme.paper))
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)), with: .color(RidgeTheme.forest))
                        context.draw(Text("Tap the opposite corner").font(.system(size: 12, weight: .semibold)).foregroundStyle(RidgeTheme.paper), at: CGPoint(x: size.width / 2, y: size.height - 22))
                    }
                }.contentShape(Rectangle()).highPriorityGesture(DragGesture(minimumDistance: 2).onChanged { value in
                    if origin == nil { origin = value.startLocation; firstCorner = nil }
                    guard let origin, geometry.size.width > 0, geometry.size.height > 0 else { return }
                    let a = CGPoint(x: min(1, max(0, origin.x / geometry.size.width)), y: min(1, max(0, origin.y / geometry.size.height)))
                    let b = CGPoint(x: min(1, max(0, value.location.x / geometry.size.width)), y: min(1, max(0, value.location.y / geometry.size.height)))
                    selection = AreaSelection(minU: min(a.x, b.x), minV: min(a.y, b.y), maxU: max(a.x, b.x), maxV: max(a.y, b.y))
                }.onEnded { _ in origin = nil })
                    .simultaneousGesture(SpatialTapGesture().onEnded { value in
                        guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                        let point = CGPoint(x: min(1, max(0, value.location.x / geometry.size.width)), y: min(1, max(0, value.location.y / geometry.size.height)))
                        if let corner = firstCorner {
                            selection = AreaSelection(minU: min(corner.x, point.x), minV: min(corner.y, point.y), maxU: max(corner.x, point.x), maxV: max(corner.y, point.y))
                            firstCorner = nil
                        } else { firstCorner = point }
                    })
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Area selection rectangle")
            .accessibilityHint("Use actions to select a central quarter or the entire area.")
            .accessibilityAction(named: "Select central quarter") { selection = AreaSelection(minU: 0.25, minV: 0.25, maxU: 0.75, maxV: 0.75) }
            .accessibilityAction(named: "Select whole area") { selection = AreaSelection() }
    }
}
