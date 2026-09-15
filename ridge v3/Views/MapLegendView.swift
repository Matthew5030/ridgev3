import SwiftUI

/// Both help surfaces describe the same shipped cartography and route style.
struct MapLegendView: View {
    var body: some View {
        VStack(spacing: 17) {
            ForEach(LegendSwatch.Kind.allCases, id: \.self) { kind in
                HStack(spacing: 14) {
                    LegendSwatch(kind: kind).frame(width: 48, height: 31).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.title).font(.system(size: 13, weight: .semibold))
                        Text(kind.detail).font(.system(size: 10)).foregroundStyle(RidgeTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct LegendSwatch: View {
    enum Kind: CaseIterable {
        case contour, path, water, woodland, route
        var title: String {
            switch self {
            case .contour: "Contours"
            case .path: "Paths & bridleways"
            case .water: "Water"
            case .woodland: "Woodland"
            case .route: "Your route"
            }
        }
        var detail: String {
            switch self {
            case .contour: "10 m intervals · heavier lines every 50 m"
            case .path: "Dashed rose and purple lines"
            case .water: "Lakes, streams and watercourses"
            case .woodland: "Pale green mapped areas"
            case .route: "Orange line with a pale border"
            }
        }
    }
    let kind: Kind
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(RidgeTheme.paper))
            switch kind {
            case .water:
                var lake = Path()
                lake.move(to: CGPoint(x: 5, y: 18)); lake.addCurve(to: CGPoint(x: 42, y: 9), control1: CGPoint(x: 9, y: -3), control2: CGPoint(x: 28, y: 23))
                lake.addCurve(to: CGPoint(x: 5, y: 18), control1: CGPoint(x: 35, y: 34), control2: CGPoint(x: 9, y: 28))
                context.fill(lake, with: .color(Color(red: 0.66, green: 0.80, blue: 0.82)))
            case .woodland:
                context.fill(Path(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerRadius: 7), with: .color(Color(red: 0.78, green: 0.85, blue: 0.74)))
            case .contour:
                for index in 0..<3 {
                    var line = Path()
                    let y = CGFloat(5 + index * 9)
                    line.move(to: CGPoint(x: 3, y: y + 4)); line.addCurve(to: CGPoint(x: 45, y: y), control1: CGPoint(x: 20, y: y - 12), control2: CGPoint(x: 30, y: y + 13))
                    context.stroke(line, with: .color(Color(red: 0.66, green: 0.60, blue: 0.49)), lineWidth: index == 1 ? 1.4 : 0.65)
                }
            case .path, .route:
                var line = Path()
                line.move(to: CGPoint(x: 4, y: 23)); line.addCurve(to: CGPoint(x: 44, y: 8), control1: CGPoint(x: 14, y: 0), control2: CGPoint(x: 29, y: 32))
                if kind == .route { context.stroke(line, with: .color(RidgeTheme.panel), style: StrokeStyle(lineWidth: 7, lineCap: .round)) }
                context.stroke(line, with: .color(kind == .route ? RidgeTheme.orange : Color(red: 0.67, green: 0.39, blue: 0.44)), style: StrokeStyle(lineWidth: kind == .route ? 3 : 2, lineCap: .round, dash: kind == .route ? [] : [4, 3]))
            }
        }
    }
}
