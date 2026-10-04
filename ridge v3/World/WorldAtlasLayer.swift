import SwiftUI
import ImageIO

/// Low-cost overhead imagery only; detailed terrain previews are drawn above it.
struct WorldAtlasLayer: View {
    let center: CGPoint
    let scale: CGFloat
    let size: CGSize
    @State private var loader = WorldAtlasLoader()
    @Environment(\.displayScale) private var displayScale
    private var viewport: WorldAtlasViewport { WorldAtlasViewport(x: center.x, y: center.y, scale: scale, width: size.width, height: size.height, pixelScale: displayScale) }
    var body: some View {
        Canvas { context, _ in
            for item in loader.pages {
                let n = item.page.divisions
                let rect = CGRect(x: (Double(item.page.x) / n - center.x) * scale + size.width / 2,
                                  y: (Double(item.page.y) / n - center.y) * scale + size.height / 2,
                                  width: scale / n, height: scale / n)
                // Half-point overlap prevents hairline cracks between filtered neighbouring pages.
                context.draw(Image(decorative: item.image, scale: 1), in: rect.insetBy(dx: -0.25, dy: -0.25))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { loader.request(viewport) }
        .onChange(of: viewport) { _, value in loader.request(value) }
        .onDisappear { loader.discardPending() }
    }
}

private struct WorldAtlasViewport: Hashable, Sendable {
    let x: CGFloat, y: CGFloat, scale: CGFloat, width: CGFloat, height: CGFloat, pixelScale: CGFloat
}

/// Finish a batch even during a continuous gesture, then use the newest viewport.
/// Cancelling a load on every animation frame can prevent any page being published.
@Observable @MainActor private final class WorldAtlasLoader {
    var pages: [WorldAtlasImage] = []
    @ObservationIgnored private let store = WorldAtlasImages()
    @ObservationIgnored private var pending: WorldAtlasViewport?
    @ObservationIgnored private var working = false
    func request(_ viewport: WorldAtlasViewport) {
        pending = viewport
        guard !working else { return }
        working = true
        Task {
            if pages.isEmpty, let initial = pending {
                pages = await store.images(viewport: initial, coarseOnly: true)
            }
            while let viewport = pending {
                pending = nil
                pages = await store.images(viewport: viewport)
            }
            working = false
        }
    }
    func discardPending() { pending = nil }
}

private struct WorldAtlasImage: @unchecked Sendable {
    let page: WorldAtlasPage
    let image: CGImage
}

/// File reads and JPEG decoding never run on the UI thread. The cache holds at
/// most 96 decoded 256px pages (24 MiB); a previous viewport can temporarily retain
/// up to another 24 MiB while its replacement is being prepared.
private actor WorldAtlasImages {
    private var root: URL?
    private var index: WorldAtlasIndex?
    private var attempted = false
    private var cache: [WorldAtlasPage: CGImage] = [:]
    private var recency: [WorldAtlasPage] = []
    func images(viewport: WorldAtlasViewport, coarseOnly: Bool = false) -> [WorldAtlasImage] {
        if !attempted {
            attempted = true
            root = Bundle.main.url(forResource: "WorldAtlas", withExtension: "bundle")
            if let root, let data = try? Data(contentsOf: root.appendingPathComponent("index.json")) { index = try? WorldAtlasIndex(data: data) }
        }
        guard let root, let index else { return [] }
        let requested = index.pages(centerX: viewport.x, centerY: viewport.y, scale: viewport.scale, width: viewport.width, height: viewport.height, pixelScale: viewport.pixelScale, coarseOnly: coarseOnly)
        var result: [WorldAtlasImage] = []
        for page in requested {
            guard !Task.isCancelled else { return [] }
            if cache[page] == nil {
                let url = root.appendingPathComponent(page.key)
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: index.tileSize,
                    kCGImageSourceShouldCacheImmediately: true
                   ] as CFDictionary) { cache[page] = image }
            }
            if let image = cache[page] {
                result.append(WorldAtlasImage(page: page, image: image))
                recency.removeAll { $0 == page }; recency.append(page)
                while recency.count > 96 { cache.removeValue(forKey: recency.removeFirst()) }
            }
        }
        return result
    }
}
