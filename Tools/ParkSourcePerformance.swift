import Foundation
import CryptoKit

@main struct ParkSourcePerformance {
    static func report(_ value: String) { try? FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8)) }
    static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let server = CommandLine.arguments.dropFirst(2).first(where: { $0.hasPrefix("http") }).flatMap(URL.init(string:))
        let retainedRoot = ProcessInfo.processInfo.environment["RIDGE_PROFILE_ROOT"]
        let working = retainedRoot.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("ridge-park-profile-\(UUID())")
        defer { if retainedRoot == nil { try? FileManager.default.removeItem(at: working) } }
        let sourceRoot = server == nil ? source.deletingLastPathComponent() : working.appendingPathComponent("sources")
        let packs = PackStore(root: working.appendingPathComponent("areas"), bundledDirectory: nil, sourceDirectory: sourceRoot)
        let begin = ContinuousClock.now
        if let server { _ = try await packs.connectSourceServer(server) }
        guard let entry = try await packs.catalogue().first(where: { $0.id == source.lastPathComponent }) else { throw RidgeError.message("Source not found") }
        report(String(format: "Source catalogue: %.3fs", seconds(begin)))
        let sites: [(String, GeoPoint)] = [
            ("Yr Wyddfa", GeoPoint(latitude: 53.0685, longitude: -4.0763)),
            ("Tryfan", GeoPoint(latitude: 53.1140, longitude: -3.9975)),
            ("Rhinog Fawr", GeoPoint(latitude: 52.8540, longitude: -4.0094)),
            ("Cadair Idris", GeoPoint(latitude: 52.6996, longitude: -3.9088))
        ]
        var identities = Set<String>()
        for (name, point) in sites {
            if server != nil && name != "Cadair Idris" { continue }
            let t = ContinuousClock.now
            guard let bounds = AtlasAreaPlanner.tile(at: point, entries: [entry]) else { throw RidgeError.message("No selectable tile at \(name)") }
            let proposal = AtlasAreaPlanner.propose(bounds: bounds, entries: [entry], spacing: 4)
            guard proposal.canOpen, let selection = proposal.selection else { throw RidgeError.message("\(name): \(proposal.reason ?? "No selection")") }
            let previewTime = seconds(t)
            if CommandLine.arguments.contains("--preview-only") {
                report(String(format: "%@: preview %.3fs", name, previewTime)); continue
            }
            let downloadStart = ContinuousClock.now
            let downloaded = try await packs.downloadSelection(from: entry, selection: selection, spacing: 4) { value in
                if value == 1 { report("Selected downloads complete") }
            }
            if server != nil { report(String(format: "Download phase: %.3fs", seconds(downloadStart))) }
            let cropStart = ContinuousClock.now
            let crop = try AreaCropper.prepare(directory: entry.directory, manifest: entry.manifest, selection: selection, spacing: 4, cartographySourceID: entry.id, downloadedPreview: downloaded)
            defer { try? FileManager.default.removeItem(at: crop.directory) }
            let cropTime = seconds(cropStart), installStart = ContinuousClock.now
            try await packs.install(from: crop.directory, manifest: crop.manifest, spacing: 4) { _ in }
            let installTime = seconds(installStart), loadStart = ContinuousClock.now
            let loaded = try await packs.load(id: crop.manifest.id)
            let loadTime = seconds(loadStart)
            guard loaded.manifest.bounds.contains(point), let height = loaded.elevation(at: point), height.isFinite else { throw RidgeError.message("Invalid selected terrain at \(name)") }
            guard identities.insert(loaded.level.sha256).inserted else { throw RidgeError.message("Different locations reused identical terrain") }
            report(String(format: "%@: preview %.3fs, crop %.3fs, install %.3fs, load %.3fs; %.1fm; %d map tiles; %d graph nodes", name, previewTime, cropTime, installTime, loadTime, height, loaded.cartography?.metadata.tiles.count ?? 0, loaded.graph?.nodes.count ?? 0))
            if server != nil {
                var offline = entry; offline.remoteSource = URL(string: "http://127.0.0.1:9/eryri-park")!
                let offlineStart = ContinuousClock.now
                _ = try await packs.downloadSelection(from: offline, selection: selection, spacing: 4) { _ in }
                let fresh = PackStore(root: working.appendingPathComponent("areas"), bundledDirectory: nil, sourceDirectory: sourceRoot)
                let reopened = try await fresh.load(id: crop.manifest.id)
                guard reopened.heights == loaded.heights else { throw RidgeError.message("Cached area changed while reopening offline") }
                report(String(format: "Cached selection and fresh-store reopen with unreachable download URL: %.3fs", seconds(offlineStart)))
                if let retainedRoot { report("Retained verified download cache: " + retainedRoot) }
            }
        }
        report(CommandLine.arguments.contains("--preview-only") ? "PASS: four real park selection previews" : server != nil ? "PASS: real Docker download, normal terrain loading and offline cache reuse" : "PASS: distinct real terrain at four sites across Eryri, through the normal loader")
    }
}
