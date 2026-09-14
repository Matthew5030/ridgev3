import SwiftUI
import UIKit

/// A proposal stays alongside the landscape so the user can inspect its bounds
/// before replacing the finite scene. Choosing a point never saves data by itself.
struct AreaExtensionCard: View {
    @Bindable var store: AppStore
    let currentSpacing: Int
    let maximumHeight: CGFloat
    var compact = false
    @Environment(\.scenePhase) private var scenePhase

    private var canExtend: Bool {
        store.pendingExtension?.unavailableReason == nil &&
        store.extensionManifest != nil && store.extensionAllowance.allowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    if !compact { Eyebrow(text: "Keep exploring") }
                    Text(store.extensionForRoute ? "Add detail along route" : "Add detail here")
                        .font(.system(compact ? .headline : .title2, design: .serif, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
                Button { store.dismissExtension() } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .frame(width: 40, height: 44)
                        .background(RidgeTheme.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(store.extensionInProgress)
                .accessibilityLabel("Close area extension")
            }.padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let proposal = store.pendingExtension {
                        if let reason = proposal.unavailableReason {
                            Label {
                                Text(reason).fixedSize(horizontal: false, vertical: true)
                            } icon: { Image(systemName: "map") }
                            .font(.subheadline).foregroundStyle(RidgeTheme.muted)
                            Text("You can keep exploring the surrounding terrain.")
                                .font(.footnote).foregroundStyle(RidgeTheme.muted)
                        } else if let preview = proposal.preview {
                            areaSummary(additionalTiles: proposal.additionalTileCount)
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Surrounding margin").font(.subheadline.weight(.semibold))
                                Picker("Surrounding margin", selection: Binding(get: { store.extensionMarginMeters }, set: store.setExtensionMargin)) {
                                    Text("250 m").tag(250.0)
                                    Text("500 m").tag(500.0)
                                    Text("1 km").tag(1000.0)
                                    Text("2 km").tag(2000.0)
                                }.pickerStyle(.segmented).disabled(store.extensionInProgress)
                                Text("The outline includes your current area and a rectangle around the new detail. Margins stop at available source coverage.")
                                    .font(.caption).foregroundStyle(RidgeTheme.muted)
                            }

                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    Text("Terrain detail").font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("Metres").font(.caption).foregroundStyle(RidgeTheme.muted)
                                }
                                HStack(spacing: 5) {
                                    ForEach([1, 2, 4, 8, 16, 32], id: \.self) { spacing in
                                        detailButton(spacing, preview: preview)
                                    }
                                }
                                Text("Map detail stays the same.")
                                    .font(.caption).foregroundStyle(RidgeTheme.muted)
                            }

                            if let reason = store.extensionAllowance.reason {
                                Label(reason, systemImage: "info.circle")
                                    .font(.footnote).foregroundStyle(RidgeTheme.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if let error = store.extensionError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(RidgeTheme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 14)
            }.scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 6) {
                if store.pendingExtension?.unavailableReason == nil {
                    // The resolution decision remains visible even when the
                    // choices scroll in a short landscape or accessibility view.
                    Label {
                        Text(store.extensionSpacing == currentSpacing
                             ? "Whole area: \(store.extensionSpacing) m terrain"
                             : "Whole area changes: \(currentSpacing) m → \(store.extensionSpacing) m")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: store.extensionSpacing == currentSpacing ? "mountain.2" : "arrow.triangle.2.circlepath")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(store.extensionSpacing == currentSpacing ? RidgeTheme.forest : RidgeTheme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 3).padding(.bottom, 3)
                    Button { store.confirmExtension() } label: {
                        HStack(spacing: 9) {
                            if store.extensionInProgress { ProgressView().tint(RidgeTheme.panel) }
                            else { Image(systemName: "square.and.arrow.down") }
                            Text(store.extensionInProgress ? "Preparing your area…" : "Save detail · \(store.extensionSpacing) m")
                        }.padding(.horizontal, 12)
                    }
                    .buttonStyle(RidgeButtonStyle())
                    .disabled(!canExtend || store.extensionInProgress || store.isRouting)
                    .opacity(canExtend || store.extensionInProgress ? 1 : 0.45)
                    .accessibilityLabel(store.extensionInProgress ? "Preparing your area" : "Save and extend the whole area at \(store.extensionSpacing) metre terrain spacing")
                    .accessibilityHint("Saves the outlined area at \(store.extensionSpacing) metre terrain spacing.")
                }
                Button("Keep looking") { store.dismissExtension() }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(store.extensionInProgress)
            }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 8)
        .frame(height: store.pendingExtension?.unavailableReason == nil ? maximumHeight : min(maximumHeight, 310))
        .background(RidgeTheme.panel.opacity(0.98), in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
        .overlay { UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28).strokeBorder(RidgeTheme.ink.opacity(0.06)) }
        .onAppear { store.refreshExtensionBudget() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.refreshExtensionBudget() } }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in store.refreshExtensionBudget() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in store.refreshExtensionBudget() }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if scenePhase == .active { store.refreshExtensionBudget() }
            }
        }
    }

    private func areaSummary(additionalTiles: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.extensionManifest.map { String(format: "%.1f km²", $0.bounds.areaSquareKilometers) } ?? "Larger area")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Text("Detailed coverage").font(.caption).foregroundStyle(RidgeTheme.muted)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(store.extensionAllowance.bytesOnDisk > 0 ? RidgeTheme.bytes(store.extensionAllowance.bytesOnDisk) : "—")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                    Text("Estimated total size").font(.caption).foregroundStyle(RidgeTheme.muted)
                }
            }
            Label(store.extensionAllowance.allowed ? "Fits this device’s current budget" : "Choose a smaller area or coarser detail", systemImage: store.extensionAllowance.allowed ? "checkmark.circle.fill" : "info.circle")
                .font(.caption).foregroundStyle(store.extensionAllowance.allowed ? RidgeTheme.forest : RidgeTheme.orange)
            Text("Estimated scene memory: \(RidgeTheme.bytes(store.extensionAllowance.estimatedMemory))")
                .font(.caption).foregroundStyle(RidgeTheme.muted)
            Label("Source pack available on this device", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(RidgeTheme.forest)
            Text(store.activeRoute == nil ? "The outlined area adds detail to your saved landscape." : "The outlined area includes your route. Your sketch stays in place.")
                .font(.footnote).foregroundStyle(RidgeTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailButton(_ spacing: Int, preview: RegionManifest) -> some View {
        let allowance = TerrainBudget.allowance(for: preview, spacing: spacing, context: store.extensionBudgetContext)
        let selected = spacing == store.extensionSpacing
        return Button { store.setExtensionSpacing(spacing) } label: {
            Text("\(spacing) m").font(.system(.caption, design: .rounded, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? RidgeTheme.panel : allowance.allowed ? RidgeTheme.ink : RidgeTheme.muted.opacity(0.5))
                .background(selected ? RidgeTheme.forest : RidgeTheme.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!allowance.allowed || store.extensionInProgress)
        .accessibilityLabel("\(spacing) metre terrain. \(allowance.allowed ? "Available" : "Unavailable for this area")")
        .accessibilityHint(allowance.reason ?? "Select this terrain detail for the whole extended area.")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
