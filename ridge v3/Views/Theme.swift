import SwiftUI

enum RidgeTheme {
    static let paper = Color(red: 0.965, green: 0.955, blue: 0.926)
    static let panel = Color(red: 0.995, green: 0.989, blue: 0.971)
    static let ink = Color(red: 0.12, green: 0.20, blue: 0.18)
    static let muted = Color(red: 0.40, green: 0.46, blue: 0.42)
    static let forest = Color(red: 0.17, green: 0.32, blue: 0.27)
    static let lime = Color(red: 0.83, green: 0.91, blue: 0.57)
    static let orange = Color(red: 0.86, green: 0.29, blue: 0.14)
    static let line = Color(red: 0.83, green: 0.85, blue: 0.79)
    static let ocean = Color(red: 0.85, green: 0.90, blue: 0.88)
    static func distance(_ meters: Double) -> String { meters >= 1000 ? String(format: "%.1f", meters / 1000) : String(format: "%.0f", meters) }
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

struct RidgeButtonStyle: ButtonStyle {
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .background(secondary ? RidgeTheme.ink.opacity(0.06) : RidgeTheme.forest)
            .foregroundStyle(secondary ? RidgeTheme.ink : RidgeTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct RoundControl: View {
    var symbol: String
    var label: String
    var active = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 46)
                .foregroundStyle(active ? RidgeTheme.paper : RidgeTheme.ink)
                .background(active ? RidgeTheme.forest : RidgeTheme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(RidgeTheme.ink.opacity(0.06)))
        }.accessibilityLabel(label)
    }
}

struct Eyebrow: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.8).foregroundStyle(RidgeTheme.muted) }
}

struct TerrainGlyph: View {
    var color: Color = RidgeTheme.forest
    var body: some View {
        Canvas { context, size in
            for index in 0..<8 {
                let inset = CGFloat(index) * 4
                let rect = CGRect(x: inset, y: inset * 0.6, width: max(1, size.width - inset * 2), height: max(1, size.height - inset * 1.2))
                var path = Path()
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY * 0.78))
                path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.7), control1: CGPoint(x: rect.width * 0.17 + rect.minX, y: rect.minY - 8), control2: CGPoint(x: rect.width * 0.62 + rect.minX, y: rect.minY - 4))
                path.addCurve(to: CGPoint(x: rect.minX, y: rect.maxY * 0.78), control1: CGPoint(x: rect.maxX - 8, y: rect.maxY + 10), control2: CGPoint(x: rect.minX + 14, y: rect.maxY + 4))
                context.stroke(path, with: .color(color.opacity(0.8)), lineWidth: 1)
            }
        }
    }
}
