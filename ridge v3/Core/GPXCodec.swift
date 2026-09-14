import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
#endif

enum GPXCodec {
    static let maximumFileBytes = 20 * 1024 * 1024

    static func decode(_ data: Data, regionID: String = "") throws -> RidgeRoute {
        guard !data.isEmpty, data.count <= maximumFileBytes else { throw RouteError.invalidFile("Choose a GPX file smaller than 20 MB.") }
        let delegate = GPXReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let success = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard success, delegate.sawRoot else { throw RouteError.invalidFile("This file is not a valid GPX document.") }
        let segments = delegate.segments.filter { !$0.points.isEmpty }
        guard !segments.isEmpty || !delegate.waypoints.isEmpty else { throw RouteError.invalidFile("This GPX file contains no route, track or waypoint coordinates.") }
        let name = [delegate.trackName, delegate.routeName, delegate.metadataName].compactMap { $0 }.first ?? "Imported route"
        var route = RidgeRoute(name: name, regionID: regionID, waypoints: delegate.waypoints, segments: segments, notes: delegate.descriptionText ?? "")
        if route.segments.isEmpty {
            // GPX waypoints are independent locations. Never invent connecting lines between them.
            route.segments = route.waypoints.map { RouteSegment(points: [$0.point], mode: "imported") }
        }
        try RouteEngine.validate(route)
        return route
    }

    static func encode(_ route: RidgeRoute) throws -> Data {
        try RouteEngine.validate(route)
        var parts = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<gpx version=\"1.1\" creator=\"Ridge\" xmlns=\"http://www.topografix.com/GPX/1/1\">", "  <metadata><name>\(escape(route.name))</name></metadata>"]
        for waypoint in route.waypoints {
            parts.append("  <wpt lat=\"\(decimal(waypoint.point.coordinate.latitude))\" lon=\"\(decimal(waypoint.point.coordinate.longitude))\">")
            if let elevation = waypoint.point.elevation { parts.append("    <ele>\(decimal(elevation))</ele>") }
            if let name = waypoint.name, !name.isEmpty { parts.append("    <name>\(escape(name))</name>") }
            parts.append("  </wpt>")
        }
        let segments = route.segments.isEmpty ? route.waypoints.map { RouteSegment(points: [$0.point], mode: "direct") } : route.segments
        if !segments.isEmpty {
            parts.append("  <trk>")
            parts.append("    <name>\(escape(route.name))</name>")
            if !route.notes.isEmpty { parts.append("    <desc>\(escape(route.notes))</desc>") }
            for segment in segments where !segment.points.isEmpty {
                parts.append("    <trkseg>")
                for point in segment.points {
                    let elevation = point.elevation.map { "<ele>\(decimal($0))</ele>" } ?? ""
                    parts.append("      <trkpt lat=\"\(decimal(point.coordinate.latitude))\" lon=\"\(decimal(point.coordinate.longitude))\">\(elevation)</trkpt>")
                }
                parts.append("    </trkseg>")
            }
            parts.append("  </trk>")
        }
        parts.append("</gpx>")
        let data = Data(parts.joined(separator: "\n").utf8)
        guard data.count <= maximumFileBytes else { throw RouteError.invalidFile("This route is too large to export as one GPX file.") }
        return data
    }

    static func read(from url: URL, regionID: String = "") throws -> RidgeRoute {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumFileBytes) else { throw RouteError.invalidFile("Choose a GPX file smaller than 20 MB.") }
        return try decode(Data(contentsOf: url), regionID: regionID)
    }

    private static func decimal(_ number: Double) -> String {
        String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), number)
    }

    private static func escape(_ value: String) -> String {
        // XML 1.0 permits tabs, newlines and carriage returns, but no other C0 controls.
        let valid = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value)
        }))
        return valid.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class GPXReader: NSObject, XMLParserDelegate {
    var failure: RouteError?
    var sawRoot = false
    var segments: [RouteSegment] = []
    var waypoints: [RouteWaypoint] = []
    var trackName: String?
    var routeName: String?
    var metadataName: String?
    var descriptionText: String?
    private var path: [String] = []
    private var textStack: [String] = []
    private var currentPoints: [RoutePoint]?
    private var point: RoutePoint?
    private var pointName: String?
    private var pointCount = 0
    private let allowedNamespaces: Set<String> = ["", "http://www.topografix.com/GPX/1/1", "http://www.topografix.com/GPX/1/0"]

    private func fail(_ parser: XMLParser, _ error: RouteError) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard path.count < 32 else { fail(parser, .invalidFile("This GPX file is nested too deeply.")); return }
        let parent = path.last
        // Extensions may reuse GPX element names; keep them outside the recognised structural paths.
        let element = allowedNamespaces.contains(namespaceURI ?? "") ? elementName : "extension:\(elementName)"
        path.append(element)
        textStack.append("")
        if path.count == 1 {
            guard element == "gpx" else { fail(parser, .invalidFile("This file is not a GPX document.")); return }
            sawRoot = true
        }
        if path == ["gpx", "trk", "trkseg"] || path == ["gpx", "rte"] {
            guard currentPoints == nil, segments.count < 10_000 else { fail(parser, .tooManyPoints); return }
            currentPoints = []
        }
        let isTrackPoint = path == ["gpx", "trk", "trkseg", "trkpt"]
        let isRoutePoint = path == ["gpx", "rte", "rtept"]
        let isWaypoint = path == ["gpx", "wpt"]
        if isTrackPoint || isRoutePoint || isWaypoint {
            guard point == nil, let lat = attributeDict["lat"].flatMap(Double.init), let lon = attributeDict["lon"].flatMap(Double.init) else { fail(parser, .invalidCoordinate); return }
            let coordinate = GeoPoint(latitude: lat, longitude: lon)
            guard coordinate.isValid else { fail(parser, .invalidCoordinate); return }
            pointCount += 1
            guard pointCount <= RouteEngine.maximumRoutePoints else { fail(parser, .tooManyPoints); return }
            point = RoutePoint(coordinate: coordinate, elevation: nil)
            pointName = nil
        } else if ["trkpt", "rtept", "wpt"].contains(element), !path.contains(where: { $0.hasPrefix("extension:") }), parent != "extensions" {
            // Silently ignoring a misplaced coordinate could import an incomplete route.
            fail(parser, .invalidFile("This GPX file has coordinates outside a valid track or route."))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !textStack.isEmpty else { return }
        guard textStack[textStack.count - 1].utf8.count + string.utf8.count <= 100_000 else { fail(parser, .invalidFile("This GPX file contains an oversized text field.")); return }
        textStack[textStack.count - 1].append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { fail(parser, .invalidFile("This GPX file contains invalid text.")); return }
        self.parser(parser, foundCharacters: string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !path.isEmpty, let text = textStack.popLast()?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        defer { path.removeLast() }
        let isPointChild = path.count >= 3 && ["trkpt", "rtept", "wpt"].contains(path[path.count - 2])
        if isPointChild, path.last == "ele", point != nil {
            guard let elevation = Double(text), elevation.isFinite else { fail(parser, .invalidFile("This GPX file contains an invalid elevation.")); return }
            point?.elevation = elevation
        }
        if isPointChild, path.last == "name", point != nil {
            guard text.count <= 160 else { fail(parser, .invalidFile("A GPX waypoint name is longer than 160 characters.")); return }
            pointName = text.isEmpty ? nil : text
        }
        if path == ["gpx", "trk", "trkseg", "trkpt"] || path == ["gpx", "rte", "rtept"] {
            guard let point else { fail(parser, .invalidCoordinate); return }
            currentPoints?.append(point)
            self.point = nil
        } else if path == ["gpx", "wpt"] {
            guard let point else { fail(parser, .invalidCoordinate); return }
            waypoints.append(RouteWaypoint(point: point, name: pointName))
            self.point = nil
        }
        if path == ["gpx", "trk", "trkseg"] || path == ["gpx", "rte"] {
            if let currentPoints, !currentPoints.isEmpty { segments.append(RouteSegment(points: currentPoints, mode: "imported")) }
            currentPoints = nil
        }
        if path == ["gpx", "trk", "name"] || path == ["gpx", "rte", "name"] || path == ["gpx", "metadata", "name"] {
            guard text.count <= 160 else { fail(parser, .invalidName); return }
            if !text.isEmpty {
                if path[1] == "trk", trackName == nil { trackName = text }
                if path[1] == "rte", routeName == nil { routeName = text }
                if path[1] == "metadata", metadataName == nil { metadataName = text }
            }
        }
        if path == ["gpx", "trk", "desc"] || path == ["gpx", "rte", "desc"] {
            if descriptionText == nil, !text.isEmpty { descriptionText = text }
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser, .invalidFile("GPX files with custom XML entities are not supported."))
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail(parser, .invalidFile("GPX files with external XML entities are not supported."))
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail(parser, .invalidFile("GPX files cannot load external resources."))
        return nil
    }
}

#if canImport(SwiftUI)
extension UTType {
    static var ridgeGPX: UTType { UTType(filenameExtension: "gpx") ?? UTType(importedAs: "com.topografix.gpx", conformingTo: .xml) }
}

struct GPXDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.ridgeGPX, .xml] }
    static var writableContentTypes: [UTType] { [.ridgeGPX] }
    var data: Data

    init(route: RidgeRoute) throws { data = try GPXCodec.encode(route) }
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= GPXCodec.maximumFileBytes else { throw RouteError.invalidFile("Choose a GPX file smaller than 20 MB.") }
        _ = try GPXCodec.decode(data)
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif
