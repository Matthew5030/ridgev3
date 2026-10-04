import SwiftUI

/// Matches the flat-surface lighting baked by Tools/world_atlas/build.py.
/// Use the same truncated 8-bit channels as the JPEG generator so its outer
/// ocean pages blend into the unbounded atlas canvas without a rectangular edge.
enum WorldAtlasPalette {
    private static let flatLight = pow(0.4 + 0.6 * sin(0.8), 1 / 2.2)
    private static func channel(_ value: Double) -> Double { floor(value * flatLight) / 255 }
    static let land = Color(red: channel(237), green: channel(233), blue: channel(217))
    static let sea = Color(red: channel(168), green: channel(203), blue: channel(209))
}
