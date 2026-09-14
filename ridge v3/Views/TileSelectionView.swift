import SwiftUI

/// The selectable unit is an existing precision tile. Camera movement changes
/// only this local preview; it never requests or refines terrain.
struct TileSelectionView: View {
    let manifest: RegionManifest
    let directory: URL
    @Binding var selection: AreaSelection
    @State private var rectangleMode = false
    @State private var anchor: TerrainCell?
    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var initialOffset: CGSize?
    @State private var initialZoom: CGFloat?

    private var grid: TerrainGrid { manifest.grid! }
    private var selectedGrid: TerrainGrid? { grid.cropped(to: selection) }
    private var selectedCount: Int { (selectedGrid?.columns ?? 0) * (selectedGrid?.rows ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 3) {
                    modeButton("One tile", symbol: "square", rectangle: false)
                    modeButton("Rectangle", symbol: "rectangle.dashed", rectangle: true)
                }.padding(4).background(RidgeTheme.ink.opacity(0.04), in: Capsule())
                Spacer(minLength: 4)
                Text("N ↑").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(RidgeTheme.muted)
            }
            GeometryReader { geometry in
                ZStack {
                    RidgeTheme.paper
                    AreaPreview(manifest: manifest, directory: directory)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(zoom).offset(offset)
                    Canvas { context, size in drawGrid(context: &context, size: size) }
                        .contentShape(Rectangle())
                        .highPriorityGesture(DragGesture(minimumDistance: 5).onChanged { value in
                            if initialOffset == nil { initialOffset = offset }
                            let start = initialOffset ?? .zero
                            offset = clamped(CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height), size: geometry.size)
                        }.onEnded { _ in initialOffset = nil }, including: zoom > 1.001 ? .all : .none)
                        .simultaneousGesture(MagnifyGesture().onChanged { value in
                            if initialZoom == nil { initialZoom = zoom }
                            zoom = min(6, max(1, (initialZoom ?? zoom) * value.magnification))
                            offset = clamped(offset, size: geometry.size)
                        }.onEnded { _ in initialZoom = nil })
                        .simultaneousGesture(SpatialTapGesture().onEnded { value in
                            guard let cell = cell(at: value.location, size: geometry.size) else { return }
                            if rectangleMode {
                                if let start = anchor {
                                    if let rectangle = grid.rectangle(from: start, to: cell) { selection = rectangle }
                                    anchor = nil
                                } else {
                                    anchor = cell
                                    if let chosen = grid.selection(column: cell.column, row: cell.row) { selection = chosen }
                                }
                            } else if let chosen = grid.selection(column: cell.column, row: cell.row) { selection = chosen }
                        })
                    VStack {
                        Spacer()
                        HStack {
                            Text(anchor == nil ? (rectangleMode ? "Tap two corner tiles" : "Tap a tile to select it") : "Now tap the opposite corner tile")
                                .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 10)
                                .background(RidgeTheme.panel.opacity(0.96), in: Capsule())
                            Spacer(minLength: 0)
                            HStack(spacing: 0) {
                                Button { changeZoom(zoom / 1.6, size: geometry.size) } label: { Image(systemName: "minus").frame(width: 40, height: 42) }.accessibilityLabel("Zoom out of tile grid")
                                Button { changeZoom(zoom * 1.6, size: geometry.size) } label: { Image(systemName: "plus").frame(width: 40, height: 42) }.accessibilityLabel("Zoom into selected tiles")
                            }.font(.system(size: 14, weight: .semibold)).background(RidgeTheme.panel.opacity(0.96), in: Capsule())
                        }.padding(10)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 22))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Precision tile grid, \(grid.columns) columns by \(grid.rows) rows. \(selectedCount) \(selectedCount == 1 ? "tile" : "tiles") selected.")
                    .accessibilityAction(named: "Select central tile") {
                        selection = grid.selection(column: grid.columns / 2, row: grid.rows / 2) ?? selection
                    }
                    .accessibilityAction(named: "Select whole grid") { selection = AreaSelection() }
            }.aspectRatio(1, contentMode: .fit)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedCount == 1 ? "1 tile selected" : "\(selectedGrid?.columns ?? 0) × \(selectedGrid?.rows ?? 0) tiles selected")
                        .font(.system(size: 16, weight: .semibold))
                    if let selectedGrid {
                        Text(selectedCount == 1 ? (selectedGrid.cellName(column: 0, row: 0) ?? "Precision tile") : "\(selectedCount) original precision tiles")
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(RidgeTheme.muted)
                    }
                }
                Spacer()
                Button("All tiles") { selection = AreaSelection(); anchor = nil; zoom = 1; offset = .zero }
                    .font(.system(size: 12, weight: .semibold)).padding(.vertical, 8)
            }
        }
    }

    private func modeButton(_ title: String, symbol: String, rectangle: Bool) -> some View {
        Button { rectangleMode = rectangle; anchor = nil } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11).padding(.vertical, 10)
                .foregroundStyle(rectangleMode == rectangle ? RidgeTheme.paper : RidgeTheme.muted)
                .background(rectangleMode == rectangle ? RidgeTheme.forest : .clear, in: Capsule())
        }.accessibilityAddTraits(rectangleMode == rectangle ? .isSelected : [])
    }

    private func screen(u: Double, v: Double, size: CGSize) -> CGPoint {
        CGPoint(x: (u - 0.5) * size.width * zoom + size.width / 2 + offset.width,
                y: (v - 0.5) * size.height * zoom + size.height / 2 + offset.height)
    }

    private func cell(at point: CGPoint, size: CGSize) -> TerrainCell? {
        let u = (point.x - size.width / 2 - offset.width) / (size.width * zoom) + 0.5
        let v = (point.y - size.height / 2 - offset.height) / (size.height * zoom) + 0.5
        guard u >= 0, v >= 0, u <= 1, v <= 1 else { return nil }
        return TerrainCell(column: min(grid.columns - 1, Int(u * Double(grid.columns))), row: min(grid.rows - 1, Int(v * Double(grid.rows))))
    }

    private func clamped(_ value: CGSize, size: CGSize) -> CGSize {
        let x = size.width * (zoom - 1) / 2, y = size.height * (zoom - 1) / 2
        return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
    }

    private func changeZoom(_ value: CGFloat, size: CGSize) {
        zoom = min(6, max(1, value))
        offset = clamped(CGSize(width: (0.5 - (selection.minU + selection.maxU) / 2) * size.width * zoom,
                                height: (0.5 - (selection.minV + selection.maxV) / 2) * size.height * zoom), size: size)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let top = screen(u: 0, v: 0, size: size), bottom = screen(u: 1, v: 1, size: size)
        let a = screen(u: selection.minU, v: selection.minV, size: size), b = screen(u: selection.maxU, v: selection.maxV, size: size)
        let selected = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        var shade = Path(CGRect(x: top.x, y: top.y, width: bottom.x - top.x, height: bottom.y - top.y)); shade.addRect(selected)
        context.fill(shade, with: .color(RidgeTheme.ink.opacity(0.18)), style: FillStyle(eoFill: true))
        for column in 0...grid.columns {
            let x = screen(u: Double(column) / Double(grid.columns), v: 0, size: size).x
            var line = Path(); line.move(to: CGPoint(x: x, y: top.y)); line.addLine(to: CGPoint(x: x, y: bottom.y))
            context.stroke(line, with: .color(RidgeTheme.forest.opacity((grid.originColumn + column) % 4 == 0 ? 0.55 : 0.3)), lineWidth: 0.75)
        }
        for row in 0...grid.rows {
            let y = screen(u: 0, v: Double(row) / Double(grid.rows), size: size).y
            var line = Path(); line.move(to: CGPoint(x: top.x, y: y)); line.addLine(to: CGPoint(x: bottom.x, y: y))
            context.stroke(line, with: .color(RidgeTheme.forest.opacity((grid.originRow + row) % 4 == 0 ? 0.55 : 0.3)), lineWidth: 0.75)
        }
        if size.width * zoom / CGFloat(grid.columns) >= 48 {
            for row in 0..<grid.rows { for column in 0..<grid.columns {
                let p = screen(u: (Double(column) + 0.15) / Double(grid.columns), v: (Double(row) + 0.2) / Double(grid.rows), size: size)
                guard CGRect(origin: .zero, size: size).contains(p) else { continue }
                context.draw(Text("\(grid.originColumn + column)·\(grid.originRow + row)").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(RidgeTheme.forest), at: p, anchor: .leading)
            } }
        }
        drawPlaces(context: &context, size: size)
        context.fill(Path(selected), with: .color(RidgeTheme.lime.opacity(0.16)))
        context.stroke(Path(selected), with: .color(RidgeTheme.paper), lineWidth: 5)
        context.stroke(Path(selected), with: .color(RidgeTheme.forest), lineWidth: 2.5)
        if selected.width > 20 && selected.height > 20 {
            let p = CGPoint(x: selected.maxX - 10, y: selected.maxY - 10)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(RidgeTheme.forest))
            context.draw(Text("✓").font(.system(size: 9, weight: .bold)).foregroundStyle(RidgeTheme.paper), at: p)
        }
    }

    private func drawPlaces(context: inout GraphicsContext, size: CGSize) {
        let priority = ["Yr Wyddfa", "Crib Goch", "Tryfan", "Glyder Fawr"]
        let places = manifest.places.filter { $0.kind == "peak" }.sorted {
            (priority.firstIndex(of: $0.name) ?? 100) < (priority.firstIndex(of: $1.name) ?? 100)
        }
        var occupied: [CGRect] = []
        for place in places {
            let uv = manifest.bounds.uv(place.coordinate), p = screen(u: uv.u, v: uv.v, size: size)
            guard CGRect(origin: .zero, size: size).insetBy(dx: 35, dy: 20).contains(p) else { continue }
            let text = context.resolve(Text(place.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(RidgeTheme.ink))
            let measured = text.measure(in: CGSize(width: 120, height: 20))
            let box = CGRect(x: p.x - measured.width / 2 - 4, y: p.y - 18, width: measured.width + 8, height: 18)
            guard !occupied.contains(where: { $0.insetBy(dx: -8, dy: -8).intersects(box) }) else { continue }
            occupied.append(box)
            context.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(RidgeTheme.paper.opacity(0.92)))
            context.draw(text, at: CGPoint(x: box.midX, y: box.midY))
            context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(RidgeTheme.forest))
        }
    }
}
