import SwiftUI

/// Public support destinations, also used on the App Store product page.
/// Feedback opens the user's mail app without attaching route or diagnostic data.
struct RidgeSupportSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Help and feedback").font(RidgeTheme.sectionTitle)
            Link(destination: URL(string: "https://bilellaworks.com/apps/ridge/support/")!) {
                Label("Help with Ridge", systemImage: "questionmark.circle")
                    .frame(minHeight: 44, alignment: .leading)
            }
            Link(destination: URL(string: "https://bilellaworks.com/apps/ridge/privacy/")!) {
                Label("Privacy policy", systemImage: "hand.raised")
                    .frame(minHeight: 44, alignment: .leading)
            }
            Link(destination: URL(string: "mailto:bilellaworks@gmail.com?subject=Ridge%20feedback")!) {
                Label("Send feedback", systemImage: "envelope")
                    .frame(minHeight: 44, alignment: .leading)
            }
            Text("Free during early access. Feedback is welcome and optional. Your routes and diagnostics are not attached automatically.")
                .font(.caption).foregroundStyle(RidgeTheme.muted)
        }
        .font(.body.weight(.medium)).tint(RidgeTheme.forest)
    }
}
