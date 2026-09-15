import SwiftUI

enum RidgeTheme {
    static let paper = Color(red: 0.96, green: 0.97, blue: 0.965)
    static let panel = Color(red: 0.995, green: 0.997, blue: 0.993)
    static let ink = Color(red: 0.12, green: 0.20, blue: 0.18)
    static let muted = Color(red: 0.36, green: 0.41, blue: 0.38)
    static let forest = Color(red: 0.17, green: 0.32, blue: 0.27)
    static let selection = Color(red: 0.84, green: 0.89, blue: 0.85)
    static let orange = Color(red: 0.86, green: 0.29, blue: 0.14)
    static let line = Color(red: 0.84, green: 0.87, blue: 0.85)
    static let ocean = Color(red: 0.85, green: 0.90, blue: 0.88)
    static let pageTitle = Font.system(.title, design: .default, weight: .semibold)
    static let sectionTitle = Font.system(.title3, design: .default, weight: .semibold)
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 10
    static func distance(_ meters: Double) -> String { meters >= 1000 ? String(format: "%.1f", meters / 1000) : String(format: "%.0f", meters) }
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

struct RidgeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var secondary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(secondary ? RidgeTheme.ink.opacity(0.06) : RidgeTheme.forest)
            .foregroundStyle(secondary ? RidgeTheme.ink : RidgeTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
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
                .background(active ? RidgeTheme.forest : RidgeTheme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: RidgeTheme.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: RidgeTheme.controlRadius).strokeBorder(RidgeTheme.ink.opacity(0.06)))
        }.accessibilityLabel(label)
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(RidgeTheme.muted) }
}
