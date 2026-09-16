import SwiftUI
import ImageIO

/// Library previews use only local map images. No heightfields, scene or network requests.
struct LibraryMapPreview: View {
    let entry: PackEntry?
    let route: RidgeRoute?
    let packs: PackStore
    @State private var preview: LibraryMapImage?
    private var identity: String { "\(entry?.directory.path ?? "none")|\(entry?.id ?? "none")|\(entry?.installed == true)|\(route?.id.uuidString ?? "area")|\(route?.modifiedAt.timeIntervalSince1970 ?? 0)" }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RidgeTheme.paper
            if let preview {
                Image(uiImage: preview.image).resizable().aspectRatio(contentMode: .fit)
                if !preview.hasMap {
                    Text(route == nil ? "Map preview unavailable" : "Route outline · map not saved")
                        .font(.caption).padding(8).background(RidgeTheme.panel.opacity(0.94), in: Capsule()).padding(12)
                }
            } else { ProgressView().tint(RidgeTheme.forest).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .aspectRatio(1.5, contentMode: .fit)
        .clipped()
        .accessibilityLabel(route.map { "Map preview of \($0.name)" } ?? "Saved area map preview")
        .onDisappear { preview = nil }
        .task(id: identity) {
            preview = nil
            let resolved: PackEntry?
            if let entry { resolved = (try? await packs.previewMap(for: entry)) ?? entry } else { resolved = nil }
            guard !Task.isCancelled else { return }
            let result = await LibraryMapRenderer.shared.preview(entry: resolved, route: route, key: identity)
            if !Task.isCancelled { preview = result }
        }
    }
}

private final class LibraryMapImage: NSObject, @unchecked Sendable {
    let image: UIImage
    let hasMap: Bool
    init(image: UIImage, hasMap: Bool) { self.image = image; self.hasMap = hasMap }
}

/// Serial, bounded thumbnail work keeps a grid of cards from decoding maps at once.
private actor LibraryMapRenderer {
    static let shared = LibraryMapRenderer()
    private let cache = NSCache<NSString, LibraryMapImage>()
    init() { cache.totalCostLimit = 24 * 1_024 * 1_024; cache.countLimit = 24 }

    func preview(entry: PackEntry?, route: RidgeRoute?, key: String) -> LibraryMapImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let paths = route.map { $0.segments.isEmpty ? [$0.waypoints.map(\.point)] : $0.segments.map(\.points) } ?? []
        let coordinates = paths.flatMap { $0.map(\.coordinate) }.filter(\.isValid)
        let bounds: GeoBounds
        if let first = coordinates.first {
            bounds = GeoBounds(minLatitude: coordinates.map(\.latitude).min() ?? first.latitude,
                               minLongitude: coordinates.map(\.longitude).min() ?? first.longitude,
                               maxLatitude: coordinates.map(\.latitude).max() ?? first.latitude,
                               maxLongitude: coordinates.map(\.longitude).max() ?? first.longitude)
        } else if let entry { bounds = entry.manifest.bounds }
        else { return nil }
        let viewport = bounds.libraryPreviewBounds(aspect: 1.5, padding: route == nil ? 1 : 1.25, cropToFill: route == nil)
        let size = CGSize(width: 720, height: 480)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        var hasMap = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            UIColor(red: 0.94, green: 0.95, blue: 0.90, alpha: 1).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            func position(_ point: GeoPoint) -> CGPoint {
                let uv = viewport.uv(point)
                return CGPoint(x: uv.u * size.width, y: uv.v * size.height)
            }
            if let entry {
                var maps: [(MapTexture, Int)] = []
                if let overview = entry.manifest.adaptive?.overview ?? entry.manifest.tiledTerrain?.overview { maps.append((overview, 0)) }
                maps += entry.manifest.textures.map { ($0, 0) }
                if let atlas = entry.manifest.cartography {
                    maps += atlas.tiles.filter { $0.image.bounds.intersects(viewport) }.map { ($0.image, CartographyAtlas.gutter) }
                }
                for (texture, gutter) in maps where texture.bounds.intersects(viewport) {
                    if Task.isCancelled { return }
                    autoreleasepool {
                        let url = entry.directory.appendingPathComponent(texture.file)
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return }
                        let a = position(GeoPoint(latitude: texture.bounds.maxLatitude, longitude: texture.bounds.minLongitude))
                        let b = position(GeoPoint(latitude: texture.bounds.minLatitude, longitude: texture.bounds.maxLongitude))
                        let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                        let margin = Double(gutter) / Double(max(1, texture.width - 2 * gutter))
                        context.saveGState(); context.clip(to: rect); context.interpolationQuality = .high
                        UIImage(cgImage: cgImage).draw(in: rect.insetBy(dx: -rect.width * margin, dy: -rect.height * margin))
                        context.restoreGState(); hasMap = true
                    }
                }
            }
            // Draw separate imported segments separately; never invent a joining leg.
            context.setLineCap(.round); context.setLineJoin(.round)
            for points in paths {
                let line = CGMutablePath()
                var previous: CGPoint?
                for (index, point) in points.enumerated() where point.coordinate.isValid {
                    let p = position(point.coordinate)
                    if let previous {
                        if hypot(p.x - previous.x, p.y - previous.y) < 1 && index != points.count - 1 { continue }
                        line.addLine(to: p)
                    } else { line.move(to: p) }
                    previous = p
                }
                context.addPath(line); context.setStrokeColor(UIColor.white.withAlphaComponent(0.95).cgColor); context.setLineWidth(8); context.strokePath()
                context.addPath(line); context.setStrokeColor(UIColor(red: 0.86, green: 0.27, blue: 0.12, alpha: 1).cgColor); context.setLineWidth(4); context.strokePath()
            }
            for (index, point) in [coordinates.first, coordinates.last].compactMap({ $0 }).enumerated() {
                let p = position(point), radius = index == 0 ? 9.0 : 6.0
                context.setFillColor((index == 0 ? UIColor(red: 0.16, green: 0.34, blue: 0.29, alpha: 1) : UIColor(red: 0.86, green: 0.27, blue: 0.12, alpha: 1)).cgColor)
                context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(3)
                context.addEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)); context.drawPath(using: .fillStroke)
            }
        }
        guard !Task.isCancelled else { return nil }
        let result = LibraryMapImage(image: image, hasMap: hasMap)
        if hasMap { cache.setObject(result, forKey: key as NSString, cost: 720 * 480 * 4) }
        return result
    }
}
